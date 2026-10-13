import concurrent.futures
import hashlib
import importlib.util
import json
import os
import pwd
import pty
import select
import subprocess
import sys
import tempfile
import termios
import types
import unittest
import uuid
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
AUTH = (ROOT / "webshell-auth.sh").read_text().rsplit('\nmain "$@"', 1)[0]
spec = importlib.util.spec_from_file_location("social", ROOT / "tools/social.py")
social = importlib.util.module_from_spec(spec)
spec.loader.exec_module(social)


def shell(command, **environment):
    return subprocess.run(["sh", "-c", AUTH + "\n" + command], text=True,
                          input="", capture_output=True,
                          env=dict(os.environ, **environment), timeout=10)


class AuthenticationTests(unittest.TestCase):
    def test_existing_account_mapping(self):
        account = "d113f1f9-d222-4637-8109-5bbd494248c3"
        result = shell('generate_username "$ACCOUNT"', ACCOUNT=account)
        self.assertEqual(result.stdout.strip(), "user_" + hashlib.md5(account.encode()).hexdigest()[:10])

    def test_uuid_validation(self):
        self.assertEqual(shell('valid_id "$ACCOUNT"', ACCOUNT=str(uuid.uuid4())).returncode, 0)
        for value in ("", "x", "../../root", str(uuid.uuid4()) + "extra"):
            self.assertNotEqual(shell('valid_id "$ACCOUNT"', ACCOUNT=value).returncode, 0)

    def test_password_is_data_not_source(self):
        stub = '''
import os, sys, types
module = types.ModuleType("passlib.hash")
class Verifier:
    @staticmethod
    def verify(password, hash_value):
        return password == os.environ["EXPECTED"] and hash_value == "testhash"
module.sha512_crypt = Verifier
sys.modules["passlib"] = types.ModuleType("passlib")
sys.modules["passlib.hash"] = module
'''
        command = '''
getent() { printf 'user:testhash:0:0:0:0:0:0:0\\n'; }
python3() { shift; shift; "$PYTHON" -c "$STUB
$1"; }
verify_password user "$PASSWORD"
'''
        for password in ("normal-password", "''' ; raise SystemExit(0); #", 'quotes" $HOME \\'):
            result = shell(command, PASSWORD=password, EXPECTED=password,
                           STUB=stub, PYTHON=sys.executable)
            self.assertEqual(result.returncode, 0, result.stderr)
            result = shell(command, PASSWORD=password, EXPECTED="wrong",
                           STUB=stub, PYTHON=sys.executable)
            self.assertNotEqual(result.returncode, 0)

    @unittest.skipUnless(importlib.util.find_spec("passlib"), "passlib not installed")
    def test_real_sha512_verification(self):
        from passlib.hash import sha512_crypt
        password = "quotes''' $HOME \\\\"
        hashed = sha512_crypt.using(rounds=1000).hash(password)
        command = '''
getent() { printf 'user:%s:0:0:0:0:0:0:0\\n' "$HASH"; }
verify_password user "$PASSWORD"
'''
        for candidate, succeeds in ((password, True), ("wrong", False)):
            result = shell(command, HASH=hashed, PASSWORD=candidate)
            self.assertEqual(result.returncode == 0, succeeds, result.stderr)
        self.assertNotEqual(shell(command, HASH="!", PASSWORD=password).returncode, 0)

    def test_password_prompt_masks_input_and_restores_terminal(self):
        master, slave = pty.openpty()
        original = termios.tcgetattr(slave)
        # Slow setup exposes the race when input arrives immediately at the prompt.
        command = '''
stty() { if [ "$1" = -g ]; then sleep 0.3; fi; command stty "$@"; }
read_password 'Password: ' || exit 1
printf 'VALUE=%s\\n' "$REPLY"
'''
        process = subprocess.Popen(["sh", "-c", AUTH + "\n" + command],
                                   stdin=slave, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            prompt = b""
            while b"Password: " not in prompt:
                self.assertTrue(select.select([process.stdout], [], [], 5)[0],
                                "Password prompt did not arrive")
                chunk = os.read(process.stdout.fileno(), 4096)
                self.assertTrue(chunk, "Exited before password prompt")
                prompt += chunk
            self.assertFalse(termios.tcgetattr(slave)[3] & termios.ECHO,
                             "Password echo is still enabled at the prompt")
            password = b"  quotes''' $HOME \\  "
            os.write(master, password + b"\n")
            output, error = process.communicate(timeout=5)
            self.assertEqual(process.returncode, 0, error)
            self.assertIn(b"VALUE=" + password + b"\n", output)
            self.assertFalse(select.select([master], [], [], 0.1)[0],
                             "Password was echoed to the terminal")
            self.assertEqual(termios.tcgetattr(slave), original)
        finally:
            if process.poll() is None:
                process.terminate()
                process.wait(timeout=5)
            process.stdout.close()
            process.stderr.close()
            os.close(master)
            os.close(slave)

    def test_client_ip_cannot_bypass_login(self):
        result = shell('''
id() { echo 0; }
handle_login() { echo authentication-required; return 1; }
main
''', CLIENT_IP=str(uuid.uuid4()))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("authentication-required", result.stdout)

    def test_failed_limits_refuse_session(self):
        result = shell('''
id() { echo 0; }
handle_login() { USERNAME=user_test; }
set_quota() { return 1; }
setup_cgroup() { echo should-not-run; }
main
''')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Login refused", result.stdout)
        self.assertNotIn("should-not-run", result.stdout)

    def test_disabled_or_failed_quota_refuses_setup(self):
        result = shell('''
quotaon() { echo 'user quota on / is off'; }
setquota() { echo should-not-run; }
set_quota user_test
''')
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("should-not-run", result.stdout)
        result = shell('''
quotaon() { echo 'user quota on / is on'; }
setquota() { return 1; }
set_quota user_test
''')
        self.assertNotEqual(result.returncode, 0)

    def test_vm_launcher_uses_repo_disk_and_local_ports(self):
        with tempfile.TemporaryDirectory() as directory:
            fake = Path(directory) / "qemu-system-x86_64"
            fake.write_text('#!/bin/sh\nprintf "%s\\n" "$@"\n')
            fake.chmod(0o755)
            repository = Path(directory) / "repository"
            repository.mkdir()
            (repository / "run.sh").write_bytes((ROOT / "run.sh").read_bytes())
            (repository / "webshell.qcow2").write_bytes(b"test disk")
            result = subprocess.run(["sh", str(repository / "run.sh")],
                                    cwd=directory, text=True, capture_output=True, timeout=10,
                                    env=dict(os.environ, PATH=directory + ":" + os.environ["PATH"]))
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn(f"file={repository}/webshell.qcow2,format=qcow2,if=virtio", result.stdout)
            self.assertIn("hostfwd=tcp:127.0.0.1:8080-:8080", result.stdout)

    def test_missing_cgroup_controllers_fail(self):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            (base / "cgroup.controllers").write_text("memory cpu pids")
            result = shell('CGROUP_BASE="$BASE"; setup_cgroup test', BASE=directory)
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse((base / "webshell_test/memory.max").exists())

    def test_account_cgroup_is_readable_under_private_umask(self):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            (base / "cgroup.controllers").write_text("memory cpu pids")
            account = base / "webshell_test"
            account.mkdir(mode=0o700)
            for name in ("memory.max", "memory.swap.max", "cpu.max", "pids.max", "cgroup.procs"):
                (account / name).write_text("")
            result = shell('umask 077; CGROUP_BASE="$BASE"; setup_cgroup test', BASE=directory)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(account.stat().st_mode & 0o777, 0o755)
            self.assertEqual((account / "memory.max").read_text().strip(), "104857600")

    def test_shared_symlink_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            (base / "target").mkdir(mode=0o700)
            (base / "shared").symlink_to(base / "target", target_is_directory=True)
            result = shell('SHARED_DIR="$SHARED"; setup_environment user_test',
                           SHARED=str(base / "shared"))
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual((base / "target").stat().st_mode & 0o777, 0o700)

    def test_eof_ends_login(self):
        self.assertNotEqual(shell("handle_login").returncode, 0)


class SocialTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.user = pwd.getpwuid(os.getuid()).pw_name
        (self.root / self.user).mkdir()
        self.store = social.Store(self.root)

    def test_identity_ignores_environment(self):
        with patch.dict(os.environ, {"USER": "root"}):
            self.assertEqual(social.Store(self.root).user, self.user)

    def test_post_like_comment_and_delete(self):
        post_id = self.store.write("post", "Hello")
        self.store.write("like", target=post_id)
        self.store.write("like", target=post_id)
        self.store.write("comment", "A comment", post_id)
        post = self.store.feed()[0]
        self.assertEqual(post["text"], "Hello")
        self.assertEqual(len(post["likes"]), 1)
        self.assertEqual(post["comments"][0]["text"], "A comment")
        self.store.write("delete", target=post_id)
        self.assertEqual(self.store.feed(), [])
        self.assertEqual(len(list((self.root / self.user).glob("*.json"))), 5)

    def test_concurrent_posts_do_not_overwrite(self):
        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as executor:
            ids = list(executor.map(lambda number: self.store.write("post", str(number)), range(32)))
        self.assertEqual(len(set(ids)), 32)
        self.assertEqual(len(self.store.feed()), 32)

    def test_concurrent_comments_are_not_lost(self):
        post_id = self.store.write("post", "Hello")
        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as executor:
            list(executor.map(lambda number: self.store.write("comment", str(number), post_id), range(24)))
        self.assertEqual(len(self.store.feed()[0]["comments"]), 24)

    def test_malformed_oversized_and_symlink_records_are_skipped(self):
        directory = self.root / self.user
        for data in ("{", "[]", '{"kind": []}', "[" * 2000 + "]" * 2000,
                     "x" * (social.MAX_RECORD + 1)):
            (directory / f"{uuid.uuid4()}.json").write_text(data)
        target = self.root / "secret"
        target.write_text(json.dumps({"kind": "post", "text": "secret"}))
        (directory / f"{uuid.uuid4()}.json").symlink_to(target)
        self.store.write("post", "Visible")
        self.assertEqual([post["text"] for post in self.store.feed()], ["Visible"])

    def test_record_author_cannot_be_spoofed(self):
        post_id = self.store.write("post", "Hello")
        file = self.root / self.user / f"{post_id}.json"
        record = json.loads(file.read_text())
        record.update(user="root", uid=0, timestamp="broken", target={"bad": "target"})
        file.write_text(json.dumps(record))
        post = self.store.feed()[0]
        self.assertEqual(post["user"], self.user)
        self.assertEqual(post["uid"], os.getuid())

    def test_another_owner_cannot_delete_post(self):
        post_id = self.store.write("post", "Hello")
        self.store.uid = os.getuid() + 1
        with self.assertRaises(ValueError):
            self.store.write("delete", target=post_id)
        # A hand-written forged deletion must also be ignored during replay.
        records = self.store.records()
        records.append(dict(kind="delete", target=post_id, uid=self.store.uid))
        with patch.object(self.store, "records", return_value=records):
            self.assertEqual(len(self.store.feed()), 1)

    def test_bad_inputs_are_rejected(self):
        for kind, text, target in (("post", "", None), ("post", "x" * 1001, None),
                                   ("comment", "hello", "../missing")):
            with self.assertRaises(ValueError):
                self.store.write(kind, text, target)

    def test_publicly_writable_record_is_ignored(self):
        post_id = self.store.write("post", "Untrusted")
        (self.root / self.user / f"{post_id}.json").chmod(0o666)
        self.assertEqual(self.store.feed(), [])

    def test_record_permissions_override_private_umask(self):
        previous = os.umask(0o077)
        try:
            post_id = self.store.write("post", "Public")
        finally:
            os.umask(previous)
        self.assertEqual((self.root / self.user / f"{post_id}.json").stat().st_mode & 0o777, 0o644)

    def test_small_terminal_can_render_and_quit(self):
        self.store.write("post", "A long post " * 20)
        class Screen:
            def keypad(self, value): pass
            def getmaxyx(self): return (4, 12)
            def erase(self): pass
            def getch(self): return ord("q")
            def addnstr(self, row, column, text, limit):
                assert 0 <= row < 4 and 0 < limit < 12
        social.main_menu(Screen(), self.store)
        self.assertEqual(social.clean("abc\x1b\n"), "abc  ")


if __name__ == "__main__":
    unittest.main()

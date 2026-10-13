import concurrent.futures
import hashlib
import importlib.util
import json
import os
import pty
import pwd
import subprocess
import sys
import tempfile
import termios
import time
import unittest
import uuid
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
AUTH = (ROOT / 'webshell-auth.sh').read_text().rsplit('\nmain "$@"', 1)[0]
spec = importlib.util.spec_from_file_location('social', ROOT / 'tools/social.py')
social = importlib.util.module_from_spec(spec)
spec.loader.exec_module(social)


def shell(command, **environment):
    return subprocess.run(['sh', '-c', AUTH + '\n' + command], input='', text=True,
                          capture_output=True, env=dict(os.environ, **environment), timeout=10)


class AuthenticationTests(unittest.TestCase):
    def test_existing_account_mapping(self):
        account = str(uuid.uuid4())
        result = shell('generate_username "$ACCOUNT"', ACCOUNT=account)
        self.assertEqual(result.stdout.strip(), 'user_' + hashlib.md5(account.encode()).hexdigest()[:10])

    def test_uuid_validation(self):
        self.assertEqual(shell('valid_id "$ACCOUNT"', ACCOUNT=str(uuid.uuid4())).returncode, 0)
        for value in ('', '../root', str(uuid.uuid4()) + 'extra'):
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
        for password in ('normal-password', "''' ; raise SystemExit(0); #", 'quotes" $HOME \\'):
            result = shell(command, PASSWORD=password, EXPECTED=password, STUB=stub, PYTHON=sys.executable)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertNotEqual(shell(command, PASSWORD=password, EXPECTED='wrong',
                                      STUB=stub, PYTHON=sys.executable).returncode, 0)

    @unittest.skipUnless(importlib.util.find_spec('passlib'), 'passlib not installed on host')
    def test_real_sha512_passwords_and_locked_accounts(self):
        from passlib.hash import sha512_crypt
        password = "quotes''' $HOME"
        hashed = sha512_crypt.using(rounds=1000).hash(password)
        command = '''
getent() { printf 'user:%s:0:0:0:0:0:0:0\\n' "$HASH"; }
verify_password user "$PASSWORD"
'''
        self.assertEqual(shell(command, HASH=hashed, PASSWORD=password).returncode, 0)
        for hash_value, candidate in ((hashed, 'wrong'), ('!', password), ('*', password), ('', password)):
            self.assertNotEqual(shell(command, HASH=hash_value, PASSWORD=candidate).returncode, 0)

    def test_password_echo_disabled_and_restored(self):
        master, slave = pty.openpty()
        process = None
        try:
            original = termios.tcgetattr(slave)[3]
            process = subprocess.Popen(['sh', '-c', AUTH + '\nread_password "Password: "; printf "VALUE=%s\\n" "$REPLY"'],
                                       stdin=slave, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            deadline = time.monotonic() + 3
            while termios.tcgetattr(slave)[3] & termios.ECHO:
                if time.monotonic() >= deadline or process.poll() is not None:
                    self.fail('Password input did not disable echo')
                time.sleep(0.01)
            password = "  quotes''' $HOME \\  "
            os.write(master, password.encode() + b'\n')
            output, error = process.communicate(timeout=5)
            self.assertEqual(process.returncode, 0, error)
            self.assertEqual(output.decode(), 'Password: \nVALUE=' + password + '\n')
            self.assertEqual(termios.tcgetattr(slave)[3] & termios.ECHO, original & termios.ECHO)
        finally:
            if process is not None and process.poll() is None:
                process.terminate()
                process.wait(timeout=5)
            os.close(master)
            os.close(slave)

    def test_transport_metadata_cannot_bypass_login(self):
        result = shell('''
id() { echo 0; }
handle_login() { echo authentication-required; return 1; }
main
''', CLIENT_IP=str(uuid.uuid4()))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('authentication-required', result.stdout)

    def test_failed_limits_refuse_session(self):
        result = shell('''
id() { echo 0; }
handle_login() { USERNAME=user_test; }
set_quota() { return 1; }
setup_cgroup() { echo should-not-run; }
main
''')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Login refused', result.stdout)
        self.assertNotIn('should-not-run', result.stdout)

    def test_disabled_and_failed_quotas(self):
        result = shell('''
quotaon() { echo 'user quota on / is off'; }
setquota() { echo should-not-run; }
set_quota user_test
''')
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('should-not-run', result.stdout)
        self.assertNotEqual(shell('''
quotaon() { echo 'user quota on / is on'; }
setquota() { return 1; }
set_quota user_test
''').returncode, 0)

    def test_missing_controller_files_fail(self):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            (base / 'cgroup.controllers').write_text('memory cpu pids')
            result = shell('CGROUP_BASE="$BASE"; setup_cgroup test', BASE=directory)
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse((base / 'webshell_test/memory.max').exists())

    def test_cgroup_is_readable_under_private_umask(self):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            (base / 'cgroup.controllers').write_text('memory cpu pids')
            account = base / 'webshell_test'
            account.mkdir(mode=0o700)
            for name in ('memory.max', 'memory.swap.max', 'cpu.max', 'pids.max', 'cgroup.procs'):
                (account / name).write_text('')
            result = shell('umask 077; CGROUP_BASE="$BASE"; setup_cgroup test', BASE=directory)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(account.stat().st_mode & 0o777, 0o755)
            self.assertEqual((account / 'memory.max').read_text().strip(), '104857600')

    def test_shared_symlink_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            (base / 'target').mkdir(mode=0o700)
            (base / 'shared').symlink_to(base / 'target', target_is_directory=True)
            result = shell('SHARED_DIR="$SHARED"; setup_environment user_test', SHARED=str(base / 'shared'))
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual((base / 'target').stat().st_mode & 0o777, 0o700)

    def test_eof_ends_login(self):
        self.assertNotEqual(shell('handle_login').returncode, 0)


class SocialTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.user = pwd.getpwuid(os.getuid()).pw_name
        (self.root / self.user).mkdir()
        self.store = social.Store(self.root)

    def test_identity_ignores_environment_and_json(self):
        with patch.dict(os.environ, {'USER': 'spoofed-user'}):
            self.assertEqual(social.Store(self.root).user, self.user)
        post_id = self.store.write('post', 'Hello')
        file = self.root / self.user / f'{post_id}.json'
        record = json.loads(file.read_text())
        record.update(user='spoofed-user', uid=-1, timestamp='bad', target={'bad': 'target'})
        file.write_text(json.dumps(record))
        post = self.store.feed()[0]
        self.assertEqual(post['user'], self.user)
        self.assertEqual(post['uid'], os.getuid())

    def test_posts_likes_comments_and_hide(self):
        post_id = self.store.write('post', 'Hello')
        self.store.write('like', target=post_id)
        self.store.write('like', target=post_id)
        self.store.write('comment', 'A comment', post_id)
        post = self.store.feed()[0]
        self.assertEqual(len(post['likes']), 1)
        self.assertEqual(post['comments'][0]['text'], 'A comment')
        self.store.write('delete', target=post_id)
        self.assertEqual(self.store.feed(), [])
        self.assertEqual(len(list((self.root / self.user).glob('*.json'))), 5)

    def test_concurrent_writes_do_not_overwrite(self):
        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as executor:
            ids = list(executor.map(lambda number: self.store.write('post', str(number)), range(24)))
        self.assertEqual(len(set(ids)), 24)
        self.assertEqual(len(self.store.feed()), 24)
        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as executor:
            list(executor.map(lambda number: self.store.write('comment', str(number), ids[0]), range(24)))
        post = next(post for post in self.store.feed() if post['id'] == ids[0])
        self.assertEqual(len(post['comments']), 24)

    def test_corrupt_large_and_symlink_records_are_ignored(self):
        directory = self.root / self.user
        for data in ('{', '[]', '{"kind": []}', '[' * 2000 + ']' * 2000, 'x' * (social.MAX_RECORD + 1)):
            (directory / f'{uuid.uuid4()}.json').write_text(data)
        target = self.root / 'secret'
        target.write_text(json.dumps({'kind': 'post', 'text': 'secret'}))
        (directory / f'{uuid.uuid4()}.json').symlink_to(target)
        self.store.write('post', 'Visible')
        self.assertEqual([post['text'] for post in self.store.feed()], ['Visible'])

    def test_another_owner_cannot_hide_post(self):
        post_id = self.store.write('post', 'Hello')
        self.store.uid = os.getuid() + 1
        with self.assertRaises(ValueError):
            self.store.write('delete', target=post_id)
        records = self.store.records()
        records.append(dict(kind='delete', target=post_id, uid=self.store.uid))
        with patch.object(self.store, 'records', return_value=records):
            self.assertEqual(len(self.store.feed()), 1)

    def test_invalid_inputs_and_publicly_writable_files(self):
        for kind, text, target in (('post', '', None), ('post', 'x' * 1001, None),
                                   ('comment', 'hello', '../missing')):
            with self.assertRaises(ValueError):
                self.store.write(kind, text, target)
        post_id = self.store.write('post', 'Untrusted')
        (self.root / self.user / f'{post_id}.json').chmod(0o666)
        self.assertEqual(self.store.feed(), [])

    def test_permissions_override_private_umask(self):
        previous = os.umask(0o077)
        try:
            post_id = self.store.write('post', 'Public')
        finally:
            os.umask(previous)
        self.assertEqual((self.root / self.user / f'{post_id}.json').stat().st_mode & 0o777, 0o644)

    def test_small_terminal_can_quit(self):
        self.store.write('post', 'A long post ' * 20)
        class Screen:
            def keypad(self, value): pass
            def getmaxyx(self): return (4, 12)
            def erase(self): pass
            def getch(self): return ord('q')
            def addnstr(self, row, column, text, limit):
                assert 0 <= row < 4 and 0 < limit < 12
        social.main_menu(Screen(), self.store)
        self.assertEqual(social.clean('abc\x1b\n'), 'abc  ')


if __name__ == '__main__':
    unittest.main()

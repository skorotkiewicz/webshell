import base64
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

# Replace only host programs that download, generate keys, or launch QEMU.
FAKE = r'''
import os
import sys
from pathlib import Path
name = Path(sys.argv[0]).name
args = sys.argv[1:]
with open(os.environ["CALLS"], "a") as log:
    log.write(json.dumps([name] + args) + "\n")
if name == "curl":
    Path(args[args.index("-o") + 1]).write_bytes(b"base image")
elif name == "sha512sum":
    line = sys.stdin.read()
    assert len(line.split()[0]) == 128
    sys.exit(int(os.environ.get("BAD_CHECKSUM", "0")))
elif name == "qemu-img" and args[0] == "convert":
    Path(args[-1]).write_bytes(b"provisioned disk")
elif name == "ssh-keygen":
    path = Path(args[args.index("-f") + 1])
    path.write_text("private fixture")
    Path(str(path) + ".pub").write_text("ssh-ed25519 AAAA test fixture")
elif name == "mkisofs":
    Path(args[args.index("-output") + 1]).write_bytes(b"seed")
elif name == "qemu-system-x86_64":
    print("WEBSHELL_BUILD_FAILED" if os.environ.get("BAD_GUEST") else " * Starting local ...WEBSHELL_BUILD_READY")
'''


class BuildTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.base = Path(self.temporary.name)
        self.repository = self.base / "repository with spaces"
        self.repository.mkdir()
        for file in ("build.sh", "run.sh", "webshell-auth.sh", "tools/social.py",
                     "tools/setup-vm.sh", "tools/start-webshell.sh", "test-limits.sh", "supervisord.conf"):
            target = self.repository / file
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT / file, target)
        self.bin = self.base / "bin"
        self.bin.mkdir()
        for name in ("curl", "sha512sum", "qemu-img", "ssh-keygen", "mkisofs", "qemu-system-x86_64"):
            file = self.bin / name
            file.write_text(f"#!{sys.executable}\nimport json\n" + FAKE)
            file.chmod(0o755)
        self.calls = self.base / "calls"
        self.environment = dict(os.environ, CALLS=str(self.calls),
                                PATH=str(self.bin) + ":" + os.environ["PATH"])

    def build(self, size="4G", **environment):
        return subprocess.run(["sh", str(self.repository / "build.sh"), size], cwd=self.base,
                              env=dict(self.environment, **environment), text=True,
                              capture_output=True, timeout=15)

    def test_complete_build_publishes_disk_key_and_cloud_config(self):
        result = self.build()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.repository / "webshell.qcow2").is_file())
        self.assertEqual((self.repository / "webshell-key").stat().st_mode & 0o777, 0o600)
        work = next(self.repository.glob(".build.*"))
        self.assertEqual(work.stat().st_mode & 0o777, 0o700)
        header, data = (work / "user-data").read_text().split("\n", 1)
        self.assertEqual(header, "#cloud-config")
        config = json.loads(data)
        self.assertFalse(config["ssh_pwauth"])
        self.assertEqual(config["runcmd"], [["/usr/local/sbin/setup-webshell"]])
        for file in config["write_files"]:
            decoded = base64.b64decode(file["content"])
            self.assertTrue(decoded)
            self.assertEqual(file["owner"], "root:root")
        calls = [json.loads(line) for line in self.calls.read_text().splitlines()]
        qemu = next(call for call in calls if call[0] == "qemu-system-x86_64")
        self.assertNotIn("hostfwd", " ".join(qemu))
        resize = next(call for call in calls if call[:2] == ["qemu-img", "resize"])
        self.assertEqual(resize[-1], "4G")

    def test_cloud_services_are_removed_only_from_registered_runlevels(self):
        script = (ROOT / "tools/start-webshell.sh").read_text()
        start = script.index("    rc-update show |")
        end = script.index("        done", start) + len("        done")
        mock = '''
rc-update() {
    if [ "$1" = show ]; then
        printf 'cloud-init-local | boot\\ncloud-final | default boot\\nsshd | default\\n'
    else
        printf 'removed %s %s\\n' "$2" "$3"
    fi
}
'''
        result = subprocess.run(["sh", "-ec", mock + script[start:end]],
                                text=True, capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines(), ["removed cloud-init-local boot",
                                                     "removed cloud-final default",
                                                     "removed cloud-final boot"])

    def test_existing_disk_is_never_overwritten(self):
        disk = self.repository / "webshell.qcow2"
        disk.write_bytes(b"existing accounts")
        result = self.build()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(disk.read_bytes(), b"existing accounts")
        self.assertFalse(self.calls.exists())

    def test_dangling_disk_symlink_is_rejected(self):
        (self.repository / "webshell.qcow2").symlink_to(self.base / "missing")
        self.assertNotEqual(self.build().returncode, 0)
        self.assertFalse(self.calls.exists())

    def test_invalid_sizes_do_not_download(self):
        for size in ("1G", "4", "4;echo bad", "-4G", "0G"):
            self.assertNotEqual(self.build(size).returncode, 0)
        self.assertFalse(self.calls.exists())

    def test_checksum_failure_does_not_publish(self):
        result = self.build(BAD_CHECKSUM="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.repository / "webshell.qcow2").exists())
        self.assertNotIn('"qemu-img"', self.calls.read_text())

    def test_cached_base_is_verified_without_downloading(self):
        (self.repository / ".alpine-3.23.4.qcow2").write_bytes(b"base image")
        result = self.build()
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = [json.loads(line)[0] for line in self.calls.read_text().splitlines()]
        self.assertNotIn("curl", calls)
        self.assertIn("sha512sum", calls)

    def test_bad_cached_checksum_does_not_publish(self):
        (self.repository / ".alpine-3.23.4.qcow2").write_bytes(b"tampered image")
        result = self.build(BAD_CHECKSUM="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.repository / "webshell.qcow2").exists())
        calls = [json.loads(line)[0] for line in self.calls.read_text().splitlines()]
        self.assertNotIn("curl", calls)
        self.assertNotIn("qemu-img", calls)

    def test_guest_failure_does_not_publish(self):
        result = self.build(BAD_GUEST="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.repository / "webshell.qcow2").exists())
        self.assertFalse((self.repository / "webshell-key").exists())
        self.assertIn("Build failed", result.stderr)

    def test_missing_disk_does_not_launch_qemu(self):
        result = subprocess.run(["sh", str(self.repository / "run.sh")],
                                env=self.environment, text=True, capture_output=True, timeout=10)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("build.sh 4G", result.stderr)
        self.assertFalse(self.calls.exists())


if __name__ == "__main__":
    unittest.main()

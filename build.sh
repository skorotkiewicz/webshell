#!/bin/sh
set -eu

repository=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
size=${1:-4G}
[ "$#" -le 1 ] || { echo 'Usage: ./build.sh [disk-size, e.g. 4G]' >&2; exit 1; }
for command in python3 curl sha512sum qemu-img qemu-system-x86_64 ssh-keygen mkisofs; do
    command -v "$command" >/dev/null || { echo "Missing host command: $command" >&2; exit 1; }
done
python3 - "$size" <<'PY'
import re
import sys
if not re.fullmatch(r"[1-9][0-9]*G", sys.argv[1]) or int(sys.argv[1][:-1]) < 2:
    sys.exit("Disk size must be at least 2G, in whole GiB. Example: ./build.sh 4G")
PY
for file in webshell.qcow2 webshell-key webshell-key.pub; do
    if [ -e "$repository/$file" ] || [ -L "$repository/$file" ]; then
        echo "Refusing to overwrite $file. Move existing VM files aside to build another." >&2
        exit 1
    fi
done

umask 077
work=$(mktemp -d "$repository/.build.XXXXXX")
printf 'Build files and logs: %s\n' "$work"
# Pin the official image and its SHA-512 digest for a reproducible base.
url=https://dl-cdn.alpinelinux.org/alpine/v3.23/releases/cloud/nocloud_alpine-3.23.4-x86_64-bios-cloudinit-r0.qcow2
checksum=05bd2071f54cb47307fd1f9ff99333b3426dafa7fea95253b1100119b4da537e5f415c369a7c74b8c4d11cc22db178e26f39ecb27b7757edbe25d19a9944f061
curl -fL -o "$work/alpine.qcow2" "$url"
printf '%s  %s\n' "$checksum" "$work/alpine.qcow2" | sha512sum -c -
qemu-img convert -f qcow2 -O qcow2 "$work/alpine.qcow2" "$work/webshell.qcow2"
qemu-img resize "$work/webshell.qcow2" "$size"
ssh-keygen -q -t ed25519 -N '' -C webshell-admin -f "$work/admin-key"

# JSON is valid YAML. Avoid hand-escaping shell scripts into cloud-config.
python3 - "$repository" "$work" <<'PY'
import base64
import json
import sys
import uuid
from pathlib import Path
repository, work = map(Path, sys.argv[1:])
files = [
    ("webshell-auth.sh", "/usr/local/bin/webshell-auth.sh", "0755"),
    ("tools/social.py", "/usr/local/bin/social", "0755"),
    ("test-limits.sh", "/usr/local/bin/test-limits.sh", "0755"),
    ("supervisord.conf", "/etc/supervisord.conf", "0644"),
    ("tools/setup-vm.sh", "/usr/local/sbin/setup-webshell", "0700"),
    ("tools/start-webshell.sh", "/etc/local.d/webshell.start", "0700"),
]
config = {
    "hostname": "webshell",
    "disable_root": False,
    "ssh_pwauth": False,
    "users": [{"name": "root", "ssh_authorized_keys": [(work / "admin-key.pub").read_text().strip()]}],
    "growpart": {"mode": "auto", "devices": ["/"], "ignore_growroot_disabled": True},
    "resize_rootfs": True,
    "write_files": [{"path": target, "owner": "root:root", "permissions": mode,
                     "encoding": "b64", "content": base64.b64encode((repository / source).read_bytes()).decode()}
                    for source, target, mode in files],
    "runcmd": [["/usr/local/sbin/setup-webshell"]],
    "power_state": {"mode": "reboot", "delay": "now", "timeout": 30,
                    "condition": "test -f /var/lib/webshell/build-pending"},
}
(work / "user-data").write_text("#cloud-config\n" + json.dumps(config))
(work / "meta-data").write_text("instance-id: webshell-" + str(uuid.uuid4()) + "\nlocal-hostname: webshell\n")
PY
mkisofs -quiet -output "$work/seed.iso" -volid cidata -joliet -rock \
    "$work/user-data" "$work/meta-data"
printf '\nInstalling WebShell. The guest will reboot, check its setup, and power off.\n'
qemu-system-x86_64 \
    -machine accel=kvm:tcg -m 2048 \
    -nic user,model=virtio \
    -drive "file=$work/webshell.qcow2,format=qcow2,if=virtio" \
    -drive "file=$work/seed.iso,format=raw,media=cdrom,readonly=on" \
    -display none -monitor none -serial stdio < /dev/null > "$work/console.log" 2>&1 &
vm_pid=$!
trap 'kill "$vm_pid" 2>/dev/null || true; wait "$vm_pid" 2>/dev/null || true; exit 1' HUP INT TERM
status=0
wait "$vm_pid" || status=$?
trap - HUP INT TERM
if [ "$status" -ne 0 ] || ! grep -q '^WEBSHELL_BUILD_READY' "$work/console.log"; then
    tail -n 60 "$work/console.log" >&2
    echo "Build failed. Full guest log: $work/console.log" >&2
    exit 1
fi
# Hard links fail rather than overwrite if another build published first.
ln "$work/admin-key" "$repository/webshell-key"
ln "$work/admin-key.pub" "$repository/webshell-key.pub"
ln "$work/webshell.qcow2" "$repository/webshell.qcow2"
printf '\nReady: %s/webshell.qcow2, %s disk\nRun ./run.sh, then open http://localhost:8080\n' "$repository" "$size"

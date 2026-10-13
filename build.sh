#!/bin/sh
set -eu
repository=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
size=${1:-4G}
[ "$#" -le 1 ] || { echo 'Usage: ./build.sh [disk-size, e.g. 4G]' >&2; exit 1; }
for command in python3 curl sha512sum qemu-img qemu-system-x86_64 mkisofs; do
    command -v "$command" >/dev/null || { echo "Missing host command: $command" >&2; exit 1; }
done
python3 - "$size" <<'PY'
import re
import sys
if not re.fullmatch(r"[1-9][0-9]*G", sys.argv[1]) or int(sys.argv[1][:-1]) < 2:
    sys.exit("Disk size must be at least 2G, in whole GiB. Example: ./build.sh 4G")
PY
if [ -e "$repository/webshell.qcow2" ] || [ -L "$repository/webshell.qcow2" ]; then
    echo 'Refusing to overwrite webshell.qcow2. Move the existing disk aside first.' >&2
    exit 1
fi
umask 077
work=$(mktemp -d "$repository/.build.XXXXXX")
printf 'Build files and logs: %s\n' "$work"
url=https://dl-cdn.alpinelinux.org/alpine/v3.23/releases/cloud/nocloud_alpine-3.23.4-x86_64-bios-cloudinit-r0.qcow2
checksum=05bd2071f54cb47307fd1f9ff99333b3426dafa7fea95253b1100119b4da537e5f415c369a7c74b8c4d11cc22db178e26f39ecb27b7757edbe25d19a9944f061
base="$repository/.alpine-3.23.4.qcow2"
if [ ! -f "$base" ]; then
    curl -fL -o "$work/alpine.qcow2" "$url"
    printf '%s  %s\n' "$checksum" "$work/alpine.qcow2" | sha512sum -c -
    ln "$work/alpine.qcow2" "$base"
fi
printf '%s  %s\n' "$checksum" "$base" | sha512sum -c -
qemu-img convert -f qcow2 -O qcow2 "$base" "$work/webshell.qcow2"
qemu-img resize "$work/webshell.qcow2" "$size"

# JSON is valid YAML; encode scripts instead of escaping them into cloud-config.
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
    "hostname": "webshell", "users": [], "disable_root": True, "ssh_pwauth": False,
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
printf '\nInstalling WebShell. The guest will reboot, check itself, and power off.\n'
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
if [ "$status" -ne 0 ] || ! grep -q 'WEBSHELL_BUILD_READY' "$work/console.log"; then
    tail -n 60 "$work/console.log" >&2
    echo "Build failed. Full guest log: $work/console.log" >&2
    exit 1
fi
# Publishing fails rather than overwriting if another build finished first.
ln "$work/webshell.qcow2" "$repository/webshell.qcow2"
printf '\nReady: %s/webshell.qcow2, %s disk\nRun ./run.sh, then open http://localhost:8080\n' "$repository" "$size"

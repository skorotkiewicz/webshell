#!/bin/sh
set -eu

repository=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
[ -f "$repository/webshell.qcow2" ] || {
    echo 'No VM disk found. Run ./build.sh 4G first.' >&2
    exit 1
}
printf 'WebShell: http://localhost:8080\nAdmin: ssh -i "%s/webshell-key" -p 10022 root@localhost\n' "$repository"
exec qemu-system-x86_64 \
    -machine accel=kvm:tcg -m 2048 \
    -nic user,model=virtio,hostfwd=tcp:127.0.0.1:10022-:22,hostfwd=tcp:127.0.0.1:8080-:8080 \
    -drive "file=$repository/webshell.qcow2,format=qcow2,if=virtio" \
    -display none -serial mon:stdio

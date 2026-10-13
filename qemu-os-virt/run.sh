#!/bin/sh

# Resolve the disk relative to this repository, not the caller's directory.
repository=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd) || exit 1
exec qemu-system-x86_64 \
    -enable-kvm \
    -m 2048 \
    -nic user,model=virtio,hostfwd=tcp:127.0.0.1:10022-:22,hostfwd=tcp:127.0.0.1:8080-:8080 \
    -drive "file=$repository/webshell.qcow2,media=disk,if=virtio" \
    -display none

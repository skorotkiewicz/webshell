#!/bin/sh

qemu-system-x86_64 \
    -enable-kvm \
    -m 2048 \
    -nic user,model=virtio,hostfwd=tcp::10022-:22,hostfwd=tcp::8080-:8080 \
    -drive file=webshell.qcow2,media=disk,if=virtio \
    -display none

# ssh root@localhost -p 10022
#!/bin/sh
# Read-only checks. Run inside a WebShell session, never as root.
failed=0
cgroup=$(awk -F: '$1 == "0" {print $3}' /proc/self/cgroup)
base="/sys/fs/cgroup$cgroup"

check() {
    local value
    if [ -r "$base/$1" ]; then
        IFS= read -r value < "$base/$1"
    else
        value=unavailable
    fi
    if [ "$value" = "$2" ]; then
        printf 'PASS %s = %s\n' "$1" "$value"
    else
        printf 'FAIL %s = %s, expected %s\n' "$1" "$value" "$2"
        failed=1
    fi
}

memory() {
    check memory.max 104857600
    check memory.swap.max 0
}
cpu() { check cpu.max '50000 100000'; }
pids() { check pids.max 100; }
disk() {
    local device
    device=$(awk '$2 == "/" {print $1; exit}' /proc/self/mounts)
    if quota -w -v 2>/dev/null | awk -v device="$device" '
        $1 == device && $3 == 5120 && $4 == 5120 {found=1}
        END {exit !found}'; then
        echo 'PASS root filesystem disk quota = 5120 KiB'
    else
        echo 'FAIL cannot verify a 5120 KiB root filesystem quota'
        failed=1
    fi
}

[ "$(id -u)" -ne 0 ] || { echo 'Run this as a WebShell user, not root.'; exit 1; }
case "${1:-all}" in
    memory|cpu|pids|disk) "$1" ;;
    all) memory; cpu; pids; disk ;;
    *) echo 'Usage: test-limits.sh [memory|cpu|pids|disk|all]'; exit 1 ;;
esac
exit "$failed"

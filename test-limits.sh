#!/bin/sh
# Read-only checks of the default limits, run inside a WebShell session.
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
[ "$(id -u)" -ne 0 ] || { echo 'Run this as a WebShell user.'; exit 1; }
check memory.max 104857600
check memory.swap.max 0
check cpu.max '50000 100000'
check pids.max 100
device=$(awk '$2 == "/" {print $1; exit}' /proc/self/mounts)
if quota -w -v 2>/dev/null | awk -v device="$device" '
    $1 == device && $3 == 5120 && $4 == 5120 {found=1}
    END {exit !found}'; then
    echo 'PASS root filesystem quota = 5120 KiB'
else
    echo 'FAIL cannot verify a 5120 KiB root filesystem quota'
    failed=1
fi
exit "$failed"

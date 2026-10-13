#!/bin/sh
# Runs once inside the new guest through cloud-init.
set -eu
trap 'echo WEBSHELL_BUILD_FAILED > /dev/ttyS0; poweroff' EXIT
printf '%s\n' \
    https://dl-cdn.alpinelinux.org/alpine/v3.23/main \
    https://dl-cdn.alpinelinux.org/alpine/v3.23/community > /etc/apk/repositories
apk update
apk add ttyd shadow supervisor quota-tools python3 py3-passlib e2fsprogs-extra

# shortcut: external ext4 quotas avoid offline edits but are deprecated; migrate before kernel support ends.
python3 - <<'PY'
from pathlib import Path
path = Path('/etc/fstab')
lines = []
found = False
for line in path.read_text().splitlines():
    parts = line.split()
    if parts and not parts[0].startswith('#') and len(parts) >= 4 and parts[1] == '/':
        if parts[2] != 'ext4':
            raise SystemExit('The image must have an ext4 root filesystem.')
        parts[3] = ','.join(dict.fromkeys(parts[3].split(',') + ['usrquota']))
        line = '\t'.join(parts)
        found = True
    lines.append(line)
if not found:
    raise SystemExit('Missing root filesystem entry in /etc/fstab.')
path.write_text('\n'.join(lines) + '\n')
PY
modprobe quota_v2
mount -o remount,usrquota /
quotacheck -cum /
quotaon -v /
printf '\nrc_cgroup_mode="unified"\n' >> /etc/rc.conf
rc-update add cgroups default
rc-update add local default
# The vendor image includes SSH; this project exposes only the webshell.
rc-update del sshd default
mkdir -p /shared-files /var/social/users /var/lib/webshell
chmod 1777 /shared-files
chmod 755 /var/social /var/social/users
: > /var/lib/webshell/build-pending
trap - EXIT
# cloud-init reboots after recording completion of runcmd.

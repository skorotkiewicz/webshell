#!/bin/sh
# OpenRC's local service runs this on each guest boot.
set -eu
umask 077
exec >> /var/log/webshell-start.log 2>&1
if [ -f /var/lib/webshell/build-pending ]; then
    trap 'tail -n 60 /var/log/webshell-start.log > /dev/ttyS0; echo WEBSHELL_BUILD_FAILED > /dev/ttyS0; poweroff' EXIT
fi
quotaon -p / | grep -Eq 'user quota.* is on' || quotaon -v /
/usr/bin/supervisord -c /etc/supervisord.conf &

if [ -f /var/lib/webshell/build-pending ]; then
    # Exercise the same helpers used by login, without starting an interactive session.
    sed '$d' /usr/local/bin/webshell-auth.sh > /run/webshell-auth-functions.sh
    (
        . /run/webshell-auth-functions.sh
        setup_cgroup buildcheck
        set_quota nobody
    )
    python3 - <<'PY'
import curses
import time
import urllib.request
from passlib.hash import sha512_crypt
password = "build-check'''"
assert sha512_crypt.verify(password, sha512_crypt.using(rounds=1000).hash(password))
for attempt in range(30):
    try:
        with urllib.request.urlopen('http://127.0.0.1:8080', timeout=2) as response:
            assert response.status == 200
        break
    except OSError:
        time.sleep(1)
else:
    raise SystemExit('ttyd did not start.')
PY
    # The ready disk must boot independently of the temporary NoCloud seed.
    rc-update show | awk '$1 ~ /^cloud-/ {for (i=3; i<=NF; i++) print $1, $i}' |
        while read -r service runlevel; do
            rc-update del "$service" "$runlevel"
        done
    mv /var/lib/webshell/build-pending /var/lib/webshell/build-complete
    printf '\nWEBSHELL_BUILD_READY\n' > /dev/ttyS0
    trap - EXIT
    poweroff
fi

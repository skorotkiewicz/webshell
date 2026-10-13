#!/bin/sh

# Existing UUID -> username mapping is kept so permanent accounts still work.
SHARED_DIR="/shared-files"
SOCIAL_DIR="/var/social"
CGROUP_BASE="/sys/fs/cgroup"
MEMORY_LIMIT="104857600"
CPU_QUOTA="50000 100000"
PIDS_LIMIT="100"
DISK_QUOTA="5120"  # KiB, enforced on the root filesystem
INODE_QUOTA="1024"

read_password() {
    printf '%s' "$1"
    local tty_state
    tty_state=$(stty -g) || return 1
    trap 'stty "$tty_state"; exit 1' HUP INT TERM
    stty -echo || return 1
    IFS= read -r REPLY
    local status=$?
    stty "$tty_state"
    trap - HUP INT TERM
    printf '\n'
    return "$status"
}

generate_username() {
    printf 'user_%s\n' "$(printf '%s' "$1" | md5sum | cut -c1-10)"
}

valid_id() {
    [ "${#1}" -eq 36 ] && printf '%s\n' "$1" |
        grep -Eq '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
}

verify_password() {
    local hash
    hash=$(getent shadow "$1" | cut -d: -f2) || return 1
    # Credentials are data on stdin, never Python source or command arguments.
    printf '%s\n%s\n' "$hash" "$2" | python3 -I -c '
import sys
from passlib.hash import sha512_crypt
hash_value, password = sys.stdin.read().split("\n", 2)[:2]
try:
    valid = sha512_crypt.verify(password, hash_value)
except (ValueError, TypeError):
    valid = False
sys.exit(0 if valid else 1)
'
}

set_quota() {
    # Fail closed if quotas are missing or disabled.
    quotaon -p / 2>/dev/null | grep -Eq 'user quota.* is on' || return 1
    setquota -u "$1" "$DISK_QUOTA" "$DISK_QUOTA" "$INODE_QUOTA" "$INODE_QUOTA" /
}

create_user() {
    local username="$1" password="$2" home_dir="/home/$1"
    [ ! -e "$home_dir" ] && [ ! -L "$home_dir" ] || return 1
    adduser -D -h "$home_dir" -s /bin/ash "$username" || return 1
    chmod 700 "$home_dir" || return 1
    # Keep incomplete accounts locked. Do not remove homes or account data.
    if ! set_quota "$username"; then
        echo 'Account setup failed. Ask the administrator to check quotas.'
        return 1
    fi
    # Drop privileges before touching files in a user-owned home.
    env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin su -s /bin/ash -c \
        'umask 077; cat > "$HOME/.profile"' "$username" <<'PROFILE' || return 1
export PATH="$HOME/bin:$PATH"
PS1='\u@webshell:\w\$ '
alias ll='ls -lah'
printf '\nPermanent account: %s\n' "$(id -un)"
printf 'Limits: 100 MiB RAM, half a CPU, 100 processes, 5 MiB disk.\n'
printf 'Home is private. /shared-files is public. Run social for the local feed.\n\n'
cd "$HOME"
PROFILE
    printf '%s:%s\n' "$username" "$password" | chpasswd -c SHA512
}

handle_login() {
    printf '\nWebShell\nType new to create a permanent account, or enter your saved ID.\n\n'
    while true; do
        printf 'User ID: '
        IFS= read -r login_id || return 1
        if [ "$login_id" = new ]; then
            local uuid password
            uuid=$(cat /proc/sys/kernel/random/uuid) || return 1
            USERNAME=$(generate_username "$uuid")
            id "$USERNAME" >/dev/null 2>&1 && continue
            read_password 'Password, at least 8 characters: ' || return 1
            password=$REPLY
            if [ "${#password}" -lt 8 ] || [ "${#password}" -gt 256 ]; then
                echo 'Use 8 to 256 characters.'
                unset password REPLY
                continue
            fi
            read_password 'Confirm password: ' || return 1
            if [ "$password" != "$REPLY" ]; then
                echo 'Passwords do not match.'
                unset password REPLY
                continue
            fi
            if create_user "$USERNAME" "$password"; then
                unset password REPLY
                printf '\nSave this ID. It is required for future logins:\n%s\n\n' "$uuid"
                return 0
            fi
            unset password REPLY
            echo 'Account creation failed.'
        else
            if ! valid_id "$login_id"; then
                echo 'Enter a saved account UUID, or new.'
                continue
            fi
            USERNAME=$(generate_username "$login_id")
            read_password 'Password: ' || return 1
            if verify_password "$USERNAME" "$REPLY"; then
                unset REPLY
                return 0
            fi
            unset REPLY
            echo 'Invalid ID or password.'
            sleep 2
        fi
    done
}

setup_cgroup() {
    local cgroup_path="$CGROUP_BASE/webshell_$1" ctrl
    [ -f "$CGROUP_BASE/cgroup.controllers" ] || return 1
    for ctrl in memory cpu pids; do
        grep -qw "$ctrl" "$CGROUP_BASE/cgroup.controllers" || return 1
        printf '+%s\n' "$ctrl" > "$CGROUP_BASE/cgroup.subtree_control" || return 1
    done
    mkdir -p "$cgroup_path" || return 1
    chmod 755 "$cgroup_path" || return 1
    # Missing controller files are errors, not ordinary files to create.
    for ctrl in memory.max memory.swap.max cpu.max pids.max cgroup.procs; do
        [ -f "$cgroup_path/$ctrl" ] || return 1
    done
    printf '%s\n' "$MEMORY_LIMIT" > "$cgroup_path/memory.max" || return 1
    printf '0\n' > "$cgroup_path/memory.swap.max" || return 1
    printf '%s\n' "$CPU_QUOTA" > "$cgroup_path/cpu.max" || return 1
    printf '%s\n' "$PIDS_LIMIT" > "$cgroup_path/pids.max" || return 1
}

setup_environment() {
    local username="$1"
    local directory
    for directory in "$SHARED_DIR" "$SOCIAL_DIR" "$SOCIAL_DIR/users"; do
        [ ! -L "$directory" ] || return 1
        mkdir -p "$directory" || return 1
        [ "$(stat -c %u "$directory")" = 0 ] || return 1
        # Secure social parents before creating anything beneath them.
        if [ "$directory" = "$SHARED_DIR" ]; then
            chmod 1777 "$directory" || return 1
        else
            chmod 755 "$directory" || return 1
        fi
    done
    # The parent is root-owned, so users cannot claim someone else's directory.
    local user_dir="$SOCIAL_DIR/users/$username"
    [ ! -L "$user_dir" ] || return 1
    if [ ! -e "$user_dir" ]; then
        mkdir -m 755 "$user_dir" || return 1
        chown "$username:$username" "$user_dir" || return 1
    fi
    [ -d "$user_dir" ] && [ "$(stat -c %u "$user_dir")" = "$(id -u "$username")" ]
}

main() {
    PATH=/usr/sbin:/usr/bin:/sbin:/bin
    export PATH
    [ "$(id -u)" -eq 0 ] || { echo 'This script must run as root through ttyd.'; return 1; }
    umask 077
    # CLIENT_IP is untrusted transport metadata, never an authentication token.
    unset CLIENT_IP ENV BASH_ENV PYTHONPATH PYTHONHOME
    handle_login || return 1
    set_quota "$USERNAME" && setup_cgroup "$USERNAME" && setup_environment "$USERNAME" || {
        echo 'Login refused: resource limits or shared storage are unavailable.'
        return 1
    }
    printf '%s\n' "$$" > "$CGROUP_BASE/webshell_$USERNAME/cgroup.procs" || return 1
    exec env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin TERM="${TERM:-xterm-256color}" su -l "$USERNAME"
}

# Tests source a copy without this entry point.
main "$@"

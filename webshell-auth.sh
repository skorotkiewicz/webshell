#!/bin/sh

# ============================================================
#          Alpine Web Shell - Authentication Script
#          For Alpine Linux 3.23+ with cgroups v2
# ============================================================

# Configuration
SHARED_DIR="/shared-files"
CGROUP_BASE="/sys/fs/cgroup"
MEMORY_LIMIT="104857600"  # 100MB in bytes
CPU_QUOTA="50000 100000"  # 50ms per 100ms (50% CPU)
PIDS_LIMIT="100"          # Max 100 processes
DISK_QUOTA="5120"         # 5MB disk quota

# ============================================================
#                     Helper Functions
# ============================================================

show_banner() {
    clear 2>/dev/null || true
    echo "============================================================"
    echo "            Alpine Web Shell - Authentication               "
    echo "============================================================"
    echo "  * Type 'new' to create a new account                      "
    echo "  * Enter your user ID to log in                            "
    echo "============================================================"
    echo ""
}

# Read password without echoing (works with ash)
read_password() {
    local prompt="$1"
    local var_name="$2"
    
    printf "%s" "$prompt"
    
    # Disable echo
    stty -echo 2>/dev/null
    
    # Read the password
    read -r REPLY
    
    # Re-enable echo
    stty echo 2>/dev/null
    
    # Print newline since echo was disabled
    echo ""
    
    # Set the variable
    eval "$var_name=\$REPLY"
}

generate_username() {
    local id="$1"
    printf '%s' "$id" | md5sum | cut -c1-10 | xargs printf 'user_%s'
}

# Create a new user with password
create_user() {
    local username="$1"
    local password="$2"
    
    # Create user with home directory and ash shell (Alpine default)
    if ! adduser -D -h "/home/$username" -s /bin/ash "$username" 2>/dev/null; then
        echo "Error: Failed to create user account."
        return 1
    fi
    
    # Set password using chpasswd
    if ! printf '%s:%s\n' "$username" "$password" | chpasswd 2>/dev/null; then
        echo "Error: Failed to set password."
        deluser "$username" 2>/dev/null
        rm -rf "/home/$username" 2>/dev/null
        return 1
    fi
    
    return 0
}

# Verify user password using Python passlib
verify_password() {
    local username="$1"
    local password="$2"
    
    # Get password hash from shadow file
    local hash
    hash=$(getent shadow "$username" 2>/dev/null | cut -d: -f2)
    
    # Check if hash exists and is valid
    if [ -z "$hash" ] || [ "$hash" = "!" ] || [ "$hash" = "*" ] || [ "$hash" = "!!" ]; then
        return 1
    fi
    
    # Verify using passlib - pass data via stdin to avoid shell escaping issues
    python3 << PYTHON_EOF
import sys
from passlib.hash import sha512_crypt

password = '''$password'''
hash_val = '''$hash'''

try:
    if sha512_crypt.verify(password, hash_val):
        sys.exit(0)
    else:
        sys.exit(1)
except Exception:
    sys.exit(1)
PYTHON_EOF
    
    return $?
}

# ============================================================
#                    Login Flow
# ============================================================

handle_login() {
    show_banner
    
    while true; do
        printf "Enter user ID: "
        read -r login_id
        
        # Validate input
        if [ -z "$login_id" ]; then
            echo "[!] Please enter a valid ID or 'new'."
            echo ""
            continue
        fi
        
        if [ "$login_id" = "new" ]; then
            # ─────────────────────────────────────────────
            # New User Registration
            # ─────────────────────────────────────────────
            echo ""
            echo "============================================================"
            echo "                   Create New Account                       "
            echo "============================================================"
            
            # Generate unique ID
            uuid=$(cat /proc/sys/kernel/random/uuid)
            USERNAME=$(generate_username "$uuid")
            
            # Check if user already exists (very unlikely with UUID)
            if id "$USERNAME" >/dev/null 2>&1; then
                echo "[!] Account collision. Please try again."
                continue
            fi
            
            # Get password (hidden input)
            read_password "Enter password: " password
            
            if [ -z "$password" ]; then
                echo "[!] Password cannot be empty."
                continue
            fi
            
            read_password "Confirm password: " password_confirm
            
            if [ "$password" != "$password_confirm" ]; then
                echo "[!] Passwords do not match."
                continue
            fi
            
            # Create the user
            echo "Creating account..."
            if create_user "$USERNAME" "$password"; then
                echo ""
                echo "============================================================"
                echo "                  Account Created!                          "
                echo "============================================================"
                printf "  Your User ID: %s\n" "$uuid"
                echo "============================================================"
                echo "  [!] SAVE THIS ID - You need it to log in again!          "
                echo "============================================================"
                echo ""
                export CLIENT_IP="$uuid"
                return 0
            else
                echo "[!] Account creation failed. Please try again."
                continue
            fi
        else
            # ─────────────────────────────────────────────
            # Existing User Login
            # ─────────────────────────────────────────────
            USERNAME=$(generate_username "$login_id")
            
            # Check if user exists
            if ! id "$USERNAME" >/dev/null 2>&1; then
                echo "[!] User not found. Type 'new' to create an account."
                echo ""
                continue
            fi
            
            # Get password (hidden input)
            read_password "Enter password: " password
            
            if verify_password "$USERNAME" "$password"; then
                echo "[+] Login successful!"
                export CLIENT_IP="$login_id"
                return 0
            else
                echo "[!] Invalid password. Please try again."
                echo ""
                continue
            fi
        fi
    done
}

# ============================================================
#                 Cgroups v2 Setup
# ============================================================

mount_cgroups() {
    # Check if cgroup2 is already mounted
    if mountpoint -q "$CGROUP_BASE" 2>/dev/null; then
        # Check if it's cgroups v2
        if [ -f "$CGROUP_BASE/cgroup.controllers" ]; then
            return 0  # Already mounted as v2
        fi
    fi
    
    # Try to mount cgroups v2
    mkdir -p "$CGROUP_BASE" 2>/dev/null
    mount -t cgroup2 none "$CGROUP_BASE" 2>/dev/null || true
    
    # Verify mount
    if [ -f "$CGROUP_BASE/cgroup.controllers" ]; then
        return 0
    fi
    
    return 1
}

setup_cgroup() {
    local username="$1"
    local cgroup_name="webshell_$username"
    local cgroup_path="$CGROUP_BASE/$cgroup_name"
    
    # First ensure cgroups is mounted
    if ! mount_cgroups; then
        echo "[!] Warning: cgroups v2 not available, skipping resource limits"
        return 1
    fi
    
    # Enable controllers on the root cgroup
    # Need to check which controllers are available
    if [ -f "$CGROUP_BASE/cgroup.subtree_control" ]; then
        # Enable available controllers
        for ctrl in memory cpu pids; do
            if grep -q "$ctrl" "$CGROUP_BASE/cgroup.controllers" 2>/dev/null; then
                echo "+$ctrl" > "$CGROUP_BASE/cgroup.subtree_control" 2>/dev/null || true
            fi
        done
    fi
    
    # Create cgroup directory
    if [ ! -d "$cgroup_path" ]; then
        mkdir -p "$cgroup_path" 2>/dev/null
        if [ ! -d "$cgroup_path" ]; then
            echo "[!] Warning: Could not create cgroup directory"
            return 1
        fi
    fi
    
    # Set resource limits (only if files exist)
    [ -f "$cgroup_path/memory.max" ] && echo "$MEMORY_LIMIT" > "$cgroup_path/memory.max" 2>/dev/null
    [ -f "$cgroup_path/cpu.max" ] && echo "$CPU_QUOTA" > "$cgroup_path/cpu.max" 2>/dev/null
    [ -f "$cgroup_path/pids.max" ] && echo "$PIDS_LIMIT" > "$cgroup_path/pids.max" 2>/dev/null
    
    return 0
}

# Add current process to cgroup
join_cgroup() {
    local username="$1"
    local cgroup_name="webshell_$username"
    local cgroup_path="$CGROUP_BASE/$cgroup_name"
    
    # Only join if cgroup exists
    if [ -f "$cgroup_path/cgroup.procs" ]; then
        echo $$ > "$cgroup_path/cgroup.procs" 2>/dev/null
    fi
}

# ============================================================
#               User Environment Setup
# ============================================================

setup_environment() {
    local username="$1"
    local user_id="$2"
    local home_dir="/home/$username"
    
    # Ensure shared directory exists with sticky bit
    [ ! -d "$SHARED_DIR" ] && mkdir -p "$SHARED_DIR"
    chmod 1777 "$SHARED_DIR" 2>/dev/null
    
    # Set disk quota if quota tools are available
    if command -v setquota >/dev/null 2>&1; then
        setquota -u "$username" "$DISK_QUOTA" "$DISK_QUOTA" 0 0 / 2>/dev/null || true
    fi
    
    # Create user's .profile
    cat > "$home_dir/.profile" << PROFILE_EOF
# Alpine Web Shell Profile

# Prompt with colors
PS1='\[\033[01;32m\]\u@webshell\[\033[00m\]:\[\033[01;34m\]\w\[\033[00m\]\$ '

# Environment
export TERM=xterm-256color
export PATH="\$HOME/bin:\$PATH"

# Aliases
alias ls='ls --color=auto'
alias ll='ls -lah'
alias la='ls -A'
alias l='ls -CF'
alias grep='grep --color=auto'

# Welcome message
echo "============================================================"
echo "            Welcome to Alpine Web Shell!                    "
echo "============================================================"
echo ""
echo "  User ID:   $user_id"
echo "  Username:  $username"
echo ""
echo "  Resource Limits:"
echo "    - Memory:    100MB"
echo "    - CPU:       50%"
echo "    - Processes: 100"
echo "    - Disk:      5MB"
echo ""
echo "  Shared Files: /shared-files"
echo "    - Create files here to share with others"
echo "    - Only you can modify/delete your own files"
echo ""
echo "============================================================"
echo ""

# Start in shared directory
cd /shared-files 2>/dev/null || cd ~
PROFILE_EOF

    chown "$username:$username" "$home_dir/.profile"
    chmod 644 "$home_dir/.profile"
}

# ============================================================
#                      Main Script
# ============================================================

main() {
    # Check if already authenticated
    if [ -z "$CLIENT_IP" ]; then
        handle_login
    fi
    
    # Derive username from client IP/ID
    USERNAME=$(generate_username "$CLIENT_IP")
    
    # Verify user still exists
    if ! id "$USERNAME" >/dev/null 2>&1; then
        echo "Error: User session invalid. Please log in again."
        unset CLIENT_IP
        exec "$0"
    fi
    
    # Setup cgroup resource limits (non-fatal if fails)
    setup_cgroup "$USERNAME"
    
    # Setup user environment
    setup_environment "$USERNAME" "$CLIENT_IP"
    
    # Join the cgroup before switching user
    join_cgroup "$USERNAME"
    
    # Switch to user shell with profile loaded
    exec su -l "$USERNAME"
}

# Run main
main
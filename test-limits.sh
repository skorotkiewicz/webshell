#!/bin/sh

# ============================================================
#          WebShell Resource Limits Test Suite
# ============================================================
# Tests: Memory (100MB), CPU (50%), PIDs (100), Disk (5MB)
# Run this script as a WebShell user to verify limits work
# ============================================================

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Test result tracking
TESTS_PASSED=0
TESTS_FAILED=0

# Cleanup trap - ensure we don't leave zombie processes
cleanup() {
    pkill -u "$(whoami)" sleep 2>/dev/null
    wait 2>/dev/null
}
trap cleanup EXIT INT TERM

print_header() {
    echo ""
    echo "============================================================"
    echo "  $1"
    echo "============================================================"
}

print_test() {
    printf "${BLUE}[TEST]${NC} %s\n" "$1"
}

print_pass() {
    printf "${GREEN}[PASS]${NC} %s\n" "$1"
    TESTS_PASSED=$((TESTS_PASSED + 1))
}

print_fail() {
    printf "${RED}[FAIL]${NC} %s\n" "$1"
    TESTS_FAILED=$((TESTS_FAILED + 1))
}

print_warn() {
    printf "${YELLOW}[WARN]${NC} %s\n" "$1"
}

print_info() {
    printf "${BLUE}[INFO]${NC} %s\n" "$1"
}

# ============================================================
#                    Memory Limit Test
# ============================================================
test_memory_limit() {
    print_header "MEMORY LIMIT TEST (100MB)"
    
    # Get cgroup path
    CGROUP_PATH=$(cat /proc/self/cgroup 2>/dev/null | head -1 | cut -d: -f3)
    MEM_CGROUP="/sys/fs/cgroup${CGROUP_PATH}"
    
    print_info "Current memory cgroup settings:"
    if [ -f "$MEM_CGROUP/memory.max" ]; then
        echo "  memory.max: $(cat $MEM_CGROUP/memory.max)"
        echo "  memory.swap.max: $(cat $MEM_CGROUP/memory.swap.max 2>/dev/null || echo 'not set')"
        echo "  memory.current: $(cat $MEM_CGROUP/memory.current 2>/dev/null)"
    else
        print_warn "Cannot read cgroup memory settings"
    fi
    
    print_test "Attempting to use 50MB RAM (should succeed)"
    
    # Use dd to create a file in RAM (tmpfs)
    # /dev/shm is tmpfs and uses actual RAM
    if dd if=/dev/zero of=/dev/shm/memtest_50mb_$$ bs=1M count=50 2>/dev/null; then
        rm -f /dev/shm/memtest_50mb_$$
        print_pass "50MB allocation succeeded"
    else
        rm -f /dev/shm/memtest_50mb_$$ 2>/dev/null
        print_fail "50MB allocation failed unexpectedly"
    fi
    
    print_test "Attempting to use 150MB RAM (should fail or be killed)"
    
    # Method 1: Try using a C program that actually touches memory
    cat > /tmp/mem_eater.c << 'MEMTEST_C'
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int main() {
    size_t size = 150 * 1024 * 1024; // 150MB
    char *mem = malloc(size);
    if (!mem) {
        printf("MALLOC_FAILED\n");
        return 1;
    }
    // Actually touch every page to force allocation
    memset(mem, 'X', size);
    printf("ALLOCATED\n");
    free(mem);
    return 0;
}
MEMTEST_C

    # Try to compile and run C version (most reliable)
    if command -v gcc >/dev/null 2>&1; then
        if gcc -o /tmp/mem_eater /tmp/mem_eater.c 2>/dev/null; then
            result=$(timeout 30 /tmp/mem_eater 2>&1)
            exit_code=$?
            rm -f /tmp/mem_eater /tmp/mem_eater.c
            
            if [ $exit_code -eq 137 ] || [ $exit_code -eq 9 ]; then
                print_pass "Process was killed (OOM) - memory limit enforced!"
                # Check OOM events
                if [ -f "$MEM_CGROUP/memory.events" ]; then
                    oom_count=$(grep "oom_kill" "$MEM_CGROUP/memory.events" 2>/dev/null | awk '{print $2}')
                    print_info "OOM kill events: ${oom_count:-0}"
                fi
                return
            elif echo "$result" | grep -q "MALLOC_FAILED"; then
                print_pass "Malloc failed - memory limit enforced!"
                return
            elif echo "$result" | grep -q "ALLOCATED"; then
                print_fail "150MB was allocated - memory limit may not be enforced"
                return
            fi
        fi
    fi
    rm -f /tmp/mem_eater.c /tmp/mem_eater 2>/dev/null
    
    # Fallback: Use shell with /dev/shm
    print_info "Trying /dev/shm method..."
    (
        dd if=/dev/zero of=/dev/shm/memtest_150mb_$$ bs=1M count=150 2>&1
        exit_code=$?
        rm -f /dev/shm/memtest_150mb_$$ 2>/dev/null
        exit $exit_code
    ) &
    child_pid=$!
    
    # Wait and check if killed
    wait $child_pid 2>/dev/null
    exit_code=$?
    rm -f /dev/shm/memtest_150mb_$$ 2>/dev/null
    
    if [ $exit_code -eq 137 ] || [ $exit_code -eq 9 ]; then
        print_pass "Process was killed (OOM) - memory limit enforced!"
    elif [ $exit_code -ne 0 ]; then
        print_pass "Write failed (exit $exit_code) - memory limit likely enforced"
    else
        # Check if OOM events increased
        if [ -f "$MEM_CGROUP/memory.events" ]; then
            oom_count=$(grep "oom_kill" "$MEM_CGROUP/memory.events" 2>/dev/null | awk '{print $2}')
            if [ "${oom_count:-0}" -gt 0 ]; then
                print_pass "OOM kills detected ($oom_count) - memory limit enforced!"
                return
            fi
        fi
        print_warn "150MB write completed - memory limit may not be strictly enforced"
        print_info "Note: cgroups v2 may allow brief overages before OOM"
    fi
}

# ============================================================
#                    CPU Quota Test
# ============================================================
test_cpu_quota() {
    print_header "CPU QUOTA TEST (50%)"
    
    print_info "Current CPU cgroup settings:"
    CGROUP_PATH=$(cat /proc/self/cgroup 2>/dev/null | head -1 | cut -d: -f3)
    if [ -n "$CGROUP_PATH" ] && [ -f "/sys/fs/cgroup${CGROUP_PATH}/cpu.max" ]; then
        echo "  cpu.max: $(cat /sys/fs/cgroup${CGROUP_PATH}/cpu.max)"
    else
        print_warn "Cannot read cgroup CPU settings"
    fi
    
    print_test "Running CPU-intensive task for 5 seconds..."
    
    # Get start time
    start_time=$(date +%s.%N)
    
    # Run a CPU-intensive task (calculate something)
    timeout 5 sh -c '
        i=0
        while true; do
            i=$((i + 1))
            : $((i * i * i))
        done
    ' 2>/dev/null &
    pid=$!
    
    # Monitor CPU usage
    sleep 1
    if command -v top >/dev/null 2>&1; then
        cpu_usage=$(top -b -n 1 -p $pid 2>/dev/null | tail -1 | awk '{print $9}')
        if [ -n "$cpu_usage" ]; then
            print_info "CPU usage: ${cpu_usage}%"
            
            # Check if CPU is throttled (should be around 50% or less)
            cpu_int=$(echo "$cpu_usage" | cut -d. -f1)
            if [ "$cpu_int" -le 60 ] 2>/dev/null; then
                print_pass "CPU appears to be throttled (${cpu_usage}%)"
            else
                print_warn "CPU usage is ${cpu_usage}% - may not be throttled"
            fi
        fi
    fi
    
    wait $pid 2>/dev/null
    
    # Check throttling stats
    if [ -n "$CGROUP_PATH" ] && [ -f "/sys/fs/cgroup${CGROUP_PATH}/cpu.stat" ]; then
        throttled=$(grep "nr_throttled" /sys/fs/cgroup${CGROUP_PATH}/cpu.stat 2>/dev/null | awk '{print $2}')
        if [ -n "$throttled" ] && [ "$throttled" -gt 0 ]; then
            print_pass "CPU was throttled $throttled times - quota is working!"
        else
            print_warn "No throttling detected in cpu.stat"
        fi
    fi
}

# ============================================================
#                    PID Limit Test
# ============================================================
test_pids_limit() {
    print_header "PID LIMIT TEST (100 processes)"
    
    # Get cgroup info
    CGROUP_PATH=$(cat /proc/self/cgroup 2>/dev/null | head -1 | cut -d: -f3)
    PID_CGROUP="/sys/fs/cgroup${CGROUP_PATH}"
    
    print_info "Current PIDs cgroup settings:"
    if [ -f "$PID_CGROUP/pids.max" ]; then
        pids_max=$(cat "$PID_CGROUP/pids.max")
        pids_current=$(cat "$PID_CGROUP/pids.current" 2>/dev/null)
        echo "  pids.max: $pids_max"
        echo "  pids.current: $pids_current"
    else
        print_warn "Cannot read cgroup PIDs settings"
        return
    fi
    
    # Handle "max" (no limit)
    if [ "$pids_max" = "max" ]; then
        print_warn "No PID limit set (max)"
        return
    fi
    
    # TEST 1: Spawn a safe number of processes
    spawn_count=30  # Safe count that won't exhaust PIDs
    
    print_test "Spawning $spawn_count background processes (should succeed)"
    
    spawned=0
    for i in $(seq 1 $spawn_count); do
        sleep 300 &
        if [ $? -eq 0 ]; then
            spawned=$((spawned + 1))
        fi
    done 2>/dev/null
    
    if [ $spawned -eq $spawn_count ]; then
        print_pass "Successfully spawned $spawned processes"
    else
        print_warn "Spawned $spawned of $spawn_count processes"
    fi
    
    # CLEANUP first batch before second test
    print_info "Cleaning up first batch..."
    pkill -u "$(whoami)" -f "sleep 300" 2>/dev/null
    sleep 1
    wait 2>/dev/null
    
    # TEST 2: Try to exceed the limit
    pids_current=$(cat "$PID_CGROUP/pids.current" 2>/dev/null)
    available=$((pids_max - pids_current))
    spawn_over=$((available + 20))  # Try to spawn more than available
    
    print_test "Spawning $spawn_over processes (should exceed limit of $pids_max)"
    
    spawned=0
    fork_failed=0
    for i in $(seq 1 $spawn_over); do
        sleep 300 2>/dev/null &
        if [ $? -eq 0 ]; then
            spawned=$((spawned + 1))
        else
            fork_failed=1
            break
        fi
    done 2>/dev/null
    
    print_info "Managed to spawn $spawned of $spawn_over requested"
    
    # Check if we hit the limit
    if [ $fork_failed -eq 1 ]; then
        print_pass "Fork failed at process $spawned - PID limit enforced!"
    elif [ -f "$PID_CGROUP/pids.events" ]; then
        fork_fails=$(grep "max" "$PID_CGROUP/pids.events" 2>/dev/null | awk '{print $2}')
        if [ -n "$fork_fails" ] && [ "$fork_fails" -gt 0 ]; then
            print_pass "Fork limit hit! ($fork_fails failures in pids.events)"
        else
            print_fail "All processes spawned - limit may not be enforced"
        fi
    else
        print_fail "All processes spawned - limit may not be enforced"
    fi
    
    # Final cleanup
    print_info "Final cleanup..."
    pkill -u "$(whoami)" -f "sleep 300" 2>/dev/null
    sleep 1
    wait 2>/dev/null
    
    if [ -f "$PID_CGROUP/pids.current" ]; then
        pids_after=$(cat "$PID_CGROUP/pids.current" 2>/dev/null)
        print_info "PIDs after cleanup: $pids_after"
    fi
}

# ============================================================
#                    Disk Quota Test
# ============================================================
test_disk_quota() {
    print_header "DISK QUOTA TEST (5MB)"
    
    print_info "Current disk quota:"
    if command -v quota >/dev/null 2>&1; then
        quota -s 2>/dev/null || print_warn "Cannot read quota (may need quota enabled)"
    else
        print_warn "quota command not available"
    fi
    
    # Test in home directory
    TEST_DIR="$HOME"
    if [ ! -w "$TEST_DIR" ]; then
        TEST_DIR="/tmp/quota_test_$$"
        mkdir -p "$TEST_DIR"
    fi
    
    print_test "Writing 2MB file (should succeed)"
    
    if dd if=/dev/zero of="$TEST_DIR/test_2mb.tmp" bs=1M count=2 2>/dev/null; then
        print_pass "2MB file created successfully"
        rm -f "$TEST_DIR/test_2mb.tmp"
    else
        print_fail "Failed to create 2MB file"
    fi
    
    print_test "Writing 10MB file (should fail with quota exceeded)"
    
    # Try to write 10MB
    dd if=/dev/zero of="$TEST_DIR/test_10mb.tmp" bs=1M count=10 2>&1
    result=$?
    
    # Check the file size
    if [ -f "$TEST_DIR/test_10mb.tmp" ]; then
        actual_size=$(du -m "$TEST_DIR/test_10mb.tmp" 2>/dev/null | cut -f1)
        print_info "Actual file size: ${actual_size}MB"
        
        if [ "$actual_size" -lt 10 ] 2>/dev/null; then
            print_pass "File was truncated to ${actual_size}MB - quota is enforced!"
        else
            print_fail "Full 10MB file was created - quota may not be enforced"
        fi
        
        rm -f "$TEST_DIR/test_10mb.tmp"
    elif [ $result -ne 0 ]; then
        print_pass "Write failed - quota is enforced!"
    else
        print_warn "Unexpected result"
    fi
    
    # Cleanup
    rm -f "$TEST_DIR/test_*.tmp" 2>/dev/null
}

# ============================================================
#                    Main
# ============================================================
main() {
    echo ""
    echo "============================================================"
    echo "       WebShell Resource Limits Test Suite"
    echo "============================================================"
    echo "  User:     $(whoami)"
    echo "  UID:      $(id -u)"
    echo "  Home:     $HOME"
    echo "  Cgroup:   $(cat /proc/self/cgroup 2>/dev/null | head -1)"
    echo "============================================================"
    
    # Run all tests (PIDs last since it may exhaust fork limit)
    test_memory_limit
    test_cpu_quota
    test_disk_quota
    test_pids_limit
}

# Check for specific test argument
case "$1" in
    memory)
        test_memory_limit
        ;;
    cpu)
        test_cpu_quota
        ;;
    pids)
        test_pids_limit
        ;;
    disk)
        test_disk_quota
        ;;
    *)
        main
        ;;
esac

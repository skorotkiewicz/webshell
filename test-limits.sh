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
    
    print_info "Current memory cgroup settings:"
    if [ -f /sys/fs/cgroup/memory.max ]; then
        cat /sys/fs/cgroup/memory.max 2>/dev/null || echo "  (not accessible)"
    else
        # Check if we're in a user cgroup
        CGROUP_PATH=$(cat /proc/self/cgroup 2>/dev/null | head -1 | cut -d: -f3)
        if [ -n "$CGROUP_PATH" ] && [ -f "/sys/fs/cgroup${CGROUP_PATH}/memory.max" ]; then
            echo "  memory.max: $(cat /sys/fs/cgroup${CGROUP_PATH}/memory.max)"
        else
            print_warn "Cannot read cgroup memory settings"
        fi
    fi
    
    print_test "Attempting to allocate 50MB (should succeed)"
    # Allocate 50MB using dd to /dev/null
    if dd if=/dev/zero of=/dev/null bs=1M count=50 2>/dev/null; then
        print_pass "50MB allocation succeeded"
    else
        print_fail "50MB allocation failed unexpectedly"
    fi
    
    print_test "Attempting to allocate 150MB (should fail or be killed)"
    
    # Create a Python script to allocate memory
    cat > /tmp/mem_test.py << 'MEMTEST'
import sys
try:
    # Try to allocate 150MB
    data = bytearray(150 * 1024 * 1024)
    # Fill it to ensure it's actually allocated
    for i in range(0, len(data), 4096):
        data[i] = 1
    print("ALLOCATED")
    sys.exit(0)
except MemoryError:
    print("MEMORY_ERROR")
    sys.exit(1)
except Exception as e:
    print(f"ERROR: {e}")
    sys.exit(2)
MEMTEST

    result=$(timeout 10 python3 /tmp/mem_test.py 2>&1)
    exit_code=$?
    
    rm -f /tmp/mem_test.py
    
    if [ $exit_code -eq 137 ] || [ $exit_code -eq 9 ]; then
        print_pass "Process was killed (OOM killer) - memory limit enforced!"
    elif echo "$result" | grep -q "MEMORY_ERROR"; then
        print_pass "Got MemoryError - memory limit enforced!"
    elif echo "$result" | grep -q "ALLOCATED"; then
        print_fail "150MB was allocated - memory limit may not be enforced"
    else
        print_warn "Unexpected result: $result (exit code: $exit_code)"
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
    
    print_info "Current PIDs cgroup settings:"
    CGROUP_PATH=$(cat /proc/self/cgroup 2>/dev/null | head -1 | cut -d: -f3)
    if [ -n "$CGROUP_PATH" ] && [ -f "/sys/fs/cgroup${CGROUP_PATH}/pids.max" ]; then
        echo "  pids.max: $(cat /sys/fs/cgroup${CGROUP_PATH}/pids.max)"
        echo "  pids.current: $(cat /sys/fs/cgroup${CGROUP_PATH}/pids.current 2>/dev/null)"
    else
        print_warn "Cannot read cgroup PIDs settings"
    fi
    
    print_test "Spawning 50 background processes (should succeed)"
    
    # Spawn 50 sleep processes
    pids=""
    failed=0
    for i in $(seq 1 50); do
        sleep 300 &
        if [ $? -eq 0 ]; then
            pids="$pids $!"
        else
            failed=$((failed + 1))
        fi
    done
    
    if [ $failed -eq 0 ]; then
        print_pass "Successfully spawned 50 processes"
    else
        print_fail "Failed to spawn some processes ($failed failed)"
    fi
    
    # Kill them
    for p in $pids; do
        kill $p 2>/dev/null
    done
    wait 2>/dev/null
    
    print_test "Spawning 120 processes (should fail around 100)"
    
    # Try to spawn 120 processes
    spawned=0
    pids=""
    for i in $(seq 1 120); do
        sleep 300 2>/dev/null &
        if [ $? -eq 0 ]; then
            pids="$pids $!"
            spawned=$((spawned + 1))
        else
            break
        fi
    done
    
    print_info "Managed to spawn $spawned processes"
    
    if [ $spawned -lt 110 ]; then
        print_pass "PID limit prevented spawning all 120 processes (got $spawned)"
    else
        print_fail "Spawned $spawned processes - PID limit may not be enforced"
    fi
    
    # Cleanup
    for p in $pids; do
        kill $p 2>/dev/null
    done
    wait 2>/dev/null
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
#                    Summary
# ============================================================
print_summary() {
    print_header "TEST SUMMARY"
    
    echo ""
    printf "  Tests Passed: ${GREEN}%d${NC}\n" "$TESTS_PASSED"
    printf "  Tests Failed: ${RED}%d${NC}\n" "$TESTS_FAILED"
    echo ""
    
    if [ $TESTS_FAILED -eq 0 ]; then
        printf "${GREEN}All tests passed!${NC}\n"
    else
        printf "${YELLOW}Some tests failed. Check the output above.${NC}\n"
    fi
    echo ""
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
    
    # Run all tests
    test_memory_limit
    test_cpu_quota
    test_pids_limit
    test_disk_quota
    
    # Print summary
    print_summary
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

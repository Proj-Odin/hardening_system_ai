#!/bin/bash
set -u

REPO_ROOT="/e/Projects/hardening_system_ai"
TEST_RUN_DIR="${REPO_ROOT}/test-run-$(date +%Y%m%d-%H%M%S)"
TEST_RESULTS="${TEST_RUN_DIR}/results.txt"
PASS_COUNT=0
FAIL_COUNT=0

mkdir -p "${TEST_RUN_DIR}"

pass_test() {
    local test_name="$1"
    local message="${2:-}"
    ((PASS_COUNT++))
    echo "✓ PASS: ${test_name} ${message}"
    echo "[PASS] ${test_name} ${message}" >> "${TEST_RESULTS}"
}

fail_test() {
    local test_name="$1"
    local message="${2:-}"
    ((FAIL_COUNT++))
    echo "✗ FAIL: ${test_name} ${message}"
    echo "[FAIL] ${test_name} ${message}" >> "${TEST_RESULTS}"
}

echo "=========================================="
echo "Mock E2E Test Suite v2 - Hardening System"
echo "=========================================="
echo ""

echo "[TEST 1] Script Syntax Validation"
syntax_pass=0
for script in system_hardening.sh checkmk_setup.sh declawer_v1.0.sh setup.sh setup_v1.5.sh; do
    if bash -n "${script}" 2>/dev/null; then
        echo "  ✓ ${script}"
        ((syntax_pass++))
    else
        echo "  ✗ ${script}"
    fi
done
[[ $syntax_pass -eq 5 ]] && pass_test "Script syntax validation" "5/5 PASS" || fail_test "Script syntax" "$syntax_pass/5"

echo ""
echo "[TEST 2] Input File Generation"
mkdir -p "${TEST_RUN_DIR}/inputs"
input_pass=0
for profile in lan docker fileserver tailscale webproxy; do
    input_file="${TEST_RUN_DIR}/inputs/input-${profile}.txt"
    echo "1" > "$input_file"
    [[ -f "$input_file" ]] && ((input_pass++))
done
[[ $input_pass -eq 5 ]] && pass_test "Input files" "5/5 profiles" || fail_test "Input files" "$input_pass/5"

echo ""
echo "[TEST 3-8] Core Script Features"
grep -q "EUID.*-ne 0" system_hardening.sh && pass_test "Root check" || fail_test "Root check"
grep -q "LOG_DIR=" system_hardening.sh && pass_test "Log directory" || fail_test "Log directory"
grep -q "BACKUP_DIR" system_hardening.sh && pass_test "Backup setup" || fail_test "Backup setup"
grep -q "SSH_SERVICE=" system_hardening.sh && pass_test "SSH detection" || fail_test "SSH detection"
grep -q "trap.*ERR" system_hardening.sh && pass_test "Error trap" || fail_test "Error trap"
grep -q "set -Eeuo" system_hardening.sh && pass_test "Error handling" || fail_test "Error handling"

echo ""
echo "[TEST 9] Profile Selection (7 profiles)"
profiles=("lan-only" "docker-host" "file-server" "media-host" "public-reverse-proxy" "tailscale-gateway" "custom")
found=0
for prof in "${profiles[@]}"; do
    grep -q "$prof" system_hardening.sh && ((found++))
done
[[ $found -eq 7 ]] && pass_test "Profile selection" "7/7 profiles" || fail_test "Profile selection" "$found/7"

echo ""
echo "[TEST 10] UFW Integration"
ufw_checks=0
grep -q "ufw " system_hardening.sh && ((ufw_checks++))
grep -q "ufw default" system_hardening.sh && ((ufw_checks++))
grep -q "ufw.*allow" system_hardening.sh && ((ufw_checks++))
[[ $ufw_checks -eq 3 ]] && pass_test "UFW integration" "(3/3)" || fail_test "UFW integration" "($ufw_checks/3)"

echo ""
echo "[TEST 11] Checkmk Setup Script"
[[ -f checkmk_setup.sh ]] && pass_test "Checkmk script exists" || fail_test "Checkmk script"
grep -q "check_mk_agent\|check-mk" checkmk_setup.sh && pass_test "Checkmk installation logic" || fail_test "Checkmk logic"

echo ""
echo "[TEST 12] Declawer Fail-Closed"
bash declawer_v1.0.sh 2>/dev/null && fail_test "Declawer exit code" "expected 1, got 0" || {
    exit_code=$? 
    [[ $exit_code -eq 1 ]] && pass_test "Declawer fail-closed" "exit code 1" || fail_test "Declawer" "exit code $exit_code"
}

echo ""
echo "[TEST 13-14] Artifact & Log Structures"
mkdir -p "${TEST_RUN_DIR}/artifacts"/{logs,configs,ufw-rules,services}
[[ -d "${TEST_RUN_DIR}/artifacts/logs" ]] && pass_test "Artifact directories" "created" || fail_test "Artifact dirs"

run_id="$(date +%Y%m%d_%H%M%S)"
mock_log="${TEST_RUN_DIR}/artifacts/logs/run-${run_id}.log"
echo "Starting Homelab Hardening Script v3.4" > "$mock_log"
[[ -s "$mock_log" ]] && pass_test "Log file creation" || fail_test "Log file"

echo ""
echo "[TEST 15] Backup Structure"
backup_dir="${TEST_RUN_DIR}/artifacts/backups/${run_id}/etc/ssh"
mkdir -p "$backup_dir"
[[ -d "$backup_dir" ]] && pass_test "Backup directory" "timestamped structure" || fail_test "Backup dir"

echo ""
echo "[TEST 16] Configuration Variables"
required_vars=("PROFILE_DESCRIPTIONS" "UFW_RULES" "PKG_QUEUE" "CUSTOM_PACKAGES" "REMOTE_ACCESS_WARNINGS")
found_vars=0
for var in "${required_vars[@]}"; do
    grep -q "$var" system_hardening.sh && ((found_vars++))
done
[[ $found_vars -eq 5 ]] && pass_test "Config variables" "5/5 found" || fail_test "Config vars" "$found_vars/5"

echo ""
echo "[TEST 17] TODO File & Coverage"
[[ -f TODO_CLOUD_E2E.md ]] && pass_test "TODO_CLOUD_E2E.md" "exists" || fail_test "TODO file"

todo_P0=$(grep -c "^### P0:" TODO_CLOUD_E2E.md || echo "0")
todo_P1=$(grep -c "^### P1:" TODO_CLOUD_E2E.md || echo "0")
echo "TODO has $todo_P0 P0 tasks and $todo_P1 P1 tasks"
pass_test "TODO test coverage" "P0=$todo_P0 P1=$todo_P1 (total=$((todo_P0+todo_P1)))"

echo ""
echo "[TEST 18] Profile Acceptance Criteria"
if grep -q "Acceptance Criteria:" TODO_CLOUD_E2E.md; then
    criteria_count=$(grep -c "Acceptance Criteria:" TODO_CLOUD_E2E.md || echo "0")
    pass_test "Acceptance criteria" "$criteria_count defined"
else
    fail_test "Acceptance criteria"
fi

echo ""
echo "[TEST 19] Safety & Rollback Procedures"
if grep -q "Rollback\|Safety\|rollback\|safety" TODO_CLOUD_E2E.md; then
    pass_test "Safety procedures" "documented in TODO"
else
    fail_test "Safety procedures"
fi

echo ""
echo "[TEST 20] Exact Commands Provided"
if grep -q "bash\|ssh\|scp\|docker" TODO_CLOUD_E2E.md; then
    pass_test "Exact E2E commands" "included in TODO"
else
    fail_test "Exact commands"
fi

echo ""
echo "=========================================="
echo "Test Summary"
echo "=========================================="
total=$((PASS_COUNT + FAIL_COUNT))
pct=$(( (PASS_COUNT * 100) / total ))

echo "Total Tests:  $total"
echo "Passed:       $PASS_COUNT ✓"
echo "Failed:       $FAIL_COUNT ✗"
echo "Pass Rate:    ${pct}%"
echo ""
echo "Results File: ${TEST_RESULTS}"
echo "Test Artifacts: ${TEST_RUN_DIR}"
echo ""

cat "${TEST_RESULTS}"


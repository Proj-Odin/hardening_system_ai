#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}"
RUN_ID="${RUN_ID:-$(date +%Y%m%d-%H%M%S)}"
TEST_RUN_DIR="${TEST_RUN_DIR:-${REPO_ROOT}/test-run-${RUN_ID}}"
TEST_RESULTS="${TEST_RUN_DIR}/results.txt"
ARTIFACT_LOG="${TEST_RUN_DIR}/artifacts/logs/mock-e2e.log"

PASS_COUNT=0
FAIL_COUNT=0

mkdir -p "${TEST_RUN_DIR}/artifacts/logs"
: > "${TEST_RESULTS}"
: > "${ARTIFACT_LOG}"

pass_test() {
    local test_name="$1"
    local message="${2:-}"
    PASS_COUNT=$((PASS_COUNT + 1))
    printf 'PASS: %s %s\n' "${test_name}" "${message}" | tee -a "${TEST_RESULTS}"
}

fail_test() {
    local test_name="$1"
    local message="${2:-}"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    printf 'FAIL: %s %s\n' "${test_name}" "${message}" | tee -a "${TEST_RESULTS}"
}

find_python() {
    if command -v python3 >/dev/null 2>&1; then
        echo "python3"
    elif command -v python >/dev/null 2>&1; then
        echo "python"
    else
        return 1
    fi
}

run_logged() {
    local test_name="$1"
    shift
    if "$@" >> "${ARTIFACT_LOG}" 2>&1; then
        pass_test "${test_name}"
    else
        fail_test "${test_name}" "see ${ARTIFACT_LOG}"
    fi
}

echo "=========================================="
echo "Mock E2E Smoke Check - Hardening System"
echo "=========================================="
echo "Repo: ${REPO_ROOT}"
echo "Artifacts: ${TEST_RUN_DIR}"
echo ""

echo "[TEST 1] Shell Syntax"
shell_scripts=(
    system_hardening.sh
    system_hardening_alpine.sh
    system_hardening_alpine_vm.sh
    system_hardening_alpine_lxc.sh
    checkmk_setup.sh
    declawer_v1.0.sh
    setup.sh
    setup_v1.5.sh
    test_ssh_port_detection.sh
    mock_e2e_tests.sh
)
syntax_pass=0
for script in "${shell_scripts[@]}"; do
    if bash -n "${REPO_ROOT}/${script}" >> "${ARTIFACT_LOG}" 2>&1; then
        syntax_pass=$((syntax_pass + 1))
    fi
done
if [[ "${syntax_pass}" -eq "${#shell_scripts[@]}" ]]; then
    pass_test "Shell syntax validation" "${syntax_pass}/${#shell_scripts[@]}"
else
    fail_test "Shell syntax validation" "${syntax_pass}/${#shell_scripts[@]} (see ${ARTIFACT_LOG})"
fi

echo ""
echo "[TEST 2] Shared Debian/Alpine Sync"
if python_bin="$(find_python)"; then
    run_logged "verify_hardening_sync.py" "${python_bin}" "${REPO_ROOT}/verify_hardening_sync.py"
else
    fail_test "verify_hardening_sync.py" "python or python3 not found"
fi

echo ""
echo "[TEST 3] SSH Port Detection Regression"
run_logged "test_ssh_port_detection.sh" bash "${REPO_ROOT}/test_ssh_port_detection.sh"

echo ""
echo "[TEST 4] Legacy Guardrail"
if bash "${REPO_ROOT}/declawer_v1.0.sh" >> "${ARTIFACT_LOG}" 2>&1; then
    fail_test "declawer_v1.0.sh fail-closed" "expected exit code 1"
else
    exit_code=$?
    if [[ "${exit_code}" -eq 1 ]]; then
        pass_test "declawer_v1.0.sh fail-closed" "exit code 1"
    else
        fail_test "declawer_v1.0.sh fail-closed" "unexpected exit code ${exit_code}"
    fi
fi

echo ""
echo "[TEST 5] Cloud TODO Structure"
todo_headings=(
    '^## Goals$'
    '^## What Is Already Covered Locally$'
    '^## Preflight$'
    '^## Cloud Test Matrix$'
    '^## Suggested Cloud Workflow$'
    '^## Immediate Next Tasks$'
    '^## Success Criteria$'
)
todo_pass=0
for heading in "${todo_headings[@]}"; do
    if grep -Eq "${heading}" "${REPO_ROOT}/TODO_CLOUD_E2E.md"; then
        todo_pass=$((todo_pass + 1))
    fi
done
if [[ "${todo_pass}" -eq "${#todo_headings[@]}" ]]; then
    pass_test "TODO_CLOUD_E2E.md structure" "${todo_pass}/${#todo_headings[@]}"
else
    fail_test "TODO_CLOUD_E2E.md structure" "${todo_pass}/${#todo_headings[@]}"
fi

echo ""
echo "[TEST 6] Ignore Rules"
ignore_pass=0
grep -Eq '^__pycache__/\r?$' "${REPO_ROOT}/.gitignore" && ignore_pass=$((ignore_pass + 1))
grep -Eq '^test-run-\*/\r?$' "${REPO_ROOT}/.gitignore" && ignore_pass=$((ignore_pass + 1))
grep -Eq '^test-run-\*\.tar\.gz\r?$' "${REPO_ROOT}/.gitignore" && ignore_pass=$((ignore_pass + 1))
if [[ "${ignore_pass}" -eq 3 ]]; then
    pass_test ".gitignore coverage" "3/3"
else
    fail_test ".gitignore coverage" "${ignore_pass}/3"
fi

echo ""
echo "[TEST 7] README Validation Notes"
readme_checks=0
grep -q 'verify_hardening_sync.py' "${REPO_ROOT}/README.md" && readme_checks=$((readme_checks + 1))
grep -q 'test_ssh_port_detection.sh' "${REPO_ROOT}/README.md" && readme_checks=$((readme_checks + 1))
grep -q 'mock_e2e_tests.sh' "${REPO_ROOT}/README.md" && readme_checks=$((readme_checks + 1))
grep -q 'TODO_CLOUD_E2E.md' "${REPO_ROOT}/README.md" && readme_checks=$((readme_checks + 1))
if [[ "${readme_checks}" -eq 4 ]]; then
    pass_test "README validation references" "4/4"
else
    fail_test "README validation references" "${readme_checks}/4"
fi

echo ""
echo "=========================================="
echo "Summary"
echo "=========================================="
total=$((PASS_COUNT + FAIL_COUNT))
pass_rate=0
if [[ "${total}" -gt 0 ]]; then
    pass_rate=$((PASS_COUNT * 100 / total))
fi

echo "Total:   ${total}"
echo "Passed:  ${PASS_COUNT}"
echo "Failed:  ${FAIL_COUNT}"
echo "Rate:    ${pass_rate}%"
echo "Results: ${TEST_RESULTS}"
echo "Log:     ${ARTIFACT_LOG}"

if [[ "${FAIL_COUNT}" -gt 0 ]]; then
    exit 1
fi

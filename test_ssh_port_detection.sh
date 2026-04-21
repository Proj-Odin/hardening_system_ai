#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

run_detect_case() {
    local script="$1"
    local case_name="$2"
    local sshd_bin="${3:-}"
    local sshd_t_port="${4:-}"
    local config_port="${5:-}"
    local socket_port="${6:-}"
    local expected="$7"

    SCRIPT_PATH="${script}" \
    CASE_NAME="${case_name}" \
    TEST_SSHD_BIN="${sshd_bin}" \
    TEST_SSHD_T_PORT="${sshd_t_port}" \
    TEST_CONFIG_PORT="${config_port}" \
    TEST_SOCKET_PORT="${socket_port}" \
    TEST_EXPECTED="${expected}" \
    bash -lc '
        set -euo pipefail
        source "${SCRIPT_PATH}"
        log() { :; }
        resolve_sshd_binary() {
            [[ -n "${TEST_SSHD_BIN}" ]] || return 1
            echo "${TEST_SSHD_BIN}"
        }
        detect_ssh_port_from_sshd_test() {
            [[ -n "${TEST_SSHD_T_PORT}" ]] || return 1
            echo "${TEST_SSHD_T_PORT}"
        }
        detect_ssh_port_from_config() {
            [[ -n "${TEST_CONFIG_PORT}" ]] || return 1
            echo "${TEST_CONFIG_PORT}"
        }
        detect_ssh_port_from_sockets() {
            [[ -n "${TEST_SOCKET_PORT}" ]] || return 1
            echo "${TEST_SOCKET_PORT}"
        }

        result="$(detect_ssh_port)"
        if [[ "${result}" != "${TEST_EXPECTED}" ]]; then
            echo "FAIL ${CASE_NAME}: expected ${TEST_EXPECTED}, got ${result}" >&2
            exit 1
        fi
    '
}

run_parser_case() {
    local script="$1"
    local case_name="$2"
    local expected="$3"

    SCRIPT_PATH="${script}" \
    CASE_NAME="${case_name}" \
    TEST_EXPECTED="${expected}" \
    bash -lc '
        set -euo pipefail
        source "${SCRIPT_PATH}"

        temp_dir="$(mktemp -d)"
        trap "rm -rf \"${temp_dir}\"" EXIT
        mkdir -p "${temp_dir}/sshd_config.d"

        cat > "${temp_dir}/sshd_config" <<EOF
Include ${temp_dir}/sshd_config.d/*.conf
# Commented directives should be ignored.
Port 22
EOF

        cat > "${temp_dir}/sshd_config.d/10-custom.conf" <<EOF
Port ${TEST_EXPECTED}
Match User backup
    PasswordAuthentication no
EOF

        SSHD_CONFIG_PARSE_SEEN=()
        result="$(parse_sshd_port_from_file "${temp_dir}/sshd_config")"
        if [[ "${result}" != "${TEST_EXPECTED}" ]]; then
            echo "FAIL ${CASE_NAME}: expected ${TEST_EXPECTED}, got ${result}" >&2
            exit 1
        fi
    '
}

run_text_case() {
    local script="$1"
    local case_name="$2"
    local expected="$3"

    SCRIPT_PATH="${script}" \
    CASE_NAME="${case_name}" \
    TEST_EXPECTED="${expected}" \
    bash -lc '
        set -euo pipefail
        source "${SCRIPT_PATH}"

        sample_output=$'"'"'port '"'"'"${TEST_EXPECTED}"$'"'"'\nlistenaddress 0.0.0.0\n'"'"'
        result="$(extract_first_port_from_text "${sample_output}")"
        if [[ "${result}" != "${TEST_EXPECTED}" ]]; then
            echo "FAIL ${CASE_NAME}: expected ${TEST_EXPECTED}, got ${result}" >&2
            exit 1
        fi
    '
}

run_suite_for_script() {
    local script="$1"

    run_text_case "${script}" "parse-sshd-t-output" "22"
    run_parser_case "${script}" "config-include-port" "2022"
    run_detect_case "${script}" "normal-port-22" "/usr/sbin/sshd" "22" "" "" "22"
    run_detect_case "${script}" "custom-port" "/usr/sbin/sshd" "2222" "" "" "2222"
    run_detect_case "${script}" "sshd-missing" "" "" "2200" "" "2200"
    run_detect_case "${script}" "sshd-t-failure" "/usr/sbin/sshd" "" "2022" "" "2022"
    run_detect_case "${script}" "socket-fallback" "/usr/sbin/sshd" "" "" "2201" "2201"
    run_detect_case "${script}" "default-22-fallback" "/usr/sbin/sshd" "" "" "" "22"
}

run_suite_for_script "${ROOT_DIR}/system_hardening.sh"
run_suite_for_script "${ROOT_DIR}/system_hardening_alpine.sh"

echo "SSH port detection tests passed."

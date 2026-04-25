#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

run_case() {
    local script="$1"
    local case_name="$2"
    local operation="$3"

    SCRIPT_PATH="${script}" \
    CASE_NAME="${case_name}" \
    TEST_OPERATION="${operation}" \
    bash -lc '
        set -euo pipefail
        source "${SCRIPT_PATH}"

        TEST_TMP="$(mktemp -d)"
        trap "rm -rf \"${TEST_TMP}\"" EXIT
        TEST_SYSCTL_FILE="${TEST_TMP}/99-disable-ipv6.conf"
        BACKUP_DIR="${TEST_TMP}/backup"
        TEST_ACTIVE_VALUE="${TEST_ACTIVE_VALUE:-0}"
        TEST_MISSING_KEYS="${TEST_MISSING_KEYS:-}"
        declare -a TEST_LOGS=()
        declare -a TEST_WARNINGS=()

        log() {
            TEST_LOGS+=("$*")
        }

        warn() {
            TEST_WARNINGS+=("$*")
            TEST_LOGS+=("WARN: $*")
        }

        key_is_missing() {
            local key="$1"
            [[ " ${TEST_MISSING_KEYS} " == *" ${key} "* ]]
        }

        sysctl() {
            local key=""
            local value=""

            case "$1" in
                -n)
                    key="$2"
                    if key_is_missing "${key}"; then
                        echo "sysctl: cannot stat /proc/sys/${key//.//}: No such file or directory" >&2
                        return 1
                    fi
                    echo "${TEST_ACTIVE_VALUE}"
                    return 0
                    ;;
                -w)
                    key="${2%%=*}"
                    value="${2#*=}"
                    if key_is_missing "${key}"; then
                        echo "sysctl: cannot stat /proc/sys/${key//.//}: No such file or directory" >&2
                        return 1
                    fi
                    echo "${key} = ${value}"
                    return 0
                    ;;
                --system)
                    echo "mock sysctl --system"
                    return 0
                    ;;
                net.ipv6.conf.*)
                    key="$1"
                    if key_is_missing "${key}"; then
                        echo "sysctl: cannot stat /proc/sys/${key//.//}: No such file or directory" >&2
                        return 1
                    fi
                    echo "${key} = 1"
                    return 0
                    ;;
                *)
                    echo "unexpected sysctl call: $*" >&2
                    return 1
                    ;;
            esac
        }

        ip() {
            if [[ "$1" == "-6" && "$2" == "addr" && "$3" == "show" ]]; then
                echo "1: lo: <LOOPBACK,UP,LOWER_UP>"
                return 0
            fi
            echo "unexpected ip call: $*" >&2
            return 1
        }

        expected_ipv6_dropin() {
            cat <<EOF
# Managed by system_hardening.sh
# Disable IPv6 system-wide
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF
        }

        assert_expected_file() {
            diff -u <(expected_ipv6_dropin) "${TEST_SYSCTL_FILE}" >/dev/null
        }

        assert_log_contains() {
            local expected="$1"
            local entry=""
            for entry in "${TEST_LOGS[@]}" "${TEST_WARNINGS[@]}"; do
                if [[ "${entry}" == *"${expected}"* ]]; then
                    return 0
                fi
            done
            echo "FAIL ${CASE_NAME}: expected log containing [${expected}]" >&2
            return 1
        }

        case "${TEST_OPERATION}" in
            interactive-default-no)
                DISABLE_IPV6=false
                configure_ipv6_disable_prompt <<< ""
                apply_ipv6_disable "${DISABLE_IPV6}" "${TEST_SYSCTL_FILE}"
                if [[ -e "${TEST_SYSCTL_FILE}" ]]; then
                    echo "FAIL ${CASE_NAME}: default No created ${TEST_SYSCTL_FILE}" >&2
                    exit 1
                fi
                assert_log_contains "IPv6 disable option not selected"
                ;;
            interactive-yes)
                DISABLE_IPV6=false
                configure_ipv6_disable_prompt <<< "y"
                apply_ipv6_disable "${DISABLE_IPV6}" "${TEST_SYSCTL_FILE}"
                assert_expected_file
                assert_log_contains "Disabling IPv6 via managed sysctl drop-in"
                assert_log_contains "IPv6 validation: net.ipv6.conf.all.disable_ipv6 = 1"
                assert_log_contains "IPv6 validation: 1: lo:"
                ;;
            rerun-no-duplicates)
                apply_ipv6_disable true "${TEST_SYSCTL_FILE}"
                apply_ipv6_disable true "${TEST_SYSCTL_FILE}"
                assert_expected_file
                for key in \
                    net.ipv6.conf.all.disable_ipv6 \
                    net.ipv6.conf.default.disable_ipv6 \
                    net.ipv6.conf.lo.disable_ipv6; do
                    if [[ "$(grep -c "^${key} = 1$" "${TEST_SYSCTL_FILE}")" -ne 1 ]]; then
                        echo "FAIL ${CASE_NAME}: duplicate or missing ${key}" >&2
                        exit 1
                    fi
                done
                ;;
            existing-managed-file-updated)
                mkdir -p "$(dirname "${TEST_SYSCTL_FILE}")"
                printf "%s\n" "# stale" "net.ipv6.conf.all.disable_ipv6 = 0" "net.ipv6.conf.all.disable_ipv6 = 0" > "${TEST_SYSCTL_FILE}"
                apply_ipv6_disable true "${TEST_SYSCTL_FILE}"
                assert_expected_file
                if grep -q "stale" "${TEST_SYSCTL_FILE}"; then
                    echo "FAIL ${CASE_NAME}: stale content remained" >&2
                    exit 1
                fi
                ;;
            missing-sysctl-keys-warn)
                TEST_MISSING_KEYS="net.ipv6.conf.default.disable_ipv6 net.ipv6.conf.lo.disable_ipv6"
                apply_ipv6_disable true "${TEST_SYSCTL_FILE}"
                assert_expected_file
                assert_log_contains "Could not set net.ipv6.conf.default.disable_ipv6=1"
                assert_log_contains "Could not read net.ipv6.conf.lo.disable_ipv6"
                ;;
            noninteractive-variable)
                DISABLE_IPV6=true
                apply_ipv6_disable "" "${TEST_SYSCTL_FILE}"
                assert_expected_file
                ;;
            already-disabled-log)
                TEST_ACTIVE_VALUE=1
                apply_ipv6_disable true "${TEST_SYSCTL_FILE}"
                assert_expected_file
                assert_log_contains "IPv6 is already disabled by active sysctl settings"
                ;;
            *)
                echo "FAIL ${CASE_NAME}: unknown operation ${TEST_OPERATION}" >&2
                exit 1
                ;;
        esac
    '
}

run_suite_for_script() {
    local script="$1"

    run_case "${script}" "interactive-default-no" "interactive-default-no"
    run_case "${script}" "interactive-yes" "interactive-yes"
    run_case "${script}" "rerun-no-duplicates" "rerun-no-duplicates"
    run_case "${script}" "existing-managed-file-updated" "existing-managed-file-updated"
    run_case "${script}" "missing-sysctl-keys-warn" "missing-sysctl-keys-warn"
    run_case "${script}" "noninteractive-variable" "noninteractive-variable"
    run_case "${script}" "already-disabled-log" "already-disabled-log"
}

run_suite_for_script "${ROOT_DIR}/system_hardening.sh"
run_suite_for_script "${ROOT_DIR}/system_hardening_alpine.sh"

echo "IPv6 disable tests passed."

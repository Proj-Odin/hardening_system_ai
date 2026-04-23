#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

run_case() {
    local script="$1"
    local case_name="$2"
    local existing_users="${3:-}"
    local existing_groups="${4:-}"
    local username="$5"
    local login_shell="$6"
    local operation="$7"
    local expected_useradd="${8:-}"
    local expected_usermod="${9:-}"
    local expected_log="${10:-}"

    SCRIPT_PATH="${script}" \
    CASE_NAME="${case_name}" \
    TEST_EXISTING_USERS="${existing_users}" \
    TEST_EXISTING_GROUPS="${existing_groups}" \
    TEST_USERNAME="${username}" \
    TEST_LOGIN_SHELL="${login_shell}" \
    TEST_OPERATION="${operation}" \
    TEST_EXPECTED_USERADD="${expected_useradd}" \
    TEST_EXPECTED_USERMOD="${expected_usermod}" \
    TEST_EXPECTED_LOG="${expected_log}" \
    bash -lc '
        set -euo pipefail
        source "${SCRIPT_PATH}"

        declare -a TEST_LOGS=()
        declare -a TEST_WARNINGS=()
        declare -a TEST_USERADD_CALLS=()
        declare -a TEST_USERMOD_CALLS=()

        contains_name() {
            local list="$1"
            local name="$2"
            local item=""

            IFS="," read -r -a items <<< "${list}"
            for item in "${items[@]}"; do
                if [[ "${item}" == "${name}" ]]; then
                    return 0
                fi
            done

            return 1
        }

        log() {
            TEST_LOGS+=("$*")
        }

        add_warning() {
            TEST_WARNINGS+=("$*")
        }

        id() {
            if [[ "$1" == "-u" ]] && contains_name "${TEST_EXISTING_USERS}" "$2"; then
                return 0
            fi
            return 1
        }

        getent() {
            if [[ "$1" == "group" ]] && contains_name "${TEST_EXISTING_GROUPS}" "$2"; then
                printf "%s:x:1000:\n" "$2"
                return 0
            fi
            return 2
        }

        useradd() {
            TEST_USERADD_CALLS+=("$*")
            return 0
        }

        usermod() {
            TEST_USERMOD_CALLS+=("$*")
            return 0
        }

        case "${TEST_OPERATION}" in
            ensure)
                ensure_local_user_present "${TEST_USERNAME}" "${TEST_LOGIN_SHELL}"
                ;;
            note)
                note_existing_group_reuse_for_requested_user "${TEST_USERNAME}" >/tmp/test-note-output.txt
                ;;
            *)
                echo "FAIL ${CASE_NAME}: unknown operation ${TEST_OPERATION}" >&2
                exit 1
                ;;
        esac

        if [[ -n "${TEST_EXPECTED_USERADD}" ]]; then
            if [[ "${#TEST_USERADD_CALLS[@]}" -ne 1 || "${TEST_USERADD_CALLS[0]}" != "${TEST_EXPECTED_USERADD}" ]]; then
                echo "FAIL ${CASE_NAME}: expected useradd [${TEST_EXPECTED_USERADD}], got [${TEST_USERADD_CALLS[*]:-}]" >&2
                exit 1
            fi
        elif [[ "${#TEST_USERADD_CALLS[@]}" -ne 0 ]]; then
            echo "FAIL ${CASE_NAME}: unexpected useradd calls [${TEST_USERADD_CALLS[*]}]" >&2
            exit 1
        fi

        if [[ -n "${TEST_EXPECTED_USERMOD}" ]]; then
            if [[ "${#TEST_USERMOD_CALLS[@]}" -ne 1 || "${TEST_USERMOD_CALLS[0]}" != "${TEST_EXPECTED_USERMOD}" ]]; then
                echo "FAIL ${CASE_NAME}: expected usermod [${TEST_EXPECTED_USERMOD}], got [${TEST_USERMOD_CALLS[*]:-}]" >&2
                exit 1
            fi
        elif [[ "${#TEST_USERMOD_CALLS[@]}" -ne 0 ]]; then
            echo "FAIL ${CASE_NAME}: unexpected usermod calls [${TEST_USERMOD_CALLS[*]}]" >&2
            exit 1
        fi

        if [[ -n "${TEST_EXPECTED_LOG}" ]]; then
            log_found=0
            for entry in "${TEST_LOGS[@]}" "${TEST_WARNINGS[@]}"; do
                if [[ "${entry}" == *"${TEST_EXPECTED_LOG}"* ]]; then
                    log_found=1
                    break
                fi
            done

            if [[ "${TEST_OPERATION}" == "note" && -f /tmp/test-note-output.txt ]]; then
                note_output="$(cat /tmp/test-note-output.txt)"
                rm -f /tmp/test-note-output.txt
                if [[ "${note_output}" == *"${TEST_EXPECTED_LOG}"* ]]; then
                    log_found=1
                fi
            fi

            if [[ "${log_found}" -ne 1 ]]; then
                echo "FAIL ${CASE_NAME}: expected log containing [${TEST_EXPECTED_LOG}]" >&2
                exit 1
            fi
        fi
    '
}

run_dual_creation_case() {
    local script="$1"
    local case_name="$2"

    SCRIPT_PATH="${script}" \
    CASE_NAME="${case_name}" \
    bash -lc '
        set -euo pipefail
        source "${SCRIPT_PATH}"

        declare -a TEST_LOGS=()
        declare -a TEST_USERADD_CALLS=()
        declare -a TEST_USERMOD_CALLS=()

        log() {
            TEST_LOGS+=("$*")
        }

        id() {
            return 1
        }

        getent() {
            return 2
        }

        useradd() {
            TEST_USERADD_CALLS+=("$*")
            return 0
        }

        usermod() {
            TEST_USERMOD_CALLS+=("$*")
            return 0
        }

        ensure_local_user_present "ops" "/bin/bash"
        ensure_local_user_present "admin" "/bin/bash"

        if [[ "${#TEST_USERADD_CALLS[@]}" -ne 2 ]]; then
            echo "FAIL ${CASE_NAME}: expected 2 useradd calls, got ${#TEST_USERADD_CALLS[@]}" >&2
            exit 1
        fi

        if [[ "${TEST_USERADD_CALLS[0]}" != "-m -s /bin/bash ops" || "${TEST_USERADD_CALLS[1]}" != "-m -s /bin/bash admin" ]]; then
            echo "FAIL ${CASE_NAME}: unexpected useradd calls [${TEST_USERADD_CALLS[*]}]" >&2
            exit 1
        fi

        if [[ "${#TEST_USERMOD_CALLS[@]}" -ne 0 ]]; then
            echo "FAIL ${CASE_NAME}: unexpected usermod calls [${TEST_USERMOD_CALLS[*]}]" >&2
            exit 1
        fi
    '
}

run_rerun_case() {
    local script="$1"
    local case_name="$2"

    SCRIPT_PATH="${script}" \
    CASE_NAME="${case_name}" \
    bash -lc '
        set -euo pipefail
        source "${SCRIPT_PATH}"

        declare -a TEST_LOGS=()
        declare -a TEST_USERADD_CALLS=()
        declare -a TEST_USERMOD_CALLS=()

        log() {
            TEST_LOGS+=("$*")
        }

        id() {
            if [[ "$1" == "-u" && ( "$2" == "ops" || "$2" == "admin" ) ]]; then
                return 0
            fi
            return 1
        }

        useradd() {
            TEST_USERADD_CALLS+=("$*")
            return 0
        }

        usermod() {
            TEST_USERMOD_CALLS+=("$*")
            return 0
        }

        ensure_local_user_present "ops" "/bin/bash"
        ensure_local_user_present "admin" "/bin/bash"

        if [[ "${#TEST_USERADD_CALLS[@]}" -ne 0 ]]; then
            echo "FAIL ${CASE_NAME}: unexpected useradd calls [${TEST_USERADD_CALLS[*]}]" >&2
            exit 1
        fi

        if [[ "${#TEST_USERMOD_CALLS[@]}" -ne 2 ]]; then
            echo "FAIL ${CASE_NAME}: expected 2 usermod calls, got ${#TEST_USERMOD_CALLS[@]}" >&2
            exit 1
        fi

        if [[ "${TEST_USERMOD_CALLS[0]}" != "-s /bin/bash ops" || "${TEST_USERMOD_CALLS[1]}" != "-s /bin/bash admin" ]]; then
            echo "FAIL ${CASE_NAME}: unexpected usermod calls [${TEST_USERMOD_CALLS[*]}]" >&2
            exit 1
        fi
    '
}

run_suite_for_script() {
    local script="$1"

    run_dual_creation_case "${script}" "normal-ops-admin-creation"
    run_case "${script}" "admin-group-collision" "" "admin" "admin" "/bin/bash" "ensure" "-m -s /bin/bash -g admin admin" "" "Created user admin with existing primary group admin"
    run_rerun_case "${script}" "rerun-existing-users"
    run_case "${script}" "custom-admin-group-collision" "" "siteadmin" "siteadmin" "/bin/zsh" "ensure" "-m -s /bin/zsh -g siteadmin siteadmin" "" "reusing existing group as primary group"
    run_case "${script}" "shell-reconciliation-existing-user" "admin" "" "admin" "/usr/bin/zsh" "ensure" "" "-s /usr/bin/zsh admin" "User exists: admin"
    run_case "${script}" "prompt-warning-existing-group" "" "admin" "admin" "/bin/bash" "note" "" "" "group admin already exists; the user will reuse it as the primary group"
}

run_suite_for_script "${ROOT_DIR}/system_hardening.sh"
run_suite_for_script "${ROOT_DIR}/system_hardening_alpine.sh"

echo "Dedicated access account creation tests passed."

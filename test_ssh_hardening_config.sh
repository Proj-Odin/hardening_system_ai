#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

run_debian_apply_case() {
    local case_name="$1"
    local disable_password="$2"
    local expected_password="$3"

    CASE_NAME="${case_name}" \
    TEST_DISABLE_PASSWORD="${disable_password}" \
    TEST_EXPECTED_PASSWORD="${expected_password}" \
    SCRIPT_PATH="${ROOT_DIR}/system_hardening.sh" bash -lc '
        set -euo pipefail
        source "${SCRIPT_PATH}"

        TEST_DROPIN=""
        TEST_WRITE_TARGET=""

        DISTRO="ubuntu"
        SSH_PORT="22"
        DISABLE_ROOT_SSH=1
        DISABLE_PASSWORD_SSH="${TEST_DISABLE_PASSWORD}"
        MANAGE_ACCESS_ACCOUNTS=0
        SSH_RATE_LIMIT=1
        SSH_SERVICE="ssh"

        log() { :; }
        warn() { :; }
        die() {
            echo "FAIL ${CASE_NAME}: $*" >&2
            exit 1
        }
        write_file_with_backup() {
            TEST_WRITE_TARGET="$1"
            TEST_DROPIN="$(cat)"
        }
        sshd_config_is_valid() { return 0; }
        sshd_effective_config() {
            printf "passwordauthentication %s\n" "${TEST_EXPECTED_PASSWORD}"
            printf "kbdinteractiveauthentication no\n"
            printf "usepam yes\n"
        }
        systemctl() { return 0; }

        apply_ssh_hardening

        [[ "${TEST_WRITE_TARGET}" == "/etc/ssh/sshd_config.d/99-homelab-hardening.conf" ]] || {
            echo "FAIL ${CASE_NAME}: unexpected SSH drop-in target ${TEST_WRITE_TARGET}" >&2
            exit 1
        }
        grep -q "^PasswordAuthentication ${TEST_EXPECTED_PASSWORD}$" <<< "${TEST_DROPIN}" || {
            echo "FAIL ${CASE_NAME}: PasswordAuthentication ${TEST_EXPECTED_PASSWORD} missing" >&2
            exit 1
        }
        grep -q "^UsePAM yes$" <<< "${TEST_DROPIN}" || {
            echo "FAIL ${CASE_NAME}: UsePAM yes missing for Debian/Ubuntu" >&2
            exit 1
        }
        grep -q "^KbdInteractiveAuthentication no$" <<< "${TEST_DROPIN}" || {
            echo "FAIL ${CASE_NAME}: KbdInteractiveAuthentication no missing" >&2
            exit 1
        }
        grep -q "^ChallengeResponseAuthentication no$" <<< "${TEST_DROPIN}" || {
            echo "FAIL ${CASE_NAME}: legacy ChallengeResponseAuthentication guard missing" >&2
            exit 1
        }
        if grep -q "^UsePAM no$" <<< "${TEST_DROPIN}"; then
            echo "FAIL ${CASE_NAME}: UsePAM no must not be written on Debian/Ubuntu" >&2
            exit 1
        fi
    '
}

run_alpine_apply_case() {
    SCRIPT_PATH="${ROOT_DIR}/system_hardening_alpine.sh" bash -lc '
        set -euo pipefail
        source "${SCRIPT_PATH}"

        TEST_DROPIN=""

        DISTRO="alpine"
        SSH_PORT="22"
        DISABLE_ROOT_SSH=1
        DISABLE_PASSWORD_SSH=0
        MANAGE_ACCESS_ACCOUNTS=0
        SSH_RATE_LIMIT=1
        SSH_SERVICE="sshd"

        log() { :; }
        warn() { :; }
        die() {
            echo "FAIL alpine apply: $*" >&2
            exit 1
        }
        ensure_sshd_include_dropin() { :; }
        write_file_with_backup() {
            TEST_DROPIN="$(cat)"
        }
        sshd_config_is_valid() { return 0; }
        sshd_effective_config() {
            printf "passwordauthentication yes\n"
            printf "kbdinteractiveauthentication no\n"
        }
        enable_service_now() { return 0; }

        apply_ssh_hardening

        grep -q "^PasswordAuthentication yes$" <<< "${TEST_DROPIN}" || {
            echo "FAIL alpine apply: PasswordAuthentication yes missing" >&2
            exit 1
        }
        grep -q "^KbdInteractiveAuthentication no$" <<< "${TEST_DROPIN}" || {
            echo "FAIL alpine apply: KbdInteractiveAuthentication no missing" >&2
            exit 1
        }
        if grep -q "^UsePAM " <<< "${TEST_DROPIN}"; then
            echo "FAIL alpine apply: UsePAM should not be managed on Alpine" >&2
            exit 1
        fi
    '
}

run_effective_validation_case() {
    local case_name="$1"
    local distro="$2"
    local disable_password="$3"
    local effective_password="$4"
    local effective_kbd="$5"
    local effective_usepam="$6"
    local should_pass="$7"

    CASE_NAME="${case_name}" \
    TEST_DISTRO="${distro}" \
    TEST_DISABLE_PASSWORD="${disable_password}" \
    TEST_EFFECTIVE_PASSWORD="${effective_password}" \
    TEST_EFFECTIVE_KBD="${effective_kbd}" \
    TEST_EFFECTIVE_USEPAM="${effective_usepam}" \
    TEST_SHOULD_PASS="${should_pass}" \
    SCRIPT_PATH="${ROOT_DIR}/system_hardening.sh" bash -lc '
        set -euo pipefail
        source "${SCRIPT_PATH}"

        DISTRO="${TEST_DISTRO}"
        DISABLE_PASSWORD_SSH="${TEST_DISABLE_PASSWORD}"
        TEST_WARNINGS=""

        warn() {
            TEST_WARNINGS+="$*;"
        }
        sshd_effective_config() {
            printf "passwordauthentication %s\n" "${TEST_EFFECTIVE_PASSWORD}"
            printf "kbdinteractiveauthentication %s\n" "${TEST_EFFECTIVE_KBD}"
            if [[ -n "${TEST_EFFECTIVE_USEPAM}" ]]; then
                printf "usepam %s\n" "${TEST_EFFECTIVE_USEPAM}"
            fi
        }

        if validate_ssh_hardening_effective; then
            result="pass"
        else
            result="fail"
        fi

        [[ "${result}" == "${TEST_SHOULD_PASS}" ]] || {
            echo "FAIL ${CASE_NAME}: expected ${TEST_SHOULD_PASS}, got ${result}" >&2
            printf "%s" "${TEST_WARNINGS}" >&2
            exit 1
        }
    '
}

run_prompt_keep_passwords_case() {
    SCRIPT_PATH="${ROOT_DIR}/system_hardening.sh" bash -lc '
        set -euo pipefail
        source "${SCRIPT_PATH}"

        DISTRO="ubuntu"
        CURRENT_SSH_PORT="22"
        DISABLE_PASSWORD_SSH=1
        SSH_RATE_LIMIT=0
        TEST_PROMPT_INDEX=0
        TEST_WARNINGS=""
        TEST_ANSWERS=(yes yes yes)

        prompt_input() { echo "$2"; }
        prompt_yes_no() {
            local answer="${TEST_ANSWERS[${TEST_PROMPT_INDEX}]}"
            TEST_PROMPT_INDEX=$((TEST_PROMPT_INDEX + 1))
            [[ "${answer}" == "yes" ]]
        }
        ssh_keys_appear_configured() { return 0; }
        add_warning() {
            TEST_WARNINGS+="$*;"
        }

        configure_ssh_prompt

        [[ "${DISABLE_PASSWORD_SSH}" -eq 0 ]] || {
            echo "FAIL prompt keep passwords: password auth should remain enabled" >&2
            exit 1
        }
        grep -q "rerun and disable passwords" <<< "${TEST_WARNINGS}" || {
            echo "FAIL prompt keep passwords: follow-up warning missing" >&2
            exit 1
        }
    '
}

run_debian_apply_case "debian-keep-passwords" "0" "yes"
run_debian_apply_case "debian-disable-passwords" "1" "no"
run_alpine_apply_case
run_effective_validation_case "effective-keep-passwords-ok" "ubuntu" "0" "yes" "no" "yes" "pass"
run_effective_validation_case "effective-keep-passwords-blocked" "ubuntu" "0" "no" "no" "yes" "fail"
run_effective_validation_case "effective-usepam-blocked" "ubuntu" "1" "no" "no" "no" "fail"
run_prompt_keep_passwords_case

echo "SSH hardening config tests passed."

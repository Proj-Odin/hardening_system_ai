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

run_zeroclaw_fresh_user_case() {
    SCRIPT_PATH="${ROOT_DIR}/system_hardening_alpine.sh" \
    bash -lc '
        set -euo pipefail
        source "${SCRIPT_PATH}"

        declare -a TEST_ADDUSER_CALLS=()
        declare -a TEST_USERMOD_CALLS=()

        log() { :; }
        warn() { :; }
        ensure_zeroclaw_directories() { :; }
        ensure_zeroclaw_shell_path() { :; }
        id() { return 1; }
        getent() { return 2; }
        adduser() {
            TEST_ADDUSER_CALLS+=("$*")
            return 0
        }
        usermod() {
            TEST_USERMOD_CALLS+=("$*")
            return 0
        }

        ensure_zeroclaw_runtime_user

        if [[ "${#TEST_ADDUSER_CALLS[@]}" -ne 1 || "${TEST_ADDUSER_CALLS[0]}" != "-D -s /bin/ash zeroclaw" ]]; then
            echo "FAIL zeroclaw-fresh-user: unexpected adduser calls [${TEST_ADDUSER_CALLS[*]:-}]" >&2
            exit 1
        fi
        if [[ "${#TEST_USERMOD_CALLS[@]}" -ne 0 ]]; then
            echo "FAIL zeroclaw-fresh-user: unexpected usermod calls [${TEST_USERMOD_CALLS[*]}]" >&2
            exit 1
        fi
    '
}

run_zeroclaw_existing_group_case() {
    SCRIPT_PATH="${ROOT_DIR}/system_hardening_alpine.sh" \
    bash -lc '
        set -euo pipefail
        source "${SCRIPT_PATH}"

        declare -a TEST_ADDUSER_CALLS=()

        log() { :; }
        warn() { :; }
        ensure_zeroclaw_directories() { :; }
        ensure_zeroclaw_shell_path() { :; }
        id() { return 1; }
        getent() {
            if [[ "$1" == "group" && "$2" == "zeroclaw" ]]; then
                printf "zeroclaw:x:1000:\n"
                return 0
            fi
            return 2
        }
        adduser() {
            TEST_ADDUSER_CALLS+=("$*")
            return 0
        }

        ensure_zeroclaw_runtime_user

        if [[ "${#TEST_ADDUSER_CALLS[@]}" -ne 1 || "${TEST_ADDUSER_CALLS[0]}" != "-D -s /bin/ash -G zeroclaw zeroclaw" ]]; then
            echo "FAIL zeroclaw-existing-group: unexpected adduser calls [${TEST_ADDUSER_CALLS[*]:-}]" >&2
            exit 1
        fi
    '
}

run_zeroclaw_existing_user_case() {
    SCRIPT_PATH="${ROOT_DIR}/system_hardening_alpine.sh" \
    bash -lc '
        set -euo pipefail
        source "${SCRIPT_PATH}"

        declare -a TEST_ADDUSER_CALLS=()
        declare -a TEST_USERMOD_CALLS=()

        log() { :; }
        warn() { :; }
        ensure_zeroclaw_directories() { :; }
        ensure_zeroclaw_shell_path() { :; }
        id() {
            if [[ "$1" == "-u" && "$2" == "zeroclaw" ]]; then
                return 0
            fi
            return 1
        }
        getent() {
            if [[ "$1" == "passwd" && "$2" == "zeroclaw" ]]; then
                printf "zeroclaw:x:1000:1000::/home/zeroclaw:/bin/sh\n"
                return 0
            fi
            return 2
        }
        adduser() {
            TEST_ADDUSER_CALLS+=("$*")
            return 0
        }
        usermod() {
            TEST_USERMOD_CALLS+=("$*")
            return 0
        }

        ensure_zeroclaw_runtime_user

        if [[ "${#TEST_ADDUSER_CALLS[@]}" -ne 0 ]]; then
            echo "FAIL zeroclaw-existing-user: unexpected adduser calls [${TEST_ADDUSER_CALLS[*]}]" >&2
            exit 1
        fi
        if [[ "${#TEST_USERMOD_CALLS[@]}" -ne 1 || "${TEST_USERMOD_CALLS[0]}" != "-s /bin/ash zeroclaw" ]]; then
            echo "FAIL zeroclaw-existing-user: unexpected usermod calls [${TEST_USERMOD_CALLS[*]:-}]" >&2
            exit 1
        fi
    '
}

run_zeroclaw_directory_repair_case() {
    SCRIPT_PATH="${ROOT_DIR}/system_hardening_alpine.sh" \
    bash -lc '
        set -euo pipefail
        source "${SCRIPT_PATH}"

        TEST_HOME_ROOT="$(mktemp -d)"
        ZEROCLAW_HOME="${TEST_HOME_ROOT}/zeroclaw"
        declare -a TEST_CHOWN_CALLS=()

        log() { :; }
        chown() {
            TEST_CHOWN_CALLS+=("$*")
            return 0
        }

        ensure_zeroclaw_directories

        for path in "${ZEROCLAW_HOME}" "${ZEROCLAW_HOME}/.zeroclaw" "${ZEROCLAW_HOME}/.zeroclaw/workspace" "${ZEROCLAW_HOME}/.cargo/bin"; do
            if [[ ! -d "${path}" ]]; then
                echo "FAIL zeroclaw-directory-repair: missing ${path}" >&2
                exit 1
            fi
        done
        if [[ "${#TEST_CHOWN_CALLS[@]}" -lt 1 || "${TEST_CHOWN_CALLS[0]}" != "-R zeroclaw:zeroclaw ${ZEROCLAW_HOME}" ]]; then
            echo "FAIL zeroclaw-directory-repair: unexpected chown calls [${TEST_CHOWN_CALLS[*]:-}]" >&2
            exit 1
        fi
    '
}

run_zeroclaw_path_once_case() {
    SCRIPT_PATH="${ROOT_DIR}/system_hardening_alpine.sh" \
    bash -lc '
        set -euo pipefail
        source "${SCRIPT_PATH}"

        TEST_HOME_ROOT="$(mktemp -d)"
        ZEROCLAW_HOME="${TEST_HOME_ROOT}/zeroclaw"
        mkdir -p "${ZEROCLAW_HOME}"

        log() { :; }
        chown() { return 0; }

        ensure_zeroclaw_shell_path
        ensure_zeroclaw_shell_path

        for rc_file in "${ZEROCLAW_HOME}/.profile" "${ZEROCLAW_HOME}/.bashrc"; do
            count="$(grep -Fxc "${ZEROCLAW_PATH_LINE}" "${rc_file}")"
            if [[ "${count}" -ne 1 ]]; then
                echo "FAIL zeroclaw-path-once: expected one PATH line in ${rc_file}, got ${count}" >&2
                exit 1
            fi
        done
    '
}

run_zeroclaw_source_install_case() {
    SCRIPT_PATH="${ROOT_DIR}/system_hardening_alpine.sh" \
    bash -lc '
        set -euo pipefail
        source "${SCRIPT_PATH}"

        declare -a TEST_RUN_CALLS=()

        log() { :; }
        warn() { :; }
        remove_bad_zeroclaw_prebuilt_if_needed() { :; }
        download_zeroclaw_source_installer() { :; }
        chown() { return 0; }
        run_as_zeroclaw_user() {
            TEST_RUN_CALLS+=("$1")
            return 0
        }

        install_zeroclaw_source_build

        if [[ "${#TEST_RUN_CALLS[@]}" -ne 1 ]]; then
            echo "FAIL zeroclaw-source-install: expected one run-as-user call, got ${#TEST_RUN_CALLS[@]}" >&2
            exit 1
        fi
        if [[ "${TEST_RUN_CALLS[0]}" != "sh /tmp/zeroclaw-install.sh --source --skip-onboard" ]]; then
            echo "FAIL zeroclaw-source-install: unexpected installer command [${TEST_RUN_CALLS[0]}]" >&2
            exit 1
        fi
        if [[ "${TEST_RUN_CALLS[0]}" == *"--prebuilt"* ]]; then
            echo "FAIL zeroclaw-source-install: installer command used --prebuilt" >&2
            exit 1
        fi
    '
}

run_zeroclaw_package_queue_case() {
    SCRIPT_PATH="${ROOT_DIR}/system_hardening_alpine.sh" \
    bash -lc '
        set -euo pipefail
        source "${SCRIPT_PATH}"

        log() { :; }
        PKG_QUEUE=()
        queue_zeroclaw_source_packages

        for pkg in bash curl git ca-certificates shadow build-base rust cargo openssl-dev pkgconf sqlite-dev file; do
            found=0
            for queued in "${PKG_QUEUE[@]}"; do
                if [[ "${queued}" == "${pkg}" ]]; then
                    found=1
                    break
                fi
            done
            if [[ "${found}" -ne 1 ]]; then
                echo "FAIL zeroclaw-package-queue: missing ${pkg}" >&2
                exit 1
            fi
        done

        for compat_pkg in gcompat libc6-compat; do
            for queued in "${PKG_QUEUE[@]}"; do
                if [[ "${queued}" == "${compat_pkg}" ]]; then
                    echo "FAIL zeroclaw-package-queue: compatibility package ${compat_pkg} should not be required" >&2
                    exit 1
                fi
            done
        done
    '
}

run_alpine_lxc_tmux_base_package_case() {
    SCRIPT_PATH="${ROOT_DIR}/system_hardening_alpine.sh" \
    bash -lc '
        set -euo pipefail
        source "${SCRIPT_PATH}"

        found=0
        for pkg in "${ALPINE_LXC_BASE_PACKAGES[@]}"; do
            if [[ "${pkg}" == "tmux" ]]; then
                found=1
                break
            fi
        done

        if [[ "${found}" -ne 1 ]]; then
            echo "FAIL alpine-lxc-tmux-base-package: tmux missing from ALPINE_LXC_BASE_PACKAGES" >&2
            exit 1
        fi
    '
}

run_alpine_lxc_tmux_install_case() {
    SCRIPT_PATH="${ROOT_DIR}/system_hardening_alpine.sh" \
    bash -lc '
        set -euo pipefail
        source "${SCRIPT_PATH}"

        DEPLOYMENT_TARGET="lxc"
        TEST_FAKE_BIN="$(mktemp -d)"
        PATH="${TEST_FAKE_BIN}:${PATH}"
        cat > "${TEST_FAKE_BIN}/tmux" <<'"'"'EOF'"'"'
#!/usr/bin/env bash
if [[ "${1:-}" == "-V" ]]; then
    echo "tmux 3.4"
    exit 0
fi
exit 0
EOF
        chmod +x "${TEST_FAKE_BIN}/tmux"

        declare -a TEST_APK_CALLS=()
        declare -a TEST_LOGS=()
        declare -a TEST_WARNINGS=()

        log() {
            TEST_LOGS+=("$*")
        }
        warn() {
            TEST_WARNINGS+=("$*")
        }
        apk() {
            TEST_APK_CALLS+=("$*")
            return 0
        }

        install_alpine_lxc_base_packages

        if [[ "${#TEST_APK_CALLS[@]}" -ne 1 || "${TEST_APK_CALLS[0]}" != "add --no-cache tmux" ]]; then
            echo "FAIL alpine-lxc-tmux-install: expected [add --no-cache tmux], got [${TEST_APK_CALLS[*]:-}]" >&2
            exit 1
        fi
        if [[ "${#TEST_WARNINGS[@]}" -ne 0 ]]; then
            echo "FAIL alpine-lxc-tmux-install: unexpected warnings [${TEST_WARNINGS[*]}]" >&2
            exit 1
        fi
        version_logged=0
        for entry in "${TEST_LOGS[@]}"; do
            if [[ "${entry}" == *"Alpine LXC tmux version: tmux 3.4"* ]]; then
                version_logged=1
                break
            fi
        done
        if [[ "${version_logged}" -ne 1 ]]; then
            echo "FAIL alpine-lxc-tmux-install: tmux -V output was not logged" >&2
            exit 1
        fi
    '
}

run_alpine_lxc_tmux_failure_nonfatal_case() {
    SCRIPT_PATH="${ROOT_DIR}/system_hardening_alpine.sh" \
    bash -lc '
        set -euo pipefail
        source "${SCRIPT_PATH}"

        DEPLOYMENT_TARGET="lxc"
        declare -a TEST_WARNINGS=()

        log() { :; }
        warn() {
            TEST_WARNINGS+=("$*")
        }
        apk() {
            return 1
        }

        install_alpine_lxc_base_packages

        if [[ "${#TEST_WARNINGS[@]}" -lt 1 || "${TEST_WARNINGS[0]}" != *"Failed to install Alpine LXC base package '"'"'tmux'"'"'"* ]]; then
            echo "FAIL alpine-lxc-tmux-failure-nonfatal: clear warning not emitted" >&2
            exit 1
        fi
    '
}

run_alpine_vm_skips_tmux_case() {
    SCRIPT_PATH="${ROOT_DIR}/system_hardening_alpine.sh" \
    bash -lc '
        set -euo pipefail
        source "${SCRIPT_PATH}"

        DEPLOYMENT_TARGET="vm"
        TEST_APK_CALLED=0

        log() { :; }
        warn() { :; }
        apk() {
            TEST_APK_CALLED=1
            return 0
        }

        install_alpine_lxc_base_packages

        if [[ "${TEST_APK_CALLED}" -ne 0 ]]; then
            echo "FAIL alpine-vm-skips-tmux: LXC tmux install affected VM target" >&2
            exit 1
        fi
    '
}

run_zeroclaw_lxc_no_systemd_case() {
    SCRIPT_PATH="${ROOT_DIR}/system_hardening_alpine.sh" \
    bash -lc '
        set -euo pipefail
        source "${SCRIPT_PATH}"

        INSTALL_ZEROCLAW=1
        DEPLOYMENT_TARGET="lxc"
        TEST_SYSTEMCTL_CALLED=0

        log() { :; }
        warn() { :; }
        ensure_zeroclaw_runtime_user() { :; }
        install_zeroclaw_source_build() { :; }
        verify_zeroclaw_install() { :; }
        systemctl() {
            TEST_SYSTEMCTL_CALLED=1
            return 0
        }

        apply_zeroclaw_source_install

        if [[ "${TEST_SYSTEMCTL_CALLED}" -ne 0 ]]; then
            echo "FAIL zeroclaw-lxc-no-systemd: systemctl was called" >&2
            exit 1
        fi
    '
}

run_zeroclaw_bad_prebuilt_case() {
    SCRIPT_PATH="${ROOT_DIR}/system_hardening_alpine.sh" \
    bash -lc '
        set -euo pipefail
        source "${SCRIPT_PATH}"

        TEST_HOME_ROOT="$(mktemp -d)"
        TEST_BIN="${TEST_HOME_ROOT}/zeroclaw"
        touch "${TEST_BIN}"
        declare -a TEST_RM_CALLS=()
        declare -a TEST_WARNINGS=()

        log() { :; }
        warn() {
            TEST_WARNINGS+=("$*")
        }
        file() {
            printf "%s: ELF 64-bit LSB pie executable, x86-64, dynamically linked, interpreter /lib64/ld-linux-x86-64.so.2\n" "$1"
        }
        rm() {
            TEST_RM_CALLS+=("$*")
            command rm "$@"
        }

        if ! zeroclaw_glibc_prebuilt_detected "${TEST_BIN}"; then
            echo "FAIL zeroclaw-bad-prebuilt: glibc binary was not detected" >&2
            exit 1
        fi

        remove_bad_zeroclaw_prebuilt_if_needed "${TEST_BIN}"

        if [[ "${#TEST_RM_CALLS[@]}" -ne 1 || "${TEST_RM_CALLS[0]}" != "-f ${TEST_BIN}" ]]; then
            echo "FAIL zeroclaw-bad-prebuilt: unexpected rm calls [${TEST_RM_CALLS[*]:-}]" >&2
            exit 1
        fi
        if [[ "${#TEST_WARNINGS[@]}" -lt 1 || "${TEST_WARNINGS[0]}" != *"Detected GNU/glibc ZeroClaw binary on Alpine"* ]]; then
            echo "FAIL zeroclaw-bad-prebuilt: warning not emitted" >&2
            exit 1
        fi
    '
}

run_zeroclaw_alpine_suite() {
    run_zeroclaw_fresh_user_case
    run_zeroclaw_existing_group_case
    run_zeroclaw_existing_user_case
    run_zeroclaw_directory_repair_case
    run_zeroclaw_path_once_case
    run_zeroclaw_source_install_case
    run_zeroclaw_package_queue_case
    run_alpine_lxc_tmux_base_package_case
    run_alpine_lxc_tmux_install_case
    run_alpine_lxc_tmux_failure_nonfatal_case
    run_alpine_vm_skips_tmux_case
    run_zeroclaw_lxc_no_systemd_case
    run_zeroclaw_bad_prebuilt_case
}

run_suite_for_script "${ROOT_DIR}/system_hardening.sh"
run_suite_for_script "${ROOT_DIR}/system_hardening_alpine.sh"
run_zeroclaw_alpine_suite

echo "Dedicated access account creation tests passed."

#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

run_shared_module_layout_case() {
    grep -q '^detect_virtualization()' "${ROOT_DIR}/lib/hardening-common.sh" || {
        echo "FAIL shared layout: detect_virtualization missing from shared module" >&2
        exit 1
    }
    if grep -q '^detect_virtualization()' "${ROOT_DIR}/system_hardening.sh" || \
       grep -q '^detect_virtualization()' "${ROOT_DIR}/system_hardening_alpine.sh"; then
        echo "FAIL shared layout: detect_virtualization must not be duplicated in entrypoint scripts" >&2
        exit 1
    fi
}

run_ubuntu_startup_case() {
    SCRIPT_PATH="${ROOT_DIR}/system_hardening.sh" bash -lc '
        set -euo pipefail

        temp_dir="$(mktemp -d)"
        trap "rm -rf \"${temp_dir}\"" EXIT
        mkdir -p "${temp_dir}/bin"
        cd "${temp_dir}"

        source "${SCRIPT_PATH}"

        OS_RELEASE_FILE="${temp_dir}/os-release"
        cat > "${OS_RELEASE_FILE}" <<EOF
ID=ubuntu
VERSION_ID="25.10"
VERSION_CODENAME=questing
UBUNTU_CODENAME=questing
PRETTY_NAME="Ubuntu 25.10"
EOF

        cat > "${temp_dir}/bin/systemd-detect-virt" <<'"'"'EOF'"'"'
#!/usr/bin/env bash
echo kvm
EOF
        chmod +x "${temp_dir}/bin/systemd-detect-virt"
        PATH="${temp_dir}/bin:${PATH}"

        LOGFILE=""
        log() { :; }
        warn() { :; }
        die() {
            echo "FAIL ubuntu startup: $*" >&2
            exit 1
        }
        systemctl() { return 1; }
        detect_ssh_port() { echo "2222"; }

        declare -F detect_virtualization >/dev/null || {
            echo "FAIL ubuntu startup: detect_virtualization is not defined" >&2
            exit 1
        }

        detect_environment

        [[ "${DISTRO}" == "ubuntu" ]] || {
            echo "FAIL ubuntu startup: expected DISTRO ubuntu, got ${DISTRO}" >&2
            exit 1
        }
        [[ "${DISTRO_VERSION}" == "25.10" ]] || {
            echo "FAIL ubuntu startup: expected VERSION_ID 25.10, got ${DISTRO_VERSION}" >&2
            exit 1
        }
        [[ "${DISTRO_CODENAME}" == "questing" ]] || {
            echo "FAIL ubuntu startup: expected codename questing, got ${DISTRO_CODENAME}" >&2
            exit 1
        }
        [[ "${DETECTED_VIRT}" == "kvm" ]] || {
            echo "FAIL ubuntu startup: expected virtualization kvm, got ${DETECTED_VIRT}" >&2
            exit 1
        }
        [[ "${SSH_PORT}" == "2222" ]] || {
            echo "FAIL ubuntu startup: expected SSH port 2222, got ${SSH_PORT}" >&2
            exit 1
        }
    '
}

run_detection_failure_fallback_case() {
    SCRIPT_PATH="${ROOT_DIR}/system_hardening.sh" bash -lc '
        set -euo pipefail
        source "${SCRIPT_PATH}"

        temp_dir="$(mktemp -d)"
        trap "rm -rf \"${temp_dir}\"" EXIT

        OS_RELEASE_FILE="${temp_dir}/os-release"
        cat > "${OS_RELEASE_FILE}" <<EOF
ID=debian
VERSION_ID="13"
VERSION_CODENAME=trixie
PRETTY_NAME="Debian GNU/Linux 13"
EOF

        LOGFILE=""
        TEST_WARNINGS=""
        log() { :; }
        warn() {
            TEST_WARNINGS+="$*;"
        }
        die() {
            echo "FAIL fallback startup: $*" >&2
            exit 1
        }
        systemctl() { return 1; }
        detect_ssh_port() { echo "22"; }
        detect_virtualization() { return 1; }

        detect_environment

        [[ "${DETECTED_VIRT}" == "unknown" ]] || {
            echo "FAIL fallback startup: expected virtualization unknown, got ${DETECTED_VIRT}" >&2
            exit 1
        }
        [[ "${TEST_WARNINGS}" == *"Virtualization detection failed unexpectedly"* ]] || {
            echo "FAIL fallback startup: missing virtualization fallback warning" >&2
            exit 1
        }
    '
}

run_missing_guard_case() {
    SCRIPT_PATH="${ROOT_DIR}/system_hardening.sh" bash -lc '
        set -euo pipefail
        source "${SCRIPT_PATH}"

        unset -f detect_virtualization
        LOGFILE=""
        TEST_ERROR=""
        log() { :; }
        die() {
            TEST_ERROR="$*"
            return 77
        }

        if ensure_virtualization_detector_loaded; then
            echo "FAIL missing guard: guard succeeded without detect_virtualization" >&2
            exit 1
        fi
        [[ "${TEST_ERROR}" == *"detect_virtualization is not defined before detect_environment"* && "${TEST_ERROR}" == *"Shared module failed to load"* ]] || {
            echo "FAIL missing guard: unclear error: ${TEST_ERROR}" >&2
            exit 1
        }
    '
}

run_shared_module_layout_case
run_ubuntu_startup_case
run_detection_failure_fallback_case
run_missing_guard_case

if command -v shellcheck >/dev/null 2>&1; then
    shellcheck "${ROOT_DIR}/system_hardening.sh"
    shellcheck "${ROOT_DIR}/lib/hardening-common.sh"
fi

echo "Startup virtualization detection tests passed."

#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

run_debian_vm_case() {
    SCRIPT_PATH="${ROOT_DIR}/system_hardening.sh" bash -lc '
        set -euo pipefail
        source "${SCRIPT_PATH}"

        PKG_QUEUE=()
        PROFILE="lan-only"
        INSTALL_FAIL2BAN=0
        ENABLE_APPARMOR=0
        UPDATE_MODE="manual"
        MANAGE_ACCESS_ACCOUNTS=0
        INSTALL_QEMU_GUEST_AGENT=1
        DETECTED_VIRT="kvm"
        TEST_SYSTEMCTL_CALLS=""
        TEST_APT_GET_CALLS=""

        log() { :; }
        warn() { :; }
        dpkg() { return 1; }
        apt-cache() {
            [[ "${1:-}" == "show" && "${2:-}" == "qemu-guest-agent" ]]
        }
        apt-get() {
            TEST_APT_GET_CALLS+="$*;"
            return 0
        }
        systemctl() {
            TEST_SYSTEMCTL_CALLS+="$*;"
            return 0
        }

        prepare_package_queue
        queue_text=" ${PKG_QUEUE[*]} "
        [[ "${queue_text}" != *" qemu-guest-agent "* ]] || {
            echo "FAIL debian vm: qemu-guest-agent should be installed through apply_qemu_guest_agent" >&2
            exit 1
        }

        apply_qemu_guest_agent
        [[ "${TEST_APT_GET_CALLS}" == *"install -y qemu-guest-agent"* ]] || {
            echo "FAIL debian vm: qemu-guest-agent package was not installed" >&2
            exit 1
        }
        [[ "${TEST_SYSTEMCTL_CALLS}" == *"enable --now qemu-guest-agent"* ]] || {
            echo "FAIL debian vm: qemu-guest-agent service was not enabled" >&2
            exit 1
        }
    '
}

run_debian_lxc_skip_case() {
    SCRIPT_PATH="${ROOT_DIR}/system_hardening.sh" bash -lc '
        set -euo pipefail
        source "${SCRIPT_PATH}"

        PKG_QUEUE=()
        PROFILE="lan-only"
        INSTALL_FAIL2BAN=0
        ENABLE_APPARMOR=0
        UPDATE_MODE="manual"
        MANAGE_ACCESS_ACCOUNTS=0
        INSTALL_QEMU_GUEST_AGENT=1
        DETECTED_VIRT="lxc"
        TEST_SYSTEMCTL_CALLED=0
        TEST_APT_GET_CALLED=0

        log() { :; }
        warn() { :; }
        dpkg() { return 1; }
        apt-cache() { return 1; }
        apt-get() {
            TEST_APT_GET_CALLED=1
            return 1
        }
        systemctl() {
            TEST_SYSTEMCTL_CALLED=1
            return 1
        }

        prepare_package_queue
        queue_text=" ${PKG_QUEUE[*]} "
        [[ "${queue_text}" != *" qemu-guest-agent "* ]] || {
            echo "FAIL debian lxc: qemu-guest-agent must not be queued for LXC" >&2
            exit 1
        }

        apply_qemu_guest_agent
        [[ "${TEST_APT_GET_CALLED}" -eq 0 ]] || {
            echo "FAIL debian lxc: qemu-guest-agent package must not be installed for LXC" >&2
            exit 1
        }
        [[ "${TEST_SYSTEMCTL_CALLED}" -eq 0 ]] || {
            echo "FAIL debian lxc: qemu-guest-agent service must not be enabled for LXC" >&2
            exit 1
        }
    '
}

run_alpine_vm_case() {
    SCRIPT_PATH="${ROOT_DIR}/system_hardening_alpine.sh" bash -lc '
        set -euo pipefail
        source "${SCRIPT_PATH}"

        PKG_QUEUE=()
        PROFILE="lan-only"
        INSTALL_FAIL2BAN=0
        ENABLE_APPARMOR=0
        UPDATE_MODE="manual"
        MANAGE_ACCESS_ACCOUNTS=0
        INSTALL_QEMU_GUEST_AGENT=1
        DETECTED_VIRT="kvm"
        DEPLOYMENT_TARGET="vm"
        INIT_SYSTEM="openrc"
        TEST_ENABLE_CALLS=""
        TEST_APK_CALLS=""

        log() { :; }
        warn() { :; }
        apk() {
            TEST_APK_CALLS+="$*;"
            return 0
        }
        service_exists() {
            [[ "$1" == "qemu-guest-agent" ]]
        }
        enable_service_now() {
            TEST_ENABLE_CALLS+="$*;"
            return 0
        }

        prepare_package_queue
        queue_text=" ${PKG_QUEUE[*]} "
        [[ "${queue_text}" != *" qemu-guest-agent "* ]] || {
            echo "FAIL alpine vm: qemu-guest-agent should be installed through apply_qemu_guest_agent" >&2
            exit 1
        }
        [[ "${queue_text}" != *" qemu-guest-agent-openrc "* ]] || {
            echo "FAIL alpine vm: qemu-guest-agent-openrc should be installed through apply_qemu_guest_agent" >&2
            exit 1
        }

        apply_qemu_guest_agent
        [[ "${TEST_APK_CALLS}" == *"add qemu-guest-agent qemu-guest-agent-openrc"* ]] || {
            echo "FAIL alpine vm: QEMU guest agent packages were not installed" >&2
            exit 1
        }
        [[ "${TEST_ENABLE_CALLS}" == *"qemu-guest-agent"* ]] || {
            echo "FAIL alpine vm: qemu-guest-agent service was not enabled" >&2
            exit 1
        }
    '
}

run_alpine_lxc_skip_case() {
    SCRIPT_PATH="${ROOT_DIR}/system_hardening_alpine.sh" bash -lc '
        set -euo pipefail
        source "${SCRIPT_PATH}"

        PKG_QUEUE=()
        PROFILE="lan-only"
        INSTALL_FAIL2BAN=0
        ENABLE_APPARMOR=0
        UPDATE_MODE="manual"
        MANAGE_ACCESS_ACCOUNTS=0
        INSTALL_QEMU_GUEST_AGENT=1
        DETECTED_VIRT="lxc"
        DEPLOYMENT_TARGET="lxc"
        INIT_SYSTEM="openrc"
        TEST_ENABLE_CALLED=0
        TEST_APK_CALLED=0

        log() { :; }
        warn() { :; }
        apk() {
            TEST_APK_CALLED=1
            return 1
        }
        service_exists() { return 1; }
        enable_service_now() {
            TEST_ENABLE_CALLED=1
            return 1
        }

        prepare_package_queue
        queue_text=" ${PKG_QUEUE[*]} "
        [[ "${queue_text}" != *" qemu-guest-agent "* ]] || {
            echo "FAIL alpine lxc: qemu-guest-agent must not be queued for LXC" >&2
            exit 1
        }
        [[ "${queue_text}" != *" qemu-guest-agent-openrc "* ]] || {
            echo "FAIL alpine lxc: qemu-guest-agent-openrc must not be queued for LXC" >&2
            exit 1
        }

        apply_qemu_guest_agent
        [[ "${TEST_APK_CALLED}" -eq 0 ]] || {
            echo "FAIL alpine lxc: QEMU guest agent packages must not be installed for LXC" >&2
            exit 1
        }
        [[ "${TEST_ENABLE_CALLED}" -eq 0 ]] || {
            echo "FAIL alpine lxc: qemu-guest-agent service must not be enabled for LXC" >&2
            exit 1
        }
    '
}

run_prompt_default_case() {
    SCRIPT_PATH="${ROOT_DIR}/system_hardening.sh" bash -lc '
        set -euo pipefail
        source "${SCRIPT_PATH}"

        DETECTED_VIRT="kvm"
        INSTALL_QEMU_GUEST_AGENT=0
        TEST_DEFAULT=""

        log() { :; }
        add_warning() { :; }
        prompt_yes_no() {
            TEST_DEFAULT="$2"
            return 0
        }

        configure_qemu_guest_agent
        [[ "${TEST_DEFAULT}" == "y" ]] || {
            echo "FAIL prompt default: KVM/QEMU guests should default qemu-guest-agent to yes" >&2
            exit 1
        }
        [[ "${INSTALL_QEMU_GUEST_AGENT}" -eq 1 ]] || {
            echo "FAIL prompt default: qemu-guest-agent selection was not recorded" >&2
            exit 1
        }
    '
}

run_debian_vm_case
run_debian_lxc_skip_case
run_alpine_vm_case
run_alpine_lxc_skip_case
run_prompt_default_case

echo "QEMU guest agent flow tests passed."

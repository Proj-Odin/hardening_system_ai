#!/usr/bin/env bash
# Shared helpers for Debian/Ubuntu and Alpine hardening entrypoints.

detect_virtualization() {
    local detected="unknown"
    local dmi_value=""
    local dmi_file=""

    if command -v systemd-detect-virt >/dev/null 2>&1; then
        detected="$(systemd-detect-virt 2>/dev/null || true)"
    fi

    if [[ -z "${detected}" || "${detected}" == "none" ]]; then
        detected="unknown"
        if grep -qaE 'container=lxc|lxc' /proc/1/environ 2>/dev/null || \
           grep -qaE '(^|/)lxc(/|$)' /proc/1/cgroup 2>/dev/null || \
           [[ -f /dev/lxc ]]; then
            detected="lxc"
        elif grep -qaE '(^|/)docker(/|$)|(^|/)kubepods(/|$)' /proc/1/cgroup 2>/dev/null || \
             [[ -f /.dockerenv ]] || \
             { [[ -r /proc/1/environ ]] && tr '\0' '\n' < /proc/1/environ 2>/dev/null | grep -q '^container='; }; then
            detected="container"
        fi
    fi

    if [[ "${detected}" == "unknown" ]]; then
        if grep -qiE 'hypervisor|kvm|qemu|microsoft|vmware|xen|virtualbox|bhyve|parallels' /proc/cpuinfo 2>/dev/null; then
            detected="vm"
        fi
    fi

    if [[ "${detected}" == "unknown" ]]; then
        for dmi_file in /sys/class/dmi/id/product_name /sys/class/dmi/id/sys_vendor /sys/class/dmi/id/board_vendor; do
            [[ -r "${dmi_file}" ]] || continue
            if ! IFS= read -r dmi_value < "${dmi_file}"; then
                dmi_value=""
            fi
            case "${dmi_value,,}" in
                *kvm*|*qemu*) detected="kvm" ;;
                *proxmox*) detected="kvm" ;;
                *vmware*) detected="vmware" ;;
                *virtualbox*) detected="oracle" ;;
                *xen*) detected="xen" ;;
                *microsoft*|*hyper-v*) detected="microsoft" ;;
            esac
            [[ "${detected}" != "unknown" ]] && break
        done
    fi

    echo "${detected:-unknown}"
}

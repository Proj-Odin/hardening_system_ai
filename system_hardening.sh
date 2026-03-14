#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# Interactive Homelab Hardening Script for Ubuntu/Debian
# Safe, menu-driven, rerun-friendly hardening for homelab hosts
# ============================================================

SCRIPT_VERSION="3.4-modular"

# Script flow at a glance:
# 1) Collect choices interactively by module.
# 2) Build a dry-run style summary of planned rules/changes.
# 3) Ask for final confirmation (apply/edit/cancel).
# 4) Apply idempotent changes with backups and logging.

# -------- Runtime State --------
DISTRO=""
DISTRO_VERSION=""
DISTRO_CODENAME=""
SSH_SERVICE=""
CURRENT_SSH_PORT="22"

LOG_DIR="/var/log/homelab-hardening"
BACKUP_ROOT="/var/backups/homelab-hardening"
RUN_ID=""
LOGFILE=""
BACKUP_DIR=""

declare -a UFW_RULES=()
declare -a PKG_QUEUE=()
declare -a SUMMARY_WARNINGS=()
declare -a CUSTOM_PACKAGES=()
declare -a REMOTE_ACCESS_WARNINGS=()
declare -a PLANNED_FILES=()
declare -a PLANNED_SERVICES=()

# REMOTE_ACCESS_RISK is a single summary flag used to print a final
# "you could lose access" warning when high-risk SSH/firewall choices exist.
REMOTE_ACCESS_RISK=0

# -------- Profile Defaults --------
PROFILE="lan-only"

SSH_PORT="22"
DISABLE_ROOT_SSH=1
DISABLE_PASSWORD_SSH=0
SSH_RATE_LIMIT=1

MANAGE_UFW=1
RESET_UFW=0
CUSTOM_FIREWALL_PORTS=""
CUSTOM_TCP_ENTRIES=""
CUSTOM_UDP_ENTRIES=""
PROFILE_FIREWALL_RESTRICT_LAN=0
PROFILE_LAN_SOURCE=""

INSTALL_FAIL2BAN=1
ENABLE_APPARMOR=1
UPDATE_MODE="notify" # notify|unattended|manual

INSTALL_CHECKMK=0
CHECKMK_SOURCE="apt" # apt|deb-url|already
CHECKMK_AGENT_URL=""
CHECKMK_COMM_MODE="tls" # tls|plaintext
CHECKMK_SERVER=""
CHECKMK_SITE="monitoring"
CHECKMK_ALLOW_FROM=""
CHECKMK_EFFECTIVE_SOURCE="not-applicable"

INSTALL_DOCKER=1
DOCKER_OPEN_TLS_API=0
DOCKER_EXTRA_PORTS=""

INSTALL_SAMBA=1
ALLOW_SAMBA_PORTS=1
FILESERVER_SMB_ENCRYPTION="desired" # required|desired|off

MEDIA_EXPOSE_PLEX=0
MEDIA_EXTRA_PORTS=""

INSTALL_NGINX=1
PUBLIC_WEB_MODE="https-only" # https-only|http-https|none
RUN_CERTBOT_NOW=0
CERTBOT_DOMAIN=""
CERTBOT_EMAIL=""

INSTALL_TAILSCALE=1
TAILSCALE_PROFILE_ENABLED=1
TAILSCALE_PUBLISH_MODE="serve" # none|serve|funnel
TAILSCALE_BACKEND_TYPE="local-web" # local-web|local-tcp|existing-reverse-proxy|custom
TAILSCALE_BACKEND_ADDR="127.0.0.1"
TAILSCALE_BACKEND_PORT="3000"
TAILSCALE_PUBLISH_PORT="443"
TAILSCALE_CUSTOM_PUBLISH_COMMAND=""
TAILSCALE_ENABLE_SUBNET_ROUTER=0
TAILSCALE_ADVERTISE_ROUTES=""
TAILSCALE_ENABLE_SSH=0
TAILSCALE_STRONG_ADMIN_CHECK=1
TAILSCALE_ENABLE_CHECKMK_STEP=1
TAILSCALE_PREFER_TLS=1
TAILSCALE_RUN_UP_NOW=0
TAILSCALE_AUTHKEY=""

CUSTOM_PROFILE_PORTS=""
CUSTOM_PROFILE_PACKAGES=""

# -------- Metadata --------
declare -A PROFILE_DESCRIPTIONS=(
    ["lan-only"]="LAN server with minimal exposed services"
    ["docker-host"]="Container host with secure Docker defaults"
    ["file-server"]="Samba/NAS style host with optional SMB encryption"
    ["media-host"]="Media workloads with optional direct streaming ports"
    ["public-reverse-proxy"]="Internet-facing reverse proxy with HTTPS preference"
    ["tailscale-gateway"]="Identity-aware private gateway via Tailscale"
    ["custom"]="Build-your-own profile with explicit choices"
)

# -------- Logging & Helpers --------
timestamp() { date +"%Y-%m-%d %H:%M:%S"; }

log() {
    local msg="$*"
    if [[ -n "${LOGFILE}" ]]; then
        echo "[$(timestamp)] ${msg}" | tee -a "${LOGFILE}"
    else
        echo "[$(timestamp)] ${msg}"
    fi
}

warn() {
    echo "[WARN] $*" >&2
    log "WARN: $*"
}

die() {
    echo "ERROR: $*" >&2
    log "ERROR: $*"
    exit 1
}

on_error() {
    local line="$1"
    local cmd="$2"
    warn "Command failed at line ${line}: ${cmd}"
    warn "Review log file: ${LOGFILE}"
}

trap 'on_error "$LINENO" "$BASH_COMMAND"' ERR

require_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        die "Run this script as root (or with sudo)."
    fi
}

setup_runtime_paths() {
    RUN_ID="$(date +%Y%m%d_%H%M%S)"
    LOGFILE="${LOG_DIR}/run-${RUN_ID}.log"
    BACKUP_DIR="${BACKUP_ROOT}/${RUN_ID}"

    mkdir -p "${LOG_DIR}" "${BACKUP_DIR}"
    touch "${LOGFILE}"

    log "Starting Homelab Hardening Script v${SCRIPT_VERSION}"
    log "Log file: ${LOGFILE}"
    log "Backup directory: ${BACKUP_DIR}"
}

detect_environment() {
    # /etc/os-release is the canonical source for distro detection.
    if [[ -f /etc/os-release ]]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        DISTRO="${ID:-unknown}"
        DISTRO_VERSION="${VERSION_ID:-unknown}"
        DISTRO_CODENAME="${VERSION_CODENAME:-${UBUNTU_CODENAME:-}}"
    else
        die "Cannot detect distribution (missing /etc/os-release)."
    fi

    if [[ "${DISTRO}" != "ubuntu" && "${DISTRO}" != "debian" ]]; then
        if [[ "${ID_LIKE:-}" == *"debian"* ]]; then
            DISTRO="debian-like"
        else
            die "This script supports Ubuntu and Debian only. Detected: ${DISTRO}"
        fi
    fi

    if systemctl list-unit-files 2>/dev/null | awk '{print $1}' | grep -qx "sshd.service"; then
        SSH_SERVICE="sshd"
    else
        SSH_SERVICE="ssh"
    fi

    # Read sshd's effective config so we detect non-default ports safely.
    if command -v sshd >/dev/null 2>&1; then
        CURRENT_SSH_PORT="$(sshd -T 2>/dev/null | awk '/^port / {print $2; exit}')"
    fi
    CURRENT_SSH_PORT="${CURRENT_SSH_PORT:-22}"
    SSH_PORT="${CURRENT_SSH_PORT}"

    if [[ "${DISTRO}" == "debian-like" ]]; then
        log "Detected distribution: ${PRETTY_NAME:-unknown} (treated as Debian family)"
    else
        log "Detected distribution: ${DISTRO} ${DISTRO_VERSION}"
    fi
    log "Detected codename: ${DISTRO_CODENAME:-unknown}"
    log "SSH service name: ${SSH_SERVICE}"
    log "Current SSH port: ${CURRENT_SSH_PORT}"
}

backup_config() {
    # Backups are timestamped and mirrored by path under BACKUP_DIR.
    local file="$1"
    if [[ ! -f "${file}" ]]; then
        return 0
    fi

    local target="${BACKUP_DIR}${file}.bak.$(date +%s)"
    mkdir -p "$(dirname "${target}")"
    cp -a "${file}" "${target}"
    log "Backed up ${file} -> ${target}"
}

write_file_with_backup() {
    # Centralized "safe write" helper used by all managed config writes.
    local file="$1"
    backup_config "${file}"
    mkdir -p "$(dirname "${file}")"
    cat > "${file}"
    log "Wrote managed file: ${file}"
}

add_warning() {
    SUMMARY_WARNINGS+=("$*")
}

add_remote_warning() {
    REMOTE_ACCESS_RISK=1
    REMOTE_ACCESS_WARNINGS+=("$*")
}

queue_package() {
    local pkg="$1"
    local existing
    for existing in "${PKG_QUEUE[@]:-}"; do
        if [[ "${existing}" == "${pkg}" ]]; then
            return 0
        fi
    done
    PKG_QUEUE+=("${pkg}")
}

trim_spaces() {
    local value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    echo "${value}"
}

valid_port() {
    local p="$1"
    [[ "${p}" =~ ^[0-9]+$ ]] || return 1
    (( p >= 1 && p <= 65535 ))
}

valid_ip_or_cidr() {
    local value="$1"
    [[ "${value}" =~ ^[0-9a-fA-F:.]+(/[0-9]{1,3})?$ ]]
}

valid_cidr() {
    local value="$1"
    [[ "${value}" =~ ^[0-9a-fA-F:.]+/[0-9]{1,3}$ ]]
}

validate_explicit_cidr_csv() {
    local csv="$1"
    local token
    local normalized=""

    IFS=',' read -r -a _cidrs <<< "${csv}"
    for token in "${_cidrs[@]:-}"; do
        token="$(trim_spaces "${token}")"
        [[ -z "${token}" ]] && continue

        if ! valid_cidr "${token}"; then
            return 1
        fi

        # Prevent broad route assumptions.
        if [[ "${token}" == "0.0.0.0/0" || "${token}" == "::/0" ]]; then
            return 1
        fi

        if [[ -z "${normalized}" ]]; then
            normalized="${token}"
        else
            normalized="${normalized},${token}"
        fi
    done

    echo "${normalized}"
}

prompt_yes_no() {
    local prompt="$1"
    local default="${2:-y}"
    local answer

    while true; do
        read -r -p "${prompt} (y/n) [${default}]: " answer
        answer="${answer:-${default}}"
        case "${answer}" in
            y|Y|yes|YES) return 0 ;;
            n|N|no|NO) return 1 ;;
            *) echo "Please answer y or n." ;;
        esac
    done
}

prompt_input() {
    local prompt="$1"
    local default="$2"
    local answer
    read -r -p "${prompt} [${default}]: " answer
    echo "${answer:-${default}}"
}

prompt_menu() {
    # Returns the numeric choice as stdout for easy command-substitution use.
    local title="$1"
    local default="$2"
    shift 2
    local options=("$@")
    local i
    local answer

    echo >&2
    echo "=== ${title} ===" >&2
    for i in "${!options[@]}"; do
        echo "$((i + 1)). ${options[$i]}" >&2
    done

    while true; do
        read -r -p "Choose [${default}]: " answer
        answer="${answer:-${default}}"
        if [[ "${answer}" =~ ^[0-9]+$ ]] && (( answer >= 1 && answer <= ${#options[@]} )); then
            echo "${answer}"
            return 0
        fi
        echo "Invalid choice. Enter 1-${#options[@]}." >&2
    done
}

ssh_keys_appear_configured() {
    # Safety check: we only suggest disabling password auth when keys appear present.
    local users=("root")
    local user home

    if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
        users+=("${SUDO_USER}")
    fi

    for user in "${users[@]}"; do
        home="$(getent passwd "${user}" | cut -d: -f6 || true)"
        if [[ -n "${home}" && -s "${home}/.ssh/authorized_keys" ]]; then
            return 0
        fi
    done

    return 1
}

add_ufw_rule() {
    local rule="$*"
    UFW_RULES+=("${rule}")
}

add_ufw_port_rule() {
    local port_spec="$1"
    local proto="$2"
    local source="${3:-}"

    if [[ -n "${source}" ]]; then
        add_ufw_rule "allow from ${source} to any port ${port_spec} proto ${proto}"
    else
        add_ufw_rule "allow ${port_spec}/${proto}"
    fi
}

remove_ufw_rule_exact() {
    local target="$1"
    local rule
    local -a kept=()
    for rule in "${UFW_RULES[@]:-}"; do
        if [[ "${rule}" != "${target}" ]]; then
            kept+=("${rule}")
        fi
    done
    UFW_RULES=("${kept[@]}")
}

add_ports_from_csv() {
    local csv="$1"
    add_ports_from_csv_scoped "${csv}" "tcp" "global"
}

add_ports_from_csv_scoped() {
    # Accepts tokens like "443", "60000:60100", or "137/udp".
    # For profile-scoped ports, optional LAN restriction is applied automatically.
    local csv="$1"
    local default_proto="${2:-tcp}"
    local scope="${3:-global}"
    local source_scope=""
    local token
    IFS=',' read -r -a _tokens <<< "${csv}"

    if [[ "${scope}" == "profile" && "${PROFILE_FIREWALL_RESTRICT_LAN}" -eq 1 && -n "${PROFILE_LAN_SOURCE}" ]]; then
        source_scope="${PROFILE_LAN_SOURCE}"
    fi

    for token in "${_tokens[@]:-}"; do
        local port_spec=""
        local proto="${default_proto}"

        token="$(trim_spaces "${token}")"
        [[ -z "${token}" ]] && continue

        if [[ "${token}" =~ ^[0-9]+(:[0-9]+)?$ ]]; then
            port_spec="${token}"
        elif [[ "${token}" =~ ^([0-9]+(:[0-9]+)?)/(tcp|udp)$ ]]; then
            port_spec="${BASH_REMATCH[1]}"
            proto="${BASH_REMATCH[3]}"
        else
            warn "Skipping invalid custom port token: ${token}"
            continue
        fi

        add_ufw_port_rule "${port_spec}" "${proto}" "${source_scope}"
    done
}

configure_profile_lan_scope_prompt() {
    # Optional LAN-scoping is a defense-in-depth control for internal profiles.
    local default_choice="${1:-y}"

    PROFILE_FIREWALL_RESTRICT_LAN=0
    PROFILE_LAN_SOURCE=""

    if prompt_yes_no "Restrict profile service ports to a LAN source subnet where appropriate?" "${default_choice}"; then
        PROFILE_FIREWALL_RESTRICT_LAN=1
        while true; do
            PROFILE_LAN_SOURCE="$(prompt_input "LAN source subnet (CIDR)" "192.168.0.0/16")"
            if valid_cidr "${PROFILE_LAN_SOURCE}"; then
                break
            fi
            echo "Invalid CIDR. Example: 192.168.0.0/16"
        done
    fi
}

dedupe_ufw_rules() {
    local -A seen=()
    local -a unique=()
    local rule

    for rule in "${UFW_RULES[@]:-}"; do
        if [[ -n "${seen[${rule}]:-}" ]]; then
            continue
        fi
        seen["${rule}"]=1
        unique+=("${rule}")
    done

    UFW_RULES=("${unique[@]}")
}

# -------- Interactive Wizard --------
select_profile() {
    local options=(
        "lan-only - ${PROFILE_DESCRIPTIONS[lan-only]}"
        "docker-host - ${PROFILE_DESCRIPTIONS[docker-host]}"
        "file-server - ${PROFILE_DESCRIPTIONS[file-server]}"
        "media-host - ${PROFILE_DESCRIPTIONS[media-host]}"
        "public-reverse-proxy - ${PROFILE_DESCRIPTIONS[public-reverse-proxy]}"
        "tailscale-gateway - ${PROFILE_DESCRIPTIONS[tailscale-gateway]}"
        "custom - ${PROFILE_DESCRIPTIONS[custom]}"
    )

    local choice
    choice="$(prompt_menu "Server Profile" "1" "${options[@]}")"

    case "${choice}" in
        1) PROFILE="lan-only" ;;
        2) PROFILE="docker-host" ;;
        3) PROFILE="file-server" ;;
        4) PROFILE="media-host" ;;
        5) PROFILE="public-reverse-proxy" ;;
        6) PROFILE="tailscale-gateway" ;;
        7) PROFILE="custom" ;;
        *) die "Unexpected profile selection" ;;
    esac

    log "Selected profile: ${PROFILE}"
}

choose_profile() {
    # Module alias kept for a clear top-level orchestration flow.
    select_profile
}

configure_ssh_prompt() {
    echo
    echo "=== SSH Hardening ==="
    echo "Detected current SSH port: ${CURRENT_SSH_PORT}"

    while true; do
        SSH_PORT="$(prompt_input "SSH port" "${CURRENT_SSH_PORT}")"
        if valid_port "${SSH_PORT}"; then
            break
        fi
        echo "Invalid port. Enter a value between 1 and 65535."
    done

    if prompt_yes_no "Disable root SSH login? (recommended)" "y"; then
        DISABLE_ROOT_SSH=1
    else
        DISABLE_ROOT_SSH=0
        add_warning "Root SSH login left enabled."
    fi

    if ssh_keys_appear_configured; then
        echo "SSH key(s) detected."
        if prompt_yes_no "Disable SSH password authentication? (recommended if key login is tested)" "n"; then
            echo
            echo "!!! STRONG WARNING !!!"
            echo "You are about to disable SSH password authentication."
            echo "SSH key login must already work for at least one admin account."
            echo "Open and test a second SSH session with keys before applying this."
            if prompt_yes_no "Continue and disable SSH password authentication?" "n"; then
                DISABLE_PASSWORD_SSH=1
                add_warning "SSH password authentication will be disabled. Verify key-based access before closing this session."
                if [[ -n "${SSH_CONNECTION:-}" ]]; then
                    add_warning "Password SSH auth will be disabled on a live SSH session. Confirm key login before disconnecting."
                fi
            else
                DISABLE_PASSWORD_SSH=0
                add_warning "SSH password authentication kept enabled by operator after warning."
            fi
        else
            DISABLE_PASSWORD_SSH=0
            add_warning "SSH password authentication will remain enabled."
        fi
    else
        DISABLE_PASSWORD_SSH=0
        warn "No authorized_keys detected for root/sudo user. Password authentication will remain enabled for safety."
        add_warning "Password SSH auth kept enabled because key login was not detected."
    fi

    if prompt_yes_no "Enable SSH connection rate limiting? (recommended)" "y"; then
        SSH_RATE_LIMIT=1
    else
        SSH_RATE_LIMIT=0
    fi
}

configure_ssh() {
    # SSH is configured early so firewall decisions can safely allow the chosen port.
    configure_ssh_prompt
}

configure_firewall_prompt() {
    echo
    echo "=== UFW Firewall ==="

    # Reset planned rules each pass so "edit choices" behaves predictably.
    UFW_RULES=()
    CUSTOM_TCP_ENTRIES=""
    CUSTOM_UDP_ENTRIES=""

    if prompt_yes_no "Manage UFW firewall in this run?" "y"; then
        MANAGE_UFW=1
    else
        MANAGE_UFW=0
        add_warning "UFW changes skipped by request."
        return
    fi

    if prompt_yes_no "Reset existing UFW rules first? (safe default: no)" "n"; then
        RESET_UFW=1
        add_warning "UFW reset selected. Existing custom firewall rules will be removed."
    else
        RESET_UFW=0
    fi

    # Always allow SSH before enabling firewall.
    add_ufw_rule "allow ${SSH_PORT}/tcp"

    # Keep current SSH port open too when changing ports.
    if [[ "${SSH_PORT}" != "${CURRENT_SSH_PORT}" ]]; then
        add_ufw_rule "allow ${CURRENT_SSH_PORT}/tcp"
        add_warning "Both old and new SSH ports will be allowed to avoid lockout."
    fi

    if [[ "${SSH_RATE_LIMIT}" -eq 1 ]]; then
        if prompt_yes_no "Apply UFW SSH rate-limit rule too? (recommended)" "y"; then
            add_ufw_rule "limit ${SSH_PORT}/tcp"
        fi
    fi

    if prompt_yes_no "Add custom TCP firewall entries?" "n"; then
        read -r -p "Custom TCP ports/ranges (comma-separated, e.g., 8080,60000:60100): " CUSTOM_TCP_ENTRIES
        add_ports_from_csv_scoped "${CUSTOM_TCP_ENTRIES}" "tcp" "global"
    fi

    if prompt_yes_no "Add custom UDP firewall entries?" "n"; then
        read -r -p "Custom UDP ports/ranges (comma-separated, e.g., 53,60000:60100): " CUSTOM_UDP_ENTRIES
        add_ports_from_csv_scoped "${CUSTOM_UDP_ENTRIES}" "udp" "global"
    fi
}

configure_firewall() {
    configure_firewall_prompt
}

configure_public_reverse_proxy() {
    # This module intentionally does not open ports unless explicitly selected.
    if prompt_yes_no "Install Nginx + Certbot packages?" "y"; then
        INSTALL_NGINX=1
    else
        INSTALL_NGINX=0
    fi

    local web_choice
    web_choice="$(prompt_menu "Public Web Exposure (explicitly select internet ports)" "1" \
        "No public web ports right now (default)" \
        "Allow HTTPS 443 only (recommended)" \
        "Allow HTTP 80 + HTTPS 443 (weaker: includes non-TLS HTTP path)")"
    case "${web_choice}" in
        1)
            PUBLIC_WEB_MODE="none"
            add_warning "No public web ports selected for public-reverse-proxy."
            ;;
        2)
            PUBLIC_WEB_MODE="https-only"
            add_ufw_rule "allow 443/tcp"
            ;;
        3)
            PUBLIC_WEB_MODE="http-https"
            add_ufw_rule "allow 80/tcp"
            add_ufw_rule "allow 443/tcp"
            ;;
    esac

    if [[ "${INSTALL_NGINX}" -eq 1 ]] && [[ "${PUBLIC_WEB_MODE}" != "none" ]]; then
        if prompt_yes_no "Attempt Certbot issuance now? (requires DNS already pointed)" "n"; then
            RUN_CERTBOT_NOW=1
            read -r -p "Certificate domain (FQDN): " CERTBOT_DOMAIN
            read -r -p "Certificate email: " CERTBOT_EMAIL
        fi
    fi
}

configure_tailscale_gateway() {
    # Kept as a dedicated module wrapper for readability in the wizard flow.
    configure_tailscale_gateway_prompt
}

configure_profile_prompt() {
    echo
    echo "=== Profile-Specific Options (${PROFILE}) ==="

    # Reset profile-specific transient inputs so reruns/edit loops are safe.
    CUSTOM_PROFILE_PORTS=""
    CUSTOM_PROFILE_PACKAGES=""
    DOCKER_EXTRA_PORTS=""
    MEDIA_EXTRA_PORTS=""
    RUN_CERTBOT_NOW=0
    CERTBOT_DOMAIN=""
    CERTBOT_EMAIL=""

    case "${PROFILE}" in
        lan-only)
            configure_profile_lan_scope_prompt "y"

            if prompt_yes_no "Add LAN-only custom TCP entries?" "n"; then
                read -r -p "LAN-only TCP ports/ranges (comma-separated): " CUSTOM_PROFILE_PORTS
                add_ports_from_csv_scoped "${CUSTOM_PROFILE_PORTS}" "tcp" "profile"
            fi
            if prompt_yes_no "Add LAN-only custom UDP entries?" "n"; then
                read -r -p "LAN-only UDP ports/ranges (comma-separated): " CUSTOM_PROFILE_PORTS
                add_ports_from_csv_scoped "${CUSTOM_PROFILE_PORTS}" "udp" "profile"
            fi
            ;;

        docker-host)
            configure_profile_lan_scope_prompt "y"

            if prompt_yes_no "Install Docker packages ('docker.io' and compose plugin)?" "y"; then
                INSTALL_DOCKER=1
            else
                INSTALL_DOCKER=0
                add_warning "Docker profile selected but Docker package install disabled."
            fi

            if prompt_yes_no "Expose Docker API on 2376/TCP? (prefer TLS where possible; do not expose plain 2375)" "n"; then
                DOCKER_OPEN_TLS_API=1
                add_ports_from_csv_scoped "2376/tcp" "tcp" "profile"
                add_warning "Docker TLS API port opened. You still must configure daemon TLS certs manually."
            else
                DOCKER_OPEN_TLS_API=0
            fi

            if prompt_yes_no "Add docker-host custom TCP entries?" "n"; then
                read -r -p "Docker-host TCP ports/ranges (comma-separated): " DOCKER_EXTRA_PORTS
                add_ports_from_csv_scoped "${DOCKER_EXTRA_PORTS}" "tcp" "profile"
            fi
            if prompt_yes_no "Add docker-host custom UDP entries?" "n"; then
                read -r -p "Docker-host UDP ports/ranges (comma-separated): " DOCKER_EXTRA_PORTS
                add_ports_from_csv_scoped "${DOCKER_EXTRA_PORTS}" "udp" "profile"
            fi
            ;;

        file-server)
            configure_profile_lan_scope_prompt "y"

            if prompt_yes_no "Install Samba packages?" "y"; then
                INSTALL_SAMBA=1
            else
                INSTALL_SAMBA=0
            fi

            if [[ "${INSTALL_SAMBA}" -eq 1 ]]; then
                if prompt_yes_no "Allow Samba ports (137/udp,138/udp,139/tcp,445/tcp)?" "y"; then
                    ALLOW_SAMBA_PORTS=1
                    add_ports_from_csv_scoped "137/udp,138/udp,139/tcp,445/tcp" "tcp" "profile"
                else
                    ALLOW_SAMBA_PORTS=0
                fi

                local smb_choice
                smb_choice="$(prompt_menu "SMB Encryption Policy" "2" \
                    "Required (strongest, may break old clients)" \
                    "Desired (recommended balance)" \
                    "Disabled (weaker compatibility mode)")"
                case "${smb_choice}" in
                    1) FILESERVER_SMB_ENCRYPTION="required" ;;
                    2) FILESERVER_SMB_ENCRYPTION="desired" ;;
                    3)
                        FILESERVER_SMB_ENCRYPTION="off"
                        add_warning "SMB encryption disabled (weaker mode)."
                        ;;
                esac
            fi
            ;;

        media-host)
            configure_profile_lan_scope_prompt "y"

            if prompt_yes_no "Expose Plex port 32400 directly? (prefer TLS where possible; direct mode is weaker than HTTPS reverse proxy)" "n"; then
                MEDIA_EXPOSE_PLEX=1
                add_ports_from_csv_scoped "32400/tcp" "tcp" "profile"
                add_warning "Direct Plex port exposure selected (non-TLS path may be used by clients)."
            else
                MEDIA_EXPOSE_PLEX=0
            fi

            if prompt_yes_no "Add media-host custom TCP entries?" "n"; then
                read -r -p "Media-host TCP ports/ranges (comma-separated): " MEDIA_EXTRA_PORTS
                add_ports_from_csv_scoped "${MEDIA_EXTRA_PORTS}" "tcp" "profile"
            fi
            if prompt_yes_no "Add media-host custom UDP entries?" "n"; then
                read -r -p "Media-host UDP ports/ranges (comma-separated): " MEDIA_EXTRA_PORTS
                add_ports_from_csv_scoped "${MEDIA_EXTRA_PORTS}" "udp" "profile"
            fi
            ;;

        public-reverse-proxy)
            configure_public_reverse_proxy
            ;;

        tailscale-gateway)
            configure_tailscale_gateway
            ;;

        custom)
            configure_profile_lan_scope_prompt "n"

            if prompt_yes_no "Add custom-profile TCP entries?" "n"; then
                read -r -p "Custom-profile TCP ports/ranges (comma-separated): " CUSTOM_PROFILE_PORTS
                add_ports_from_csv_scoped "${CUSTOM_PROFILE_PORTS}" "tcp" "profile"
            fi
            if prompt_yes_no "Add custom-profile UDP entries?" "n"; then
                read -r -p "Custom-profile UDP ports/ranges (comma-separated): " CUSTOM_PROFILE_PORTS
                add_ports_from_csv_scoped "${CUSTOM_PROFILE_PORTS}" "udp" "profile"
            fi

            read -r -p "Extra apt packages to install (CSV package names; blank for none): " CUSTOM_PROFILE_PACKAGES
            ;;
    esac
}

configure_tailscale_gateway_prompt() {
    local mode_choice
    local backend_choice
    local routes_input
    local normalized_routes

    echo
    echo "=== Tailscale Gateway (Hardened Access Profile) ==="

    # Baseline defaults are reinitialized on each run/edit cycle.
    INSTALL_TAILSCALE=1
    TAILSCALE_PUBLISH_MODE="serve"
    TAILSCALE_BACKEND_TYPE="local-web"
    TAILSCALE_BACKEND_ADDR="127.0.0.1"
    TAILSCALE_BACKEND_PORT="3000"
    TAILSCALE_PUBLISH_PORT="443"
    TAILSCALE_CUSTOM_PUBLISH_COMMAND=""
    TAILSCALE_ENABLE_SUBNET_ROUTER=0
    TAILSCALE_ADVERTISE_ROUTES=""
    TAILSCALE_ENABLE_SSH=0
    TAILSCALE_STRONG_ADMIN_CHECK=1
    TAILSCALE_ENABLE_CHECKMK_STEP=1
    TAILSCALE_PREFER_TLS=1
    TAILSCALE_RUN_UP_NOW=0
    TAILSCALE_AUTHKEY=""

    if prompt_yes_no "Enable Tailscale profile?" "y"; then
        TAILSCALE_PROFILE_ENABLED=1
    else
        TAILSCALE_PROFILE_ENABLED=0
        add_warning "Tailscale gateway profile was selected but disabled by operator."
        return
    fi

    # No public ports by default for this profile. SSH is moved to tailscale0.
    remove_ufw_rule_exact "allow ${SSH_PORT}/tcp"
    remove_ufw_rule_exact "allow ${CURRENT_SSH_PORT}/tcp"
    remove_ufw_rule_exact "limit ${SSH_PORT}/tcp"
    add_ufw_rule "allow in on tailscale0 to any port ${SSH_PORT} proto tcp"

    if prompt_yes_no "Install Tailscale if missing?" "y"; then
        INSTALL_TAILSCALE=1
    else
        INSTALL_TAILSCALE=0
        add_warning "Tailscale install was skipped. Existing tailscale binary/service must already be present."
    fi

    mode_choice="$(prompt_menu "Publishing mode (prefer secure/private paths before public exposure)" "2" \
        "none" \
        "serve" \
        "funnel (PUBLIC INTERNET EXPOSURE)")"
    case "${mode_choice}" in
        1) TAILSCALE_PUBLISH_MODE="none" ;;
        2) TAILSCALE_PUBLISH_MODE="serve" ;;
        3)
            TAILSCALE_PUBLISH_MODE="funnel"
            add_warning "Funnel selected: this publishes to the public internet."
            ;;
    esac

    backend_choice="$(prompt_menu "Backend type" "1" \
        "local web app" \
        "local TCP app" \
        "existing reverse proxy" \
        "custom")"
    case "${backend_choice}" in
        1)
            TAILSCALE_BACKEND_TYPE="local-web"
            TAILSCALE_BACKEND_PORT="3000"
            TAILSCALE_PUBLISH_PORT="443"
            ;;
        2)
            TAILSCALE_BACKEND_TYPE="local-tcp"
            TAILSCALE_BACKEND_PORT="22"
            TAILSCALE_PUBLISH_PORT="2222"
            ;;
        3)
            TAILSCALE_BACKEND_TYPE="existing-reverse-proxy"
            TAILSCALE_BACKEND_PORT="443"
            TAILSCALE_PUBLISH_PORT="443"
            ;;
        4)
            TAILSCALE_BACKEND_TYPE="custom"
            TAILSCALE_BACKEND_PORT="3000"
            TAILSCALE_PUBLISH_PORT="443"
            ;;
    esac

    TAILSCALE_BACKEND_ADDR="$(prompt_input "Backend target address (prefer 127.0.0.1)" "127.0.0.1")"
    while true; do
        TAILSCALE_BACKEND_PORT="$(prompt_input "Backend target port" "${TAILSCALE_BACKEND_PORT}")"
        if valid_port "${TAILSCALE_BACKEND_PORT}"; then
            break
        fi
        echo "Invalid backend target port. Use 1-65535."
    done

    while true; do
        TAILSCALE_PUBLISH_PORT="$(prompt_input "Tailscale published port" "${TAILSCALE_PUBLISH_PORT}")"
        if valid_port "${TAILSCALE_PUBLISH_PORT}"; then
            break
        fi
        echo "Invalid publish port. Use 1-65535."
    done

    if [[ "${TAILSCALE_BACKEND_ADDR}" != "127.0.0.1" && "${TAILSCALE_BACKEND_ADDR}" != "::1" ]]; then
        add_warning "Backend target is not loopback. Prefer 127.0.0.1 when possible."
    fi

    if [[ "${TAILSCALE_BACKEND_TYPE}" == "custom" ]]; then
        read -r -p "Custom publish command (optional, leave blank to skip command execution): " TAILSCALE_CUSTOM_PUBLISH_COMMAND
    fi

    if prompt_yes_no "Enable subnet routing?" "n"; then
        TAILSCALE_ENABLE_SUBNET_ROUTER=1
        while true; do
            read -r -p "Which CIDRs to advertise? (comma-separated, explicit CIDRs only): " routes_input
            normalized_routes="$(validate_explicit_cidr_csv "${routes_input}" || true)"
            if [[ -n "${normalized_routes}" ]]; then
                TAILSCALE_ADVERTISE_ROUTES="${normalized_routes}"
                add_warning "Review advertised CIDRs before apply: ${TAILSCALE_ADVERTISE_ROUTES}"
                break
            fi
            echo "Invalid CIDR list. Use explicit CIDRs only (example: 192.168.10.0/24,10.20.0.0/16)."
            echo "Default routes (0.0.0.0/0, ::/0) are not allowed by this profile."
        done
    else
        TAILSCALE_ENABLE_SUBNET_ROUTER=0
        TAILSCALE_ADVERTISE_ROUTES=""
    fi

    if prompt_yes_no "Enable Tailscale SSH?" "y"; then
        TAILSCALE_ENABLE_SSH=1
        if prompt_yes_no "Require stronger auth/check mode for admin or root?" "y"; then
            TAILSCALE_STRONG_ADMIN_CHECK=1
            add_warning "Strong admin/root mode enabled for Tailscale SSH."
        else
            TAILSCALE_STRONG_ADMIN_CHECK=0
            add_warning "Tailscale SSH enabled without strong admin/root mode."
        fi
    else
        TAILSCALE_ENABLE_SSH=0
        TAILSCALE_STRONG_ADMIN_CHECK=0
    fi

    if prompt_yes_no "Enable Checkmk integration inline in this hardening run? (no separate checkmk_setup.sh needed)" "n"; then
        TAILSCALE_ENABLE_CHECKMK_STEP=1
    else
        TAILSCALE_ENABLE_CHECKMK_STEP=0
        INSTALL_CHECKMK=0
    fi

    if prompt_yes_no "Prefer TLS where possible?" "y"; then
        TAILSCALE_PREFER_TLS=1
    else
        TAILSCALE_PREFER_TLS=0
        add_warning "TLS preference disabled; weaker publishing/monitoring paths may be selected."
    fi

    if prompt_yes_no "Run tailscale up automatically at apply time?" "n"; then
        TAILSCALE_RUN_UP_NOW=1
        read -r -s -p "Optional auth key (leave empty for browser login): " TAILSCALE_AUTHKEY
        echo
    else
        TAILSCALE_RUN_UP_NOW=0
        TAILSCALE_AUTHKEY=""
    fi
}

configure_fail2ban() {
    if prompt_yes_no "Install/configure Fail2Ban? (recommended)" "y"; then
        INSTALL_FAIL2BAN=1
    else
        INSTALL_FAIL2BAN=0
    fi
}

configure_apparmor() {
    local apparmor_default="y"
    if [[ "${DISTRO}" == "debian" ]]; then
        apparmor_default="n"
    fi
    if prompt_yes_no "Enable AppArmor? (recommended when compatible with your workloads)" "${apparmor_default}"; then
        ENABLE_APPARMOR=1
    else
        ENABLE_APPARMOR=0
    fi
}

configure_unattended_upgrades() {
    local update_choice
    update_choice="$(prompt_menu "Update Strategy" "1" \
        "Notifications only (manual patching)" \
        "Enable unattended-upgrades" \
        "Manual updates only")"

    case "${update_choice}" in
        1) UPDATE_MODE="notify" ;;
        2) UPDATE_MODE="unattended" ;;
        3) UPDATE_MODE="manual" ;;
    esac
}

configure_base_security() {
    # Base security module groups host-wide controls (not role-specific services).
    echo
    echo "=== Base Security ==="
    configure_fail2ban
    configure_unattended_upgrades
    configure_apparmor
}

configure_security_services_prompt() {
    # Backward-compatible alias kept during modular refactor.
    configure_base_security
}

configure_checkmk_prompt() {
    local comm_default="1"

    # Reset Checkmk-specific transient values for rerun/edit safety.
    CHECKMK_ALLOW_FROM=""
    CHECKMK_SERVER=""
    CHECKMK_SITE="monitoring"

    if [[ "${PROFILE}" == "tailscale-gateway" && "${TAILSCALE_ENABLE_CHECKMK_STEP}" -ne 1 ]]; then
        INSTALL_CHECKMK=0
        log "Checkmk integration skipped by tailscale-gateway profile choice."
        return
    fi

    echo
    echo "=== Checkmk Integration (Optional) ==="
    echo "Prefer TLS where possible for Checkmk agent communication."
    if [[ "${PROFILE}" == "tailscale-gateway" ]]; then
        echo "For tailscale-gateway, Checkmk is handled in this wizard (no separate checkmk_setup.sh run required)."
    fi

    if [[ "${PROFILE}" == "tailscale-gateway" ]]; then
        INSTALL_CHECKMK=1
    else
        if ! prompt_yes_no "Configure Checkmk agent integration for this host?" "n"; then
            INSTALL_CHECKMK=0
            return
        fi
        INSTALL_CHECKMK=1
    fi

    local src_choice
    src_choice="$(prompt_menu "Checkmk Agent Installation Source" "1" \
        "Install from apt package ('check-mk-agent')" \
        "Install from .deb URL" \
        "Agent already installed; configure comms only")"

    case "${src_choice}" in
        1) CHECKMK_SOURCE="apt" ;;
        2)
            CHECKMK_SOURCE="deb-url"
            read -r -p "Enter Checkmk agent .deb URL: " CHECKMK_AGENT_URL
            ;;
        3) CHECKMK_SOURCE="already" ;;
    esac

    # If the operator disabled TLS preference for tailscale profile,
    # default Checkmk choice to plaintext but still present TLS first.
    if [[ "${PROFILE}" == "tailscale-gateway" && "${TAILSCALE_PREFER_TLS}" -eq 0 ]]; then
        comm_default="2"
    fi

    local comm_choice
    comm_choice="$(prompt_menu "Checkmk Communication Mode (prefer TLS where possible)" "${comm_default}" \
        "TLS / Agent Controller (preferred when supported)" \
        "Plain TCP 6556 (weaker legacy mode)")"

    case "${comm_choice}" in
        1)
            CHECKMK_COMM_MODE="tls"
            read -r -p "Checkmk server FQDN: " CHECKMK_SERVER
            CHECKMK_SITE="$(prompt_input "Checkmk site name" "monitoring")"
            ;;
        2)
            CHECKMK_COMM_MODE="plaintext"
            read -r -p "Restrict plain 6556 access to IP/CIDR (blank uses LAN source restriction when available; otherwise allows any): " CHECKMK_ALLOW_FROM
            if [[ -z "${CHECKMK_ALLOW_FROM}" ]]; then
                if [[ "${PROFILE_FIREWALL_RESTRICT_LAN}" -eq 1 && -n "${PROFILE_LAN_SOURCE}" ]]; then
                    add_warning "Checkmk plain mode selected without explicit source; LAN source restriction will be used (${PROFILE_LAN_SOURCE})."
                else
                    add_warning "Checkmk plain mode selected with open 6556 access (weaker mode)."
                fi
            elif ! valid_ip_or_cidr "${CHECKMK_ALLOW_FROM}"; then
                warn "Invalid IP/CIDR provided; using fallback source policy for 6556."
                CHECKMK_ALLOW_FROM=""
                add_warning "Invalid Checkmk source filter; source will fall back to LAN restriction when available, otherwise any source."
            fi
            ;;
    esac
}

configure_checkmk() {
    configure_checkmk_prompt
}

parse_custom_packages() {
    local token
    CUSTOM_PACKAGES=()
    IFS=',' read -r -a _pkgs <<< "${CUSTOM_PROFILE_PACKAGES}"
    for token in "${_pkgs[@]:-}"; do
        token="$(trim_spaces "${token}")"
        [[ -z "${token}" ]] && continue
        if [[ "${token}" =~ ^[a-z0-9][a-z0-9+.-]*$ ]]; then
            CUSTOM_PACKAGES+=("${token}")
        else
            warn "Skipping invalid package token: ${token}"
        fi
    done
}

build_ufw_rules_from_services() {
    # Adds firewall rules implied by selected integrations (currently Checkmk).
    # This runs before summary and apply so both views stay aligned.
    CHECKMK_EFFECTIVE_SOURCE="not-applicable"

    if [[ "${MANAGE_UFW}" -ne 1 ]]; then
        return
    fi

    if [[ "${INSTALL_CHECKMK}" -eq 1 && "${CHECKMK_COMM_MODE}" == "plaintext" ]]; then
        if [[ -n "${CHECKMK_ALLOW_FROM}" ]]; then
            add_ufw_rule "allow from ${CHECKMK_ALLOW_FROM} to any port 6556 proto tcp"
            CHECKMK_EFFECTIVE_SOURCE="${CHECKMK_ALLOW_FROM}"
        elif [[ "${PROFILE_FIREWALL_RESTRICT_LAN}" -eq 1 && -n "${PROFILE_LAN_SOURCE}" ]]; then
            add_ufw_rule "allow from ${PROFILE_LAN_SOURCE} to any port 6556 proto tcp"
            CHECKMK_EFFECTIVE_SOURCE="${PROFILE_LAN_SOURCE}"
            add_warning "Checkmk plaintext source not explicitly set; using LAN source restriction ${PROFILE_LAN_SOURCE}."
        else
            add_ufw_rule "allow 6556/tcp"
            CHECKMK_EFFECTIVE_SOURCE="any"
            add_warning "Checkmk plaintext access is open to any source (weaker mode)."
        fi
    elif [[ "${INSTALL_CHECKMK}" -eq 1 && "${CHECKMK_COMM_MODE}" == "tls" ]]; then
        CHECKMK_EFFECTIVE_SOURCE="n/a (TLS agent-controller mode)"
    fi

    dedupe_ufw_rules
}

ensure_ssh_access_rule_present() {
    # Hard safety guard: refuse firewall apply if SSH would become inaccessible.
    local has_ssh_access_rule=0
    local rule

    for rule in "${UFW_RULES[@]:-}"; do
        if [[ "${rule}" == "allow ${SSH_PORT}/tcp" || \
              "${rule}" == "allow ${CURRENT_SSH_PORT}/tcp" || \
              "${rule}" == "allow in on tailscale0 to any port ${SSH_PORT} proto tcp" ]]; then
            has_ssh_access_rule=1
            break
        fi
    done

    if [[ "${has_ssh_access_rule}" -ne 1 ]]; then
        die "No SSH access rule is planned. Refusing to enable UFW to avoid remote lockout."
    fi
}

evaluate_remote_access_risk() {
    # Aggregates human-facing warnings for risky SSH/firewall combinations.
    local rule
    local has_public_ssh_rule=0
    local has_tailscale_ssh_rule=0

    REMOTE_ACCESS_RISK=0
    REMOTE_ACCESS_WARNINGS=()

    if [[ "${SSH_PORT}" != "${CURRENT_SSH_PORT}" ]]; then
        add_remote_warning "SSH port will change from ${CURRENT_SSH_PORT} to ${SSH_PORT}."
    fi

    if [[ "${DISABLE_PASSWORD_SSH}" -eq 1 ]]; then
        add_remote_warning "SSH password authentication will be disabled. Key login must already work."
    fi

    if [[ "${DISABLE_ROOT_SSH}" -eq 1 ]]; then
        add_remote_warning "Root SSH login will be disabled."
    fi

    if [[ "${MANAGE_UFW}" -eq 1 ]]; then
        for rule in "${UFW_RULES[@]:-}"; do
            if [[ "${rule}" == "allow ${SSH_PORT}/tcp" || "${rule}" == "allow ${CURRENT_SSH_PORT}/tcp" ]]; then
                has_public_ssh_rule=1
            fi
            if [[ "${rule}" == "allow in on tailscale0 to any port ${SSH_PORT} proto tcp" ]]; then
                has_tailscale_ssh_rule=1
            fi
        done

        if [[ "${has_public_ssh_rule}" -ne 1 && "${has_tailscale_ssh_rule}" -eq 1 ]]; then
            add_remote_warning "SSH access is restricted to tailscale0 only. You must have working Tailscale connectivity."
        elif [[ "${has_public_ssh_rule}" -ne 1 && "${has_tailscale_ssh_rule}" -ne 1 ]]; then
            add_remote_warning "No explicit SSH allow rule is present. Firewall changes may block all remote access."
        fi
    fi

    if [[ "${PROFILE}" == "tailscale-gateway" && "${TAILSCALE_ENABLE_SSH}" -eq 1 && "${TAILSCALE_RUN_UP_NOW}" -ne 1 ]]; then
        add_remote_warning "Tailscale SSH is enabled but tailscale up is not automatic in this run."
    fi
}

add_planned_file() {
    local item="$1"
    local existing
    for existing in "${PLANNED_FILES[@]:-}"; do
        if [[ "${existing}" == "${item}" ]]; then
            return 0
        fi
    done
    PLANNED_FILES+=("${item}")
}

add_planned_service() {
    local item="$1"
    local existing
    for existing in "${PLANNED_SERVICES[@]:-}"; do
        if [[ "${existing}" == "${item}" ]]; then
            return 0
        fi
    done
    PLANNED_SERVICES+=("${item}")
}

build_change_plan_preview() {
    # Builds a preview list of files/services likely touched during apply.
    # This is informational and intentionally conservative.
    PLANNED_FILES=()
    PLANNED_SERVICES=()

    add_planned_file "/etc/ssh/sshd_config.d/99-homelab-hardening.conf"
    add_planned_service "${SSH_SERVICE} (reload/restart)"

    if [[ "${MANAGE_UFW}" -eq 1 ]]; then
        add_planned_file "/etc/ufw/user.rules"
        add_planned_file "/etc/ufw/user6.rules"
        add_planned_file "/etc/default/ufw"
        add_planned_service "ufw (enable/apply rules)"
    fi

    if [[ "${INSTALL_FAIL2BAN}" -eq 1 ]]; then
        add_planned_file "/etc/fail2ban/jail.d/sshd.local"
        add_planned_service "fail2ban (enable/start)"
    fi

    if [[ "${ENABLE_APPARMOR}" -eq 1 ]]; then
        add_planned_service "apparmor (enable/start if available)"
    fi

    case "${UPDATE_MODE}" in
        notify)
            add_planned_file "/etc/apticron/apticron.conf (if present)"
            ;;
        unattended)
            add_planned_file "/etc/apt/apt.conf.d/20auto-upgrades"
            add_planned_service "unattended-upgrades (reconfigure)"
            ;;
    esac

    case "${PROFILE}" in
        docker-host)
            if [[ "${INSTALL_DOCKER}" -eq 1 ]]; then
                add_planned_service "docker (enable/start)"
            fi
            ;;
        file-server)
            if [[ "${INSTALL_SAMBA}" -eq 1 ]]; then
                add_planned_file "/etc/samba/smb.conf.d/99-homelab-hardening.conf"
                add_planned_file "/etc/samba/smb.conf (include drop-in, if needed)"
                add_planned_service "smbd (enable/start)"
                add_planned_service "nmbd (enable/start if available)"
            fi
            ;;
        public-reverse-proxy)
            if [[ "${INSTALL_NGINX}" -eq 1 ]]; then
                add_planned_service "nginx (enable/start)"
            fi
            ;;
        tailscale-gateway)
            if [[ "${TAILSCALE_PROFILE_ENABLED}" -eq 1 ]]; then
                add_planned_service "tailscaled (enable/start)"
                add_planned_file "/etc/ssh/sshd_config.d/98-tailscale-gateway-admin.conf (managed by strong-admin mode)"
                if [[ "${TAILSCALE_ENABLE_SUBNET_ROUTER}" -eq 1 && -n "${TAILSCALE_ADVERTISE_ROUTES}" ]]; then
                    add_planned_file "/etc/sysctl.d/99-homelab-tailscale.conf"
                fi
            fi
            ;;
    esac
}

show_summary() {
    local checkmk_tls_label="not applicable"
    local exposure_tls_label="not applicable"
    local exposure_tls_note=""
    local docker_tls_label="not applicable"
    local smb_tls_label="not applicable"

    # Compute derived state just before rendering review output.
    build_ufw_rules_from_services
    evaluate_remote_access_risk
    build_change_plan_preview

    echo
    echo "======================================================"
    echo "Planned Hardening Summary"
    echo "======================================================"
    echo "Profile:                 ${PROFILE}"
    echo "Profile description:     ${PROFILE_DESCRIPTIONS[${PROFILE}]}"
    echo "Distribution:            ${DISTRO} ${DISTRO_VERSION} (${DISTRO_CODENAME:-unknown})"
    echo "SSH service:             ${SSH_SERVICE}"
    echo "Log file:                ${LOGFILE}"
    echo "Backup directory:        ${BACKUP_DIR}"
    echo
    echo "SSH:"
    echo "  Port:                  ${SSH_PORT}"
    echo "  Disable root login:    $([[ "${DISABLE_ROOT_SSH}" -eq 1 ]] && echo "yes" || echo "no")"
    echo "  Disable password auth: $([[ "${DISABLE_PASSWORD_SSH}" -eq 1 ]] && echo "yes" || echo "no")"
    echo "  Rate limiting:         $([[ "${SSH_RATE_LIMIT}" -eq 1 ]] && echo "yes" || echo "no")"
    echo
    echo "Firewall (UFW):"
    echo "  Manage UFW:            $([[ "${MANAGE_UFW}" -eq 1 ]] && echo "yes" || echo "no")"
    if [[ "${MANAGE_UFW}" -eq 1 ]]; then
        echo "  Reset existing rules:  $([[ "${RESET_UFW}" -eq 1 ]] && echo "yes" || echo "no")"
        echo "  Profile LAN restrict:  $([[ "${PROFILE_FIREWALL_RESTRICT_LAN}" -eq 1 ]] && echo "yes" || echo "no")"
        if [[ "${PROFILE_FIREWALL_RESTRICT_LAN}" -eq 1 ]]; then
            echo "  LAN source subnet:     ${PROFILE_LAN_SOURCE}"
        fi
        echo "  Custom TCP entries:    ${CUSTOM_TCP_ENTRIES:-none}"
        echo "  Custom UDP entries:    ${CUSTOM_UDP_ENTRIES:-none}"
        echo "  Planned rules:"
        if (( ${#UFW_RULES[@]} == 0 )); then
            echo "    - none"
        else
            local rule
            for rule in "${UFW_RULES[@]}"; do
                echo "    - ${rule}"
            done
        fi
    fi
    echo
    echo "Security services:"
    echo "  Fail2Ban:              $([[ "${INSTALL_FAIL2BAN}" -eq 1 ]] && echo "install" || echo "skip")"
    echo "  AppArmor:              $([[ "${ENABLE_APPARMOR}" -eq 1 ]] && echo "enable" || echo "skip")"
    echo "  Unattended-upgrades:   $([[ "${UPDATE_MODE}" == "unattended" ]] && echo "enabled" || echo "disabled")"
    echo "  Update mode:           ${UPDATE_MODE}"
    echo
    echo "Checkmk:"
    echo "  Enabled:               $([[ "${INSTALL_CHECKMK}" -eq 1 ]] && echo "yes" || echo "no")"
    if [[ "${INSTALL_CHECKMK}" -eq 1 ]]; then
        echo "  Source:                ${CHECKMK_SOURCE}"
        echo "  Mode:                  ${CHECKMK_COMM_MODE}"
        echo "  Communication:         ${CHECKMK_COMM_MODE} $([[ "${CHECKMK_COMM_MODE}" == "plaintext" ]] && echo "(weaker mode)" || echo "")"
        if [[ "${CHECKMK_COMM_MODE}" == "tls" ]]; then
            echo "  Server:                ${CHECKMK_SERVER:-not set}"
            echo "  Site:                  ${CHECKMK_SITE}"
            checkmk_tls_label="TLS"
        else
            echo "  Allow from:            ${CHECKMK_EFFECTIVE_SOURCE}"
            checkmk_tls_label="non-TLS"
        fi
    fi

    if [[ "${PROFILE}" == "tailscale-gateway" ]]; then
        echo
        echo "Tailscale gateway:"
        echo "  Profile enabled:       $([[ "${TAILSCALE_PROFILE_ENABLED}" -eq 1 ]] && echo "yes" || echo "no")"
        if [[ "${TAILSCALE_PROFILE_ENABLED}" -eq 1 ]]; then
            echo "  Install if missing:    $([[ "${INSTALL_TAILSCALE}" -eq 1 ]] && echo "yes" || echo "no")"
            echo "  Publishing mode:       ${TAILSCALE_PUBLISH_MODE} $([[ "${TAILSCALE_PUBLISH_MODE}" == "funnel" ]] && echo "(PUBLIC INTERNET EXPOSURE)" || echo "")"
            echo "  Backend type:          ${TAILSCALE_BACKEND_TYPE}"
            echo "  Backend target:        ${TAILSCALE_BACKEND_ADDR}:${TAILSCALE_BACKEND_PORT}"
            echo "  Published port:        ${TAILSCALE_PUBLISH_PORT}"
            echo "  Subnet routing:        $([[ "${TAILSCALE_ENABLE_SUBNET_ROUTER}" -eq 1 ]] && echo "enabled" || echo "disabled")"
            echo "  Advertised CIDRs:      ${TAILSCALE_ADVERTISE_ROUTES:-none}"
            echo "  Tailscale SSH:         $([[ "${TAILSCALE_ENABLE_SSH}" -eq 1 ]] && echo "enabled" || echo "disabled")"
            echo "  Strong admin/root:     $([[ "${TAILSCALE_STRONG_ADMIN_CHECK}" -eq 1 ]] && echo "enabled" || echo "disabled")"
            echo "  Prefer TLS:            $([[ "${TAILSCALE_PREFER_TLS}" -eq 1 ]] && echo "yes" || echo "no")"
            if [[ -n "${TAILSCALE_CUSTOM_PUBLISH_COMMAND}" ]]; then
                echo "  Custom publish cmd:    ${TAILSCALE_CUSTOM_PUBLISH_COMMAND}"
            fi
        else
            echo "  Mode:                  disabled (no tailscale publishing or routing changes)"
        fi
    fi

    case "${PROFILE}" in
        public-reverse-proxy)
            case "${PUBLIC_WEB_MODE}" in
                https-only)
                    exposure_tls_label="TLS"
                    exposure_tls_note="HTTPS-only public publishing"
                    ;;
                http-https)
                    exposure_tls_label="non-TLS"
                    exposure_tls_note="mixed mode includes non-TLS HTTP path (weaker)"
                    ;;
                none)
                    exposure_tls_label="not applicable"
                    exposure_tls_note="no web publishing selected"
                    ;;
            esac
            ;;
        media-host)
            if [[ "${MEDIA_EXPOSE_PLEX}" -eq 1 ]]; then
                exposure_tls_label="non-TLS"
                exposure_tls_note="direct Plex exposure may use non-TLS paths"
            else
                exposure_tls_label="not applicable"
                exposure_tls_note="direct media publishing not enabled"
            fi
            ;;
        tailscale-gateway)
            if [[ "${TAILSCALE_PROFILE_ENABLED}" -eq 1 ]]; then
                case "${TAILSCALE_PUBLISH_MODE}" in
                    none)
                        exposure_tls_label="not applicable"
                        exposure_tls_note="no tailscale publishing selected"
                        ;;
                    serve|funnel)
                        case "${TAILSCALE_BACKEND_TYPE}" in
                            existing-reverse-proxy)
                                if [[ "${TAILSCALE_PREFER_TLS}" -eq 1 ]]; then
                                    exposure_tls_label="TLS"
                                    exposure_tls_note="TLS-preferred reverse-proxy backend"
                                else
                                    exposure_tls_label="non-TLS"
                                    exposure_tls_note="TLS preference disabled for reverse-proxy backend"
                                fi
                                ;;
                            local-web)
                                exposure_tls_label="non-TLS"
                                exposure_tls_note="loopback HTTP backend over tailscale path"
                                ;;
                            local-tcp)
                                exposure_tls_label="non-TLS"
                                exposure_tls_note="TCP passthrough backend"
                                ;;
                            custom)
                                exposure_tls_label="not applicable"
                                exposure_tls_note="custom publish command"
                                ;;
                        esac

                        if [[ "${TAILSCALE_PUBLISH_MODE}" == "funnel" ]]; then
                            exposure_tls_note="${exposure_tls_note}; funnel is public internet exposure"
                        fi
                        ;;
                esac
            else
                exposure_tls_label="not applicable"
                exposure_tls_note="tailscale-gateway profile disabled"
            fi
            ;;
        *)
            exposure_tls_label="not applicable"
            exposure_tls_note="no profile-specific publishing integration selected"
            ;;
    esac

    if [[ "${PROFILE}" == "docker-host" ]]; then
        if [[ "${DOCKER_OPEN_TLS_API}" -eq 1 ]]; then
            docker_tls_label="TLS"
        else
            docker_tls_label="not applicable"
        fi
    fi

    if [[ "${PROFILE}" == "file-server" && "${INSTALL_SAMBA}" -eq 1 ]]; then
        smb_tls_label="not applicable"
    fi

    echo
    echo "TLS posture:"
    echo "  Checkmk communication: ${checkmk_tls_label}"
    echo "  Service exposure:      ${exposure_tls_label} (${exposure_tls_note})"
    if [[ "${PROFILE}" == "docker-host" ]]; then
        echo "  Docker API:            ${docker_tls_label} $([[ "${DOCKER_OPEN_TLS_API}" -eq 1 ]] && echo "(TLS-capable endpoint; cert setup still required)" || echo "(not enabled)")"
    fi
    if [[ "${PROFILE}" == "file-server" && "${INSTALL_SAMBA}" -eq 1 ]]; then
        echo "  Samba transport TLS:   ${smb_tls_label} (SMB encryption policy: ${FILESERVER_SMB_ENCRYPTION})"
    fi

    echo
    echo "Files to modify (with backups before write):"
    if (( ${#PLANNED_FILES[@]} == 0 )); then
        echo "  - none"
    else
        local planned_file
        for planned_file in "${PLANNED_FILES[@]}"; do
            echo "  - ${planned_file}"
        done
    fi

    echo
    echo "Services to restart/enable:"
    if (( ${#PLANNED_SERVICES[@]} == 0 )); then
        echo "  - none"
    else
        local planned_service
        for planned_service in "${PLANNED_SERVICES[@]}"; do
            echo "  - ${planned_service}"
        done
    fi

    if (( ${#SUMMARY_WARNINGS[@]} > 0 )); then
        echo
        echo "Warnings to review before apply:"
        local item
        for item in "${SUMMARY_WARNINGS[@]}"; do
            echo "  - ${item}"
        done
    fi

    if [[ "${REMOTE_ACCESS_RISK}" -eq 1 ]]; then
        echo
        echo "FINAL REMOTE ACCESS WARNING:"
        local access_item
        for access_item in "${REMOTE_ACCESS_WARNINGS[@]}"; do
            echo "  - ${access_item}"
        done
    fi

    echo "======================================================"
}

review_summary() {
    # Module alias for clearer high-level flow naming.
    show_summary
}

# -------- Apply Phase --------
run_cmd() {
    log "RUN: $*"
    "$@"
}

install_queued_packages() {
    if (( ${#PKG_QUEUE[@]} == 0 )); then
        log "No package installs required."
        return
    fi

    log "Installing packages: ${PKG_QUEUE[*]}"
    DEBIAN_FRONTEND=noninteractive apt-get install -y "${PKG_QUEUE[@]}"
}

prepare_package_queue() {
    # Package queue is deduplicated so reruns do not cause noisy repeat installs.
    queue_package "openssh-server"
    queue_package "ufw"
    queue_package "ca-certificates"
    queue_package "curl"
    queue_package "wget"

    if [[ "${INSTALL_FAIL2BAN}" -eq 1 ]]; then
        queue_package "fail2ban"
    fi

    if [[ "${ENABLE_APPARMOR}" -eq 1 ]]; then
        queue_package "apparmor"
        queue_package "apparmor-utils"
    fi

    case "${UPDATE_MODE}" in
        notify) queue_package "apticron" ;;
        unattended) queue_package "unattended-upgrades" ;;
    esac

    case "${PROFILE}" in
        docker-host)
            if [[ "${INSTALL_DOCKER}" -eq 1 ]]; then
                queue_package "docker.io"
                queue_package "docker-compose-plugin"
            fi
            ;;
        file-server)
            if [[ "${INSTALL_SAMBA}" -eq 1 ]]; then
                queue_package "samba"
            fi
            ;;
        public-reverse-proxy)
            if [[ "${INSTALL_NGINX}" -eq 1 ]]; then
                queue_package "nginx"
                queue_package "certbot"
                queue_package "python3-certbot-nginx"
            fi
            ;;
        custom)
            parse_custom_packages
            local pkg
            for pkg in "${CUSTOM_PACKAGES[@]:-}"; do
                queue_package "${pkg}"
            done
            ;;
    esac

}

install_tailscale_package() {
    # Tries distro package first; if unavailable, adds official Tailscale repo.
    if dpkg -s tailscale >/dev/null 2>&1; then
        log "Tailscale already installed"
        return 0
    fi

    if apt-cache policy tailscale 2>/dev/null | grep -q "Candidate: (none)"; then
        if [[ -z "${DISTRO_CODENAME}" ]]; then
            warn "Cannot infer distro codename for Tailscale repo setup."
            return 1
        fi

        log "Adding official Tailscale apt repository for ${DISTRO_CODENAME}"
        backup_config "/etc/apt/sources.list.d/tailscale.list"
        curl -fsSL "https://pkgs.tailscale.com/stable/${DISTRO_CODENAME}.noarmor.gpg" \
            -o /usr/share/keyrings/tailscale-archive-keyring.gpg
        curl -fsSL "https://pkgs.tailscale.com/stable/${DISTRO_CODENAME}.tailscale-keyring.list" \
            -o /etc/apt/sources.list.d/tailscale.list
        apt-get update
    fi

    apt-get install -y tailscale
}

apply_ssh_hardening() {
    # SSH is validated with sshd -t before reload/restart to prevent lockout.
    log "Applying SSH hardening"

    local ssh_dropin="/etc/ssh/sshd_config.d/99-homelab-hardening.conf"

    write_file_with_backup "${ssh_dropin}" <<EOF
# Managed by homelab hardening script (${SCRIPT_VERSION})
Port ${SSH_PORT}
PermitRootLogin $([[ "${DISABLE_ROOT_SSH}" -eq 1 ]] && echo "no" || echo "yes")
PasswordAuthentication $([[ "${DISABLE_PASSWORD_SSH}" -eq 1 ]] && echo "no" || echo "yes")
PermitEmptyPasswords no
ChallengeResponseAuthentication no
PubkeyAuthentication yes
X11Forwarding no
ClientAliveInterval 300
ClientAliveCountMax 2
$([[ "${SSH_RATE_LIMIT}" -eq 1 ]] && echo "MaxStartups 3:30:10" || echo "# MaxStartups unchanged by policy")
EOF

    if ! sshd -t; then
        die "sshd configuration validation failed. SSH config was not applied safely."
    fi

    systemctl reload "${SSH_SERVICE}" || systemctl restart "${SSH_SERVICE}"
    log "SSH service reloaded successfully"
}

apply_ufw() {
    if [[ "${MANAGE_UFW}" -ne 1 ]]; then
        log "Skipping UFW changes"
        return
    fi

    # UFW defaults are strict: deny incoming, allow outgoing.
    log "Applying UFW policy"
    ensure_ssh_access_rule_present
    backup_config "/etc/ufw/user.rules"
    backup_config "/etc/ufw/user6.rules"
    backup_config "/etc/default/ufw"

    if [[ "${RESET_UFW}" -eq 1 ]]; then
        run_cmd ufw --force reset
    fi

    run_cmd ufw default deny incoming
    run_cmd ufw default allow outgoing

    local rule
    for rule in "${UFW_RULES[@]}"; do
        log "RUN: ufw ${rule}"
        # shellcheck disable=SC2086
        ufw ${rule}
    done

    run_cmd ufw --force enable
}

apply_fail2ban() {
    if [[ "${INSTALL_FAIL2BAN}" -ne 1 ]]; then
        return
    fi

    log "Configuring Fail2Ban"
    write_file_with_backup "/etc/fail2ban/jail.d/sshd.local" <<EOF
[sshd]
enabled = true
port = ${SSH_PORT}
maxretry = 5
findtime = 10m
bantime = 1h
EOF

    systemctl enable --now fail2ban
}

apply_apparmor() {
    if [[ "${ENABLE_APPARMOR}" -ne 1 ]]; then
        return
    fi

    log "Ensuring AppArmor is enabled"
    if systemctl list-unit-files 2>/dev/null | awk '{print $1}' | grep -qx "apparmor.service"; then
        systemctl enable --now apparmor
    else
        warn "AppArmor service not found. Kernel/userland support may be missing."
    fi
}

apply_update_mode() {
    case "${UPDATE_MODE}" in
        notify)
            log "Configuring apticron (notification-only updates)"
            if [[ -f /etc/apticron/apticron.conf ]]; then
                backup_config "/etc/apticron/apticron.conf"
                sed -i 's/^EMAIL=.*/EMAIL="root"/' /etc/apticron/apticron.conf || true
                sed -i 's/^NOTIFY_NO_UPDATES=.*/NOTIFY_NO_UPDATES="0"/' /etc/apticron/apticron.conf || true
            fi
            ;;
        unattended)
            log "Configuring unattended-upgrades"
            write_file_with_backup "/etc/apt/apt.conf.d/20auto-upgrades" <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "7";
APT::Periodic::Unattended-Upgrade "1";
EOF
            dpkg-reconfigure -f noninteractive unattended-upgrades || warn "dpkg-reconfigure unattended-upgrades failed"
            ;;
        manual)
            log "Manual update mode selected; no automation configured"
            ;;
    esac
}

apply_checkmk() {
    if [[ "${INSTALL_CHECKMK}" -ne 1 ]]; then
        return
    fi

    log "Applying Checkmk integration"

    case "${CHECKMK_SOURCE}" in
        apt)
            if ! dpkg -s check-mk-agent >/dev/null 2>&1; then
                if ! apt-get install -y check-mk-agent; then
                    warn "Failed to install check-mk-agent from apt."
                    add_warning "Checkmk agent installation failed from apt."
                    return
                fi
            fi
            ;;
        deb-url)
            if [[ -z "${CHECKMK_AGENT_URL}" ]]; then
                warn "No Checkmk .deb URL provided; skipping installation."
            else
                local deb_path="/tmp/checkmk-agent.deb"
                curl -fsSL "${CHECKMK_AGENT_URL}" -o "${deb_path}"
                dpkg -i "${deb_path}" || apt-get -f install -y
                rm -f "${deb_path}"
            fi
            ;;
        already)
            log "Checkmk agent marked as pre-installed"
            ;;
    esac

    # TLS mode is preferred and avoids opening plain 6556 when possible.
    if [[ "${CHECKMK_COMM_MODE}" == "tls" ]]; then
        log "TLS mode selected for Checkmk communications"
        if command -v cmk-agent-ctl >/dev/null 2>&1; then
            log "To complete TLS registration, run: cmk-agent-ctl register --server ${CHECKMK_SERVER} --site ${CHECKMK_SITE}"
        else
            warn "cmk-agent-ctl not found. Verify your Checkmk agent version for TLS support."
        fi
    else
        log "Plain Checkmk mode selected (weaker mode)"
    fi
}

ensure_samba_include_dropin() {
    local main_cfg="/etc/samba/smb.conf"
    local include_line="include = /etc/samba/smb.conf.d/*.conf"

    if [[ ! -f "${main_cfg}" ]]; then
        return
    fi

    if ! grep -Eq '^\s*include\s*=\s*/etc/samba/smb\.conf\.d/\*\.conf\s*$' "${main_cfg}"; then
        backup_config "${main_cfg}"
        printf "\n%s\n" "${include_line}" >> "${main_cfg}"
        log "Added Samba include for /etc/samba/smb.conf.d/*.conf"
    fi
}

build_tailscale_publish_target() {
    # Build backend target URI used by tailscale serve/funnel apply logic.
    local scheme="http"

    case "${TAILSCALE_BACKEND_TYPE}" in
        existing-reverse-proxy)
            if [[ "${TAILSCALE_PREFER_TLS}" -eq 1 ]]; then
                scheme="https"
            fi
            ;;
        local-web)
            scheme="http"
            ;;
        local-tcp)
            echo "tcp://${TAILSCALE_BACKEND_ADDR}:${TAILSCALE_BACKEND_PORT}"
            return 0
            ;;
        custom)
            echo ""
            return 0
            ;;
    esac

    echo "${scheme}://${TAILSCALE_BACKEND_ADDR}:${TAILSCALE_BACKEND_PORT}"
}

apply_tailscale_strong_admin_controls() {
    # Optional stricter SSH policy drop-in for tailscale-gateway admin paths.
    local strict_file="/etc/ssh/sshd_config.d/98-tailscale-gateway-admin.conf"

    if [[ "${TAILSCALE_ENABLE_SSH}" -eq 1 && "${TAILSCALE_STRONG_ADMIN_CHECK}" -eq 1 ]]; then
        write_file_with_backup "${strict_file}" <<'EOF'
# Managed by homelab hardening script (tailscale-gateway strong admin mode)
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
EOF

        if sshd -t; then
            systemctl reload "${SSH_SERVICE}" || systemctl restart "${SSH_SERVICE}"
        else
            warn "Strong admin SSH controls failed validation; keeping prior SSH runtime config."
        fi
    else
        if [[ -f "${strict_file}" ]]; then
            backup_config "${strict_file}"
            rm -f "${strict_file}"
            if sshd -t; then
                systemctl reload "${SSH_SERVICE}" || systemctl restart "${SSH_SERVICE}"
            fi
        fi
    fi
}

apply_tailscale_gateway_profile() {
    # Applies only tailscale-specific runtime actions. Core hardening still
    # happens through global apply modules (SSH/UFW/Fail2Ban/etc).
    local publish_target

    if [[ "${TAILSCALE_PROFILE_ENABLED}" -ne 1 ]]; then
        log "Tailscale gateway profile disabled by operator; skipping tailscale-specific apply."
        return
    fi

    if [[ "${INSTALL_TAILSCALE}" -eq 1 ]]; then
        if ! install_tailscale_package; then
            add_warning "Tailscale installation failed."
            return
        fi
    fi

    if command -v tailscale >/dev/null 2>&1; then
        systemctl enable --now tailscaled || warn "Failed to enable tailscaled service"
    else
        warn "tailscale binary not found; cannot apply gateway runtime settings."
        return
    fi

    if [[ "${TAILSCALE_ENABLE_SUBNET_ROUTER}" -eq 1 ]]; then
        if [[ -z "${TAILSCALE_ADVERTISE_ROUTES}" ]]; then
            warn "Subnet routing requested but no explicit CIDRs were provided. Skipping route advertisement."
        else
            write_file_with_backup "/etc/sysctl.d/99-homelab-tailscale.conf" <<'EOF'
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
EOF
            sysctl --system >/dev/null
        fi
    fi

    apply_tailscale_strong_admin_controls

    if [[ "${TAILSCALE_RUN_UP_NOW}" -eq 1 ]]; then
        local -a ts_args=(up)
        if [[ "${TAILSCALE_ENABLE_SSH}" -eq 1 ]]; then
            ts_args+=(--ssh)
        fi
        if [[ "${TAILSCALE_ENABLE_SUBNET_ROUTER}" -eq 1 && -n "${TAILSCALE_ADVERTISE_ROUTES}" ]]; then
            ts_args+=(--advertise-routes="${TAILSCALE_ADVERTISE_ROUTES}")
        fi
        if [[ -n "${TAILSCALE_AUTHKEY}" ]]; then
            ts_args+=(--authkey="${TAILSCALE_AUTHKEY}")
        fi

        if ! tailscale "${ts_args[@]}"; then
            warn "tailscale up failed. Run tailscale up manually after fixing connectivity/auth."
        fi
    else
        log "Skipping automatic tailscale up by operator choice."
    fi

    case "${TAILSCALE_PUBLISH_MODE}" in
        none)
            log "Tailscale publishing mode: none"
            ;;
        serve|funnel)
            publish_target="$(build_tailscale_publish_target)"
            if [[ -z "${publish_target}" && -z "${TAILSCALE_CUSTOM_PUBLISH_COMMAND}" ]]; then
                warn "No publish target resolved for tailscale publishing mode ${TAILSCALE_PUBLISH_MODE}."
                return
            fi

            if [[ "${TAILSCALE_BACKEND_TYPE}" == "custom" ]]; then
                if [[ -n "${TAILSCALE_CUSTOM_PUBLISH_COMMAND}" ]]; then
                    log "Custom publish command captured for review: ${TAILSCALE_CUSTOM_PUBLISH_COMMAND}"
                    if [[ "${TAILSCALE_RUN_UP_NOW}" -eq 1 ]]; then
                        if ! sh -c "${TAILSCALE_CUSTOM_PUBLISH_COMMAND}"; then
                            warn "Custom tailscale publish command failed."
                        fi
                    fi
                fi
            elif [[ "${TAILSCALE_BACKEND_TYPE}" == "local-tcp" ]]; then
                log "Applying tailscale TCP publish: ${publish_target} on ${TAILSCALE_PUBLISH_PORT}"
                if [[ "${TAILSCALE_RUN_UP_NOW}" -eq 1 ]]; then
                    tailscale serve --bg --tcp="${TAILSCALE_PUBLISH_PORT}" "${publish_target}" || \
                        warn "tailscale serve (TCP) failed; verify command syntax for your installed tailscale version."
                fi
            else
                log "Applying tailscale web publish: ${publish_target} on ${TAILSCALE_PUBLISH_PORT}"
                if [[ "${TAILSCALE_RUN_UP_NOW}" -eq 1 ]]; then
                    tailscale serve --bg --https="${TAILSCALE_PUBLISH_PORT}" / "${publish_target}" || \
                        warn "tailscale serve (web) failed; verify command syntax for your installed tailscale version."
                fi
            fi

            if [[ "${TAILSCALE_PUBLISH_MODE}" == "funnel" ]]; then
                warn "Funnel mode enables public internet exposure."
                if [[ "${TAILSCALE_RUN_UP_NOW}" -eq 1 ]]; then
                    tailscale funnel "${TAILSCALE_PUBLISH_PORT}" on || \
                        warn "tailscale funnel enable failed; verify funnel availability and ACL policy."
                else
                    log "Funnel planned but not applied automatically because tailscale up automation is disabled."
                fi
            fi
            ;;
    esac
}

apply_profile_specific() {
    # Role-specific runtime/config work that does not belong to global modules.
    case "${PROFILE}" in
        docker-host)
            if [[ "${INSTALL_DOCKER}" -eq 1 ]]; then
                systemctl enable --now docker || warn "Failed to enable Docker service"
                if [[ "${DOCKER_OPEN_TLS_API}" -eq 1 ]]; then
                    log "Docker TLS API exposure selected (manual daemon TLS cert configuration still required)"
                fi
            fi
            ;;

        file-server)
            if [[ "${INSTALL_SAMBA}" -eq 1 ]]; then
                ensure_samba_include_dropin
                write_file_with_backup "/etc/samba/smb.conf.d/99-homelab-hardening.conf" <<EOF
[global]
server min protocol = SMB2
smb encrypt = ${FILESERVER_SMB_ENCRYPTION}
EOF
                if command -v testparm >/dev/null 2>&1; then
                    testparm -s >/dev/null
                fi
                systemctl enable --now smbd || warn "Failed to enable smbd"
                if systemctl list-unit-files 2>/dev/null | awk '{print $1}' | grep -qx "nmbd.service"; then
                    systemctl enable --now nmbd || warn "Failed to enable nmbd"
                fi
            fi
            ;;

        media-host)
            if [[ "${MEDIA_EXPOSE_PLEX}" -eq 1 ]]; then
                log "Media host configured to expose Plex port 32400"
            else
                log "Media host configured without direct Plex port exposure (prefer HTTPS publishing)"
            fi
            ;;

        public-reverse-proxy)
            if [[ "${INSTALL_NGINX}" -eq 1 ]]; then
                systemctl enable --now nginx || warn "Failed to enable Nginx"
            fi

            if [[ "${RUN_CERTBOT_NOW}" -eq 1 ]]; then
                if [[ -z "${CERTBOT_DOMAIN}" || -z "${CERTBOT_EMAIL}" ]]; then
                    warn "Certbot requested but domain/email missing; skipping cert issuance."
                else
                    if ! certbot --nginx --non-interactive --agree-tos -m "${CERTBOT_EMAIL}" -d "${CERTBOT_DOMAIN}" --redirect; then
                        warn "Certbot failed. Check DNS and reverse-proxy configuration."
                    fi
                fi
            fi
            ;;

        tailscale-gateway)
            apply_tailscale_gateway_profile
            ;;

        lan-only|custom)
            :
            ;;
    esac
}

apply_all_changes() {
    # Apply order matters:
    # 1) install packages, 2) harden SSH, 3) enforce firewall, 4) security services.
    log "Starting apply phase"

    prepare_package_queue

    run_cmd apt-get update
    install_queued_packages

    apply_ssh_hardening
    apply_ufw
    apply_fail2ban
    apply_apparmor
    apply_update_mode
    apply_checkmk
    apply_profile_specific

    log "Hardening apply phase complete"
}

apply_changes() {
    # Module alias for high-level naming consistency.
    apply_all_changes
}

print_post_apply() {
    echo
    echo "======================================================"
    echo "Hardening Complete"
    echo "======================================================"
    echo "Profile:          ${PROFILE}"
    echo "Log file:         ${LOGFILE}"
    echo "Backup directory: ${BACKUP_DIR}"
    echo
    echo "Next checks:"
    echo "1) Verify SSH login in a second session before closing this one."
    echo "2) Run: ufw status verbose"
    echo "3) Run: systemctl --failed"
    if [[ "${INSTALL_CHECKMK}" -eq 1 && "${CHECKMK_COMM_MODE}" == "tls" ]]; then
        echo "4) Complete Checkmk TLS registration (cmk-agent-ctl register)."
    fi
    echo "======================================================"
}

reset_wizard_review_state() {
    # Clears derived/planned state before each wizard pass.
    # This preserves safe rerun behavior when user chooses "edit choices".
    UFW_RULES=()
    SUMMARY_WARNINGS=()
    REMOTE_ACCESS_WARNINGS=()
    PLANNED_FILES=()
    PLANNED_SERVICES=()
    REMOTE_ACCESS_RISK=0
    CHECKMK_EFFECTIVE_SOURCE="not-applicable"
}

run_interactive_wizard() {
    # Top-level configuration module sequence (interactive phase only).
    reset_wizard_review_state
    choose_profile
    configure_ssh
    configure_firewall
    configure_profile_prompt
    configure_base_security
    configure_checkmk
}

final_review_gate() {
    # Review loop lets operator iterate safely before any mutating actions run.
    local review_choice

    while true; do
        review_summary

        review_choice="$(prompt_menu "Final Review (no changes are applied yet)" "2" \
            "Confirm and apply changes" \
            "Go back and edit choices" \
            "Cancel without applying anything")"

        case "${review_choice}" in
            1)
                return 0
                ;;
            2)
                log "Operator chose to edit selections from final review."
                run_interactive_wizard
                ;;
            3)
                log "User cancelled before apply"
                return 1
                ;;
        esac
    done
}

main() {
    # Entry point: detect environment, collect choices, review, then apply.
    require_root
    setup_runtime_paths
    detect_environment

    echo "Homelab Hardening Script v${SCRIPT_VERSION}"
    echo "Safe defaults, interactive prompts, and rollback-friendly backups"

    run_interactive_wizard

    if ! final_review_gate; then
        echo "No changes applied."
        exit 0
    fi

    apply_changes
    print_post_apply
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi

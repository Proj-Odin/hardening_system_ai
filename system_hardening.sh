#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Interactive Homelab Hardening Script for Ubuntu/Debian
# Menu-driven, profile-based system hardening with safety features
# ============================================================

# -------- Global Variables --------
SCRIPT_VERSION="2.0-interactive"
LOGFILE="/var/log/homelab_hardening-$(date +%Y%m%d_%H%M%S).log"
BACKUP_DIR="/var/backups/homelab_hardening/$(date +%Y%m%d_%H%M%S)"
DISTRO=""
SSH_SERVICE=""
CURRENT_PROFILE=""
CONFIG_CHANGES=()

# -------- Profile Definitions --------
declare -A PROFILE_DEFAULTS=(
    # [profile_name]="description|ssh_port|allow_root_ssh|allow_password_auth|fail2ban|ufw_rules|services|notes"
    ["lan-only"]="LAN-only server|22|0|0|1|ssh|sshd,ufw|Basic LAN server with SSH access"
    ["docker-host"]="Docker container host|22|0|0|1|ssh,docker|docker,sshd,ufw|Docker host with container management"
    ["file-server"]="Network file server|22|0|0|1|ssh,samba|smbd,nmbd,sshd,ufw|Samba file sharing server"
    ["media-host"]="Media streaming server|22|0|0|1|ssh,plex|plexmediaserver,sshd,ufw|Plex media server"
    ["public-reverse-proxy"]="Public reverse proxy|22|0|0|1|ssh,http,https|nginx,sshd,ufw|Nginx reverse proxy for public services"
    ["tailscale-gateway"]="Tailscale identity gateway|22|0|0|1|ssh,tailscale|tailscaled,sshd,ufw|Tailscale subnet router with identity-aware access"
    ["custom"]="Custom configuration|22|0|0|1|ssh|sshd,ufw|Fully customizable hardening profile"
)

# -------- Helper Functions --------
timestamp() { date +"%Y-%m-%d %H:%M:%S"; }
log() { echo "[$(timestamp)] $*" | tee -a "${LOGFILE}"; }
warn() { echo -e "\n[WARN] $*" >&2; log "WARN: $*"; }
die() { echo "ERROR: $*" >&2; log "ERROR: $*"; exit 1; }

# Detect distribution and SSH service
detect_environment() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        DISTRO="${ID:-unknown}"
    elif [[ -f /etc/debian_version ]]; then
        DISTRO="debian"
    else
        DISTRO="unknown"
    fi

    if systemctl list-units --all 2>/dev/null | grep -q sshd.service; then
        SSH_SERVICE="sshd"
    else
        SSH_SERVICE="ssh"
    fi

    log "Detected distribution: ${DISTRO}"
    log "SSH service: ${SSH_SERVICE}"
}

# Backup configuration files
backup_config() {
    local file="$1"
    local backup_file="${BACKUP_DIR}$(dirname "$file")/$(basename "$file").backup.$(date +%s)"

    if [[ -f "$file" ]]; then
        mkdir -p "$(dirname "$backup_file")"
        cp "$file" "$backup_file"
        log "Backed up $file to $backup_file"
    fi
}

# Check if SSH key authentication is working
check_ssh_keys_working() {
    # This is a simplified check - in practice you'd want more robust validation
    if [[ -f ~/.ssh/authorized_keys ]] && [[ -s ~/.ssh/authorized_keys ]]; then
        return 0
    else
        return 1
    fi
}

# Interactive menu system
show_menu() {
    local title="$1"
    shift
    local options=("$@")

    echo
    echo "=== $title ==="
    for i in "${!options[@]}"; do
        echo "$((i+1)). ${options[$i]}"
    done
    echo
}

get_user_choice() {
    local prompt="$1"
    local default="$2"
    local choices="$3"

    while true; do
        read -r -p "$prompt [$default]: " choice
        choice="${choice:-$default}"

        if [[ "$choices" == *"any"* ]]; then
            echo "$choice"
            return
        fi

        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "$choices" ]; then
            echo "$choice"
            return
        fi

        echo "Invalid choice. Please try again."
    done
}

confirm_action() {
    local prompt="$1"
    local default="${2:-n}"

    while true; do
        read -r -p "$prompt (y/n) [$default]: " choice
        choice="${choice:-$default}"
        case "$choice" in
            [Yy]|[Yy][Ee][Ss]) return 0 ;;
            [Nn]|[Nn][Oo]) return 1 ;;
            *) echo "Please answer yes or no." ;;
        esac
    done
}

# -------- Profile Selection --------
select_profile() {
    local profiles=("lan-only" "docker-host" "file-server" "media-host" "public-reverse-proxy" "tailscale-gateway" "custom")

    show_menu "Homelab Server Profiles" "${profiles[@]}"
    local choice=$(get_user_choice "Select your server profile" "1" "${#profiles[@]}")

    CURRENT_PROFILE="${profiles[$((choice-1))]}"
    log "Selected profile: $CURRENT_PROFILE"
}

# -------- Configuration Prompts --------
configure_ssh() {
    echo
    echo "=== SSH Configuration ==="

    # SSH Port
    SSH_PORT=$(get_user_choice "SSH port (avoid 22 for security)" "22" "any")
    validate_port "$SSH_PORT"

    # Root login
    if confirm_action "Disable root SSH login?" "y"; then
        DISABLE_ROOT_SSH=1
    else
        DISABLE_ROOT_SSH=0
    fi

    # Password authentication
    if check_ssh_keys_working; then
        echo "SSH key authentication appears to be configured."
        if confirm_action "Disable password authentication for SSH?" "y"; then
            ALLOW_PASSWORD_AUTH=0
        else
            ALLOW_PASSWORD_AUTH=1
        fi
    else
        warn "SSH key authentication not detected. Keeping password auth enabled for safety."
        ALLOW_PASSWORD_AUTH=1
    fi

    # Rate limiting
    if confirm_action "Enable SSH rate limiting (recommended)?" "y"; then
        SSH_RATE_LIMIT=1
    else
        SSH_RATE_LIMIT=0
    fi
}

configure_firewall() {
    echo
    echo "=== Firewall Configuration ==="

    # Basic UFW setup
    INSTALL_UFW=1
    UFW_RULES="ssh:${SSH_PORT}"

    # Profile-specific rules
    case "$CURRENT_PROFILE" in
        "docker-host")
            if confirm_action "Allow Docker Swarm ports (2376, 2377, 7946, 4789)?" "n"; then
                UFW_RULES="${UFW_RULES},2376,2377,7946,4789"
            fi
            ;;
        "file-server")
            if confirm_action "Allow Samba ports (137,138,139,445)?" "y"; then
                UFW_RULES="${UFW_RULES},137,138,139,445"
            fi
            ;;
        "media-host")
            if confirm_action "Allow Plex media server port (32400)?" "y"; then
                UFW_RULES="${UFW_RULES},32400"
            fi
            ;;
        "public-reverse-proxy")
            if confirm_action "Allow HTTP (80) and HTTPS (443) ports?" "y"; then
                UFW_RULES="${UFW_RULES},80,443"
            fi
            ;;
        "tailscale-gateway")
            # Tailscale uses its own internal networking
            ;;
    esac

    # Custom rules
    if confirm_action "Add custom firewall rules?" "n"; then
        echo "Enter additional ports (comma-separated, e.g., '8080,8443'):"
        read -r custom_ports
        if [[ -n "$custom_ports" ]]; then
            UFW_RULES="${UFW_RULES},${custom_ports}"
        fi
    fi
}

configure_security_services() {
    echo
    echo "=== Security Services ==="

    # Fail2Ban
    if confirm_action "Install and configure Fail2Ban (recommended)?" "y"; then
        INSTALL_FAIL2BAN=1
    else
        INSTALL_FAIL2BAN=0
    fi

    # AppArmor
    if confirm_action "Enable AppArmor (recommended for Ubuntu)?" "y"; then
        ENABLE_APPARMOR=1
    else
        ENABLE_APPARMOR=0
    fi

    # Update management
    echo
    echo "=== Update Management ==="
    echo "Choose update approach:"
    echo "1. Semi-automated (notifications only, manual install)"
    echo "2. Unattended upgrades (automatic, not recommended for production)"
    echo "3. Manual only (no automation)"
    local update_choice=$(get_user_choice "Update approach" "1" "3")

    case "$update_choice" in
        1)
            INSTALL_APT_NOTIFICATIONS=1
            INSTALL_UNATTENDED_UPGRADES=0
            ;;
        2)
            if confirm_action "WARNING: Unattended upgrades can break things. Continue?" "n"; then
                INSTALL_UNATTENDED_UPGRADES=1
                INSTALL_APT_NOTIFICATIONS=0
            else
                INSTALL_APT_NOTIFICATIONS=1
                INSTALL_UNATTENDED_UPGRADES=0
            fi
            ;;
        3)
            INSTALL_APT_NOTIFICATIONS=0
            INSTALL_UNATTENDED_UPGRADES=0
            ;;
    esac
}

configure_checkmk() {
    echo
    echo "=== Checkmk Monitoring (Optional) ==="

    if confirm_action "Install Checkmk agent for monitoring?" "n"; then
        INSTALL_CHECKMK=1

        echo "Checkmk agent URL:"
        read -r -p "Enter Checkmk agent .deb URL: " CMK_AGENT_DEB_URL

        echo "Checkmk server IP (leave empty for no restriction):"
        read -r -p "Server IP: " CMK_SERVER_IP

        echo "Checkmk site name:"
        read -r -p "Site name [monitoring]: " CMK_SITE
        CMK_SITE="${CMK_SITE:-monitoring}"

        # TLS preference
        if confirm_action "Use TLS for Checkmk agent communication?" "y"; then
            CMK_TLS=1
        else
            CMK_TLS=0
        fi
    else
        INSTALL_CHECKMK=0
    fi
}

# -------- Summary and Confirmation --------
show_summary() {
    echo
    echo "=========================================="
    echo "HOMELAB HARDENING SUMMARY"
    echo "=========================================="
    echo "Profile: $CURRENT_PROFILE"
    echo "Distribution: $DISTRO"
    echo "SSH Service: $SSH_SERVICE"
    echo "Log file: $LOGFILE"
    echo "Backup directory: $BACKUP_DIR"
    echo
    echo "SSH Configuration:"
    echo "  Port: $SSH_PORT"
    echo "  Root login: $([[ "$DISABLE_ROOT_SSH" == "1" ]] && echo "Disabled" || echo "Enabled")"
    echo "  Password auth: $([[ "$ALLOW_PASSWORD_AUTH" == "1" ]] && echo "Enabled" || echo "Disabled")"
    echo "  Rate limiting: $([[ "$SSH_RATE_LIMIT" == "1" ]] && echo "Enabled" || echo "Disabled")"
    echo
    echo "Firewall (UFW):"
    echo "  Rules: $UFW_RULES"
    echo
    echo "Security Services:"
    echo "  Fail2Ban: $([[ "$INSTALL_FAIL2BAN" == "1" ]] && echo "Install" || echo "Skip")"
    echo "  AppArmor: $([[ "$ENABLE_APPARMOR" == "1" ]] && echo "Enable" || echo "Skip")"
    echo
    echo "Update Management:"
    if [[ "$INSTALL_APT_NOTIFICATIONS" == "1" ]]; then
        echo "  Semi-automated (apticron notifications)"
    elif [[ "$INSTALL_UNATTENDED_UPGRADES" == "1" ]]; then
        echo "  Unattended upgrades (WARNING: Can break things!)"
    else
        echo "  Manual updates only"
    fi
    echo
    echo "Checkmk Monitoring:"
    if [[ "$INSTALL_CHECKMK" == "1" ]]; then
        echo "  Agent URL: $CMK_AGENT_DEB_URL"
        echo "  Server IP: ${CMK_SERVER_IP:-Any}"
        echo "  Site: $CMK_SITE"
        echo "  TLS: $([[ "$CMK_TLS" == "1" ]] && echo "Enabled" || echo "Disabled")"
    else
        echo "  Skip Checkmk installation"
    fi
    echo "=========================================="
}

# -------- Apply Changes --------
apply_changes() {
    log "Starting hardening process..."

    # Create backup directory
    mkdir -p "$BACKUP_DIR"

    # Update system
    log "Updating system packages..."
    apt-get update -y
    apt-get upgrade -y

    # Install basic packages
    apt-get install -y openssh-server ufw ca-certificates curl wget

    # SSH hardening
    configure_ssh_hardening

    # Firewall
    configure_ufw

    # Security services
    if [[ "$INSTALL_FAIL2BAN" == "1" ]]; then
        install_fail2ban
    fi

    if [[ "$ENABLE_APPARMOR" == "1" ]]; then
        enable_apparmor
    fi

    # Update management
    if [[ "$INSTALL_APT_NOTIFICATIONS" == "1" ]]; then
        install_apticron
    elif [[ "$INSTALL_UNATTENDED_UPGRADES" == "1" ]]; then
        install_unattended_upgrades
    fi

    # Checkmk
    if [[ "$INSTALL_CHECKMK" == "1" ]]; then
        install_checkmk
    fi

    # Profile-specific setup
    apply_profile_specific

    log "Hardening completed successfully!"
}

# -------- Implementation Functions --------
configure_ssh_hardening() {
    log "Configuring SSH hardening..."

    # Backup SSH config
    backup_config "/etc/ssh/sshd_config"

    # Ensure drop-in directory
    mkdir -p /etc/ssh/sshd_config.d

    # Create hardening config
    cat > /etc/ssh/sshd_config.d/99-homelab-hardening.conf <<EOF
# Homelab hardening - $(timestamp)
Port ${SSH_PORT}
$( [[ "$DISABLE_ROOT_SSH" == "1" ]] && echo "PermitRootLogin no" || echo "PermitRootLogin yes" )
PasswordAuthentication $( [[ "$ALLOW_PASSWORD_AUTH" == "1" ]] && echo "yes" || echo "no" )
PermitEmptyPasswords no
ChallengeResponseAuthentication no
X11Forwarding no
AllowTcpForwarding yes
ClientAliveInterval 300
ClientAliveCountMax 2
$( [[ "$SSH_RATE_LIMIT" == "1" ]] && echo "MaxStartups 3:30:10" || echo "# Rate limiting disabled" )
EOF

    # Test and restart SSH
    sshd -t
    systemctl restart "$SSH_SERVICE"
}

configure_ufw() {
    log "Configuring UFW firewall..."

    ufw --force reset
    ufw default deny incoming
    ufw default allow outgoing

    # Parse and apply rules
    IFS=',' read -ra RULES <<< "$UFW_RULES"
    for rule in "${RULES[@]}"; do
        if [[ "$rule" == "ssh:"* ]]; then
            port="${rule#ssh:}"
            ufw allow "$port/tcp"
        elif [[ "$rule" =~ ^[0-9]+$ ]]; then
            ufw allow "$rule/tcp"
        else
            ufw allow "$rule"
        fi
    done

    ufw --force enable
}

install_fail2ban() {
    log "Installing Fail2Ban..."
    apt-get install -y fail2ban

    cat > /etc/fail2ban/jail.d/sshd.conf <<EOF
[sshd]
enabled = true
port = ${SSH_PORT}
maxretry = 5
findtime = 10m
bantime = 1h
EOF

    systemctl enable --now fail2ban
}

enable_apparmor() {
    log "Enabling AppArmor..."
    apt-get install -y apparmor apparmor-utils

    # Enable AppArmor in GRUB if not already
    if ! grep -q "apparmor=1" /etc/default/grub; then
        sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="/GRUB_CMDLINE_LINUX_DEFAULT="apparmor=1 security=apparmor /' /etc/default/grub
        update-grub
    fi

    systemctl enable apparmor
}

install_apticron() {
    log "Installing apticron for update notifications..."
    apt-get install -y apticron

    # Configure apticron
    sed -i 's/^EMAIL=.*/EMAIL="root"/' /etc/apticron/apticron.conf
    sed -i 's/^NOTIFY_NO_UPDATES=.*/NOTIFY_NO_UPDATES="0"/' /etc/apticron/apticron.conf
}

install_unattended_upgrades() {
    log "Installing unattended-upgrades..."
    apt-get install -y unattended-upgrades
    dpkg-reconfigure -f noninteractive unattended-upgrades
}

install_checkmk() {
    log "Installing Checkmk agent..."

    # Download and install agent
    curl -fsSL "$CMK_AGENT_DEB_URL" -o /tmp/checkmk-agent.deb
    dpkg -i /tmp/checkmk-agent.deb || apt-get -f install -y
    rm -f /tmp/checkmk-agent.deb

    # Configure firewall
    if [[ -n "$CMK_SERVER_IP" ]]; then
        ufw allow from "$CMK_SERVER_IP" to any port 6556 proto tcp
    else
        ufw allow 6556/tcp
    fi

    # TLS configuration (if supported)
    if [[ "$CMK_TLS" == "1" ]]; then
        log "TLS requested for Checkmk - check agent documentation for TLS setup"
    fi
}

apply_profile_specific() {
    log "Applying profile-specific configuration: $CURRENT_PROFILE"

    case "$CURRENT_PROFILE" in
        "docker-host")
            apt-get install -y docker.io docker-compose
            systemctl enable docker
            ;;
        "file-server")
            apt-get install -y samba
            # Note: Samba configuration would need additional setup
            ;;
        "media-host")
            # Note: Plex installation would require additional steps
            ;;
        "public-reverse-proxy")
            apt-get install -y nginx certbot
            # Note: Nginx and TLS configuration would need additional setup
            ;;
        "tailscale-gateway")
            # Install Tailscale
            curl -fsSL https://tailscale.com/install.sh | sh
            # Note: Tailscale configuration would need additional setup
            ;;
    esac
}

# -------- Main Function --------
main() {
    echo "Homelab Hardening Script v${SCRIPT_VERSION}"
    echo "=========================================="

    # Initial setup
    detect_environment

    # Interactive configuration
    select_profile
    configure_ssh
    configure_firewall
    configure_security_services
    configure_checkmk

    # Show summary and confirm
    show_summary

    if ! confirm_action "Apply these changes?" "n"; then
        echo "Hardening cancelled by user."
        exit 0
    fi

    # Apply changes
    apply_changes

    echo
    echo "=========================================="
    echo "Hardening completed! Review the log file:"
    echo "$LOGFILE"
    echo "=========================================="
}

# -------- Script Entry Point --------
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi


#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# General System Hardening Script for Debian/Ubuntu
# Applies basic security hardening measures
# ============================================================

# -------- Defaults (can be overridden via env) --------------
DEFAULT_SSH_PORT="${DEFAULT_SSH_PORT:-22}"
INSTALL_FAIL2BAN="${INSTALL_FAIL2BAN:-1}"
INSTALL_UNATTENDED_UPGRADES="${INSTALL_UNATTENDED_UPGRADES:-0}"  # Changed default to 0
INSTALL_APT_NOTIFICATIONS="${INSTALL_APT_NOTIFICATIONS:-1}"     # New option
DISABLE_ROOT_SSH="${DISABLE_ROOT_SSH:-1}"
ALLOW_PASSWORD_AUTH="${ALLOW_PASSWORD_AUTH:-0}"
NONINTERACTIVE="${NONINTERACTIVE:-0}"

timestamp() { date +"%Y%m%d_%H%M%S"; }
log() { echo -e "\n==> $*"; }
warn() { echo -e "\n[WARN] $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

validate_port() {
  local port="$1"
  if [[ ! "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
    die "Invalid port number: $port"
  fi
}

need_root() { [[ "${EUID}" -eq 0 ]] || die "Run as root (sudo -i)."; }
has_apt() { command -v apt-get >/dev/null 2>&1 || die "This script expects Debian/Ubuntu (apt-get)."; }

# Detect distribution
detect_distro() {
  if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    echo "${ID:-unknown}"
  elif [[ -f /etc/debian_version ]]; then
    echo "debian"
  else
    echo "unknown"
  fi
}

# Get SSH service name (ssh on Ubuntu, sshd on some Debian versions)
get_ssh_service() {
  if systemctl list-units --all | grep -q sshd.service; then
    echo "sshd"
  else
    echo "ssh"
  fi
}

# -------- Main Logic --------

need_root
has_apt

# Detect distribution
DISTRO="$(detect_distro)"
SSH_SERVICE="$(get_ssh_service)"

if [[ "${DISTRO}" != "debian" && "${DISTRO}" != "ubuntu" ]]; then
  warn "This script is designed for Debian/Ubuntu. Detected: ${DISTRO}. Continuing anyway..."
fi

log "Detected distribution: ${DISTRO}"
log "SSH service: ${SSH_SERVICE}"

LOGFILE="/var/log/system_hardening-$(timestamp).log"
exec > >(tee -a "${LOGFILE}") 2>&1
log "Logging to ${LOGFILE}"

export DEBIAN_FRONTEND=noninteractive

# -------- Prompts or env overrides --------
SSH_PORT="${SSH_PORT:-}"
prompt_if_needed() {
  local varname="$1" prompt="$2" default="$3"
  local current="${!varname:-}"
  if [[ -n "${current}" ]]; then return 0; fi
  if [[ "${NONINTERACTIVE}" == "1" ]]; then
    printf -v "${varname}" "%s" "${default}"
    return 0
  fi
  read -r -p "${prompt} [${default}]: " reply
  reply="${reply:-$default}"
  printf -v "${varname}" "%s" "${reply}"
}

prompt_if_needed SSH_PORT "SSH port to configure" "${DEFAULT_SSH_PORT}"

validate_port "${SSH_PORT}"

# -------- Update system --------
log "Updating system packages..."
apt-get update -y
apt-get upgrade -y

# -------- Install basic security packages --------
log "Installing security packages..."
apt-get install -y \
  openssh-server \
  ufw \
  ca-certificates \
  curl \
  wget

if [[ "${INSTALL_FAIL2BAN}" == "1" ]]; then
  apt-get install -y fail2ban
fi

if [[ "${INSTALL_UNATTENDED_UPGRADES}" == "1" ]]; then
  apt-get install -y unattended-upgrades
  dpkg-reconfigure -f noninteractive unattended-upgrades || true
fi

if [[ "${INSTALL_APT_NOTIFICATIONS}" == "1" ]]; then
  if apt-cache show apticron >/dev/null 2>&1; then
    apt-get install -y apticron
    # Configure apticron for email notifications
    if [[ -f /etc/apticron/apticron.conf ]]; then
      sed -i 's/^EMAIL=.*/EMAIL="root"/' /etc/apticron/apticron.conf
      sed -i 's/^NOTIFY_NO_UPDATES=.*/NOTIFY_NO_UPDATES="0"/' /etc/apticron/apticron.conf
    fi
  else
    warn "apticron package not available on this system. Skipping update notifications."
  fi
fi

# -------- SSH Hardening --------
log "Configuring SSH hardening..."

# Ensure sshd_config includes drop-in directory
if ! grep -qiE '^\s*Include\s+/etc/ssh/sshd_config\.d/\*\.conf' /etc/ssh/sshd_config; then
  echo "" >> /etc/ssh/sshd_config
  echo "Include /etc/ssh/sshd_config.d/*.conf" >> /etc/ssh/sshd_config
fi
mkdir -p /etc/ssh/sshd_config.d

# Write hardening drop-in
cat > /etc/ssh/sshd_config.d/99-hardening.conf <<EOF
# Managed by system hardening script
Port ${SSH_PORT}

PermitRootLogin $([[ "${DISABLE_ROOT_SSH}" == "1" ]] && echo "no" || echo "yes")
PasswordAuthentication $([[ "${ALLOW_PASSWORD_AUTH}" == "1" ]] && echo "yes" || echo "no")
PermitEmptyPasswords no
ChallengeResponseAuthentication no

X11Forwarding no
AllowTcpForwarding yes

ClientAliveInterval 300
ClientAliveCountMax 2

# Use strong ciphers and key exchange
Ciphers aes256-gcm@openssh.com,chacha20-poly1305@openssh.com,aes256-ctr,aes192-ctr,aes128-ctr
KexAlgorithms curve25519-sha256@libssh.org,diffie-hellman-group-exchange-sha256
MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com,umac-128-etm@openssh.com
EOF

chmod 0644 /etc/ssh/sshd_config.d/99-hardening.conf

# Test SSH config
sshd -t
systemctl restart "${SSH_SERVICE}"

# -------- UFW Firewall --------
log "Configuring UFW firewall..."
ufw --force reset
ufw default deny incoming
ufw default allow outgoing

# Allow SSH on configured port from anywhere (adjust as needed)
ufw allow "${SSH_PORT}/tcp"

ufw --force enable

# -------- Fail2Ban --------
if [[ "${INSTALL_FAIL2BAN}" == "1" ]]; then
  log "Configuring Fail2Ban..."

  cat > /etc/fail2ban/jail.d/sshd.local <<EOF
[DEFAULT]
backend = systemd
banaction = ufw

[sshd]
enabled = true
port = ${SSH_PORT}
maxretry = 5
findtime = 10m
bantime = 1h
EOF

  systemctl enable --now fail2ban
  systemctl restart fail2ban
fi

# -------- Additional hardening --------
log "Applying additional hardening measures..."

# Disable unnecessary services
systemctl disable --now avahi-daemon 2>/dev/null || true
systemctl disable --now cups 2>/dev/null || true

# Secure /etc/hosts
if ! grep -q "127.0.0.1 localhost" /etc/hosts; then
  echo "127.0.0.1 localhost" >> /etc/hosts
fi

# Set secure umask
if ! grep -q "umask 027" /etc/bash.bashrc; then
  echo "umask 027" >> /etc/bash.bashrc
fi

# -------- Summary --------
log "System hardening completed."
echo
echo "==================== HARDENING SUMMARY ===================="
echo "Log file         : ${LOGFILE}"
echo "Distribution     : ${DISTRO}"
echo "SSH service      : ${SSH_SERVICE}"
echo "SSH port         : ${SSH_PORT}"
echo "Root SSH login   : $([[ "${DISABLE_ROOT_SSH}" == "1" ]] && echo "Disabled" || echo "Enabled")"
echo "Password auth    : $([[ "${ALLOW_PASSWORD_AUTH}" == "1" ]] && echo "Enabled" || echo "Disabled")"
echo "Fail2Ban         : $([[ "${INSTALL_FAIL2BAN}" == "1" ]] && echo "Installed" || echo "Not installed")"
echo "Unattended upgrades: $([[ "${INSTALL_UNATTENDED_UPGRADES}" == "1" ]] && echo "Enabled" || echo "Not enabled")"
echo "APT notifications: $([[ "${INSTALL_APT_NOTIFICATIONS}" == "1" ]] && echo "Installed (apticron)" || echo "Not installed")"
echo
echo "Quick checks:"
echo "  systemctl status ssh --no-pager"
echo "  ufw status verbose"
if [[ "${INSTALL_FAIL2BAN}" == "1" ]]; then
  echo "  fail2ban-client status sshd"
fi
if [[ "${INSTALL_APT_NOTIFICATIONS}" == "1" ]]; then
  echo "  Check /etc/apticron/apticron.conf for email configuration"
  echo "  Test: apticron"
fi
echo "==========================================================="</content>
<parameter name="filePath">e:\Projects\hardening_system_ai\system_hardening.sh
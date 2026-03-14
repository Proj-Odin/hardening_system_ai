#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Checkmk Agent Installation and Configuration Script
# Installs Checkmk agent and configures monitoring
# ============================================================

# -------- Defaults (can be overridden via env) --------------
CMK_AGENT_DEB_URL="${CMK_AGENT_DEB_URL:-}"
CMK_SERVER_IP="${CMK_SERVER_IP:-}"
CMK_SITE="${CMK_SITE:-}"
FORCE_REINSTALL="${FORCE_REINSTALL:-0}"
INSTALL_SMART_PLUGINS="${INSTALL_SMART_PLUGINS:-1}"
NONINTERACTIVE="${NONINTERACTIVE:-0}"

timestamp() { date +"%Y%m%d_%H%M%S"; }
log() { echo -e "\n==> $*"; }
warn() { echo -e "\n[WARN] $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

TMP_DEB=""
cleanup() {
  if [[ -n "${TMP_DEB}" && -f "${TMP_DEB}" ]]; then
    rm -f -- "${TMP_DEB}"
  fi
}
trap cleanup EXIT

need_root() { [[ "${EUID}" -eq 0 ]] || die "Run as root (sudo -i)."; }
has_apt() { command -v apt-get >/dev/null 2>&1 || die "This script expects Debian/Ubuntu (apt-get)."; }

pkg_installed() { dpkg -s "$1" >/dev/null 2>&1; }

ensure_pkg() {
  local p="$1"
  if pkg_installed "$p"; then
    log "Package already installed: $p"
  else
    log "Installing package: $p"
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$p"
  fi
}

# -------- Main Logic --------

need_root
has_apt

LOGFILE="/var/log/checkmk_setup-$(timestamp).log"
exec > >(tee -a "${LOGFILE}") 2>&1
log "Logging to ${LOGFILE}"

export DEBIAN_FRONTEND=noninteractive

# -------- Prompts or env overrides --------
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

if [[ -z "${CMK_AGENT_DEB_URL}" ]]; then
  prompt_if_needed CMK_AGENT_DEB_URL "Checkmk agent .deb URL" ""
fi

if [[ -z "${CMK_SERVER_IP}" ]]; then
  prompt_if_needed CMK_SERVER_IP "Checkmk server IP (leave empty for no restriction)" ""
fi

if [[ -z "${CMK_SITE}" ]]; then
  prompt_if_needed CMK_SITE "Checkmk site name" "monitoring"
fi

if [[ -z "${CMK_AGENT_DEB_URL}" ]]; then
  die "CMK_AGENT_DEB_URL is required"
fi

# -------- Install prerequisites --------
log "Installing prerequisites..."
apt-get update -y
ensure_pkg curl
ensure_pkg wget
ensure_pkg ca-certificates
ensure_pkg dos2unix
ensure_pkg smartmontools

# -------- Install Checkmk agent --------
agent_present=0
command -v check_mk_agent >/dev/null 2>&1 && agent_present=1

if [[ "$agent_present" -eq 1 && "$FORCE_REINSTALL" != "1" ]]; then
  log "Checkmk agent already installed. Skipping installation."
else
  log "Downloading and installing Checkmk agent..."
  TMP_DEB="$(mktemp /tmp/checkmk-agent.XXXXXX.deb)"
  curl -fsSL "${CMK_AGENT_DEB_URL}" -o "${TMP_DEB}"
  if ! dpkg -i "${TMP_DEB}"; then
    apt-get -f install -y
  fi
  rm -f -- "${TMP_DEB}"
  TMP_DEB=""

  if ! command -v check_mk_agent >/dev/null 2>&1; then
    die "Checkmk agent installation failed"
  fi
  log "Checkmk agent installed successfully"
fi

# -------- Configure firewall for agent --------
log "Configuring firewall for Checkmk agent (TCP/6556)..."
ensure_pkg ufw

if ! ufw status | grep -qi "Status: active"; then
  warn "UFW not active. Please configure firewall manually to allow TCP/6556 from Checkmk server."
else
  if [[ -n "${CMK_SERVER_IP}" ]]; then
    ufw allow from "${CMK_SERVER_IP}" to any port 6556 proto tcp
    log "Allowed TCP/6556 from ${CMK_SERVER_IP}"
  else
    ufw allow 6556/tcp
    warn "Allowed TCP/6556 from anywhere. Consider restricting to Checkmk server IP."
  fi
fi

# -------- Install smart plugins --------
if [[ "${INSTALL_SMART_PLUGINS}" == "1" ]]; then
  log "Installing SMART monitoring plugins..."

  # Determine smart_posix URL
  base_url="${CMK_AGENT_DEB_URL%/*}"
  smart_url="${base_url}/plugins/smart_posix"

  smart_dir="/usr/lib/check_mk_agent/plugins/300"
  smart_path="${smart_dir}/smart_posix"

  mkdir -p "$smart_dir"

  if [[ -x "$smart_path" ]]; then
    log "smart_posix already installed"
  else
    log "Downloading smart_posix plugin..."
    curl -fsSL "$smart_url" -o "$smart_path"
    chmod 0755 "$smart_path"
    dos2unix "$smart_path" >/dev/null 2>&1 || true
    log "smart_posix installed"
  fi
fi

# -------- Install additional plugins (optional) --------
log "Installing additional monitoring plugins..."

# Systemd plugin
systemd_plugin_dir="/usr/lib/check_mk_agent/plugins"
systemd_plugin="${systemd_plugin_dir}/systemd_units"

if [[ ! -x "$systemd_plugin" ]]; then
  cat > "$systemd_plugin" <<'EOF'
#!/bin/bash
# Checkmk plugin for systemd unit status

echo '<<<systemd_units>>>'
systemctl list-units --all --no-pager --no-legend | while read -r unit load active sub description; do
  echo "$unit|$load|$active|$sub|$description"
done
EOF
  chmod 0755 "$systemd_plugin"
  log "systemd_units plugin installed"
fi

# -------- Configure local checks (optional example) --------
local_check_dir="/usr/lib/check_mk_agent/local"
local_check="${local_check_dir}/system_security"

mkdir -p "$local_check_dir"

cat > "$local_check" <<'EOF'
#!/bin/bash
# Local security checks for Checkmk

# Check if root login is disabled
if grep -q "^PermitRootLogin no" /etc/ssh/sshd_config /etc/ssh/sshd_config.d/* 2>/dev/null; then
  echo "0 SSH_RootLogin - Root login disabled"
else
  echo "1 SSH_RootLogin - Root login may be enabled"
fi

# Check password authentication
if grep -q "^PasswordAuthentication no" /etc/ssh/sshd_config /etc/ssh/sshd_config.d/* 2>/dev/null; then
  echo "0 SSH_PasswordAuth - Password authentication disabled"
else
  echo "1 SSH_PasswordAuth - Password authentication may be enabled"
fi

# Check UFW status
if ufw status | grep -q "Status: active"; then
  echo "0 Firewall_UFW - UFW is active"
else
  echo "1 Firewall_UFW - UFW is not active"
fi

# Check unattended upgrades
if systemctl is-active --quiet unattended-upgrades; then
  echo "0 UnattendedUpgrades - Service is active"
else
  echo "1 UnattendedUpgrades - Service is not active"
fi
EOF

chmod 0755 "$local_check"
log "Local security checks installed"

# -------- Test agent --------
log "Testing Checkmk agent..."
if check_mk_agent >/dev/null 2>&1; then
  log "Checkmk agent test passed"
else
  warn "Checkmk agent test failed"
fi

# -------- Summary --------
log "Checkmk setup completed."
echo
echo "==================== CHECKMK SUMMARY ======================"
echo "Log file           : ${LOGFILE}"
echo "Agent installed    : $(command -v check_mk_agent)"
echo "Server IP          : ${CMK_SERVER_IP:-Any}"
echo "Site               : ${CMK_SITE}"
echo "SMART plugins      : $([[ "${INSTALL_SMART_PLUGINS}" == "1" ]] && echo "Installed" || echo "Not installed")"
echo
echo "To register with Checkmk server:"
echo "  cmk-agent-ctl register --server ${CMK_SERVER_IP:-<server_ip>} --site ${CMK_SITE} --hostname $(hostname)"
echo
echo "Quick checks:"
echo "  check_mk_agent | head -20"
echo "  ufw status | grep 6556"
echo "==========================================================="

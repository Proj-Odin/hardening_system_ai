#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

APP_DIR="${APP_DIR:-/opt/litellm-gateway}"
ENV_FILE="${APP_DIR}/.env"
GATEWAY_ENV_FILE="${APP_DIR}/gateway.env"
COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-litellm-gateway}"
LITELLM_HOST_IP="${LITELLM_HOST_IP:-}"
LITELLM_PORT="${LITELLM_PORT:-}"
TRUSTED_CLIENT_CIDR="${TRUSTED_CLIENT_CIDR:-${TRUSTED_CIDR:-}}"
OLLAMA_BRIDGE_API_BASE="${OLLAMA_BRIDGE_API_BASE:-}"
DOCKER_LITELLM_SUBNET="${DOCKER_LITELLM_SUBNET:-}"
OLLAMA_HOST_BIND="${OLLAMA_HOST_BIND:-0.0.0.0:11434}"
ZEROCLAW_HOST_IP="${ZEROCLAW_HOST_IP:-}"
BIND_ADDR="${BIND_ADDR:-}"
LITELLM_IMAGE="${LITELLM_IMAGE:-}"
POSTGRES_IMAGE="${POSTGRES_IMAGE:-}"
LITELLM_READ_ONLY="${LITELLM_READ_ONLY:-}"
INSTALL_OLLAMA=0
COPY_ADMIN_KEY=0
INTERACTIVE=0
REPAIR_DATABASE_URL=0
YES=0

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2
}

warn() {
  printf '[WARN] %s\n' "$*" >&2
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -r "${SCRIPT_DIR}/litellm-sanity-lib.sh" ]; then
  # shellcheck disable=SC1091
  . "${SCRIPT_DIR}/litellm-sanity-lib.sh"
else
  warn "litellm-sanity-lib.sh not found; account sanity checks will be limited."
fi

usage() {
  cat <<'EOF'
Usage: configure-ollama-cloud-bridge.sh [options]

Options:
  --install-ollama                Install Ollama if missing. Explicit opt-in only.
  --copy-admin-key                Emergency/manual: copy admin Ollama key into service user.
  --interactive                   Run interactive Ollama cloud smoke command.
  --litellm-host-ip IP            LAN/Tailscale IP clients should use for LiteLLM.
  --litellm-port PORT             Host LiteLLM port. Default prompt value: 4000.
  --trusted-client-cidr CIDR      CIDR or single-client /32 allowed to reach LiteLLM.
  --ollama-bridge-api-base URL    URL LiteLLM containers use for host Ollama.
  --docker-litellm-subnet CIDR    Docker subnet allowed to reach host Ollama.
  --ollama-host-bind HOST:PORT    Ollama service bind. Default: 0.0.0.0:11434.
  --zeroclaw-host-ip IP           Optional ZeroClaw host IP for saved examples/tests.
  --repair-database-url           Rewrite DATABASE_URL from POSTGRES_PASSWORD if they differ.
  --yes                           Apply firewall/key-copy confirmations non-interactively.
  -h, --help                      Show this help.
EOF
}

die_arg() {
  die "$1 requires a value"
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --install-ollama) INSTALL_OLLAMA=1 ;;
      --copy-admin-key) COPY_ADMIN_KEY=1 ;;
      --interactive) INTERACTIVE=1 ;;
      --yes) YES=1 ;;
      --repair-database-url) REPAIR_DATABASE_URL=1 ;;
      --litellm-host-ip)
        shift
        [ "$#" -gt 0 ] || die_arg "--litellm-host-ip"
        LITELLM_HOST_IP="$1"
        ;;
      --litellm-port|--port)
        shift
        [ "$#" -gt 0 ] || die_arg "--litellm-port"
        LITELLM_PORT="$1"
        ;;
      --trusted-client-cidr|--trusted-cidr)
        shift
        [ "$#" -gt 0 ] || die_arg "--trusted-client-cidr"
        TRUSTED_CLIENT_CIDR="$1"
        ;;
      --ollama-bridge-api-base)
        shift
        [ "$#" -gt 0 ] || die_arg "--ollama-bridge-api-base"
        OLLAMA_BRIDGE_API_BASE="$1"
        ;;
      --docker-litellm-subnet)
        shift
        [ "$#" -gt 0 ] || die_arg "--docker-litellm-subnet"
        DOCKER_LITELLM_SUBNET="$1"
        ;;
      --ollama-host-bind)
        shift
        [ "$#" -gt 0 ] || die_arg "--ollama-host-bind"
        OLLAMA_HOST_BIND="$1"
        ;;
      --zeroclaw-host-ip)
        shift
        [ "$#" -gt 0 ] || die_arg "--zeroclaw-host-ip"
        ZEROCLAW_HOST_IP="$1"
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "Unknown option: $1"
        ;;
    esac
    shift
  done
}

require_root() {
  [ "${EUID}" -eq 0 ] || die "Run as root."
}

get_file_value() {
  local file="$1"
  local key="$2"
  local value
  [ -f "$file" ] || return 0
  value="$(awk -F= -v key="$key" '
    /^[[:space:]]*#/ || $0 !~ /=/ { next }
    {
      k=$1
      sub(/^[[:space:]]+/, "", k)
      sub(/[[:space:]]+$/, "", k)
      if (k == key) {
        sub(/^[^=]*=/, "")
        print
        exit
      }
    }
  ' "$file")"
  value="${value%$'\r'}"
  case "$value" in
    \"*\") value="${value#\"}"; value="${value%\"}" ;;
    \'*\') value="${value#\'}"; value="${value%\'}" ;;
  esac
  printf '%s\n' "$value"
}

load_gateway_env() {
  local saved
  saved="$(get_file_value "$GATEWAY_ENV_FILE" COMPOSE_PROJECT_NAME)"
  [ -z "$saved" ] || COMPOSE_PROJECT_NAME="$saved"
  saved="$(get_file_value "$GATEWAY_ENV_FILE" LITELLM_HOST_IP)"
  [ -n "$LITELLM_HOST_IP" ] || LITELLM_HOST_IP="$saved"
  saved="$(get_file_value "$GATEWAY_ENV_FILE" LITELLM_PORT)"
  [ -n "$LITELLM_PORT" ] || LITELLM_PORT="$saved"
  saved="$(get_file_value "$GATEWAY_ENV_FILE" TRUSTED_CLIENT_CIDR)"
  [ -n "$TRUSTED_CLIENT_CIDR" ] || TRUSTED_CLIENT_CIDR="$saved"
  saved="$(get_file_value "$GATEWAY_ENV_FILE" OLLAMA_BRIDGE_API_BASE)"
  [ -n "$OLLAMA_BRIDGE_API_BASE" ] || OLLAMA_BRIDGE_API_BASE="$saved"
  saved="$(get_file_value "$GATEWAY_ENV_FILE" DOCKER_LITELLM_SUBNET)"
  [ -n "$DOCKER_LITELLM_SUBNET" ] || DOCKER_LITELLM_SUBNET="$saved"
  saved="$(get_file_value "$GATEWAY_ENV_FILE" OLLAMA_HOST_BIND)"
  [ -z "$saved" ] || OLLAMA_HOST_BIND="$saved"
  saved="$(get_file_value "$GATEWAY_ENV_FILE" ZEROCLAW_HOST_IP)"
  [ -n "$ZEROCLAW_HOST_IP" ] || ZEROCLAW_HOST_IP="$saved"
  saved="$(get_file_value "$GATEWAY_ENV_FILE" BIND_ADDR)"
  [ -n "$BIND_ADDR" ] || BIND_ADDR="$saved"
  saved="$(get_file_value "$GATEWAY_ENV_FILE" LITELLM_IMAGE)"
  [ -n "$LITELLM_IMAGE" ] || LITELLM_IMAGE="$saved"
  saved="$(get_file_value "$GATEWAY_ENV_FILE" POSTGRES_IMAGE)"
  [ -n "$POSTGRES_IMAGE" ] || POSTGRES_IMAGE="$saved"
  saved="$(get_file_value "$GATEWAY_ENV_FILE" LITELLM_READ_ONLY)"
  [ -n "$LITELLM_READ_ONLY" ] || LITELLM_READ_ONLY="$saved"
}

detect_primary_ip() {
  hostname -I 2>/dev/null | awk '{print $1}' || true
}

docker_network_name() {
  printf '%s_litellm_internal\n' "$COMPOSE_PROJECT_NAME"
}

detect_docker_gateway() {
  command -v docker >/dev/null 2>&1 || return 0
  docker network inspect "$(docker_network_name)" --format '{{(index .IPAM.Config 0).Gateway}}' 2>/dev/null || true
}

detect_docker_subnet() {
  command -v docker >/dev/null 2>&1 || return 0
  docker network inspect "$(docker_network_name)" --format '{{(index .IPAM.Config 0).Subnet}}' 2>/dev/null || true
}

prompt_value() {
  local var_name="$1"
  local prompt="$2"
  local default="${3:-}"
  local required="${4:-required}"
  local current="${!var_name:-}"
  local entered

  if [ -n "$current" ]; then
    return 0
  fi

  if [ "$YES" -eq 1 ]; then
    entered="$default"
  elif [ -t 0 ]; then
    if [ -n "$default" ]; then
      read -r -p "${prompt} [${default}]: " entered
      entered="${entered:-$default}"
    else
      read -r -p "${prompt}: " entered
    fi
  else
    entered="$default"
  fi

  if [ -z "$entered" ] && [ "$required" = "required" ]; then
    die "Missing required value for ${var_name}. Pass the matching flag or set it in ${GATEWAY_ENV_FILE}."
  fi
  printf -v "$var_name" '%s' "$entered"
}

confirm() {
  local prompt="$1"
  local answer
  if [ "$YES" -eq 1 ]; then
    return 0
  fi
  [ -t 0 ] || die "Confirmation required. Rerun with --yes after reviewing the action: ${prompt}"
  read -r -p "${prompt} [y/N]: " answer
  case "$answer" in
    y|Y|yes|YES) ;;
    *) die "User declined." ;;
  esac
}

collect_network_settings() {
  local detected_gateway
  local detected_subnet
  prompt_value LITELLM_HOST_IP "Enter LiteLLM gateway LAN/Tailscale IP clients should use" "$(detect_primary_ip)" optional
  prompt_value LITELLM_PORT "Enter LiteLLM host port clients should use" "4000" optional

  detected_gateway="$(detect_docker_gateway)"
  if [ -z "$OLLAMA_BRIDGE_API_BASE" ] && [ -n "$detected_gateway" ]; then
    OLLAMA_BRIDGE_API_BASE="http://${detected_gateway}:11434"
  fi
  prompt_value OLLAMA_BRIDGE_API_BASE "Enter Ollama bridge API base reachable from the LiteLLM container" "$OLLAMA_BRIDGE_API_BASE" required

  detected_subnet="$(detect_docker_subnet)"
  if [ -z "$DOCKER_LITELLM_SUBNET" ] && [ -n "$detected_subnet" ]; then
    DOCKER_LITELLM_SUBNET="$detected_subnet"
  fi
  prompt_value DOCKER_LITELLM_SUBNET "Enter Docker subnet allowed to reach the host Ollama daemon" "$DOCKER_LITELLM_SUBNET" required

  prompt_value TRUSTED_CLIENT_CIDR "Enter trusted client CIDR allowed to access LiteLLM port ${LITELLM_PORT:-4000}" "" optional
  prompt_value ZEROCLAW_HOST_IP "Enter ZeroClaw host IP or leave blank to skip ZeroClaw-specific tests" "" optional
}

save_gateway_env() {
  install -d -m 0750 "$APP_DIR"
  cat > "$GATEWAY_ENV_FILE" <<EOF
# Managed by LiteLLM gateway helper scripts.
# Non-secret deployment-specific network and image settings.
LITELLM_HOST_IP=${LITELLM_HOST_IP}
LITELLM_PORT=${LITELLM_PORT}
TRUSTED_CLIENT_CIDR=${TRUSTED_CLIENT_CIDR}
OLLAMA_BRIDGE_API_BASE=${OLLAMA_BRIDGE_API_BASE}
DOCKER_LITELLM_SUBNET=${DOCKER_LITELLM_SUBNET}
OLLAMA_HOST_BIND=${OLLAMA_HOST_BIND}
ZEROCLAW_HOST_IP=${ZEROCLAW_HOST_IP}
BIND_ADDR=${BIND_ADDR}
COMPOSE_PROJECT_NAME=${COMPOSE_PROJECT_NAME}
LITELLM_IMAGE=${LITELLM_IMAGE}
POSTGRES_IMAGE=${POSTGRES_IMAGE}
LITELLM_READ_ONLY=${LITELLM_READ_ONLY}
EOF
  chmod 0640 "$GATEWAY_ENV_FILE"
  log "Saved non-secret bridge settings to ${GATEWAY_ENV_FILE}"
}

install_ollama_if_requested() {
  if command -v ollama >/dev/null 2>&1; then
    return
  fi
  [ "$INSTALL_OLLAMA" -eq 1 ] || die "ollama is not installed. Rerun with --install-ollama only if you accept installing Ollama on this host."
  log "Installing Ollama because --install-ollama was passed"
  curl -fsSL https://ollama.com/install.sh -o /tmp/ollama-install.sh
  sh /tmp/ollama-install.sh
  command -v ollama >/dev/null 2>&1 || die "Ollama install did not provide an ollama command."
}

show_ollama_identity() {
  local passwd_entry
  local service_home
  local public_key

  log "Ollama version:"
  ollama --version || true

  passwd_entry="$(getent passwd ollama || true)"
  [ -n "$passwd_entry" ] || die "Ollama service user 'ollama' was not found."
  service_home="$(printf '%s' "$passwd_entry" | awk -F: '{print $6}')"
  public_key="${service_home}/.ollama/id_ed25519.pub"

  printf '\nOllama service account:\n  %s\n' "$passwd_entry"
  printf 'Ollama service home:\n  %s\n' "$service_home"
  printf 'Expected service public key:\n  %s\n' "$public_key"

  if [ -r "$public_key" ]; then
    printf '\nAdd this public key at https://ollama.com/settings/keys:\n\n'
    sed 's/^/  /' "$public_key"
    printf '\n'
  else
    warn "Public key is not readable yet. Start/restart Ollama, then check ${public_key}."
  fi
}

copy_admin_key_if_requested() {
  local admin_user
  local admin_home
  local service_home
  [ "$COPY_ADMIN_KEY" -eq 1 ] || return 0

  cat >&2 <<'EOF'

**********************************************************************
EMERGENCY KEY COPY WARNING

Copying an admin user's Ollama private key into the system service account
expands the blast radius of that private key. Prefer adding the service user's
own public key to ollama.com/settings/keys instead.
**********************************************************************
EOF
  confirm "Copy the admin Ollama private key into the ollama service account anyway?"

  admin_user="${SUDO_USER:-root}"
  if [ "$admin_user" = "root" ]; then
    admin_home="/root"
  else
    admin_home="$(getent passwd "$admin_user" | awk -F: '{print $6}')"
  fi
  service_home="$(getent passwd ollama | awk -F: '{print $6}')"
  [ -r "${admin_home}/.ollama/id_ed25519" ] || die "Admin private key not found: ${admin_home}/.ollama/id_ed25519"
  install -d -m 0700 -o ollama -g ollama "${service_home}/.ollama"
  install -m 0600 -o ollama -g ollama "${admin_home}/.ollama/id_ed25519" "${service_home}/.ollama/id_ed25519"
  if [ -r "${admin_home}/.ollama/id_ed25519.pub" ]; then
    install -m 0644 -o ollama -g ollama "${admin_home}/.ollama/id_ed25519.pub" "${service_home}/.ollama/id_ed25519.pub"
  fi
}

write_systemd_override() {
  local override_dir="/etc/systemd/system/ollama.service.d"
  local override_file="${override_dir}/override.conf"
  install -d -m 0755 "$override_dir"
  cat > "$override_file" <<EOF
[Service]
Environment="OLLAMA_HOST=${OLLAMA_HOST_BIND}"
EOF
  log "Wrote ${override_file}"
  systemctl daemon-reload
  systemctl restart ollama
}

verify_ollama_listen() {
  log "Checking Ollama listener on 11434"
  if ss -lntp | grep 11434; then
    log "Ollama is listening. Expected bind should be restricted by firewall rules, not public exposure."
  else
    die "Ollama is not listening on port 11434 after restart."
  fi
}

configure_ufw_for_docker_subnet() {
  command -v ufw >/dev/null 2>&1 || {
    warn "ufw is not installed; manually restrict port 11434 to ${DOCKER_LITELLM_SUBNET}."
    return 0
  }
  confirm "Allow only Docker subnet ${DOCKER_LITELLM_SUBNET} to reach host Ollama on TCP 11434 with UFW?"
  ufw allow from "$DOCKER_LITELLM_SUBNET" to any port 11434 proto tcp comment "Ollama bridge from LiteLLM Docker subnet"
  ufw status verbose
}

main() {
  parse_args "$@"
  require_root
  load_gateway_env
  collect_network_settings
  if declare -F sanity_host_banner >/dev/null 2>&1; then
    sanity_host_banner "LiteLLM gateway/Ollama bridge host" "$APP_DIR" "${APP_DIR}/docker-compose.yml"
    sanity_ollama_identity_check
    sanity_env_report "$ENV_FILE"
    sanity_database_url_password_check "$ENV_FILE" "$REPAIR_DATABASE_URL"
    sanity_docker_service_check
    sanity_compose_running_check "$APP_DIR" "$COMPOSE_PROJECT_NAME" "${APP_DIR}/docker-compose.yml"
    sanity_firewall_access_check "${LITELLM_PORT:-4000}" "$TRUSTED_CLIENT_CIDR"
    sanity_ollama_api_key_note
    sanity_ollama_account_checklist "$INTERACTIVE"
  fi
  install_ollama_if_requested
  show_ollama_identity
  copy_admin_key_if_requested
  write_systemd_override
  verify_ollama_listen
  configure_ufw_for_docker_subnet
  save_gateway_env

  cat <<EOF

Ollama bridge configuration complete.

LiteLLM should use:
  OLLAMA_BRIDGE_API_BASE=${OLLAMA_BRIDGE_API_BASE}

Before relying on Ollama Cloud, make sure the service public key shown above is
added to:
  https://ollama.com/settings/keys
EOF
}

main "$@"

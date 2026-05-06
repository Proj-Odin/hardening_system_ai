#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

APP_NAME="litellm-gateway"
APP_DIR="${APP_DIR:-/opt/litellm-gateway}"
CONFIG_DIR="${APP_DIR}/config"
BACKUP_DIR="${APP_DIR}/backups"
LOG_DIR="/var/log/litellm-gateway"
ENV_FILE="${APP_DIR}/.env"
GATEWAY_ENV_FILE="${APP_DIR}/gateway.env"
COMPOSE_FILE="${APP_DIR}/docker-compose.yml"
CONFIG_FILE="${CONFIG_DIR}/config.yaml"
EGRESS_ALLOWLIST="${APP_DIR}/egress-allowlist.txt"

DEFAULT_LITELLM_IMAGE="ghcr.io/berriai/litellm-non_root:v1.83.3-stable.patch.2"
PREVIOUS_INVALID_LITELLM_DEFAULT_IMAGE="ghcr.io/berriai/litellm-non_root:v1.83.0-stable"
DEFAULT_POSTGRES_IMAGE="postgres:16-bookworm"
LITELLM_IMAGE="${LITELLM_IMAGE:-$DEFAULT_LITELLM_IMAGE}"
POSTGRES_IMAGE="${POSTGRES_IMAGE:-$DEFAULT_POSTGRES_IMAGE}"
COSIGN_KEY_URL="${COSIGN_KEY_URL:-https://raw.githubusercontent.com/BerriAI/litellm/0112e53046018d726492c814b3644b7d376029d0/cosign.pub}"
COSIGN_VERSION="${COSIGN_VERSION:-3.0.6}"

BIND_ADDR="${BIND_ADDR:-0.0.0.0}"
LITELLM_CONTAINER_PORT="4000"
LITELLM_HOST_IP="${LITELLM_HOST_IP:-}"
LITELLM_PORT="${LITELLM_PORT:-}"
TRUSTED_CLIENT_CIDR="${TRUSTED_CLIENT_CIDR:-${TRUSTED_CIDR:-}}"
OLLAMA_BRIDGE_API_BASE="${OLLAMA_BRIDGE_API_BASE:-}"
DOCKER_LITELLM_SUBNET="${DOCKER_LITELLM_SUBNET:-}"
OLLAMA_HOST_BIND="${OLLAMA_HOST_BIND:-0.0.0.0:11434}"
ZEROCLAW_HOST_IP="${ZEROCLAW_HOST_IP:-}"
LITELLM_READ_ONLY="false"
COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-litellm-gateway}"

FORCE=0
SKIP_COSIGN=0
STRICT_EGRESS=0
YES=0
OPENROUTER_CONFIGURED=0
LOGFILE=""

on_error() {
  local line="$1"
  local cmd="$2"
  echo "ERROR: command failed at line ${line}: ${cmd}" >&2
  if [ -n "$LOGFILE" ]; then
    echo "Review log: $LOGFILE" >&2
  fi
}
trap 'on_error "$LINENO" "$BASH_COMMAND"' ERR

log() {
  local msg="$*"
  if [ -n "$LOGFILE" ]; then
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$msg" | tee -a "$LOGFILE" >&2
  else
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$msg" >&2
  fi
}

warn() {
  printf '[WARN] %s\n' "$*" >&2
  log "WARN: $*"
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  log "ERROR: $*"
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
Usage: setup-litellm-gateway.sh [options]

Options:
  --force                         Allow unsupported OS after warning.
  --skip-cosign                   Lab debugging only; requires typing I_ACCEPT_SUPPLY_CHAIN_RISK.
  --strict-egress                 Generate a stricter egress allowlist and router firewall plan.
  --image IMAGE                   Override LITELLM_IMAGE.
  --bind-addr ADDR                Host bind address for Docker publish. Default: 0.0.0.0.
  --litellm-host-ip IP            LAN/Tailscale IP clients should use for LiteLLM.
  --litellm-port PORT             Host LiteLLM port. Default prompt value: 4000.
  --port PORT                     Legacy alias for --litellm-port.
  --trusted-client-cidr CIDR      CIDR or single-client /32 allowed to reach LiteLLM.
  --trusted-cidr CIDR             Legacy alias for --trusted-client-cidr.
  --ollama-bridge-api-base URL    URL LiteLLM containers use for host Ollama.
  --docker-litellm-subnet CIDR    Docker subnet allowed to reach host Ollama.
  --ollama-host-bind HOST:PORT    Ollama service bind. Default: 0.0.0.0:11434.
  --zeroclaw-host-ip IP           Optional ZeroClaw host IP for saved examples/tests.
  --yes                           Accept detected/default non-secret network values.
  -h, --help                      Show this help.

This installer is Docker-only and refuses LiteLLM "latest", nightly, dev, and
main-latest image tags. It never installs LiteLLM from PyPI.
EOF
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --force) FORCE=1 ;;
      --skip-cosign) SKIP_COSIGN=1 ;;
      --strict-egress) STRICT_EGRESS=1 ;;
      --yes) YES=1 ;;
      --image)
        shift
        [ "$#" -gt 0 ] || die "--image requires a value"
        LITELLM_IMAGE="$1"
        ;;
      --bind-addr)
        shift
        [ "$#" -gt 0 ] || die "--bind-addr requires a value"
        BIND_ADDR="$1"
        ;;
      --litellm-host-ip)
        shift
        [ "$#" -gt 0 ] || die "--litellm-host-ip requires a value"
        LITELLM_HOST_IP="$1"
        ;;
      --litellm-port|--port)
        shift
        [ "$#" -gt 0 ] || die "--litellm-port requires a value"
        LITELLM_PORT="$1"
        ;;
      --trusted-client-cidr|--trusted-cidr)
        shift
        [ "$#" -gt 0 ] || die "--trusted-client-cidr requires a value"
        TRUSTED_CLIENT_CIDR="$1"
        ;;
      --ollama-bridge-api-base)
        shift
        [ "$#" -gt 0 ] || die "--ollama-bridge-api-base requires a value"
        OLLAMA_BRIDGE_API_BASE="$1"
        ;;
      --docker-litellm-subnet)
        shift
        [ "$#" -gt 0 ] || die "--docker-litellm-subnet requires a value"
        DOCKER_LITELLM_SUBNET="$1"
        ;;
      --ollama-host-bind)
        shift
        [ "$#" -gt 0 ] || die "--ollama-host-bind requires a value"
        OLLAMA_HOST_BIND="$1"
        ;;
      --zeroclaw-host-ip)
        shift
        [ "$#" -gt 0 ] || die "--zeroclaw-host-ip requires a value"
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
  [ "${EUID}" -eq 0 ] || die "Run as root. This script writes under /opt, /var/log, UFW, Docker, and systemd."
}

setup_logging() {
  mkdir -p "$LOG_DIR"
  LOGFILE="${LOG_DIR}/setup-$(date +%Y%m%d_%H%M%S).log"
  touch "$LOGFILE"
  chmod 0600 "$LOGFILE"
  log "Starting LiteLLM gateway setup"
}

detect_os() {
  if [ ! -r /etc/os-release ]; then
    [ "$FORCE" -eq 1 ] || die "Cannot detect OS. Use --force only for lab debugging."
    warn "Cannot detect OS; continuing because --force was passed."
    return
  fi

  # shellcheck disable=SC1091
  . /etc/os-release
  case "${ID:-}:${VERSION_ID:-}" in
    debian:12*|debian:13*|ubuntu:24.04*)
      log "Detected supported OS: ${PRETTY_NAME:-$ID}"
      return
      ;;
  esac

  if [ "$FORCE" -eq 1 ]; then
    warn "Unsupported OS '${PRETTY_NAME:-${ID:-unknown}}'; continuing because --force was passed."
  else
    die "Unsupported OS '${PRETTY_NAME:-${ID:-unknown}}'. Target Debian 12/13 or Ubuntu 24.04, or pass --force."
  fi
}

image_tag() {
  local ref="$1"
  ref="${ref%@*}"
  if [ "${ref##*/}" != "${ref##*:}" ]; then
    printf '%s\n' "${ref##*:}"
  else
    printf '%s\n' ""
  fi
}

image_repo() {
  local ref="$1"
  ref="${ref%@*}"
  if [ "${ref##*/}" != "${ref##*:}" ]; then
    printf '%s\n' "${ref%:*}"
  else
    printf '%s\n' "$ref"
  fi
}

ensure_litellm_ghcr_image() {
  local ref="$1"
  local repo
  repo="$(image_repo "$ref")"
  case "$repo" in
    ghcr.io/berriai/litellm|ghcr.io/berriai/litellm-non_root|ghcr.io/berriai/litellm-database)
      ;;
    *)
      die "Refusing LiteLLM image outside signed BerriAI GHCR repos: $ref"
      ;;
  esac
}

refuse_bad_image_tag() {
  local ref="$1"
  local tag
  local lower
  if [[ "$ref" == *@sha256:* ]]; then
    return 0
  fi
  tag="$(image_tag "$ref")"
  [ -n "$tag" ] || die "Image reference must include an explicit tag or digest: $ref"
  lower="$(printf '%s' "$tag" | tr '[:upper:]' '[:lower:]')"
  case "$lower" in
    *latest*|*main-latest*|*nightly*|*dev*)
      die "Refusing unsafe image tag '$tag' in '$ref'. Use a signed stable tag, never latest/nightly/dev."
      ;;
  esac
}

check_no_host_pypi_litellm() {
  local pip_cmd
  for pip_cmd in "python3 -m pip" "python -m pip" "pip3" "pip"; do
    if $pip_cmd show litellm >/dev/null 2>&1; then
      die "Host PyPI package 'litellm' is installed. This gateway is Docker-only. Remove/triage host PyPI LiteLLM before setup."
    fi
  done
}

apt_install_base() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y ca-certificates curl gnupg jq openssl ufw iptables
}

install_docker_official_repo() {
  local os_id
  local codename
  local arch

  # shellcheck disable=SC1091
  . /etc/os-release
  os_id="${ID:-debian}"
  codename="${VERSION_CODENAME:-}"
  arch="$(dpkg --print-architecture)"
  [ -n "$codename" ] || die "Unable to determine Debian/Ubuntu codename for Docker repository."

  log "Configuring Docker official apt repository idempotently"
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL "https://download.docker.com/linux/${os_id}/gpg" -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  cat > /etc/apt/sources.list.d/docker.list <<EOF
deb [arch=${arch} signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${os_id} ${codename} stable
EOF
  apt-get update
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
}

install_docker() {
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    log "Docker and compose plugin already installed"
    return
  fi

  log "Installing Docker from distro packages where available"
  if ! apt-get install -y docker.io docker-compose-plugin; then
    warn "Distro Docker packages were not sufficient; falling back to Docker official repository."
    install_docker_official_repo
  fi

  command -v docker >/dev/null 2>&1 || die "Docker install failed."
  docker compose version >/dev/null 2>&1 || die "Docker compose plugin install failed."
}

version_ge() {
  local actual="$1"
  local minimum="$2"
  [ "$(printf '%s\n%s\n' "$minimum" "$actual" | sort -V | head -n1)" = "$minimum" ]
}

cosign_semver() {
  cosign version 2>/dev/null | grep -Eo 'v?[0-9]+\.[0-9]+\.[0-9]+' | head -n1 | sed 's/^v//' || true
}

cosign_version_ok() {
  local version
  version="$(cosign_semver)"
  case "$version" in
    2.*) version_ge "$version" "2.6.3" ;;
    3.*) version_ge "$version" "3.0.6" ;;
    *) return 1 ;;
  esac
}

install_cosign() {
  local arch
  local deb
  local url

  if command -v cosign >/dev/null 2>&1; then
    if cosign_version_ok; then
      log "cosign already installed: $(cosign_semver)"
      return
    fi
    warn "Installed cosign is older than the desired security floor; installing pinned v${COSIGN_VERSION}."
  fi

  if apt-cache show cosign >/dev/null 2>&1; then
    log "Installing cosign from distro repository"
    apt-get install -y cosign
    if cosign_version_ok; then
      return
    fi
    warn "Distro cosign is older than the desired security floor; installing pinned v${COSIGN_VERSION}."
  fi

  arch="$(dpkg --print-architecture)"
  case "$arch" in
    amd64|arm64) ;;
    *) die "No automatic cosign .deb install mapping for architecture '$arch'. Install cosign manually and rerun." ;;
  esac

  deb="/tmp/cosign_${COSIGN_VERSION}_${arch}.deb"
  url="https://github.com/sigstore/cosign/releases/download/v${COSIGN_VERSION}/cosign_${COSIGN_VERSION}_${arch}.deb"
  log "Installing cosign from pinned Sigstore release package: v${COSIGN_VERSION}"
  curl -fsSL "$url" -o "$deb"
  dpkg -i "$deb" || apt-get install -f -y
  command -v cosign >/dev/null 2>&1 || die "cosign install failed."
  cosign_version_ok || die "Installed cosign version is still below the required security floor."
}

enable_docker() {
  systemctl enable --now docker
  docker info >/dev/null
}

prepare_host() {
  log "Installing host dependencies"
  apt_install_base
  install_docker
  install_cosign
  enable_docker
}

ensure_layout() {
  log "Creating gateway directories"
  if ! getent group litellm-gateway >/dev/null 2>&1; then
    groupadd --system litellm-gateway
  fi
  if ! id -u litellm-gateway >/dev/null 2>&1; then
    useradd --system --home-dir "$APP_DIR" --shell /usr/sbin/nologin --gid litellm-gateway litellm-gateway
  fi

  install -d -m 0750 -o root -g litellm-gateway "$APP_DIR" "$CONFIG_DIR" "$BACKUP_DIR" "$LOG_DIR"
  chmod 0750 "$APP_DIR" "$CONFIG_DIR" "$BACKUP_DIR"
}

backup_existing_file() {
  local path="$1"
  local stamp
  [ -e "$path" ] || return 0
  stamp="$(date +%Y%m%d_%H%M%S)"
  cp -a "$path" "${path}.bak.${stamp}"
  log "Backed up existing ${path} to ${path}.bak.${stamp}"
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

get_env_value() {
  get_file_value "$ENV_FILE" "$1"
}

get_gateway_value() {
  get_file_value "$GATEWAY_ENV_FILE" "$1"
}

apply_existing_settings() {
  local existing

  existing="$(get_env_value LITELLM_IMAGE)"
  [ -n "$existing" ] || existing="$(get_gateway_value LITELLM_IMAGE)"
  if [ -n "$existing" ] && [ "$LITELLM_IMAGE" = "$DEFAULT_LITELLM_IMAGE" ]; then
    if [ "$existing" = "$PREVIOUS_INVALID_LITELLM_DEFAULT_IMAGE" ]; then
      warn "Replacing previous generated LiteLLM default image tag with ${DEFAULT_LITELLM_IMAGE}."
    else
      LITELLM_IMAGE="$existing"
    fi
  fi

  existing="$(get_env_value POSTGRES_IMAGE)"
  [ -n "$existing" ] || existing="$(get_gateway_value POSTGRES_IMAGE)"
  if [ -n "$existing" ] && [ "$POSTGRES_IMAGE" = "$DEFAULT_POSTGRES_IMAGE" ]; then
    POSTGRES_IMAGE="$existing"
  fi

  existing="$(get_gateway_value COMPOSE_PROJECT_NAME)"
  [ -n "$existing" ] || existing="$(get_env_value COMPOSE_PROJECT_NAME)"
  if [ -n "$existing" ] && [ "$COMPOSE_PROJECT_NAME" = "litellm-gateway" ]; then
    COMPOSE_PROJECT_NAME="$existing"
  fi

  existing="$(get_gateway_value BIND_ADDR)"
  [ -n "$existing" ] || existing="$(get_env_value BIND_ADDR)"
  if [ -n "$existing" ] && [ "$BIND_ADDR" = "0.0.0.0" ]; then
    BIND_ADDR="$existing"
  fi

  existing="$(get_gateway_value LITELLM_HOST_IP)"
  if [ -n "$existing" ] && [ -z "$LITELLM_HOST_IP" ]; then
    LITELLM_HOST_IP="$existing"
  fi

  existing="$(get_gateway_value LITELLM_PORT)"
  [ -n "$existing" ] || existing="$(get_env_value LITELLM_PORT)"
  if [ -n "$existing" ] && [ -z "$LITELLM_PORT" ]; then
    LITELLM_PORT="$existing"
  fi

  existing="$(get_gateway_value TRUSTED_CLIENT_CIDR)"
  [ -n "$existing" ] || existing="$(get_env_value TRUSTED_CLIENT_CIDR)"
  [ -n "$existing" ] || existing="$(get_env_value TRUSTED_CIDR)"
  if [ -n "$existing" ] && [ -z "$TRUSTED_CLIENT_CIDR" ]; then
    TRUSTED_CLIENT_CIDR="$existing"
  fi

  existing="$(get_gateway_value OLLAMA_BRIDGE_API_BASE)"
  if [ -n "$existing" ] && [ -z "$OLLAMA_BRIDGE_API_BASE" ]; then
    OLLAMA_BRIDGE_API_BASE="$existing"
  fi

  existing="$(get_gateway_value DOCKER_LITELLM_SUBNET)"
  if [ -n "$existing" ] && [ -z "$DOCKER_LITELLM_SUBNET" ]; then
    DOCKER_LITELLM_SUBNET="$existing"
  fi

  existing="$(get_gateway_value OLLAMA_HOST_BIND)"
  if [ -n "$existing" ] && [ "$OLLAMA_HOST_BIND" = "0.0.0.0:11434" ]; then
    OLLAMA_HOST_BIND="$existing"
  fi

  existing="$(get_gateway_value ZEROCLAW_HOST_IP)"
  if [ -n "$existing" ] && [ -z "$ZEROCLAW_HOST_IP" ]; then
    ZEROCLAW_HOST_IP="$existing"
  fi
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
    die "Missing required value for ${var_name}. Pass the matching flag or set ${var_name}."
  fi

  printf -v "$var_name" '%s' "$entered"
}

collect_network_settings() {
  local detected_ip
  local detected_gateway
  local detected_subnet

  detected_ip="$(detect_primary_ip)"
  prompt_value LITELLM_HOST_IP "Enter LiteLLM gateway LAN/Tailscale IP clients should use" "$detected_ip" required
  prompt_value LITELLM_PORT "Enter LiteLLM host port clients should use" "4000" required
  prompt_value TRUSTED_CLIENT_CIDR "Enter trusted client CIDR allowed to access LiteLLM port ${LITELLM_PORT}" "" required

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

  prompt_value ZEROCLAW_HOST_IP "Enter ZeroClaw host IP or leave blank to skip ZeroClaw-specific tests" "" optional
}

secret_or_generate() {
  local var_name="$1"
  local prefix="${2:-}"
  local current="${!var_name:-}"
  if [ -z "$current" ]; then
    current="$(get_env_value "$var_name")"
  fi
  if [ -n "$current" ] && [[ "$current" != change-me* ]] && [[ "$current" != REPLACE_* ]]; then
    printf '%s\n' "$current"
    return
  fi
  printf '%s%s\n' "$prefix" "$(openssl rand -hex 32)"
}

prompt_openrouter_key_if_missing() {
  local current="${OPENROUTER_API_KEY:-}"
  local entered
  if [ -z "$current" ]; then
    current="$(get_env_value OPENROUTER_API_KEY)"
  fi
  if [ -n "$current" ] && [[ "$current" != REPLACE_* ]] && [[ "$current" != change-me* ]]; then
    printf '%s\n' "$current"
    return
  fi

  if [ "$YES" -eq 1 ] || [ ! -t 0 ]; then
    printf '%s\n' ""
    return
  fi

  printf 'Enter optional dedicated low-budget OPENROUTER_API_KEY, or leave blank to skip OpenRouter: ' >&2
  IFS= read -r -s entered
  printf '\n' >&2
  printf '%s\n' "$entered"
}

write_secret_env_file() {
  local postgres_password
  local master_key
  local salt_key
  local openrouter_key

  postgres_password="$(secret_or_generate POSTGRES_PASSWORD)"
  master_key="$(secret_or_generate LITELLM_MASTER_KEY "sk-")"
  salt_key="$(secret_or_generate LITELLM_SALT_KEY)"
  openrouter_key="$(prompt_openrouter_key_if_missing)"

  [[ "$master_key" == sk-* ]] || die "LITELLM_MASTER_KEY must start with sk-."
  if [ -n "$openrouter_key" ]; then
    OPENROUTER_CONFIGURED=1
  else
    OPENROUTER_CONFIGURED=0
  fi

  backup_existing_file "$ENV_FILE"
  log "Writing protected secret environment file: $ENV_FILE"
  cat > "$ENV_FILE" <<EOF
# Managed by setup-litellm-gateway.sh.
# Sensitive: provider keys, LiteLLM keys, and database password.
POSTGRES_USER=litellm
POSTGRES_DB=litellm
POSTGRES_PASSWORD=${postgres_password}
DATABASE_URL=postgresql://litellm:${postgres_password}@postgres:5432/litellm
LITELLM_MASTER_KEY=${master_key}
LITELLM_SALT_KEY=${salt_key}
OPENROUTER_API_KEY=${openrouter_key}
EOF
  chown root:litellm-gateway "$ENV_FILE"
  chmod 0600 "$ENV_FILE"
}

write_gateway_env_file() {
  backup_existing_file "$GATEWAY_ENV_FILE"
  log "Writing non-secret gateway network environment file: $GATEWAY_ENV_FILE"
  cat > "$GATEWAY_ENV_FILE" <<EOF
# Managed by setup-litellm-gateway.sh.
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
  chown root:litellm-gateway "$GATEWAY_ENV_FILE"
  chmod 0640 "$GATEWAY_ENV_FILE"
}

confirm_skip_cosign() {
  [ "$SKIP_COSIGN" -eq 1 ] || return 0
  cat >&2 <<'EOF'

**********************************************************************
SUPPLY CHAIN WARNING

You passed --skip-cosign. This disables signature verification before
running the LiteLLM container. Use this only in an isolated lab.
**********************************************************************
EOF
  local answer
  read -r -p "Type I_ACCEPT_SUPPLY_CHAIN_RISK to continue: " answer
  [ "$answer" = "I_ACCEPT_SUPPLY_CHAIN_RISK" ] || die "Refusing to skip cosign verification."
}

cosign_verify_image() {
  local ref="$1"
  if [ "$SKIP_COSIGN" -eq 1 ]; then
    warn "Skipping cosign verification for $ref because --skip-cosign was accepted."
    return
  fi

  log "Verifying LiteLLM image signature with cosign"
  log "cosign verify --key ${COSIGN_KEY_URL} ${ref}"
  cosign verify --key "$COSIGN_KEY_URL" "$ref" >/dev/null
}

pull_and_resolve_digest() {
  local ref="$1"
  local repo
  local digest_ref

  refuse_bad_image_tag "$ref"
  log "Pulling image: $ref"
  docker pull "$ref" >&2
  repo="$(image_repo "$ref")"
  digest_ref="$(docker image inspect "$ref" --format '{{json .RepoDigests}}' | jq -r --arg repo "$repo" '.[] | select(startswith($repo + "@sha256:"))' | head -n1)"
  [ -n "$digest_ref" ] || die "Unable to resolve immutable digest for $ref"
  printf '%s\n' "$digest_ref"
}

write_litellm_config() {
  backup_existing_file "$CONFIG_FILE"
  log "Writing LiteLLM config with selected Ollama bridge base: $CONFIG_FILE"
  cat > "$CONFIG_FILE" <<EOF
model_list:
  - model_name: ollama-gpt-oss-cloud
    litellm_params:
      model: ollama/gpt-oss:120b-cloud
      api_base: "${OLLAMA_BRIDGE_API_BASE}"

  - model_name: ollama-kimi-k26-cloud
    litellm_params:
      model: ollama/kimi-k2.6:cloud
      api_base: "${OLLAMA_BRIDGE_API_BASE}"

  - model_name: ollama-glm-51-cloud
    litellm_params:
      model: ollama/glm-5.1:cloud
      api_base: "${OLLAMA_BRIDGE_API_BASE}"

  - model_name: ollama-deepseek-v4-pro-cloud
    litellm_params:
      model: ollama/deepseek-v4-pro:cloud
      api_base: "${OLLAMA_BRIDGE_API_BASE}"

  - model_name: ollama-gemma4-31b-cloud
    litellm_params:
      model: ollama/gemma4:31b-cloud
      api_base: "${OLLAMA_BRIDGE_API_BASE}"

  - model_name: ollama-nemotron-3-super-cloud
    litellm_params:
      model: ollama/nemotron-3-super:cloud
      api_base: "${OLLAMA_BRIDGE_API_BASE}"

  - model_name: embed-nomic
    litellm_params:
      model: ollama/nomic-embed-text
      api_base: "${OLLAMA_BRIDGE_API_BASE}"
    model_info:
      mode: embedding

  - model_name: embed-embeddinggemma
    litellm_params:
      model: ollama/embeddinggemma
      api_base: "${OLLAMA_BRIDGE_API_BASE}"
    model_info:
      mode: embedding

  - model_name: embed-qwen3
    litellm_params:
      model: ollama/qwen3-embedding
      api_base: "${OLLAMA_BRIDGE_API_BASE}"
    model_info:
      mode: embedding
EOF

  if [ "$OPENROUTER_CONFIGURED" -eq 1 ]; then
    cat >> "$CONFIG_FILE" <<'EOF'

  - model_name: openrouter-auto
    litellm_params:
      model: openrouter/openrouter/auto
      api_key: os.environ/OPENROUTER_API_KEY
EOF
  fi

  cat >> "$CONFIG_FILE" <<'EOF'

litellm_settings:
  set_verbose: false
  drop_params: true
  request_timeout: 600
  num_retries: 2
  telemetry: false

general_settings:
  master_key: os.environ/LITELLM_MASTER_KEY
  database_url: os.environ/DATABASE_URL
  store_model_in_db: true
  proxy_batch_write_at: 60
  database_connection_pool_limit: 10
  json_logs: true
  disable_spend_logs: false
  store_prompts_in_spend_logs: false
EOF
  chown root:litellm-gateway "$CONFIG_FILE"
  chmod 0640 "$CONFIG_FILE"
}

validate_config_with_container() {
  local litellm_digest="$1"
  log "Validating config YAML syntax inside LiteLLM image"
  docker run --rm --entrypoint python \
    -v "${CONFIG_FILE}:/config.yaml:ro" \
    "$litellm_digest" \
    -c 'import yaml; yaml.safe_load(open("/config.yaml", "r", encoding="utf-8"))' >/dev/null
}

resolve_image_uid_gid() {
  local image="$1"
  local ids
  local user_spec
  local uid
  local gid

  ids="$(docker run --rm --entrypoint sh "$image" -c 'printf "%s:%s\n" "$(id -u)" "$(id -g)"' 2>/dev/null || true)"
  if [[ "$ids" =~ ^[0-9]+:[0-9]+$ ]]; then
    printf '%s\n' "$ids"
    return
  fi

  user_spec="$(docker image inspect "$image" --format '{{.Config.User}}' 2>/dev/null || true)"
  case "$user_spec" in
    "") printf '0:0\n' ;;
    *:*)
      uid="${user_spec%%:*}"
      gid="${user_spec##*:}"
      if [[ "$uid" =~ ^[0-9]+$ ]] && [[ "$gid" =~ ^[0-9]+$ ]]; then
        printf '%s:%s\n' "$uid" "$gid"
      elif [ "$uid" = "nobody" ] || [ "$gid" = "nobody" ] || [ "$gid" = "nogroup" ]; then
        printf '65534:65534\n'
      else
        warn "Unable to resolve image user '$user_spec'; falling back to root-owned config."
        printf '0:0\n'
      fi
      ;;
    [0-9]*) printf '%s:0\n' "$user_spec" ;;
    nobody) printf '65534:65534\n' ;;
    *)
      warn "Unable to resolve image user '$user_spec'; falling back to root-owned config."
      printf '0:0\n'
      ;;
  esac
}

align_config_permissions_for_image() {
  local image="$1"
  local ids
  ids="$(resolve_image_uid_gid "$image")"
  chown "$ids" "$CONFIG_FILE"
  chmod 0640 "$CONFIG_FILE"
  log "Set config.yaml owner to container UID:GID ${ids} and mode 0640 so the non-root image can read it."
}

write_compose_file() {
  local litellm_digest="$1"
  local postgres_digest="$2"

  backup_existing_file "$COMPOSE_FILE"
  log "Writing digest-pinned compose file: $COMPOSE_FILE"
  cat > "$COMPOSE_FILE" <<EOF
services:
  litellm:
    image: ${litellm_digest}
    restart: unless-stopped
    env_file:
      - .env
      - gateway.env
    command: ["--config", "/app/config.yaml", "--host", "0.0.0.0", "--port", "${LITELLM_CONTAINER_PORT}"]
    ports:
      - "${BIND_ADDR}:${LITELLM_PORT}:${LITELLM_CONTAINER_PORT}"
    depends_on:
      postgres:
        condition: service_healthy
    volumes:
      - type: bind
        source: ${CONFIG_FILE}
        target: /app/config.yaml
        read_only: true
    cap_drop:
      - ALL
    security_opt:
      - no-new-privileges:true
    read_only: false
    tmpfs:
      - /tmp:size=128m,mode=1777
    pids_limit: 256
    mem_limit: 2g
    healthcheck:
      test: ["CMD-SHELL", "python -c \"import urllib.request; urllib.request.urlopen('http://127.0.0.1:${LITELLM_CONTAINER_PORT}/health/liveliness', timeout=5)\""]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 30s
    networks:
      - litellm_internal

  postgres:
    image: ${postgres_digest}
    restart: unless-stopped
    env_file:
      - .env
    environment:
      POSTGRES_USER: "\${POSTGRES_USER}"
      POSTGRES_PASSWORD: "\${POSTGRES_PASSWORD}"
      POSTGRES_DB: "\${POSTGRES_DB}"
    volumes:
      - litellm_postgres_data:/var/lib/postgresql/data
    expose:
      - "5432"
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U \${POSTGRES_USER} -d \${POSTGRES_DB}"]
      interval: 10s
      timeout: 5s
      retries: 10
    networks:
      - litellm_internal

networks:
  litellm_internal:
    driver: bridge

volumes:
  litellm_postgres_data:
EOF
  chown root:litellm-gateway "$COMPOSE_FILE"
  chmod 0640 "$COMPOSE_FILE"
}

detect_ssh_port() {
  local port=""
  if command -v sshd >/dev/null 2>&1; then
    port="$(sshd -T 2>/dev/null | awk '/^port / {print $2; exit}' || true)"
  fi
  if [ -z "$port" ] && [ -f /etc/ssh/sshd_config ]; then
    port="$(awk 'tolower($1)=="port" && $2 ~ /^[0-9]+$/ {print $2; exit}' /etc/ssh/sshd_config || true)"
  fi
  printf '%s\n' "${port:-22}"
}

configure_ufw() {
  local ssh_port
  ssh_port="$(detect_ssh_port)"
  log "Configuring UFW: allow SSH ${ssh_port}/tcp and LiteLLM ${LITELLM_PORT}/tcp from ${TRUSTED_CLIENT_CIDR}"
  ufw default deny incoming >/dev/null || warn "Unable to set UFW default deny incoming."
  ufw default allow outgoing >/dev/null || warn "Unable to set UFW default allow outgoing."
  ufw allow "${ssh_port}/tcp" comment "preserve SSH access" >/dev/null || warn "Unable to add SSH UFW rule."
  ufw allow from "$TRUSTED_CLIENT_CIDR" to any port "$LITELLM_PORT" proto tcp comment "LiteLLM gateway trusted clients" >/dev/null || warn "Unable to add LiteLLM UFW rule."
  ufw --force enable
  ufw status verbose | tee -a "$LOGFILE"
}

write_docker_user_rules() {
  local helper="/usr/local/sbin/litellm-gateway-docker-user-rules"
  local unit="/etc/systemd/system/litellm-gateway-firewall.service"

  log "Installing idempotent DOCKER-USER firewall helper"
cat > "$helper" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
iptables -N DOCKER-USER 2>/dev/null || true
while rule_num=\$(iptables -L DOCKER-USER --line-numbers 2>/dev/null | awk '/litellm-gateway/ {print \$1; exit}'); [ -n "\${rule_num}" ]; do
  iptables -D DOCKER-USER "\${rule_num}"
done
iptables -I DOCKER-USER 1 -p tcp --dport ${LITELLM_CONTAINER_PORT} -s ${TRUSTED_CLIENT_CIDR} -m comment --comment "litellm-gateway allow trusted clients" -j RETURN
iptables -I DOCKER-USER 2 -p tcp --dport ${LITELLM_CONTAINER_PORT} -m comment --comment "litellm-gateway deny untrusted clients" -j DROP
EOF
  chmod 0755 "$helper"

  cat > "$unit" <<EOF
[Unit]
Description=LiteLLM Gateway DOCKER-USER firewall rules
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
ExecStart=${helper}
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now litellm-gateway-firewall.service || warn "Unable to enable DOCKER-USER firewall persistence. Review ${helper}."
}

write_egress_allowlist() {
  log "Writing egress allowlist notes: $EGRESS_ALLOWLIST"
  cat > "$EGRESS_ALLOWLIST" <<'EOF'
# LiteLLM gateway egress allowlist notes.
# Domain-based egress with iptables/nftables is brittle because provider IPs change.
#
# Default mode is monitor/document-only.
#
# Provider/API domains commonly needed:
ollama.com
openrouter.ai
api.openai.com
api.anthropic.com
generativelanguage.googleapis.com

# Local model endpoints should be deployment-specific:
# <OLLAMA_BRIDGE_API_BASE>  # Host Ollama bridge reachable from the LiteLLM container
# <LOCAL_VLLM_URL>          # vLLM OpenAI-compatible API, if used
EOF
  chmod 0640 "$EGRESS_ALLOWLIST"

  if [ "$STRICT_EGRESS" -eq 1 ]; then
    local plan="${APP_DIR}/strict-egress-router-plan.md"
    log "Strict egress requested; generating router firewall plan: $plan"
    cat > "$plan" <<EOF
# LiteLLM Gateway Strict Egress Plan

Generated: $(date -Is)

This file is intentionally a router/firewall plan, not brittle host iptables
rules. Provider domains can resolve to changing CDNs. For a homelab, enforce
fail-closed egress on UniFi/OPNsense/pfSense or upstream firewall where DNS and
address groups can be managed safely.

Recommended policy:
1. Put this VM in a dedicated VLAN or firewall group.
2. Allow DNS only to your resolver.
3. Allow TCP 443 from this VM to provider address groups resolved from:
   - ollama.com
   - openrouter.ai
   - api.openai.com
   - api.anthropic.com
   - generativelanguage.googleapis.com
4. Allow local Ollama/vLLM destinations explicitly.
5. Deny all other outbound internet from this VM.

Refresh cadence: at least daily, and before provider changes.
EOF
    chmod 0640 "$plan"
  fi
}

start_gateway() {
  log "Starting LiteLLM gateway with Docker Compose"
  (cd "$APP_DIR" && docker compose -p "$COMPOSE_PROJECT_NAME" up -d)
}

refresh_detected_docker_network_settings() {
  local detected_gateway
  local detected_subnet
  detected_gateway="$(detect_docker_gateway)"
  detected_subnet="$(detect_docker_subnet)"
  if [ -n "$detected_subnet" ] && [ "$detected_subnet" != "$DOCKER_LITELLM_SUBNET" ]; then
    warn "Docker network subnet is ${detected_subnet}, but gateway.env has ${DOCKER_LITELLM_SUBNET}. Keeping the saved value; update gateway.env if the bridge firewall should use the detected subnet."
  fi
  if [ -n "$detected_gateway" ]; then
    log "Detected Docker network gateway after startup: ${detected_gateway}"
  fi
}

print_next_steps() {
  cat <<EOF

LiteLLM Gateway setup complete.

Client endpoint:
  http://${LITELLM_HOST_IP}:${LITELLM_PORT}/v1

Saved non-secret network settings:
  ${GATEWAY_ENV_FILE}

Next checks:
  sudo ${APP_DIR}/verify-litellm-gateway.sh
  sudo ${APP_DIR}/configure-ollama-cloud-bridge.sh
  sudo ${APP_DIR}/verify-ollama-cloud-bridge.sh
  sudo docker compose -p ${COMPOSE_PROJECT_NAME} -f ${COMPOSE_FILE} ps
  sudo ufw status verbose

Create per-app virtual keys before pointing ZeroClaw/OpenClaw/NemoClaw at this gateway.
EOF
}

copy_helper_scripts() {
  local repo_script_dir
  local helper
  repo_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  for helper in \
    verify-litellm-gateway.sh \
    update-litellm-gateway.sh \
    backup-litellm-gateway.sh \
    configure-ollama-cloud-bridge.sh \
    verify-ollama-cloud-bridge.sh \
    create-litellm-client-key.sh; do
    if [ -f "${repo_script_dir}/${helper}" ]; then
      install -m 0750 -o root -g litellm-gateway "${repo_script_dir}/${helper}" "${APP_DIR}/${helper}"
    fi
  done
}

main() {
  parse_args "$@"
  require_root
  setup_logging
  if declare -F sanity_host_banner >/dev/null 2>&1; then
    sanity_host_banner "LiteLLM setup host" "$APP_DIR" "$COMPOSE_FILE"
    sanity_ollama_identity_check
    sanity_env_report "$ENV_FILE"
    sanity_database_url_password_check "$ENV_FILE" "$REPAIR_DATABASE_URL"
  fi
  detect_os
  apply_existing_settings
  collect_network_settings
  ensure_litellm_ghcr_image "$LITELLM_IMAGE"
  refuse_bad_image_tag "$LITELLM_IMAGE"
  refuse_bad_image_tag "$POSTGRES_IMAGE"
  check_no_host_pypi_litellm
  confirm_skip_cosign
  prepare_host
  ensure_layout
  copy_helper_scripts
  write_secret_env_file
  write_gateway_env_file
  write_litellm_config

  local litellm_digest
  local postgres_digest
  litellm_digest="$(pull_and_resolve_digest "$LITELLM_IMAGE")"
  cosign_verify_image "$LITELLM_IMAGE"
  cosign_verify_image "$litellm_digest"
  postgres_digest="$(pull_and_resolve_digest "$POSTGRES_IMAGE")"

  write_compose_file "$litellm_digest" "$postgres_digest"
  ensure_compose_network_exists
  collect_docker_bridge_settings
  write_gateway_env_file
  write_litellm_config
  align_config_permissions_for_image "$litellm_digest"
  validate_config_with_container "$litellm_digest"
  write_egress_allowlist
  configure_ufw
  write_docker_user_rules
  start_gateway
  refresh_detected_docker_network_settings

  "${APP_DIR}/verify-litellm-gateway.sh" || warn "Verification reported issues. Review output before using the gateway."
  print_next_steps
}

main "$@"

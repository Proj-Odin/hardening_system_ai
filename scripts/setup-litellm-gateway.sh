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
COMPOSE_FILE="${APP_DIR}/docker-compose.yml"
CONFIG_FILE="${CONFIG_DIR}/config.yaml"
EGRESS_ALLOWLIST="${APP_DIR}/egress-allowlist.txt"
DEFAULT_LITELLM_IMAGE="ghcr.io/berriai/litellm-non_root:v1.83.0-stable"
DEFAULT_POSTGRES_IMAGE="postgres:16-bookworm"
LITELLM_IMAGE="${LITELLM_IMAGE:-$DEFAULT_LITELLM_IMAGE}"
POSTGRES_IMAGE="${POSTGRES_IMAGE:-$DEFAULT_POSTGRES_IMAGE}"
COSIGN_KEY_URL="${COSIGN_KEY_URL:-https://raw.githubusercontent.com/BerriAI/litellm/0112e53046018d726492c814b3644b7d376029d0/cosign.pub}"
COSIGN_VERSION="${COSIGN_VERSION:-3.0.6}"
BIND_ADDR="${BIND_ADDR:-0.0.0.0}"
LITELLM_PORT="${LITELLM_PORT:-4000}"
LITELLM_CONTAINER_PORT="4000"
TRUSTED_CIDR="${TRUSTED_CIDR:-}"
LITELLM_READ_ONLY="${LITELLM_READ_ONLY:-true}"
COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-litellm-gateway}"
FORCE=0
SKIP_COSIGN=0
STRICT_EGRESS=0

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

usage() {
  cat <<'EOF'
Usage: setup-litellm-gateway.sh [options]

Options:
  --force                 Allow unsupported OS after warning.
  --skip-cosign           Lab debugging only; requires typing I_ACCEPT_SUPPLY_CHAIN_RISK.
  --strict-egress         Generate a stricter egress allowlist and router firewall plan.
  --image IMAGE           Override LITELLM_IMAGE.
  --bind-addr ADDR        Host bind address. Default: 0.0.0.0.
  --port PORT             Host LiteLLM port. Default: 4000.
  --trusted-cidr CIDR     CIDR allowed to reach LiteLLM. Default prompt: 172.16.172.0/24.
  -h, --help              Show this help.

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
      --port)
        shift
        [ "$#" -gt 0 ] || die "--port requires a value"
        LITELLM_PORT="$1"
        ;;
      --trusted-cidr)
        shift
        [ "$#" -gt 0 ] || die "--trusted-cidr requires a value"
        TRUSTED_CIDR="$1"
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

get_env_value() {
  local key="$1"
  local value
  [ -f "$ENV_FILE" ] || return 0
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
  ' "$ENV_FILE")"
  value="${value%$'\r'}"
  case "$value" in
    \"*\") value="${value#\"}"; value="${value%\"}" ;;
    \'*\') value="${value#\'}"; value="${value%\'}" ;;
  esac
  printf '%s\n' "$value"
}

apply_existing_settings() {
  local existing

  existing="$(get_env_value LITELLM_IMAGE)"
  if [ -n "$existing" ] && [ "$LITELLM_IMAGE" = "$DEFAULT_LITELLM_IMAGE" ]; then
    LITELLM_IMAGE="$existing"
  fi

  existing="$(get_env_value POSTGRES_IMAGE)"
  if [ -n "$existing" ] && [ "$POSTGRES_IMAGE" = "$DEFAULT_POSTGRES_IMAGE" ]; then
    POSTGRES_IMAGE="$existing"
  fi

  existing="$(get_env_value BIND_ADDR)"
  if [ -n "$existing" ] && [ "$BIND_ADDR" = "0.0.0.0" ]; then
    BIND_ADDR="$existing"
  fi

  existing="$(get_env_value LITELLM_PORT)"
  if [ -n "$existing" ] && [ "$LITELLM_PORT" = "4000" ]; then
    LITELLM_PORT="$existing"
  fi

  existing="$(get_env_value TRUSTED_CIDR)"
  if [ -n "$existing" ] && [ -z "$TRUSTED_CIDR" ]; then
    TRUSTED_CIDR="$existing"
  fi

  existing="$(get_env_value LITELLM_READ_ONLY)"
  if [ -n "$existing" ] && [ "$LITELLM_READ_ONLY" = "true" ]; then
    LITELLM_READ_ONLY="$existing"
  fi

  existing="$(get_env_value COMPOSE_PROJECT_NAME)"
  if [ -n "$existing" ] && [ "$COMPOSE_PROJECT_NAME" = "litellm-gateway" ]; then
    COMPOSE_PROJECT_NAME="$existing"
  fi
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
  if [ -z "$current" ]; then
    current="$(get_env_value OPENROUTER_API_KEY)"
  fi
  if [ -n "$current" ] && [[ "$current" != REPLACE_* ]] && [[ "$current" != change-me* ]]; then
    printf '%s\n' "$current"
    return
  fi

  printf 'Enter dedicated low-budget OPENROUTER_API_KEY for this gateway: ' >&2
  local entered
  IFS= read -r -s entered
  printf '\n' >&2
  [ -n "$entered" ] || die "OPENROUTER_API_KEY is required for the default OpenRouter route."
  printf '%s\n' "$entered"
}

write_env_file() {
  local postgres_password
  local master_key
  local salt_key
  local openrouter_key
  local trusted
  local existing_trusted

  existing_trusted="$(get_env_value TRUSTED_CIDR)"
  trusted="${TRUSTED_CIDR:-$existing_trusted}"
  if [ -z "$trusted" ]; then
    read -r -p "Trusted CIDR allowed to reach LiteLLM [172.16.172.0/24]: " trusted
    trusted="${trusted:-172.16.172.0/24}"
  fi
  TRUSTED_CIDR="$trusted"

  postgres_password="$(secret_or_generate POSTGRES_PASSWORD)"
  master_key="$(secret_or_generate LITELLM_MASTER_KEY "sk-")"
  salt_key="$(secret_or_generate LITELLM_SALT_KEY)"
  openrouter_key="$(prompt_openrouter_key_if_missing)"

  [[ "$master_key" == sk-* ]] || die "LITELLM_MASTER_KEY must start with sk-."

  backup_existing_file "$ENV_FILE"
  log "Writing secret environment file: $ENV_FILE"
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
BIND_ADDR=${BIND_ADDR}
LITELLM_PORT=${LITELLM_PORT}
TRUSTED_CIDR=${TRUSTED_CIDR}
LITELLM_IMAGE=${LITELLM_IMAGE}
POSTGRES_IMAGE=${POSTGRES_IMAGE}
LITELLM_READ_ONLY=${LITELLM_READ_ONLY}
COMPOSE_PROJECT_NAME=${COMPOSE_PROJECT_NAME}
EOF
  chown root:litellm-gateway "$ENV_FILE"
  chmod 0600 "$ENV_FILE"
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
  log "Writing LiteLLM config: $CONFIG_FILE"
  cat > "$CONFIG_FILE" <<'EOF'
model_list:
  - model_name: openrouter-auto
    litellm_params:
      model: openrouter/openrouter/auto
      api_key: os.environ/OPENROUTER_API_KEY

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
  local read_only="$LITELLM_READ_ONLY"

  case "$read_only" in
    true|false) ;;
    *) die "LITELLM_READ_ONLY must be true or false." ;;
  esac

  backup_existing_file "$COMPOSE_FILE"
  log "Writing digest-pinned compose file: $COMPOSE_FILE"
  cat > "$COMPOSE_FILE" <<EOF
services:
  litellm:
    image: ${litellm_digest}
    restart: unless-stopped
    env_file:
      - .env
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
    read_only: ${read_only}
    tmpfs:
      - /tmp:size=128m,mode=1777
    pids_limit: 256
    mem_limit: 1g
    healthcheck:
      test: ["CMD-SHELL", "python -c \"import urllib.request; urllib.request.urlopen('http://127.0.0.1:${LITELLM_CONTAINER_PORT}/health', timeout=5)\""]
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
  log "Configuring UFW: allow SSH ${ssh_port}/tcp and LiteLLM ${LITELLM_PORT}/tcp from ${TRUSTED_CIDR}"
  ufw default deny incoming >/dev/null || warn "Unable to set UFW default deny incoming."
  ufw default allow outgoing >/dev/null || warn "Unable to set UFW default allow outgoing."
  ufw allow "${ssh_port}/tcp" comment "preserve SSH access" >/dev/null || warn "Unable to add SSH UFW rule."
  ufw allow from "$TRUSTED_CIDR" to any port "$LITELLM_PORT" proto tcp comment "LiteLLM gateway trusted CIDR" >/dev/null || warn "Unable to add LiteLLM UFW rule."
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
iptables -I DOCKER-USER 1 -p tcp --dport ${LITELLM_CONTAINER_PORT} -s ${TRUSTED_CIDR} -m comment --comment "litellm-gateway allow trusted" -j RETURN
iptables -I DOCKER-USER 2 -p tcp --dport ${LITELLM_CONTAINER_PORT} -m comment --comment "litellm-gateway deny untrusted" -j DROP
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
openrouter.ai
api.openai.com
api.anthropic.com
generativelanguage.googleapis.com

# Future local model endpoints:
# 172.16.172.50:11434  # Ollama
# 172.16.172.60:8000   # vLLM OpenAI-compatible API
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
   - openrouter.ai
   - api.openai.com
   - api.anthropic.com
   - generativelanguage.googleapis.com
4. Allow local Ollama/vLLM IPs explicitly.
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

print_next_steps() {
  local vm_ip
  vm_ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  cat <<EOF

LiteLLM Gateway setup complete.

Endpoint:
  http://${vm_ip:-<vm-ip>}:${LITELLM_PORT}/v1

Next checks:
  sudo ${APP_DIR}/verify-litellm-gateway.sh
  sudo ufw status verbose
  sudo docker compose -p ${COMPOSE_PROJECT_NAME} -f ${COMPOSE_FILE} ps

Create per-app virtual keys before pointing ZeroClaw/OpenClaw/NemoClaw at this gateway.
EOF
}

copy_helper_scripts() {
  local repo_script_dir
  repo_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  install -m 0750 -o root -g litellm-gateway "${repo_script_dir}/verify-litellm-gateway.sh" "${APP_DIR}/verify-litellm-gateway.sh"
  install -m 0750 -o root -g litellm-gateway "${repo_script_dir}/update-litellm-gateway.sh" "${APP_DIR}/update-litellm-gateway.sh"
  install -m 0750 -o root -g litellm-gateway "${repo_script_dir}/backup-litellm-gateway.sh" "${APP_DIR}/backup-litellm-gateway.sh"
}

main() {
  parse_args "$@"
  require_root
  setup_logging
  detect_os
  apply_existing_settings
  ensure_litellm_ghcr_image "$LITELLM_IMAGE"
  refuse_bad_image_tag "$LITELLM_IMAGE"
  refuse_bad_image_tag "$POSTGRES_IMAGE"
  check_no_host_pypi_litellm
  confirm_skip_cosign
  prepare_host
  ensure_layout
  copy_helper_scripts
  write_env_file
  write_litellm_config

  local litellm_digest
  local postgres_digest
  litellm_digest="$(pull_and_resolve_digest "$LITELLM_IMAGE")"
  cosign_verify_image "$LITELLM_IMAGE"
  cosign_verify_image "$litellm_digest"
  align_config_permissions_for_image "$litellm_digest"
  postgres_digest="$(pull_and_resolve_digest "$POSTGRES_IMAGE")"

  validate_config_with_container "$litellm_digest"
  write_compose_file "$litellm_digest" "$postgres_digest"
  write_egress_allowlist
  configure_ufw
  write_docker_user_rules
  start_gateway

  "${APP_DIR}/verify-litellm-gateway.sh" || warn "Verification reported issues. Review output before using the gateway."
  print_next_steps
}

main "$@"

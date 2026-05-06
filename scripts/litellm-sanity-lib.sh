#!/usr/bin/env bash

sanity_warn() {
  if declare -F warn_check >/dev/null 2>&1; then
    warn_check "$*"
  elif declare -F warn >/dev/null 2>&1; then
    warn "$*"
  else
    printf '[WARN] %s\n' "$*" >&2
  fi
}

sanity_fail() {
  if declare -F fail_check >/dev/null 2>&1; then
    fail_check "$*"
  elif declare -F die >/dev/null 2>&1; then
    die "$*"
  else
    printf '[FAIL] %s\n' "$*" >&2
    return 1
  fi
}

sanity_note() {
  printf '%s\n' "$*"
}

sanity_file_value() {
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

gateway_env_key_allowed() {
  case "$1" in
    LITELLM_HOST_IP|LITELLM_PORT|TRUSTED_CLIENT_CIDR|OLLAMA_BRIDGE_API_BASE|DOCKER_LITELLM_SUBNET|OLLAMA_HOST_BIND|ZEROCLAW_HOST_IP)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

gateway_env_value_safe() {
  local value="$1"
  [ -z "$value" ] && return 0
  if printf '%s' "$value" | grep -Eq '[;&|`$()<>]'; then
    return 1
  fi
  if printf '%s' "$value" | grep -Eq '[[:cntrl:]]'; then
    return 1
  fi
  return 0
}

read_gateway_env_value() {
  local file="$1"
  local key="$2"
  local value

  [[ "$key" =~ ^[A-Z_][A-Z0-9_]*$ ]] || {
    sanity_warn "Rejected invalid gateway.env key name: ${key}"
    return 1
  }
  gateway_env_key_allowed "$key" || {
    sanity_warn "Ignoring unsupported gateway.env key request: ${key}"
    return 1
  }

  value="$(sanity_file_value "$file" "$key")"
  if ! gateway_env_value_safe "$value"; then
    sanity_warn "Rejected unsafe value for ${key} in ${file}; refusing to use it."
    return 1
  fi
  printf '%s\n' "$value"
}

load_gateway_env_safe() {
  local file="$1"
  local line
  local key
  local value
  [ -f "$file" ] || return 0

  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    case "$line" in
      ""|\#*) continue ;;
      *=*) ;;
      *)
        sanity_warn "Ignoring malformed gateway.env line without KEY=VALUE."
        continue
        ;;
    esac
    key="${line%%=*}"
    value="${line#*=}"
    key="${key#"${key%%[![:space:]]*}"}"
    key="${key%"${key##*[![:space:]]}"}"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    case "$value" in
      \"*\") value="${value#\"}"; value="${value%\"}" ;;
      \'*\') value="${value#\'}"; value="${value%\'}" ;;
    esac
    [[ "$key" =~ ^[A-Z_][A-Z0-9_]*$ ]] || {
      sanity_warn "Rejected invalid gateway.env key name: ${key:-<empty>}"
      continue
    }
    gateway_env_key_allowed "$key" || {
      sanity_warn "Ignoring unsupported gateway.env key: ${key}"
      continue
    }
    if ! gateway_env_value_safe "$value"; then
      sanity_warn "Rejected unsafe value for ${key} in ${file}; refusing to use it."
      continue
    fi
    printf -v "$key" '%s' "$value"
  done < "$file"
}

sanity_os_name() {
  if [ -r /etc/os-release ]; then
    (
      # shellcheck disable=SC1091
      . /etc/os-release
      printf '%s\n' "${PRETTY_NAME:-${ID:-unknown}}"
    )
  elif [ -r /etc/alpine-release ]; then
    printf 'Alpine Linux %s\n' "$(cat /etc/alpine-release)"
  else
    uname -s
  fi
}

sanity_detect_role() {
  local app_dir="${1:-/opt/litellm-gateway}"
  local compose_file="${2:-${app_dir}/docker-compose.yml}"
  local roles=""

  [ -f "$compose_file" ] && roles="${roles}LiteLLM gateway installed, "
  [ -d /home/zeroclaw/.zeroclaw ] && roles="${roles}ZeroClaw host, "
  [ -r /etc/alpine-release ] && roles="${roles}Alpine, "
  command -v apt >/dev/null 2>&1 && roles="${roles}Debian/Ubuntu-like, "
  command -v docker >/dev/null 2>&1 && roles="${roles}Docker host, "

  roles="${roles%, }"
  printf '%s\n' "${roles:-unknown}"
}

sanity_host_banner() {
  local expected_role="$1"
  local app_dir="${2:-/opt/litellm-gateway}"
  local compose_file="${3:-${app_dir}/docker-compose.yml}"
  local roles
  local os_name

  roles="$(sanity_detect_role "$app_dir" "$compose_file")"
  os_name="$(sanity_os_name)"

  printf '\nAccount and credential sanity checks\n'
  printf 'You are running this on: %s (%s)\n' "$(hostname 2>/dev/null || printf unknown)" "$os_name"
  printf 'Detected role: %s\n' "$roles"
  printf 'Expected role for this script: %s\n' "$expected_role"
  printf 'whoami: %s\n' "$(whoami 2>/dev/null || printf unknown)"
  printf 'id: %s\n' "$(id 2>/dev/null || printf unknown)"
  printf 'hostname: %s\n' "$(hostname 2>/dev/null || printf unknown)"
  printf '\nLinux identity reminder:\n'
  printf '  admin/root installs packages and manages services.\n'
  printf '  zeroclaw user runs ZeroClaw.\n'
  printf '  ollama service user runs the Ollama daemon.\n'
  printf '  LiteLLM container runs as non-root/nobody.\n'

  if command -v ps >/dev/null 2>&1; then
    printf '\nOllama processes:\n'
    ps -eo user,pid,cmd | grep '[o]llama' || true
  fi
  printf '\nOllama service account:\n'
  getent passwd ollama || true

  if ps -eo user,cmd 2>/dev/null | awk '$1 == "ollama" { found=1 } END { exit found ? 0 : 1 }'; then
    sanity_warn "Signing in as your admin user does not automatically authenticate the ollama service user."
  fi

  case "$expected_role" in
    *"LiteLLM setup"*)
      if { [ -r /etc/alpine-release ] || [ -d /home/zeroclaw/.zeroclaw ]; } && [ "${FORCE:-0}" -ne 1 ]; then
        sanity_fail "This looks like Alpine and/or a ZeroClaw host. LiteLLM setup is expected on the Debian/Ubuntu LiteLLM gateway. Rerun with --force only if this is intentional."
      fi
      ;;
    *"ZeroClaw"*)
      if [ -f "$compose_file" ]; then
        sanity_warn "This looks like the LiteLLM gateway. ZeroClaw integration commands usually run from the ZeroClaw/client host."
      fi
      ;;
  esac
}

sanity_user_home() {
  local user_name="${1:-}"
  if [ -n "$user_name" ] && getent passwd "$user_name" >/dev/null 2>&1; then
    getent passwd "$user_name" | awk -F: '{print $6}'
  else
    printf '%s\n' "${HOME:-}"
  fi
}

sanity_ollama_identity_check() {
  local admin_user="${SUDO_USER:-$(whoami 2>/dev/null || true)}"
  local admin_home
  local service_home
  local current_pub
  local service_pub
  local current_fp=""
  local service_fp=""

  admin_home="$(sanity_user_home "$admin_user")"
  current_pub="${admin_home}/.ollama/id_ed25519.pub"
  service_home="$(getent passwd ollama 2>/dev/null | awk -F: '{print $6}' || true)"
  service_pub="${service_home:-/usr/share/ollama}/.ollama/id_ed25519.pub"

  printf '\nOllama CLI vs daemon identity check:\n'
  if [ -r "$current_pub" ]; then
    current_fp="$(ssh-keygen -lf "$current_pub" 2>/dev/null | awk '{print $2}' || true)"
    printf '  Current user Ollama key fingerprint: %s\n' "${current_fp:-unreadable}"
  else
    printf '  Current user Ollama key fingerprint: MISSING (%s)\n' "$current_pub"
  fi

  if [ -r "$service_pub" ]; then
    service_fp="$(ssh-keygen -lf "$service_pub" 2>/dev/null | awk '{print $2}' || true)"
    printf '  Service user Ollama key fingerprint: %s\n' "${service_fp:-unreadable}"
  else
    printf '  Service user Ollama key fingerprint: MISSING (%s)\n' "$service_pub"
  fi

  if [ -n "$current_fp" ] && [ -n "$service_fp" ] && [ "$current_fp" != "$service_fp" ]; then
    sanity_warn "These are different Ollama identities. The CLI may work while the local API daemon returns unauthorized for cloud models."
  fi
}

sanity_secret_value() {
  local name="$1"
  local value="$2"
  local prefix="<redacted>"
  if [ -z "$value" ]; then
    printf '  %s=MISSING\n' "$name"
    return
  fi
  case "$value" in
    sk-*) prefix="sk-..." ;;
    postgresql://*) prefix="$(printf '%s' "$value" | sed -E 's#(postgresql://[^:]+:)[^@]+(@.*)#\1***\2#')" ;;
    *) prefix="<set>" ;;
  esac
  printf '  %s=SET length=%s prefix=%s\n' "$name" "${#value}" "$prefix"
}

sanity_env_report() {
  local env_file="$1"
  local name
  local value
  printf '\nEnvironment variable sanity checks:\n'
  for name in LITELLM_MASTER_KEY LITELLM_SALT_KEY DATABASE_URL POSTGRES_PASSWORD OPENROUTER_API_KEY OLLAMA_API_KEY LITELLM_CLIENT_KEY; do
    value="${!name:-}"
    [ -n "$value" ] || value="$(sanity_file_value "$env_file" "$name")"
    sanity_secret_value "$name" "$value"
  done
}

sanity_repair_database_url() {
  local env_file="$1"
  local postgres_password="$2"
  local stamp
  local tmp
  [ -n "$postgres_password" ] || return 1
  [ -f "$env_file" ] || return 1
  stamp="$(date +%Y%m%d_%H%M%S)"
  cp -a "$env_file" "${env_file}.bak.${stamp}"
  tmp="$(mktemp)"
  awk -v new_url="DATABASE_URL=postgresql://litellm:${postgres_password}@postgres:5432/litellm" '
    BEGIN { replaced=0 }
    /^DATABASE_URL=/ { print new_url; replaced=1; next }
    { print }
    END { if (replaced != 1) print new_url }
  ' "$env_file" > "$tmp"
  cat "$tmp" > "$env_file"
  rm -f "$tmp"
  chmod 0600 "$env_file"
  printf 'Repaired DATABASE_URL in %s and backed up the old file to %s.bak.%s\n' "$env_file" "$env_file" "$stamp"
}

sanity_database_url_password_check() {
  local env_file="$1"
  local repair="${2:-0}"
  local postgres_password="${POSTGRES_PASSWORD:-}"
  local database_url="${DATABASE_URL:-}"
  local url_password

  [ -n "$postgres_password" ] || postgres_password="$(sanity_file_value "$env_file" POSTGRES_PASSWORD)"
  [ -n "$database_url" ] || database_url="$(sanity_file_value "$env_file" DATABASE_URL)"

  [ -n "$postgres_password" ] || return 0
  [ -n "$database_url" ] || return 0
  url_password="$(printf '%s' "$database_url" | sed -n -E 's#^postgresql://[^:]+:([^@]+)@.*#\1#p')"
  [ -n "$url_password" ] || return 0

  if [ "$postgres_password" != "$url_password" ]; then
    if [ "$repair" -eq 1 ]; then
      sanity_repair_database_url "$env_file" "$postgres_password"
    else
      sanity_fail "POSTGRES_PASSWORD and DATABASE_URL password do not match. LiteLLM may restart or fail DB auth. Rerun with --repair-database-url to rewrite DATABASE_URL from POSTGRES_PASSWORD."
    fi
  else
    printf '  DATABASE_URL password matches POSTGRES_PASSWORD.\n'
  fi
}

sanity_client_key_summary() {
  local key="${LITELLM_CLIENT_KEY:-}"
  printf '\nLiteLLM client key sanity check:\n'
  if [ -z "$key" ]; then
    printf '  LITELLM_CLIENT_KEY=MISSING\n'
    sanity_warn "Authorization header would be empty for client-key tests."
    return 1
  fi
  printf '  key length: %s\n' "${#key}"
  case "$key" in
    sk-*) printf '  key prefix: sk-...\n' ;;
    *) sanity_warn "Client API key should usually start with sk-." ;;
  esac
}

sanity_docker_service_check() {
  printf '\nDocker service sanity check:\n'
  if ! command -v systemctl >/dev/null 2>&1; then
    sanity_warn "systemctl is not available; cannot check Docker service state."
    return 0
  fi
  printf '  docker enabled: %s\n' "$(systemctl is-enabled docker 2>/dev/null || printf unknown)"
  printf '  docker active: %s\n' "$(systemctl is-active docker 2>/dev/null || printf unknown)"
  if ! systemctl is-active docker >/dev/null 2>&1; then
    sanity_warn "Docker is not active. Start it with: systemctl enable --now docker"
  fi
  if ! systemctl is-enabled docker >/dev/null 2>&1; then
    sanity_warn "Docker is not enabled. Enable it with: systemctl enable --now docker"
  fi
}

sanity_compose_running_check() {
  local app_dir="$1"
  local project="$2"
  local compose_file="$3"
  printf '\nLiteLLM stack running sanity check:\n'
  if [ ! -f "$compose_file" ]; then
    sanity_warn "Compose file not found: ${compose_file}"
    return 0
  fi
  if command -v docker >/dev/null 2>&1; then
    docker compose -p "$project" -f "$compose_file" ps || true
    if ! docker compose -p "$project" -f "$compose_file" ps --status running 2>/dev/null | grep -q "${project}-"; then
      sanity_warn "LiteLLM stack is installed but may not be running. Start it with: docker compose -p ${project} -f ${compose_file} up -d"
    fi
  else
    sanity_warn "Docker command is missing; cannot inspect Compose state."
  fi
}

sanity_firewall_access_check() {
  local port="$1"
  local cidr="${2:-}"
  printf '\nFirewall/access sanity check:\n'
  if command -v ss >/dev/null 2>&1; then
    ss -lntp 2>/dev/null | grep ":${port}" || sanity_warn "No listener found for port ${port}."
  fi
  if command -v ufw >/dev/null 2>&1; then
    ufw status verbose || true
  fi
  [ -z "$cidr" ] || printf 'Expected UFW allow source for LiteLLM: %s to port %s/tcp\n' "$cidr" "$port"
  printf 'If ping fails but curl works, ICMP may simply be blocked.\n'
  printf 'If curl fails, check LiteLLM stack state, UFW allow rules, Proxmox firewall, wrong IP, and Docker port binding.\n'
}

sanity_ollama_account_checklist() {
  local interactive="${1:-0}"
  printf '\nOllama account and access checklist:\n'
  printf '  - Are you signed into the intended Ollama account?\n'
  printf '  - Did "ollama signin" report the expected username?\n'
  printf '  - Did you add the service user public key to https://ollama.com/settings/keys?\n'
  printf '  - Are you testing a cloud model name that is actually available?\n'
  printf '  - CLI cloud model naming example: gpt-oss:120b-cloud\n'
  printf '  - LiteLLM bridge model IDs known here: ollama/gpt-oss:120b-cloud and ollama/kimi-k2.6:cloud\n'
  printf '\nUseful manual commands:\n'
  printf '  ollama signin\n'
  printf '  ollama list\n'
  printf '  ollama run gpt-oss:120b-cloud\n'
  if command -v ollama >/dev/null 2>&1; then
    printf '\nCurrent ollama list output:\n'
    ollama list || true
    if [ "$interactive" -eq 1 ]; then
      printf '\nRunning interactive Ollama cloud smoke test because --interactive was passed.\n'
      ollama run gpt-oss:120b-cloud || true
    fi
  else
    sanity_warn "ollama command is not installed or not on PATH."
  fi
}

sanity_ollama_api_key_note() {
  printf '\nOllama API key vs CLI sign-in distinction:\n'
  printf '  OLLAMA_API_KEY is for programmatic cloud API access.\n'
  printf '  Ollama CLI cloud use may rely on "ollama signin" and local SSH identity files.\n'
  printf '  Local Ollama daemon cloud access uses the service user identity, not necessarily the admin user OLLAMA_API_KEY.\n'
  printf '  /api/tags success does not prove /api/chat or /api/generate inference is authorized.\n'
  printf '  Model listing and inference may fail differently.\n'
}

#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

APP_DIR="${APP_DIR:-/opt/litellm-gateway}"
ENV_FILE="${APP_DIR}/.env"
GATEWAY_ENV_FILE="${APP_DIR}/gateway.env"
COMPOSE_FILE="${APP_DIR}/docker-compose.yml"
COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-}"
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
VERIFY_CHAT_MODEL="${VERIFY_CHAT_MODEL:-}"
SKIP_PROVIDER_TEST="${SKIP_PROVIDER_TEST:-0}"
YES=0
REPAIR_DATABASE_URL=0
FAILURES=0

on_error() {
  printf 'ERROR: command failed at line %s: %s\n' "$1" "$2" >&2
}
trap 'on_error "$LINENO" "$BASH_COMMAND"' ERR

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

fail_check() {
  printf '[FAIL] %s\n' "$*" >&2
  FAILURES=$((FAILURES + 1))
}

pass_check() {
  printf '[PASS] %s\n' "$*"
}

warn_check() {
  printf '[WARN] %s\n' "$*" >&2
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -r "${SCRIPT_DIR}/litellm-sanity-lib.sh" ]; then
  # shellcheck disable=SC1091
  . "${SCRIPT_DIR}/litellm-sanity-lib.sh"
else
  warn_check "litellm-sanity-lib.sh not found; account sanity checks will be limited."
fi

usage() {
  cat <<'EOF'
Usage: verify-litellm-gateway.sh [options]

Options:
  --litellm-host-ip IP            LAN/Tailscale IP clients should use for LiteLLM.
  --litellm-port PORT             Host LiteLLM port. Default prompt value: 4000.
  --trusted-client-cidr CIDR      CIDR or single-client /32 allowed to reach LiteLLM.
  --ollama-bridge-api-base URL    URL LiteLLM containers use for host Ollama.
  --docker-litellm-subnet CIDR    Docker subnet allowed to reach host Ollama.
  --zeroclaw-host-ip IP           Optional ZeroClaw host IP for saved examples/tests.
  --chat-model MODEL              Chat model smoke test target.
  --skip-provider-test            Skip routed chat completion smoke test.
  --repair-database-url           Rewrite DATABASE_URL from POSTGRES_PASSWORD if they differ.
  --yes                           Accept detected/default non-secret network values.
  -h, --help                      Show this help.
EOF
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --yes) YES=1 ;;
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
      --zeroclaw-host-ip)
        shift
        [ "$#" -gt 0 ] || die_arg "--zeroclaw-host-ip"
        ZEROCLAW_HOST_IP="$1"
        ;;
      --chat-model)
        shift
        [ "$#" -gt 0 ] || die_arg "--chat-model"
        VERIFY_CHAT_MODEL="$1"
        ;;
      --skip-provider-test)
        SKIP_PROVIDER_TEST=1
        ;;
      --repair-database-url)
        REPAIR_DATABASE_URL=1
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        printf 'ERROR: Unknown option: %s\n' "$1" >&2
        exit 1
        ;;
    esac
    shift
  done
}

die_arg() {
  printf 'ERROR: %s requires a value\n' "$1" >&2
  exit 1
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
    fail_check "Missing required value for ${var_name}. Pass a flag or set it in ${GATEWAY_ENV_FILE}."
    return 1
  fi

  printf -v "$var_name" '%s' "$entered"
}

load_settings() {
  local env_project
  local detected_gateway
  local detected_subnet
  local saved

  env_project="$(get_gateway_value COMPOSE_PROJECT_NAME)"
  [ -n "$env_project" ] || env_project="$(get_env_value COMPOSE_PROJECT_NAME)"
  COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-${env_project:-litellm-gateway}}"

  LITELLM_MASTER_KEY="${LITELLM_MASTER_KEY:-$(get_env_value LITELLM_MASTER_KEY)}"
  LITELLM_CLIENT_KEY="${LITELLM_CLIENT_KEY:-$(get_env_value LITELLM_CLIENT_KEY)}"
  LITELLM_HOST_IP="${LITELLM_HOST_IP:-$(get_gateway_value LITELLM_HOST_IP)}"
  LITELLM_PORT="${LITELLM_PORT:-$(get_gateway_value LITELLM_PORT)}"
  [ -n "$LITELLM_PORT" ] || LITELLM_PORT="$(get_env_value LITELLM_PORT)"
  TRUSTED_CLIENT_CIDR="${TRUSTED_CLIENT_CIDR:-$(get_gateway_value TRUSTED_CLIENT_CIDR)}"
  [ -n "$TRUSTED_CLIENT_CIDR" ] || TRUSTED_CLIENT_CIDR="$(get_env_value TRUSTED_CIDR)"
  OLLAMA_BRIDGE_API_BASE="${OLLAMA_BRIDGE_API_BASE:-$(get_gateway_value OLLAMA_BRIDGE_API_BASE)}"
  DOCKER_LITELLM_SUBNET="${DOCKER_LITELLM_SUBNET:-$(get_gateway_value DOCKER_LITELLM_SUBNET)}"
  saved="$(get_gateway_value OLLAMA_HOST_BIND)"
  if [ -n "$saved" ] && [ "$OLLAMA_HOST_BIND" = "0.0.0.0:11434" ]; then
    OLLAMA_HOST_BIND="$saved"
  fi
  ZEROCLAW_HOST_IP="${ZEROCLAW_HOST_IP:-$(get_gateway_value ZEROCLAW_HOST_IP)}"
  BIND_ADDR="${BIND_ADDR:-$(get_gateway_value BIND_ADDR)}"
  LITELLM_IMAGE="${LITELLM_IMAGE:-$(get_gateway_value LITELLM_IMAGE)}"
  POSTGRES_IMAGE="${POSTGRES_IMAGE:-$(get_gateway_value POSTGRES_IMAGE)}"
  LITELLM_READ_ONLY="${LITELLM_READ_ONLY:-$(get_gateway_value LITELLM_READ_ONLY)}"

  detected_gateway="$(detect_docker_gateway)"
  detected_subnet="$(detect_docker_subnet)"
  if [ -z "$OLLAMA_BRIDGE_API_BASE" ] && [ -n "$detected_gateway" ]; then
    OLLAMA_BRIDGE_API_BASE="http://${detected_gateway}:11434"
  fi
  if [ -z "$DOCKER_LITELLM_SUBNET" ] && [ -n "$detected_subnet" ]; then
    DOCKER_LITELLM_SUBNET="$detected_subnet"
  fi

  prompt_value LITELLM_HOST_IP "Enter LiteLLM gateway LAN/Tailscale IP clients should use" "$(detect_primary_ip)" required || true
  prompt_value LITELLM_PORT "Enter LiteLLM host port clients should use" "4000" required || true
  prompt_value TRUSTED_CLIENT_CIDR "Enter trusted client CIDR allowed to access LiteLLM port ${LITELLM_PORT:-4000}" "" optional || true
  prompt_value OLLAMA_BRIDGE_API_BASE "Enter Ollama bridge API base reachable from the LiteLLM container" "$OLLAMA_BRIDGE_API_BASE" optional || true
  prompt_value DOCKER_LITELLM_SUBNET "Enter Docker subnet allowed to reach the host Ollama daemon" "$DOCKER_LITELLM_SUBNET" optional || true
  prompt_value ZEROCLAW_HOST_IP "Enter ZeroClaw host IP or leave blank to skip ZeroClaw-specific tests" "" optional || true
}

save_gateway_env() {
  [ "${EUID}" -eq 0 ] || return 0
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
}

compose() {
  (cd "$APP_DIR" && docker compose -p "$COMPOSE_PROJECT_NAME" "$@")
}

check_compose_status() {
  log "Docker Compose status"
  if compose ps; then
    pass_check "docker compose ps completed"
  else
    fail_check "docker compose ps failed"
  fi
}

check_health() {
  local litellm_health
  local pg_health
  litellm_health="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "${COMPOSE_PROJECT_NAME}-litellm-1" 2>/dev/null || true)"
  pg_health="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "${COMPOSE_PROJECT_NAME}-postgres-1" 2>/dev/null || true)"

  if [ "$litellm_health" = "healthy" ] || [ "$litellm_health" = "running" ]; then
    pass_check "LiteLLM container status: $litellm_health"
  else
    fail_check "LiteLLM container is not healthy/running: ${litellm_health:-missing}"
  fi

  if [ "$pg_health" = "healthy" ]; then
    pass_check "Postgres health: healthy"
  else
    fail_check "Postgres health is not healthy: ${pg_health:-missing}"
  fi
}

check_ports() {
  log "Bound ports"
  if command -v ss >/dev/null 2>&1; then
    ss -ltnp 2>/dev/null | awk -v port=":${LITELLM_PORT}" '$0 ~ port {print}'
  else
    warn_check "ss command not available"
  fi

  if docker port "${COMPOSE_PROJECT_NAME}-postgres-1" 5432 >/dev/null 2>&1; then
    fail_check "Postgres appears to publish a host port"
  else
    pass_check "Postgres is not published to the host"
  fi
}

check_compose_pinning() {
  local image_lines
  local unpinned
  image_lines="$(grep -E '^[[:space:]]*image:' "$COMPOSE_FILE" || true)"
  printf '%s\n' "$image_lines"
  unpinned="$(printf '%s\n' "$image_lines" | grep -Ev '@sha256:[a-f0-9]{64}([[:space:]]|$)' || true)"
  if [ -n "$image_lines" ] && [ -z "$unpinned" ]; then
    pass_check "all compose image references use sha256 digest pins"
  else
    fail_check "one or more compose image references are not digest-pinned"
  fi

  if grep -Eiq '(^|[:/_-])(latest|main-latest|nightly|dev)([[:space:]]|$)' "$COMPOSE_FILE"; then
    fail_check "compose file contains forbidden latest/nightly/dev tag text"
  else
    pass_check "compose file does not contain forbidden latest/nightly/dev image tags"
  fi
}

check_file_permissions() {
  local mode
  if [ ! -f "$ENV_FILE" ]; then
    fail_check "missing env file: $ENV_FILE"
    return
  fi
  mode="$(stat -c '%a' "$ENV_FILE")"
  if [ "$mode" = "600" ]; then
    pass_check ".env permissions are 600"
  else
    fail_check ".env permissions are $mode, expected 600"
  fi

  if [ -f "$GATEWAY_ENV_FILE" ]; then
    mode="$(stat -c '%a' "$GATEWAY_ENV_FILE")"
    case "$mode" in
      600|640) pass_check "gateway.env permissions are $mode" ;;
      *) fail_check "gateway.env permissions are $mode, expected 600 or 640" ;;
    esac
  else
    warn_check "gateway.env is missing; falling back to flags/env/autodetect where possible"
  fi
}

check_no_pypi_litellm() {
  local pip_cmd
  local found=0
  for pip_cmd in "python3 -m pip" "python -m pip" "pip3" "pip"; do
    if $pip_cmd show litellm >/dev/null 2>&1; then
      found=1
      warn_check "Host PyPI LiteLLM detected via: $pip_cmd show litellm"
    fi
  done
  if [ "$found" -eq 0 ]; then
    pass_check "No host PyPI LiteLLM package detected"
  else
    fail_check "Host PyPI LiteLLM package is installed; this deployment should be Docker-only"
  fi
}

curl_capture() {
  local method="$1"
  local url="$2"
  local body="${3:-}"
  local output_file="$4"
  local error_file="$5"
  shift 5
  if [ -n "$body" ]; then
    curl -sS -X "$method" -o "$output_file" -w '%{http_code}' "$@" -d "$body" "$url" 2>"$error_file" || true
  else
    curl -sS -X "$method" -o "$output_file" -w '%{http_code}' "$@" "$url" 2>"$error_file" || true
  fi
}

print_http_failure() {
  local label="$1"
  local status="$2"
  local body="$3"
  local curl_error="$4"
  printf '%s failed with HTTP status: %s\n' "$label" "${status:-unknown}" >&2
  printf '%s response body:\n%s\n' "$label" "${body:-<empty>}" >&2
  if [ -n "$curl_error" ]; then
    printf '%s curl error output:\n%s\n' "$label" "$curl_error" >&2
  fi
}

classify_litellm_failure() {
  local status="$1"
  local body="$2"
  local curl_error="$3"
  case "$status" in
    000)
      fail_check "gateway down or unreachable on localhost:${LITELLM_PORT}"
      ;;
    401|403)
      fail_check "auth failure from LiteLLM; check LITELLM_MASTER_KEY or virtual key scope"
      ;;
    404|400)
      fail_check "model/provider failure from LiteLLM; check model name and config.yaml"
      ;;
    500|502|503|504)
      if printf '%s\n%s\n' "$body" "$curl_error" | grep -Eiq 'ollama|api_base|connection|refused|upstream|timeout'; then
        fail_check "upstream Ollama failure; check OLLAMA_BRIDGE_API_BASE and host Ollama reachability"
      else
        fail_check "LiteLLM provider failure; inspect container logs"
      fi
      ;;
    *)
      fail_check "unexpected LiteLLM HTTP status ${status:-unknown}"
      ;;
  esac
}

choose_chat_model() {
  local models_body="$1"
  if [ -n "$VERIFY_CHAT_MODEL" ]; then
    printf '%s\n' "$VERIFY_CHAT_MODEL"
    return
  fi
  if printf '%s' "$models_body" | grep -q 'ollama-kimi-k26-cloud'; then
    printf '%s\n' "ollama-kimi-k26-cloud"
  elif printf '%s' "$models_body" | grep -q 'ollama-gpt-oss-cloud'; then
    printf '%s\n' "ollama-gpt-oss-cloud"
  else
    printf '%s\n' "ollama-kimi-k26-cloud"
  fi
}

check_http() {
  local base="http://127.0.0.1:${LITELLM_PORT}"
  local response_file
  local error_file
  local http_status
  local response_body
  local curl_error
  local models_body=""
  local chat_model
  local payload

  response_file="$(mktemp)"
  error_file="$(mktemp)"
  http_status="$(curl_capture GET "${base}/health/liveliness" "" "$response_file" "$error_file")"
  response_body="$(cat "$response_file" 2>/dev/null || true)"
  curl_error="$(cat "$error_file" 2>/dev/null || true)"
  if [[ "$http_status" =~ ^2[0-9][0-9]$ ]]; then
    pass_check "LiteLLM unauthenticated liveliness endpoint responded at ${base}/health/liveliness"
  else
    print_http_failure "LiteLLM liveliness" "$http_status" "$response_body" "$curl_error"
    classify_litellm_failure "$http_status" "$response_body" "$curl_error"
  fi

  : > "$response_file"
  : > "$error_file"
  http_status="$(curl_capture GET "${base}/health" "" "$response_file" "$error_file")"
  response_body="$(cat "$response_file" 2>/dev/null || true)"
  curl_error="$(cat "$error_file" 2>/dev/null || true)"
  if [ "$http_status" = "401" ]; then
    pass_check "/health returned 401 as expected for auth-protected health; using /health/liveliness for readiness"
  elif [[ "$http_status" =~ ^2[0-9][0-9]$ ]]; then
    pass_check "/health responded without auth on this LiteLLM build"
  else
    warn_check "/health returned HTTP ${http_status:-unknown}; this is not treated as gateway-down"
  fi

  if [ -z "${LITELLM_MASTER_KEY:-}" ]; then
    fail_check "LITELLM_MASTER_KEY missing from ${ENV_FILE}"
    rm -f "$response_file" "$error_file"
    return
  fi

  : > "$response_file"
  : > "$error_file"
  http_status="$(curl_capture GET "${base}/v1/models" "" "$response_file" "$error_file" -H "Authorization: Bearer ${LITELLM_MASTER_KEY}")"
  models_body="$(cat "$response_file" 2>/dev/null || true)"
  curl_error="$(cat "$error_file" 2>/dev/null || true)"
  if [[ "$http_status" =~ ^2[0-9][0-9]$ ]]; then
    pass_check "OpenAI-compatible /v1/models responded with master key"
  else
    print_http_failure "/v1/models" "$http_status" "$models_body" "$curl_error"
    classify_litellm_failure "$http_status" "$models_body" "$curl_error"
  fi

  if declare -F sanity_client_key_summary >/dev/null 2>&1 && sanity_client_key_summary; then
    local client_models_body
    local master_count
    local client_count
    : > "$response_file"
    : > "$error_file"
    http_status="$(curl_capture GET "${base}/v1/models" "" "$response_file" "$error_file" -H "Authorization: Bearer ${LITELLM_CLIENT_KEY}")"
    client_models_body="$(cat "$response_file" 2>/dev/null || true)"
    curl_error="$(cat "$error_file" 2>/dev/null || true)"
    if [[ "$http_status" =~ ^2[0-9][0-9]$ ]]; then
      pass_check "/v1/models responded with LITELLM_CLIENT_KEY"
      master_count="$(printf '%s' "$models_body" | jq -r '.data | length' 2>/dev/null || true)"
      client_count="$(printf '%s' "$client_models_body" | jq -r '.data | length' 2>/dev/null || true)"
      if [[ "$master_count" =~ ^[0-9]+$ ]] && [[ "$client_count" =~ ^[0-9]+$ ]] && [ "$client_count" -lt "$master_count" ]; then
        warn_check "Client key sees fewer models than the master key. This is expected if the virtual key is scoped."
      fi
      if ! printf '%s' "$client_models_body" | grep -q 'openrouter-auto'; then
        warn_check "openrouter-auto is missing from the client key model list. Expected if the client key intentionally excludes OpenRouter."
      fi
    else
      print_http_failure "/v1/models with LITELLM_CLIENT_KEY" "$http_status" "$client_models_body" "$curl_error"
      classify_litellm_failure "$http_status" "$client_models_body" "$curl_error"
    fi
  fi

  if [ "$SKIP_PROVIDER_TEST" = "1" ]; then
    warn_check "Skipping routed chat completion test because SKIP_PROVIDER_TEST=1 or --skip-provider-test was used"
    rm -f "$response_file" "$error_file"
    return
  fi

  chat_model="$(choose_chat_model "$models_body")"
  if [ -n "$models_body" ] && ! printf '%s' "$models_body" | grep -q "$chat_model"; then
    fail_check "chat test model '${chat_model}' is not listed by /v1/models"
    rm -f "$response_file" "$error_file"
    return
  fi

  payload="$(jq -n --arg model "$chat_model" '{
    model: $model,
    messages: [{role: "user", content: "Reply with only these words: litellm gateway test ok"}],
    max_tokens: 100,
    temperature: 0
  }')"
  : > "$response_file"
  : > "$error_file"
  http_status="$(curl_capture POST "${base}/v1/chat/completions" "$payload" "$response_file" "$error_file" \
    -H "Authorization: Bearer ${LITELLM_MASTER_KEY}" \
    -H "Content-Type: application/json")"
  response_body="$(cat "$response_file" 2>/dev/null || true)"
  curl_error="$(cat "$error_file" 2>/dev/null || true)"
  rm -f "$response_file" "$error_file"

  if [[ "$http_status" =~ ^2[0-9][0-9]$ ]]; then
    pass_check "LiteLLM routed chat completion test with model ${chat_model}"
  else
    print_http_failure "LiteLLM chat completion" "$http_status" "$response_body" "$curl_error"
    classify_litellm_failure "$http_status" "$response_body" "$curl_error"
  fi
}

print_endpoint() {
  printf '\nClient endpoint:\n  http://%s:%s/v1\n' "${LITELLM_HOST_IP:-<LITELLM_HOST_IP>}" "${LITELLM_PORT:-<LITELLM_PORT>}"
  if [ -n "$TRUSTED_CLIENT_CIDR" ]; then
    printf 'Trusted client CIDR:\n  %s\n' "$TRUSTED_CLIENT_CIDR"
  fi
  if [ -n "$OLLAMA_BRIDGE_API_BASE" ]; then
    printf 'Ollama bridge API base:\n  %s\n' "$OLLAMA_BRIDGE_API_BASE"
  fi
}

main() {
  parse_args "$@"
  load_settings
  if declare -F sanity_host_banner >/dev/null 2>&1; then
    sanity_host_banner "LiteLLM gateway verification host" "$APP_DIR" "$COMPOSE_FILE"
    sanity_ollama_identity_check
    sanity_env_report "$ENV_FILE"
    sanity_database_url_password_check "$ENV_FILE" "$REPAIR_DATABASE_URL"
    sanity_docker_service_check
    sanity_compose_running_check "$APP_DIR" "$COMPOSE_PROJECT_NAME" "$COMPOSE_FILE"
    sanity_firewall_access_check "${LITELLM_PORT:-4000}" "$TRUSTED_CLIENT_CIDR"
  fi
  save_gateway_env
  command -v docker >/dev/null 2>&1 || fail_check "docker is not installed"
  command -v jq >/dev/null 2>&1 || fail_check "jq is required for JSON request generation"
  [ -f "$COMPOSE_FILE" ] || fail_check "compose file missing: $COMPOSE_FILE"
  [ "$FAILURES" -eq 0 ] || exit 1

  check_compose_status
  check_health
  check_ports
  check_compose_pinning
  check_file_permissions
  check_no_pypi_litellm
  check_http
  print_endpoint

  if [ "$FAILURES" -gt 0 ]; then
    printf '\nVerification failed with %s issue(s).\n' "$FAILURES" >&2
    exit 1
  fi
  printf '\nVerification passed.\n'
}

main "$@"

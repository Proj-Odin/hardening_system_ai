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
DIRECT_OLLAMA_CHAT_MODEL="${DIRECT_OLLAMA_CHAT_MODEL:-gpt-oss:120b-cloud}"
LITELLM_CHAT_MODEL="${LITELLM_CHAT_MODEL:-ollama-kimi-k26-cloud}"
LITELLM_EMBEDDING_MODEL="${LITELLM_EMBEDDING_MODEL:-embed-nomic}"
YES=0
INTERACTIVE=0
REPAIR_DATABASE_URL=0
FAILURES=0

pass_check() {
  printf '[PASS] %s\n' "$*"
}

fail_check() {
  printf '[FAIL] %s\n' "$*" >&2
  FAILURES=$((FAILURES + 1))
}

warn_check() {
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
  warn_check "litellm-sanity-lib.sh not found; account sanity checks will be limited."
fi

usage() {
  cat <<'EOF'
Usage: verify-ollama-cloud-bridge.sh [options]

Options:
  --litellm-host-ip IP            LAN/Tailscale IP clients should use for LiteLLM.
  --litellm-port PORT             Host LiteLLM port. Default prompt value: 4000.
  --trusted-client-cidr CIDR      CIDR or single-client /32 allowed to reach LiteLLM.
  --ollama-bridge-api-base URL    URL LiteLLM containers use for host Ollama.
  --docker-litellm-subnet CIDR    Docker subnet allowed to reach host Ollama.
  --ollama-host-bind HOST:PORT    Ollama service bind. Default: 0.0.0.0:11434.
  --zeroclaw-host-ip IP           Optional ZeroClaw host IP for targeted tests.
  --direct-ollama-model MODEL     Direct Ollama /api/chat model. Default: gpt-oss:120b-cloud.
  --litellm-chat-model MODEL      LiteLLM chat model. Default: ollama-kimi-k26-cloud.
  --litellm-embedding-model MODEL LiteLLM embedding model. Default: embed-nomic.
  --interactive                   Run interactive Ollama cloud smoke command.
  --repair-database-url           Rewrite DATABASE_URL from POSTGRES_PASSWORD if they differ.
  --yes                           Accept detected/default non-secret network values.
  -h, --help                      Show this help.
EOF
}

die_arg() {
  die "$1 requires a value"
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --yes) YES=1 ;;
      --interactive) INTERACTIVE=1 ;;
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
      --direct-ollama-model)
        shift
        [ "$#" -gt 0 ] || die_arg "--direct-ollama-model"
        DIRECT_OLLAMA_CHAT_MODEL="$1"
        ;;
      --litellm-chat-model)
        shift
        [ "$#" -gt 0 ] || die_arg "--litellm-chat-model"
        LITELLM_CHAT_MODEL="$1"
        ;;
      --litellm-embedding-model)
        shift
        [ "$#" -gt 0 ] || die_arg "--litellm-embedding-model"
        LITELLM_EMBEDDING_MODEL="$1"
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

load_env() {
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
  LITELLM_MASTER_KEY="${LITELLM_MASTER_KEY:-$(get_file_value "$ENV_FILE" LITELLM_MASTER_KEY)}"
  OLLAMA_API_KEY="${OLLAMA_API_KEY:-$(get_file_value "$ENV_FILE" OLLAMA_API_KEY)}"
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
    fail_check "Missing required value for ${var_name}. Pass a flag or save it in ${GATEWAY_ENV_FILE}."
    return 1
  fi
  printf -v "$var_name" '%s' "$entered"
}

collect_settings() {
  local detected_gateway
  local detected_subnet
  detected_gateway="$(detect_docker_gateway)"
  detected_subnet="$(detect_docker_subnet)"
  if [ -z "$OLLAMA_BRIDGE_API_BASE" ] && [ -n "$detected_gateway" ]; then
    OLLAMA_BRIDGE_API_BASE="http://${detected_gateway}:11434"
  fi
  if [ -z "$DOCKER_LITELLM_SUBNET" ] && [ -n "$detected_subnet" ]; then
    DOCKER_LITELLM_SUBNET="$detected_subnet"
  fi
  prompt_value LITELLM_HOST_IP "Enter LiteLLM gateway LAN/Tailscale IP clients should use" "$(detect_primary_ip)" optional || true
  prompt_value LITELLM_PORT "Enter LiteLLM host port clients should use" "4000" required || true
  prompt_value OLLAMA_BRIDGE_API_BASE "Enter Ollama bridge API base reachable from the LiteLLM container" "$OLLAMA_BRIDGE_API_BASE" required || true
  prompt_value DOCKER_LITELLM_SUBNET "Enter Docker subnet allowed to reach the host Ollama daemon" "$DOCKER_LITELLM_SUBNET" optional || true
  prompt_value TRUSTED_CLIENT_CIDR "Enter trusted client CIDR allowed to access LiteLLM port ${LITELLM_PORT:-4000}" "" optional || true
  prompt_value ZEROCLAW_HOST_IP "Enter ZeroClaw host IP or leave blank to skip ZeroClaw-specific tests" "" optional || true
}

save_gateway_env() {
  [ "${EUID}" -eq 0 ] || return 0
  install -d -m 0750 "$APP_DIR"
  cat > "$GATEWAY_ENV_FILE" <<EOF
# Managed by LiteLLM gateway helper scripts.
# Non-secret deployment-specific network settings.
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

report_http_result() {
  local label="$1"
  local status="$2"
  local body="$3"
  local curl_error="$4"
  if [[ "$status" =~ ^2[0-9][0-9]$ ]]; then
    pass_check "$label"
  else
    fail_check "$label failed with HTTP status ${status:-unknown}"
    printf '%s response body:\n%s\n' "$label" "${body:-<empty>}" >&2
    if [ -n "$curl_error" ]; then
      printf '%s curl error output:\n%s\n' "$label" "$curl_error" >&2
    fi
  fi
}

http_test() {
  local label="$1"
  local method="$2"
  local url="$3"
  local body="${4:-}"
  shift 4
  local response_file
  local error_file
  local status
  local response_body
  local curl_error
  response_file="$(mktemp)"
  error_file="$(mktemp)"
  status="$(curl_capture "$method" "$url" "$body" "$response_file" "$error_file" "$@")"
  response_body="$(cat "$response_file" 2>/dev/null || true)"
  curl_error="$(cat "$error_file" 2>/dev/null || true)"
  rm -f "$response_file" "$error_file"
  report_http_result "$label" "$status" "$response_body" "$curl_error"
}

test_ollama_cloud_api_key_access() {
  local response_file
  local error_file
  local catalog_status
  local inference_status
  local catalog_body
  local inference_body
  local curl_error
  local payload

  printf '\nOllama Cloud API key distinction tests:\n'
  if [ -z "${OLLAMA_API_KEY:-}" ]; then
    warn_check "OLLAMA_API_KEY is missing; skipping direct Ollama Cloud catalog and OpenAI-compatible inference tests."
    return
  fi
  printf '  OLLAMA_API_KEY=SET length=%s prefix=<set>\n' "${#OLLAMA_API_KEY}"

  response_file="$(mktemp)"
  error_file="$(mktemp)"
  catalog_status="$(curl_capture GET "https://ollama.com/api/tags" "" "$response_file" "$error_file" -H "Authorization: Bearer ${OLLAMA_API_KEY}")"
  catalog_body="$(cat "$response_file" 2>/dev/null || true)"
  curl_error="$(cat "$error_file" 2>/dev/null || true)"
  if [[ "$catalog_status" =~ ^2[0-9][0-9]$ ]]; then
    pass_check "Ollama Cloud model catalog request succeeded with OLLAMA_API_KEY"
  else
    report_http_result "Ollama Cloud model catalog request" "$catalog_status" "$catalog_body" "$curl_error"
  fi

  payload="$(jq -n --arg model "$DIRECT_OLLAMA_CHAT_MODEL" '{
    model: $model,
    messages: [{role: "user", content: "Reply with only: ollama cloud api ok"}],
    max_tokens: 20,
    temperature: 0
  }')"
  : > "$response_file"
  : > "$error_file"
  inference_status="$(curl_capture POST "https://ollama.com/v1/chat/completions" "$payload" "$response_file" "$error_file" \
    -H "Authorization: Bearer ${OLLAMA_API_KEY}" \
    -H "Content-Type: application/json")"
  inference_body="$(cat "$response_file" 2>/dev/null || true)"
  curl_error="$(cat "$error_file" 2>/dev/null || true)"
  rm -f "$response_file" "$error_file"

  if [[ "$inference_status" =~ ^2[0-9][0-9]$ ]]; then
    pass_check "Direct Ollama Cloud OpenAI-compatible inference succeeded"
  else
    report_http_result "Direct Ollama Cloud OpenAI-compatible inference" "$inference_status" "$inference_body" "$curl_error"
    if [[ "$catalog_status" =~ ^2[0-9][0-9]$ ]] && [ "$inference_status" = "401" ]; then
      warn_check "Catalog access works, but inference is unauthorized. Check account, subscription/entitlement, model name, or endpoint."
    fi
  fi
}

test_host_local_ollama() {
  http_test "Host can reach Ollama on loopback" GET "http://127.0.0.1:11434/api/tags"
}

test_host_gateway_ollama() {
  http_test "Host can reach Ollama through Docker gateway URL" GET "${OLLAMA_BRIDGE_API_BASE%/}/api/tags"
}

test_container_to_ollama() {
  local container="${COMPOSE_PROJECT_NAME}-litellm-1"
  local url="${OLLAMA_BRIDGE_API_BASE%/}/api/tags"
  if docker exec "$container" python -c "import urllib.request; print(urllib.request.urlopen('${url}', timeout=10).status)" >/dev/null 2>&1; then
    pass_check "LiteLLM container can reach host Ollama bridge"
  else
    fail_check "LiteLLM container cannot reach ${url}; check OLLAMA_HOST=${OLLAMA_HOST_BIND} and the UFW rule for ${DOCKER_LITELLM_SUBNET:-<DOCKER_LITELLM_SUBNET>}"
  fi
}

test_direct_ollama_cloud_chat() {
  local payload
  local response_file
  local error_file
  local status
  local body
  local curl_error
  payload="$(jq -n --arg model "$DIRECT_OLLAMA_CHAT_MODEL" '{
    model: $model,
    stream: false,
    messages: [{role: "user", content: "Say exactly: ollama local bridge test ok"}]
  }')"
  response_file="$(mktemp)"
  error_file="$(mktemp)"
  status="$(curl_capture POST "http://127.0.0.1:11434/api/chat" "$payload" "$response_file" "$error_file" -H "Content-Type: application/json")"
  body="$(cat "$response_file" 2>/dev/null || true)"
  curl_error="$(cat "$error_file" 2>/dev/null || true)"
  rm -f "$response_file" "$error_file"
  report_http_result "Direct local Ollama cloud model chat" "$status" "$body" "$curl_error"
  if [ "$status" = "401" ]; then
    warn_check "CLI user may be authenticated, but Ollama service user likely is not. Add the service user's public key to https://ollama.com/settings/keys."
  fi
}

test_litellm_chat() {
  local payload
  if [ -z "${LITELLM_MASTER_KEY:-}" ]; then
    fail_check "LITELLM_MASTER_KEY missing from ${ENV_FILE}; cannot test LiteLLM chat"
    return
  fi
  payload="$(jq -n --arg model "$LITELLM_CHAT_MODEL" '{
    model: $model,
    messages: [{role: "user", content: "Reply with only these words: litellm ollama bridge ok"}],
    max_tokens: 100,
    temperature: 0
  }')"
  http_test "LiteLLM chat through Ollama bridge" POST "http://127.0.0.1:${LITELLM_PORT}/v1/chat/completions" "$payload" \
    -H "Authorization: Bearer ${LITELLM_MASTER_KEY}" \
    -H "Content-Type: application/json"
}

test_litellm_embedding() {
  local payload
  if [ -z "${LITELLM_MASTER_KEY:-}" ]; then
    fail_check "LITELLM_MASTER_KEY missing from ${ENV_FILE}; cannot test LiteLLM embeddings"
    return
  fi
  payload="$(jq -n --arg model "$LITELLM_EMBEDDING_MODEL" '{
    model: $model,
    input: "ollama local embedding bridge test"
  }')"
  http_test "LiteLLM embedding through local Ollama" POST "http://127.0.0.1:${LITELLM_PORT}/v1/embeddings" "$payload" \
    -H "Authorization: Bearer ${LITELLM_MASTER_KEY}" \
    -H "Content-Type: application/json"
}

main() {
  parse_args "$@"
  load_env
  collect_settings
  if declare -F sanity_host_banner >/dev/null 2>&1; then
    sanity_host_banner "LiteLLM gateway/Ollama bridge verification host" "$APP_DIR" "${APP_DIR}/docker-compose.yml"
    sanity_ollama_identity_check
    sanity_env_report "$ENV_FILE"
    sanity_database_url_password_check "$ENV_FILE" "$REPAIR_DATABASE_URL"
    sanity_docker_service_check
    sanity_compose_running_check "$APP_DIR" "$COMPOSE_PROJECT_NAME" "${APP_DIR}/docker-compose.yml"
    sanity_ollama_api_key_note
    sanity_ollama_account_checklist "$INTERACTIVE"
  fi
  command -v curl >/dev/null 2>&1 || fail_check "curl is required"
  command -v docker >/dev/null 2>&1 || fail_check "docker is required"
  command -v jq >/dev/null 2>&1 || fail_check "jq is required"
  [ "$FAILURES" -eq 0 ] || exit 1
  save_gateway_env

  test_ollama_cloud_api_key_access
  test_host_local_ollama
  test_host_gateway_ollama
  test_container_to_ollama
  test_direct_ollama_cloud_chat
  test_litellm_chat
  test_litellm_embedding

  if [ "$FAILURES" -gt 0 ]; then
    printf '\nOllama bridge verification failed with %s issue(s).\n' "$FAILURES" >&2
    exit 1
  fi
  printf '\nOllama bridge verification passed.\n'
}

main "$@"

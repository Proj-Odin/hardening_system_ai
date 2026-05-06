#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

APP_DIR="${APP_DIR:-/opt/litellm-gateway}"
ENV_FILE="${APP_DIR}/.env"
GATEWAY_ENV_FILE="${APP_DIR}/gateway.env"
LITELLM_HOST_IP="${LITELLM_HOST_IP:-}"
LITELLM_PORT="${LITELLM_PORT:-}"
TRUSTED_CLIENT_CIDR="${TRUSTED_CLIENT_CIDR:-${TRUSTED_CIDR:-}}"
OLLAMA_BRIDGE_API_BASE="${OLLAMA_BRIDGE_API_BASE:-}"
DOCKER_LITELLM_SUBNET="${DOCKER_LITELLM_SUBNET:-}"
OLLAMA_HOST_BIND="${OLLAMA_HOST_BIND:-0.0.0.0:11434}"
ZEROCLAW_HOST_IP="${ZEROCLAW_HOST_IP:-}"
COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-litellm-gateway}"
KEY_ALIAS="${KEY_ALIAS:-zeroclaw}"
MAX_BUDGET="${MAX_BUDGET:-10}"
BUDGET_DURATION="${BUDGET_DURATION:-30d}"
INCLUDE_OPENROUTER=0
YES=0
REPAIR_DATABASE_URL=0

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -r "${SCRIPT_DIR}/litellm-sanity-lib.sh" ]; then
  # shellcheck disable=SC1091
  . "${SCRIPT_DIR}/litellm-sanity-lib.sh"
fi

usage() {
  cat <<'EOF'
Usage: create-litellm-client-key.sh [options]

Options:
  --alias NAME                    LiteLLM virtual key alias. Default: zeroclaw.
  --max-budget NUMBER             LiteLLM max budget. Default: 10.
  --budget-duration DURATION      LiteLLM budget duration. Default: 30d.
  --include-openrouter            Include openrouter-auto in the scoped model list.
  --litellm-host-ip IP            LAN/Tailscale IP clients should use for LiteLLM.
  --litellm-port PORT             Host LiteLLM port. Default prompt value: 4000.
  --trusted-client-cidr CIDR      CIDR or single-client /32 allowed to reach LiteLLM.
  --ollama-bridge-api-base URL    URL LiteLLM containers use for host Ollama.
  --docker-litellm-subnet CIDR    Docker subnet allowed to reach host Ollama.
  --ollama-host-bind HOST:PORT    Ollama service bind. Default: 0.0.0.0:11434.
  --zeroclaw-host-ip IP           Optional ZeroClaw host IP for saved examples/tests.
  --repair-database-url           Rewrite DATABASE_URL from POSTGRES_PASSWORD if they differ.
  --yes                           Accept detected/default non-secret network values.
  -h, --help                      Show this help.

The returned "key" value is the client API key. "token_id" is an identifier,
not the API key.
EOF
}

die_arg() {
  die "$1 requires a value"
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --yes) YES=1 ;;
      --include-openrouter) INCLUDE_OPENROUTER=1 ;;
      --repair-database-url) REPAIR_DATABASE_URL=1 ;;
      --alias)
        shift
        [ "$#" -gt 0 ] || die_arg "--alias"
        KEY_ALIAS="$1"
        ;;
      --max-budget)
        shift
        [ "$#" -gt 0 ] || die_arg "--max-budget"
        MAX_BUDGET="$1"
        ;;
      --budget-duration)
        shift
        [ "$#" -gt 0 ] || die_arg "--budget-duration"
        BUDGET_DURATION="$1"
        ;;
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

source_env_file() {
  local file="$1"
  [ -f "$file" ] || return 0
  # shellcheck disable=SC1090
  set -a
  . "$file"
  set +a
}

load_gateway_env_file() {
  local value
  declare -F sanity_file_value >/dev/null 2>&1 || return 0
  value="$(sanity_file_value "$GATEWAY_ENV_FILE" LITELLM_HOST_IP)"
  [ -n "$LITELLM_HOST_IP" ] || LITELLM_HOST_IP="$value"
  value="$(sanity_file_value "$GATEWAY_ENV_FILE" LITELLM_PORT)"
  [ -n "$LITELLM_PORT" ] || LITELLM_PORT="$value"
  value="$(sanity_file_value "$GATEWAY_ENV_FILE" TRUSTED_CLIENT_CIDR)"
  [ -n "$TRUSTED_CLIENT_CIDR" ] || TRUSTED_CLIENT_CIDR="$value"
  value="$(sanity_file_value "$GATEWAY_ENV_FILE" OLLAMA_BRIDGE_API_BASE)"
  [ -n "$OLLAMA_BRIDGE_API_BASE" ] || OLLAMA_BRIDGE_API_BASE="$value"
  value="$(sanity_file_value "$GATEWAY_ENV_FILE" DOCKER_LITELLM_SUBNET)"
  [ -n "$DOCKER_LITELLM_SUBNET" ] || DOCKER_LITELLM_SUBNET="$value"
  value="$(sanity_file_value "$GATEWAY_ENV_FILE" OLLAMA_HOST_BIND)"
  [ "$OLLAMA_HOST_BIND" = "0.0.0.0:11434" ] && [ -n "$value" ] && OLLAMA_HOST_BIND="$value"
  value="$(sanity_file_value "$GATEWAY_ENV_FILE" ZEROCLAW_HOST_IP)"
  [ -n "$ZEROCLAW_HOST_IP" ] || ZEROCLAW_HOST_IP="$value"
  value="$(sanity_file_value "$GATEWAY_ENV_FILE" COMPOSE_PROJECT_NAME)"
  [ "$COMPOSE_PROJECT_NAME" = "litellm-gateway" ] && [ -n "$value" ] && COMPOSE_PROJECT_NAME="$value"
}

detect_primary_ip() {
  hostname -I 2>/dev/null | awk '{print $1}' || true
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
    die "Missing required value for ${var_name}. Pass a flag or save it in ${GATEWAY_ENV_FILE}."
  fi
  printf -v "$var_name" '%s' "$entered"
}

collect_settings() {
  prompt_value LITELLM_HOST_IP "Enter LiteLLM gateway LAN/Tailscale IP clients should use" "$(detect_primary_ip)" required
  prompt_value LITELLM_PORT "Enter LiteLLM host port clients should use" "4000" required
  prompt_value TRUSTED_CLIENT_CIDR "Enter trusted client CIDR allowed to access LiteLLM port ${LITELLM_PORT}" "" optional
  prompt_value OLLAMA_BRIDGE_API_BASE "Enter Ollama bridge API base reachable from the LiteLLM container" "$OLLAMA_BRIDGE_API_BASE" optional
  prompt_value DOCKER_LITELLM_SUBNET "Enter Docker subnet allowed to reach the host Ollama daemon" "$DOCKER_LITELLM_SUBNET" optional
  prompt_value ZEROCLAW_HOST_IP "Enter ZeroClaw host IP or leave blank to skip ZeroClaw-specific tests" "" optional
}

models_json() {
  local -a models
  models=(
    ollama-gpt-oss-cloud
    ollama-kimi-k26-cloud
    ollama-glm-51-cloud
    ollama-deepseek-v4-pro-cloud
    ollama-gemma4-31b-cloud
    ollama-nemotron-3-super-cloud
    embed-nomic
    embed-embeddinggemma
    embed-qwen3
  )
  if [ "$INCLUDE_OPENROUTER" -eq 1 ]; then
    models+=(openrouter-auto)
  fi
  printf '%s\n' "${models[@]}" | jq -R . | jq -s .
}

create_key() {
  local base
  local payload
  local response_file
  local error_file
  local status
  local body
  local curl_error
  local client_key
  local token_id
  local key_dir
  local key_file

  [ -n "${LITELLM_MASTER_KEY:-}" ] || die "LITELLM_MASTER_KEY is missing. This script sources ${ENV_FILE}."
  command -v jq >/dev/null 2>&1 || die "jq is required."
  command -v curl >/dev/null 2>&1 || die "curl is required."

  base="http://${LITELLM_HOST_IP}:${LITELLM_PORT}"
  payload="$(jq -n \
    --arg alias "$KEY_ALIAS" \
    --arg duration "$BUDGET_DURATION" \
    --argjson max_budget "$MAX_BUDGET" \
    --argjson models "$(models_json)" \
    '{key_alias: $alias, models: $models, max_budget: $max_budget, budget_duration: $duration}')"

  response_file="$(mktemp)"
  error_file="$(mktemp)"
  status="$(curl -sS -X POST "${base}/key/generate" \
    -o "$response_file" \
    -w '%{http_code}' \
    -H "Authorization: Bearer ${LITELLM_MASTER_KEY}" \
    -H "Content-Type: application/json" \
    -d "$payload" 2>"$error_file" || true)"
  body="$(cat "$response_file" 2>/dev/null || true)"
  curl_error="$(cat "$error_file" 2>/dev/null || true)"
  rm -f "$response_file" "$error_file"

  if ! [[ "$status" =~ ^2[0-9][0-9]$ ]]; then
    printf 'LiteLLM /key/generate failed with HTTP status: %s\n' "${status:-unknown}" >&2
    printf 'Response body:\n%s\n' "${body:-<empty>}" >&2
    if [ -n "$curl_error" ]; then
      printf 'curl error output:\n%s\n' "$curl_error" >&2
    fi
    exit 1
  fi

  client_key="$(printf '%s' "$body" | jq -r '.key // .token // empty')"
  token_id="$(printf '%s' "$body" | jq -r '.token_id // empty')"
  key_dir="${APP_DIR}/client-keys"
  key_file="${key_dir}/${KEY_ALIAS}-$(date +%Y%m%d_%H%M%S).json"
  install -d -m 0700 "$key_dir"
  printf '%s\n' "$body" > "$key_file"
  chmod 0600 "$key_file"

  printf '\nLiteLLM client key created for alias: %s\n\n' "$KEY_ALIAS"
  printf 'key field: client API key (stored in protected response file; not printed)\n'
  printf 'key length: %s\n' "${#client_key}"
  case "$client_key" in
    sk-*) printf 'key prefix: sk-...\n' ;;
    "") printf 'key prefix: MISSING\n' ;;
    *) printf 'key prefix: <unexpected>\n' ;;
  esac
  printf 'token_id: %s\n' "${token_id:-<missing from response>}"
  printf 'protected response file: %s\n\n' "$key_file"
  printf 'Use the response field named "key" as the client API key. "token_id" is not the API key.\n'
}

main() {
  source_env_file "$ENV_FILE"
  load_gateway_env_file
  parse_args "$@"
  collect_settings
  if declare -F sanity_host_banner >/dev/null 2>&1; then
    sanity_host_banner "LiteLLM gateway client-key creation host" "$APP_DIR" "${APP_DIR}/docker-compose.yml"
    sanity_env_report "$ENV_FILE"
    sanity_database_url_password_check "$ENV_FILE" "$REPAIR_DATABASE_URL"
  fi
  create_key
}

main "$@"

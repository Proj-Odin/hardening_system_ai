#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

APP_USER="${APP_USER:-zeroclaw}"
APP_HOME="${APP_HOME:-}"
CONFIG_FILE="${CONFIG_FILE:-}"
LITELLM_BASE_URL="${LITELLM_BASE_URL:-}"
LITELLM_CLIENT_KEY="${LITELLM_CLIENT_KEY:-}"
LITELLM_EMBEDDING_MODEL="${LITELLM_EMBEDDING_MODEL:-embed-nomic}"
CURL_CONNECT_TIMEOUT="${CURL_CONNECT_TIMEOUT:-5}"
CURL_MAX_TIME="${CURL_MAX_TIME:-20}"
CURL_RETRY="${CURL_RETRY:-1}"
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

usage() {
  cat <<'EOF'
Usage: verify-zeroclaw-embedding-safety.sh [options]

Options:
  --user USER                      ZeroClaw account. Default: zeroclaw.
  --config PATH                    Config path. Default: /home/USER/.zeroclaw/config.toml.
  --litellm-base-url URL           LiteLLM OpenAI-compatible base URL, e.g. http://HOST:4000/v1.
  --litellm-client-key KEY         Scoped LiteLLM client key.
  --embedding-model MODEL          Embedding model to test. Default: embed-nomic.
  -h, --help                       Show this help.

Environment:
  LITELLM_BASE_URL, LITELLM_CLIENT_KEY, LITELLM_EMBEDDING_MODEL may also be used.
  CURL_CONNECT_TIMEOUT, CURL_MAX_TIME, CURL_RETRY tune bounded network checks.
EOF
}

die_arg() {
  die "$1 requires a value"
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --user)
        shift
        [ "$#" -gt 0 ] || die_arg "--user"
        APP_USER="$1"
        ;;
      --config)
        shift
        [ "$#" -gt 0 ] || die_arg "--config"
        CONFIG_FILE="$1"
        ;;
      --litellm-base-url)
        shift
        [ "$#" -gt 0 ] || die_arg "--litellm-base-url"
        LITELLM_BASE_URL="$1"
        ;;
      --litellm-client-key)
        shift
        [ "$#" -gt 0 ] || die_arg "--litellm-client-key"
        LITELLM_CLIENT_KEY="$1"
        ;;
      --embedding-model)
        shift
        [ "$#" -gt 0 ] || die_arg "--embedding-model"
        LITELLM_EMBEDDING_MODEL="$1"
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *) die "Unknown option: $1" ;;
    esac
    shift
  done
}

resolve_paths() {
  if [ -z "$APP_HOME" ]; then
    APP_HOME="$(getent passwd "$APP_USER" 2>/dev/null | awk -F: '{print $6}' || true)"
    [ -n "$APP_HOME" ] || APP_HOME="/home/${APP_USER}"
  fi
  [ -n "$CONFIG_FILE" ] || CONFIG_FILE="${APP_HOME}/.zeroclaw/config.toml"
}

toml_section_value() {
  local section="$1"
  local key="$2"
  [ -f "$CONFIG_FILE" ] || return 0
  awk -v section="$section" -v key="$key" '
    /^[[:space:]]*\[[^]]+\][[:space:]]*($|#)/ {
      current = $0
      sub(/^[[:space:]]*\[/, "", current)
      sub(/\][[:space:]]*($|#).*/, "", current)
      in_section = (current == section)
      next
    }
    in_section && $0 ~ "^[[:space:]]*" key "[[:space:]]*=" {
      sub(/^[^=]*=/, "")
      sub(/[[:space:]]+#.*$/, "")
      gsub(/^[[:space:]]+|[[:space:]]+$/, "")
      gsub(/^"|"$/, "")
      print
      exit
    }
  ' "$CONFIG_FILE"
}

print_memory_config() {
  if [ ! -f "$CONFIG_FILE" ]; then
    warn_check "ZeroClaw config not found: $CONFIG_FILE"
    return
  fi

  printf 'ZeroClaw config: %s\n' "$CONFIG_FILE"
  printf '[memory]\n'
  printf 'backend = %s\n' "$(toml_section_value memory backend)"
  printf 'auto_save = %s\n' "$(toml_section_value memory auto_save)"
  printf 'embedding_provider = %s\n' "$(toml_section_value memory embedding_provider)"
  printf 'embedding_model = %s\n' "$(toml_section_value memory embedding_model)"
  printf 'embedding_dimensions = %s\n' "$(toml_section_value memory embedding_dimensions)"
}

json_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

test_text_embedding() {
  if [ -z "$LITELLM_BASE_URL" ] || [ -z "$LITELLM_CLIENT_KEY" ]; then
    warn_check "Skipping LiteLLM embedding check; set LITELLM_BASE_URL and LITELLM_CLIENT_KEY."
    return
  fi
  command -v curl >/dev/null 2>&1 || die "curl is required for LiteLLM embedding check"

  local base_url model body tmp http_status
  base_url="${LITELLM_BASE_URL%/}"
  model="$(json_escape "$LITELLM_EMBEDDING_MODEL")"
  body="{\"model\":\"${model}\",\"input\":\"zeroclaw text-only embedding safety test\"}"
  tmp="$(mktemp)"
  trap 'rm -f "$tmp"' EXIT

  http_status="$(curl -sS \
    --connect-timeout "$CURL_CONNECT_TIMEOUT" \
    --max-time "$CURL_MAX_TIME" \
    --retry "$CURL_RETRY" \
    --retry-delay 0 \
    -o "$tmp" \
    -w '%{http_code}' \
    -H "Authorization: Bearer ${LITELLM_CLIENT_KEY}" \
    -H "Content-Type: application/json" \
    -d "$body" \
    "${base_url}/embeddings" || true)"

  case "$http_status" in
    2??)
      if grep -q '"embedding"' "$tmp"; then
        pass_check "LiteLLM text-only embedding succeeded for ${LITELLM_EMBEDDING_MODEL}"
      else
        fail_check "LiteLLM embedding response was HTTP ${http_status} but did not include an embedding"
      fi
      ;;
    000|"")
      fail_check "LiteLLM embedding endpoint unreachable or timed out after ${CURL_MAX_TIME}s max-time. URL: ${base_url}/embeddings"
      ;;
    *)
      fail_check "LiteLLM text-only embedding failed with HTTP ${http_status}. Response: $(head -c 300 "$tmp")"
      ;;
  esac
}

print_embedding_safety_notice() {
  printf '%s\n' "Refusing to send image/base64/image_url payloads to /v1/embeddings."
  printf '%s\n' "Image payloads should be tested through the vision/chat path, not the embedding path."
}

main() {
  parse_args "$@"
  resolve_paths
  print_memory_config
  test_text_embedding
  print_embedding_safety_notice

  if [ "$FAILURES" -gt 0 ]; then
    printf '[FAIL] %s check(s) failed.\n' "$FAILURES" >&2
    exit 1
  fi
  pass_check "Embedding safety verification completed without sending media payloads to embeddings."
}

main "$@"

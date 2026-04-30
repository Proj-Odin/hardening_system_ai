#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

APP_DIR="${APP_DIR:-/opt/litellm-gateway}"
ENV_FILE="${APP_DIR}/.env"
COMPOSE_FILE="${APP_DIR}/docker-compose.yml"
COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-}"
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

load_env() {
  local env_project
  local env_port
  local env_bind
  local env_master_key
  env_project="$(get_env_value COMPOSE_PROJECT_NAME)"
  env_port="$(get_env_value LITELLM_PORT)"
  env_bind="$(get_env_value BIND_ADDR)"
  env_master_key="$(get_env_value LITELLM_MASTER_KEY)"
  COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-${env_project:-litellm-gateway}}"
  LITELLM_PORT="${LITELLM_PORT:-${env_port:-4000}}"
  BIND_ADDR="${BIND_ADDR:-${env_bind:-0.0.0.0}}"
  LITELLM_MASTER_KEY="${LITELLM_MASTER_KEY:-$env_master_key}"
  SKIP_PROVIDER_TEST="${SKIP_PROVIDER_TEST:-0}"
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

check_env_permissions() {
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

endpoint_host() {
  if [ "$BIND_ADDR" = "0.0.0.0" ] || [ "$BIND_ADDR" = "::" ]; then
    printf '127.0.0.1\n'
  else
    printf '%s\n' "$BIND_ADDR"
  fi
}

check_http() {
  local host
  local base
  host="$(endpoint_host)"
  base="http://${host}:${LITELLM_PORT}"

  if curl -fsS "${base}/health" >/dev/null; then
    pass_check "LiteLLM health endpoint responded"
  else
    fail_check "LiteLLM health endpoint failed: ${base}/health"
  fi

  if [ -n "${LITELLM_MASTER_KEY:-}" ]; then
    if curl -fsS -H "Authorization: Bearer ${LITELLM_MASTER_KEY}" "${base}/v1/models" >/dev/null; then
      pass_check "OpenAI-compatible /v1/models responded with master key"
    else
      fail_check "OpenAI-compatible /v1/models request failed"
    fi

    if [ "$SKIP_PROVIDER_TEST" = "1" ]; then
      warn_check "Skipping routed OpenRouter test because SKIP_PROVIDER_TEST=1"
    elif curl -fsS \
      -H "Authorization: Bearer ${LITELLM_MASTER_KEY}" \
      -H "Content-Type: application/json" \
      -d '{"model":"openrouter-auto","messages":[{"role":"user","content":"Reply with ok."}],"max_tokens":8}' \
      "${base}/v1/chat/completions" >/dev/null; then
      pass_check "LiteLLM routed a tiny OpenRouter chat completion test"
    else
      fail_check "LiteLLM OpenRouter chat completion test failed"
    fi
  else
    fail_check "LITELLM_MASTER_KEY missing from environment"
  fi
}

print_endpoint() {
  local vm_ip
  vm_ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  printf '\nLocal endpoint for clients:\n  http://%s:%s/v1\n' "${vm_ip:-<vm-ip>}" "$LITELLM_PORT"
}

main() {
  load_env
  command -v docker >/dev/null 2>&1 || fail_check "docker is not installed"
  [ -f "$COMPOSE_FILE" ] || fail_check "compose file missing: $COMPOSE_FILE"
  [ "$FAILURES" -eq 0 ] || exit 1

  check_compose_status
  check_health
  check_ports
  check_compose_pinning
  check_env_permissions
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

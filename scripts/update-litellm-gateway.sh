#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

APP_DIR="${APP_DIR:-/opt/litellm-gateway}"
ENV_FILE="${APP_DIR}/.env"
GATEWAY_ENV_FILE="${APP_DIR}/gateway.env"
COMPOSE_FILE="${APP_DIR}/docker-compose.yml"
CONFIG_FILE="${APP_DIR}/config/config.yaml"
BACKUP_ROOT="${APP_DIR}/backups"
LOG_DIR="/var/log/litellm-gateway"
COSIGN_KEY_URL="${COSIGN_KEY_URL:-https://raw.githubusercontent.com/BerriAI/litellm/0112e53046018d726492c814b3644b7d376029d0/cosign.pub}"
COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-}"
LITELLM_IMAGE="${LITELLM_IMAGE:-}"
SKIP_COSIGN=0
LOGFILE=""

on_error() {
  echo "ERROR: command failed at line $1: $2" >&2
  [ -z "$LOGFILE" ] || echo "Review log: $LOGFILE" >&2
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
Usage: update-litellm-gateway.sh --image IMAGE [--skip-cosign]

Requires an explicit stable LITELLM_IMAGE target. Refuses latest/nightly/dev
tags, verifies the image with cosign, resolves an immutable digest, backs up
metadata, updates docker-compose.yml, and rolls back if verification fails.
EOF
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --image)
        shift
        [ "$#" -gt 0 ] || die "--image requires a value"
        LITELLM_IMAGE="$1"
        ;;
      --skip-cosign)
        SKIP_COSIGN=1
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

setup_logging() {
  mkdir -p "$LOG_DIR"
  LOGFILE="${LOG_DIR}/update-$(date +%Y%m%d_%H%M%S).log"
  touch "$LOGFILE"
  chmod 0600 "$LOGFILE"
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

get_env_value() {
  get_file_value "$ENV_FILE" "$1"
}

get_gateway_value() {
  get_file_value "$GATEWAY_ENV_FILE" "$1"
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

load_settings() {
  local env_project
  env_project="$(get_gateway_value COMPOSE_PROJECT_NAME)"
  [ -n "$env_project" ] || env_project="$(get_env_value COMPOSE_PROJECT_NAME)"
  COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-${env_project:-litellm-gateway}}"
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
  local tag
  local lower
  if [[ "$1" == *@sha256:* ]]; then
    return 0
  fi
  tag="$(image_tag "$1")"
  [ -n "$tag" ] || die "LITELLM_IMAGE must include an explicit tag."
  lower="$(printf '%s' "$tag" | tr '[:upper:]' '[:lower:]')"
  case "$lower" in
    *latest*|*main-latest*|*nightly*|*dev*)
      die "Refusing unsafe LiteLLM tag '$tag'. Use a signed stable tag."
      ;;
  esac
}

confirm_skip_cosign() {
  [ "$SKIP_COSIGN" -eq 1 ] || return 0
  cat >&2 <<'EOF'

**********************************************************************
SUPPLY CHAIN WARNING
You passed --skip-cosign. This disables image signature verification.
Use only in an isolated lab.
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
  log "cosign verify --key ${COSIGN_KEY_URL} ${ref}"
  cosign verify --key "$COSIGN_KEY_URL" "$ref" >/dev/null
}

pull_and_resolve_digest() {
  local ref="$1"
  local repo
  local digest_ref

  log "Pulling LiteLLM image: $ref"
  docker pull "$ref" >&2
  repo="$(image_repo "$ref")"
  digest_ref="$(docker image inspect "$ref" --format '{{json .RepoDigests}}' | jq -r --arg repo "$repo" '.[] | select(startswith($repo + "@sha256:"))' | head -n1)"
  [ -n "$digest_ref" ] || die "Unable to resolve digest for $ref"
  printf '%s\n' "$digest_ref"
}

backup_metadata() {
  local stamp
  local dir
  stamp="$(date +%Y%m%d_%H%M%S)"
  dir="${BACKUP_ROOT}/pre-update-${stamp}"
  mkdir -p "$dir"
  [ -f "$COMPOSE_FILE" ] || die "Missing compose file: $COMPOSE_FILE"
  cp -a "$COMPOSE_FILE" "$dir/docker-compose.yml"
  [ -f "$CONFIG_FILE" ] && cp -a "$CONFIG_FILE" "$dir/config.yaml"
  [ -f "$GATEWAY_ENV_FILE" ] && cp -a "$GATEWAY_ENV_FILE" "$dir/gateway.env"
  [ -f "$ENV_FILE" ] && cp -a "$ENV_FILE" "$dir/env.SENSITIVE"
  chmod -R go-rwx "$dir"
  log "Backed up update metadata: $dir"
  printf '%s\n' "$dir"
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
  [ -f "$CONFIG_FILE" ] || return 0
  ids="$(resolve_image_uid_gid "$image")"
  chown "$ids" "$CONFIG_FILE"
  chmod 0640 "$CONFIG_FILE"
  log "Set config.yaml owner to container UID:GID ${ids} and mode 0640."
}

litellm_image_from_compose() {
  local file="$1"
  awk '
    /^  litellm:/ { in_litellm=1; next }
    /^  [a-zA-Z0-9_-]+:/ && $0 !~ /^  litellm:/ { in_litellm=0 }
    in_litellm && /^[[:space:]]*image:/ {
      sub(/^[[:space:]]*image:[[:space:]]*/, "")
      print
      exit
    }
  ' "$file"
}

replace_litellm_image() {
  local digest_ref="$1"
  local tmp
  tmp="$(mktemp)"
  awk -v digest="$digest_ref" '
    BEGIN { in_litellm=0; replaced=0 }
    /^  litellm:/ { in_litellm=1; print; next }
    /^  [a-zA-Z0-9_-]+:/ && $0 !~ /^  litellm:/ { in_litellm=0 }
    in_litellm && /^[[:space:]]*image:/ && replaced==0 {
      sub(/image:.*/, "image: " digest)
      replaced=1
    }
    { print }
    END { if (replaced != 1) exit 42 }
  ' "$COMPOSE_FILE" > "$tmp" || {
    rm -f "$tmp"
    die "Unable to replace LiteLLM image in compose file."
  }
  cp "$tmp" "$COMPOSE_FILE"
  rm -f "$tmp"
  chmod 0640 "$COMPOSE_FILE"
  log "Updated compose LiteLLM image to $digest_ref"
}

compose_up() {
  (cd "$APP_DIR" && docker compose -p "$COMPOSE_PROJECT_NAME" up -d)
}

rollback() {
  local backup_dir="$1"
  local previous_image
  warn "Rolling back compose file from $backup_dir"
  cp -a "${backup_dir}/docker-compose.yml" "$COMPOSE_FILE"
  previous_image="$(litellm_image_from_compose "$COMPOSE_FILE")"
  [ -z "$previous_image" ] || align_config_permissions_for_image "$previous_image"
  compose_up || warn "Rollback compose up failed; manual intervention required."
}

main() {
  parse_args "$@"
  require_root
  setup_logging
  load_settings
  [ -n "$LITELLM_IMAGE" ] || die "Set LITELLM_IMAGE or pass --image. Updates require an explicit target."
  command -v docker >/dev/null 2>&1 || die "docker is required."
  command -v jq >/dev/null 2>&1 || die "jq is required."
  command -v cosign >/dev/null 2>&1 || [ "$SKIP_COSIGN" -eq 1 ] || die "cosign is required."
  ensure_litellm_ghcr_image "$LITELLM_IMAGE"
  refuse_bad_image_tag "$LITELLM_IMAGE"
  confirm_skip_cosign

  local digest_ref
  local backup_dir
  digest_ref="$(pull_and_resolve_digest "$LITELLM_IMAGE")"
  cosign_verify_image "$LITELLM_IMAGE"
  cosign_verify_image "$digest_ref"
  backup_dir="$(backup_metadata)"
  align_config_permissions_for_image "$digest_ref"
  replace_litellm_image "$digest_ref"
  compose_up

  if ! "${APP_DIR}/verify-litellm-gateway.sh"; then
    rollback "$backup_dir"
    die "Update verification failed; compose file was rolled back."
  fi

  log "LiteLLM gateway update complete: $digest_ref"
}

main "$@"

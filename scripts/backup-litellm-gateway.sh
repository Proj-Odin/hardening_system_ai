#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

APP_DIR="${APP_DIR:-/opt/litellm-gateway}"
ENV_FILE="${APP_DIR}/.env"
COMPOSE_FILE="${APP_DIR}/docker-compose.yml"
CONFIG_FILE="${APP_DIR}/config/config.yaml"
BACKUP_ROOT="${APP_DIR}/backups"
COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-}"
SMB_SHARE="${SMB_SHARE:-}"
SMB_CREDS="${SMB_CREDS:-}"
SMB_REMOTE_DIR="${SMB_REMOTE_DIR:-litellm-gateway}"

on_error() {
  printf 'ERROR: command failed at line %s: %s\n' "$1" "$2" >&2
}
trap 'on_error "$LINENO" "$BASH_COMMAND"' ERR

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
  local env_pg_user
  local env_pg_db
  local env_pg_password
  env_project="$(get_env_value COMPOSE_PROJECT_NAME)"
  env_pg_user="$(get_env_value POSTGRES_USER)"
  env_pg_db="$(get_env_value POSTGRES_DB)"
  env_pg_password="$(get_env_value POSTGRES_PASSWORD)"
  COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-${env_project:-litellm-gateway}}"
  POSTGRES_USER="${POSTGRES_USER:-${env_pg_user:-litellm}}"
  POSTGRES_DB="${POSTGRES_DB:-${env_pg_db:-litellm}}"
  POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-$env_pg_password}"
}

compose() {
  (cd "$APP_DIR" && docker compose -p "$COMPOSE_PROJECT_NAME" "$@")
}

copy_metadata() {
  local dest="$1"
  mkdir -p "${dest}/config" "${dest}/db"
  [ -f "$COMPOSE_FILE" ] && cp -a "$COMPOSE_FILE" "${dest}/docker-compose.yml"
  [ -f "$CONFIG_FILE" ] && cp -a "$CONFIG_FILE" "${dest}/config/config.yaml"

  if [ -f "$ENV_FILE" ]; then
    if command -v gpg >/dev/null 2>&1 && [ -n "${BACKUP_GPG_RECIPIENT:-}" ]; then
      gpg --batch --yes --recipient "$BACKUP_GPG_RECIPIENT" --encrypt --output "${dest}/env.gpg" "$ENV_FILE"
      printf 'Encrypted .env to env.gpg for recipient %s\n' "$BACKUP_GPG_RECIPIENT" > "${dest}/ENV_README.txt"
    else
      cp -a "$ENV_FILE" "${dest}/env.SENSITIVE"
      chmod 0600 "${dest}/env.SENSITIVE"
      cat > "${dest}/ENV_README.txt" <<'EOF'
env.SENSITIVE contains LiteLLM, provider, and database secrets.
Protect it like a password vault. Prefer BACKUP_GPG_RECIPIENT for encrypted backups.
EOF
    fi
  fi
}

dump_postgres() {
  local dest="$1"
  log "Creating Postgres dump"
  if compose exec -T -e PGPASSWORD="${POSTGRES_PASSWORD:-}" postgres pg_dump -U "${POSTGRES_USER:-litellm}" -d "${POSTGRES_DB:-litellm}" > "${dest}/db/litellm.sql"; then
    gzip -9 "${dest}/db/litellm.sql"
  else
    warn "Postgres dump failed; backup will contain metadata only."
    rm -f "${dest}/db/litellm.sql"
  fi
}

write_manifest() {
  local dest="$1"
  cat > "${dest}/manifest.txt" <<EOF
LiteLLM Gateway backup
Created: $(date -Is)
Host: $(hostname -f 2>/dev/null || hostname)
App dir: ${APP_DIR}
Includes:
- docker-compose.yml
- config/config.yaml
- env.SENSITIVE or env.gpg when present
- db/litellm.sql.gz when Postgres dump succeeds
EOF
  (cd "$dest" && find . -type f -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS.txt)
}

make_tarball() {
  local dest="$1"
  local tarball="${dest}/litellm-gateway-backup.tar.gz"
  tar -C "$dest" --exclude "./litellm-gateway-backup.tar.gz" -czf "$tarball" .
  (cd "$dest" && sha256sum litellm-gateway-backup.tar.gz >> SHA256SUMS.txt)
}

smbclient_run() {
  local command_string="$1"
  smbclient "$SMB_SHARE" -A "$SMB_CREDS" -c "$command_string"
}

ensure_remote_dir() {
  local remote="$1"
  local current=""
  local part
  local -a parts
  IFS='/' read -r -a parts <<< "$remote"
  for part in "${parts[@]}"; do
    [ -n "$part" ] || continue
    if [ -z "$current" ]; then
      current="$part"
    else
      current="${current}/${part}"
    fi
    smbclient_run "mkdir ${current}" >/dev/null 2>&1 || true
  done
}

upload_smbclient() {
  local dest="$1"
  local timestamp="$2"
  local remote="${SMB_REMOTE_DIR%/}/${timestamp}"

  [ -n "$SMB_SHARE" ] || return 0
  [ -n "$SMB_CREDS" ] || die "SMB_CREDS is required when SMB_SHARE is set."
  [ -r "$SMB_CREDS" ] || die "SMB_CREDS is not readable: $SMB_CREDS"
  command -v smbclient >/dev/null 2>&1 || die "smbclient is required for SMB upload."

  log "Uploading backup to SMB: ${SMB_SHARE}/${remote}"
  ensure_remote_dir "$remote"
  smbclient_run "lcd ${dest}; cd ${remote}; put manifest.txt; put SHA256SUMS.txt; put litellm-gateway-backup.tar.gz"
  smbclient_run "cd ${remote}; ls" >/dev/null
}

main() {
  [ "${EUID}" -eq 0 ] || die "Run as root so Docker/Postgres backup and .env access work."
  command -v docker >/dev/null 2>&1 || die "docker is required."
  load_env

  local timestamp
  local dest
  timestamp="$(date +%Y%m%d_%H%M%S)"
  dest="${BACKUP_ROOT}/${timestamp}"
  mkdir -p "$dest"
  chmod 0700 "$dest"

  copy_metadata "$dest"
  dump_postgres "$dest"
  write_manifest "$dest"
  make_tarball "$dest"
  upload_smbclient "$dest" "$timestamp"

  log "Backup complete: $dest"
}

main "$@"

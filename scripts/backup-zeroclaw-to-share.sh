#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

# Backup a ZeroClaw install to a mounted share. The SQLite database is copied
# with sqlite3's native .backup command so this is safe to run while SQLite is
# active. The full tarball may still reflect live file state if ZeroClaw is
# running.

trim_space() {
  local value="$1"

  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s\n' "$value"
}

strip_simple_quotes() {
  local value="$1"

  if [[ "$value" == \"*\" && "$value" == *\" && ${#value} -ge 2 ]]; then
    value="${value:1:${#value}-2}"
  elif [[ "$value" == \'*\' && "$value" == *\' && ${#value} -ge 2 ]]; then
    value="${value:1:${#value}-2}"
  fi

  printf '%s\n' "$value"
}

load_backup_env_file() {
  local env_file="$1"
  local line
  local name
  local value

  [ -f "$env_file" ] || return 0

  while IFS= read -r line || [ -n "$line" ]; do
    line="$(trim_space "$line")"

    case "$line" in
      "" | \#*) continue ;;
    esac

    line="${line#export }"

    case "$line" in
      *=*) ;;
      *) continue ;;
    esac

    name="$(trim_space "${line%%=*}")"
    value="$(trim_space "${line#*=}")"
    value="$(strip_simple_quotes "$value")"

    [[ "$name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue

    case "$name" in
      ZC_USER | ZC_HOME | ZC_DIR | DEST_ROOT | SHARE_MOUNT | REQUIRE_MOUNT | RETENTION_DAYS | DB_PATH | DRY_RUN | AUTO_INSTALL_DEPS | DEST_MODE | SMB_URL | SMB_USER | SMB_CREDENTIALS)
        ;;
      *) continue ;;
    esac

    if [ "${!name+x}" = "x" ]; then
      continue
    fi

    printf -v "$name" '%s' "$value"
  done < "$env_file"
}

expand_home_path() {
  local path="$1"
  local home="${HOME:-/home/admin}"

  case "$path" in
    "~") printf '%s\n' "$home" ;;
    "~/"*) printf '%s/%s\n' "$home" "${path#~/}" ;;
    *) printf '%s\n' "$path" ;;
  esac
}

BACKUP_ENV_FILE="${BACKUP_ENV_FILE:-${HOME:-/home/admin}/.zeroclaw-backup.env}"
BACKUP_ENV_FILE="$(expand_home_path "$BACKUP_ENV_FILE")"
load_backup_env_file "$BACKUP_ENV_FILE"

ZC_USER="${ZC_USER:-admin}"
ZC_HOME="${ZC_HOME:-/home/${ZC_USER}}"
ZC_DIR="${ZC_DIR:-${ZC_HOME}/.zeroclaw}"
DEST_ROOT="${DEST_ROOT:-/mnt/share/zeroclaw-backups}"
SHARE_MOUNT="${SHARE_MOUNT:-/mnt/share}"
REQUIRE_MOUNT="${REQUIRE_MOUNT:-1}"
RETENTION_DAYS="${RETENTION_DAYS:-30}"
DB_PATH="${DB_PATH:-}"
DRY_RUN="${DRY_RUN:-0}"
AUTO_INSTALL_DEPS="${AUTO_INSTALL_DEPS:-0}"
DEST_MODE="${DEST_MODE:-mount}"
SMB_URL="${SMB_URL:-}"
SMB_USER="${SMB_USER:-}"
SMB_CREDENTIALS="${SMB_CREDENTIALS:-/etc/smbcredentials/truenas-zeroclaw}"
LOCK_DIR="${LOCK_DIR:-/tmp/zeroclaw-backup.lock}"

REQUIRED_COMMANDS=(bash sqlite3 tar gzip find sha256sum awk)
ALPINE_PACKAGES=(bash sqlite tar gzip findutils coreutils)
SMB_CREDENTIALS_FILE="$SMB_CREDENTIALS"

trim_trailing_slashes() {
  local value="$1"

  while [ "$value" != "/" ] && [ "${value%/}" != "$value" ]; do
    value="${value%/}"
  done

  printf '%s\n' "$value"
}

refresh_derived_paths() {
  ZC_HOME="$(trim_trailing_slashes "$ZC_HOME")"
  ZC_DIR="$(trim_trailing_slashes "$ZC_DIR")"
  DEST_ROOT="$(trim_trailing_slashes "$DEST_ROOT")"
  SHARE_MOUNT="$(trim_trailing_slashes "$SHARE_MOUNT")"
  SMB_URL="$(trim_trailing_slashes "$SMB_URL")"

  if [ "$DEST_MODE" = "smbclient" ]; then
    DEST_HOST_DIR="${SMB_URL}/${HOST}"
    FINAL_DIR="${DEST_HOST_DIR}/${TIMESTAMP}"
    TMP_DIR="/tmp/zeroclaw-backup.${HOST}.${TIMESTAMP}"
  else
    DEST_HOST_DIR="${DEST_ROOT}/${HOST}"
    FINAL_DIR="${DEST_HOST_DIR}/${TIMESTAMP}"
    TMP_DIR="${FINAL_DIR}.tmp"
  fi
}

HOST="${HOST:-$(hostname 2>/dev/null || printf 'unknown-host')}"
TIMESTAMP="${TIMESTAMP:-$(date '+%Y%m%d_%H%M%S')}"
DEST_HOST_DIR=""
FINAL_DIR=""
TMP_DIR=""
refresh_derived_paths

LOCK_HELD=0
TMP_CREATED=0
FINALIZED=0
PRESERVE_TMP_ON_ERROR=0

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S%z')" "$*"
}

warn() {
  log "WARN: $*"
}

fail() {
  log "ERROR: $*"
  exit 1
}

cleanup() {
  local status=$?

  if [ "$status" -ne 0 ] && [ "$TMP_CREATED" = "1" ] && [ "$FINALIZED" != "1" ] && [ -n "${TMP_DIR:-}" ] && [ -d "$TMP_DIR" ]; then
    if [ "$PRESERVE_TMP_ON_ERROR" = "1" ]; then
      warn "Leaving local backup in place after failure: $TMP_DIR"
    else
      log "Removing incomplete temporary backup: $TMP_DIR"
      rm -rf "$TMP_DIR" || true
    fi
  fi

  if [ "$LOCK_HELD" = "1" ]; then
    rmdir "$LOCK_DIR" 2>/dev/null || true
  fi

  exit "$status"
}

trap cleanup EXIT

usage() {
  cat <<'USAGE'
Usage:
  backup-zeroclaw-to-share.sh
  backup-zeroclaw-to-share.sh --setup-truenas
  backup-zeroclaw-to-share.sh --smbclient-upload
  backup-zeroclaw-to-share.sh --help

Default mode backs up ZeroClaw to DEST_ROOT after confirming SHARE_MOUNT is
mounted when REQUIRE_MOUNT=1.

SMB client upload mode builds the backup under /tmp and uploads it to SMB_URL
without requiring Linux mount capabilities.

Setup mode starts an interactive TrueNAS NFS/SMB mount wizard.
USAGE
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1
}

missing_commands() {
  local cmd

  for cmd in "${REQUIRED_COMMANDS[@]}"; do
    if ! require_cmd "$cmd"; then
      printf '%s\n' "$cmd"
    fi
  done

  if [ "${DEST_MODE:-mount}" = "smbclient" ] && ! require_cmd smbclient; then
    printf 'smbclient\n'
  fi
}

contains_missing_command() {
  local missing="$1"
  local command_name="$2"

  case $'\n'"$missing"$'\n' in
    *$'\n'"$command_name"$'\n'*) return 0 ;;
    *) return 1 ;;
  esac
}

join_words() {
  local out=""
  local word

  for word in "$@"; do
    if [ -n "$out" ]; then
      out="${out} ${word}"
    else
      out="$word"
    fi
  done

  printf '%s\n' "$out"
}

print_apk_install_line() {
  log "  sudo apk add --no-cache $(join_words "$@")"
}

log_missing_commands() {
  local missing="$1"
  local cmd

  log "Missing required command(s):"
  while IFS= read -r cmd; do
    [ -n "$cmd" ] || continue
    log "  - $cmd"
  done <<< "$missing"
}

print_alpine_dependency_help() {
  local missing="$1"
  local packages=("${ALPINE_PACKAGES[@]}")

  if contains_missing_command "$missing" "sqlite3"; then
    log "Install sqlite3 on Alpine with:"
    print_apk_install_line sqlite
  fi

  if contains_missing_command "$missing" "smbclient"; then
    log "Install smbclient upload support on Alpine with:"
    print_apk_install_line samba-client
    packages+=(samba-client)
  fi

  log "Full recommended Alpine package command:"
  print_apk_install_line "${packages[@]}"
}

is_alpine_linux() {
  [ -f /etc/alpine-release ] || require_cmd apk
}

print_manual_apk_command() {
  log "Manual Alpine install command:"
  print_apk_install_line "$@"
}

print_privileged_command() {
  local arg

  printf '  '
  for arg in "$@"; do
    printf '%q ' "$arg"
  done
  printf '\n'
}

run_privileged() {
  if [ "${EUID:-1}" -eq 0 ]; then
    "$@"
  elif require_cmd sudo; then
    sudo "$@"
  else
    log "ERROR: This action requires root privileges and sudo is not available"
    log "Run this command manually as root:"
    print_privileged_command "$@"
    return 1
  fi
}

install_alpine_packages() {
  local packages=("$@")

  if ! is_alpine_linux; then
    fail "This installer is Alpine-focused and will not attempt apt/yum/dnf installs"
  fi

  if ! require_cmd apk; then
    print_manual_apk_command "${packages[@]}"
    fail "Alpine Linux detected, but apk was not found in PATH"
  fi

  if [ "${EUID:-1}" -ne 0 ] && ! require_cmd sudo; then
    print_manual_apk_command "${packages[@]}"
    fail "Not running as root and sudo is not available"
  fi

  run_privileged apk add --no-cache "${packages[@]}"
}

install_deps_alpine() {
  local missing="$1"
  local packages=("${ALPINE_PACKAGES[@]}")

  if ! is_alpine_linux; then
    log "ERROR: AUTO_INSTALL_DEPS=1 requested, but this does not appear to be Alpine Linux"
    log_missing_commands "$missing"
    print_alpine_dependency_help "$missing"
    exit 1
  fi

  if ! require_cmd apk; then
    log "ERROR: Alpine Linux detected, but apk was not found in PATH"
    print_alpine_dependency_help "$missing"
    exit 1
  fi

  if contains_missing_command "$missing" "smbclient"; then
    packages+=(samba-client)
  fi

  if [ "${EUID:-1}" -eq 0 ]; then
    log "AUTO_INSTALL_DEPS=1; installing missing Alpine backup dependencies with apk"
    apk add --no-cache "${packages[@]}"
  elif require_cmd sudo; then
    log "AUTO_INSTALL_DEPS=1; installing missing Alpine backup dependencies with sudo apk"
    sudo apk add --no-cache "${packages[@]}"
  else
    log "ERROR: AUTO_INSTALL_DEPS=1 requested, but the script is not running as root and sudo is not available"
    log_missing_commands "$missing"
    print_alpine_dependency_help "$missing"
    exit 1
  fi
}

validate_or_install_deps() {
  local missing

  if [ "$AUTO_INSTALL_DEPS" != "0" ] && [ "$AUTO_INSTALL_DEPS" != "1" ]; then
    fail "AUTO_INSTALL_DEPS must be 0 or 1: $AUTO_INSTALL_DEPS"
  fi

  missing="$(missing_commands)"
  if [ -z "$missing" ]; then
    return
  fi

  log_missing_commands "$missing"

  if [ "$AUTO_INSTALL_DEPS" = "1" ]; then
    install_deps_alpine "$missing"

    missing="$(missing_commands)"
    if [ -n "$missing" ]; then
      log "ERROR: Dependency installation finished, but required command(s) are still missing"
      log_missing_commands "$missing"
      print_alpine_dependency_help "$missing"
      exit 1
    fi

    log "Dependency validation passed after Alpine package installation"
    return
  fi

  print_alpine_dependency_help "$missing"
  fail "Install missing dependencies, or rerun with AUTO_INSTALL_DEPS=1 on Alpine Linux"
}

validate_smb_path_component() {
  local value="$1"
  local label="$2"

  if [[ ! "$value" =~ ^[A-Za-z0-9._-]+$ ]]; then
    fail "$label must contain only letters, numbers, dots, underscores, and dashes in smbclient mode: $value"
  fi
}

validate_settings() {
  case "$HOST" in
    "" | */*) fail "HOST must be non-empty and cannot contain '/'" ;;
  esac

  case "$ZC_HOME" in
    /*) ;;
    *) fail "ZC_HOME must be an absolute path: $ZC_HOME" ;;
  esac

  case "$ZC_DIR" in
    /*) ;;
    *) fail "ZC_DIR must be an absolute path: $ZC_DIR" ;;
  esac

  [[ "$RETENTION_DAYS" =~ ^[0-9]+$ ]] || fail "RETENTION_DAYS must be a non-negative integer: $RETENTION_DAYS"

  if [ "$DRY_RUN" != "0" ] && [ "$DRY_RUN" != "1" ]; then
    fail "DRY_RUN must be 0 or 1: $DRY_RUN"
  fi

  case "$DEST_MODE" in
    mount | smbclient) ;;
    *) fail "DEST_MODE must be mount or smbclient: $DEST_MODE" ;;
  esac

  if [ ! -d "$ZC_DIR" ]; then
    fail "ZeroClaw directory does not exist: $ZC_DIR"
  fi

  if [ "$DEST_MODE" = "smbclient" ]; then
    [ -n "$SMB_URL" ] || fail "SMB_URL is required when DEST_MODE=smbclient"
    [ -n "$SMB_USER" ] || fail "SMB_USER is required when DEST_MODE=smbclient"
    [ -n "$SMB_CREDENTIALS" ] || fail "SMB_CREDENTIALS is required when DEST_MODE=smbclient"
    validate_smb_path_component "$HOST" "HOST"
    validate_smb_path_component "$TIMESTAMP" "TIMESTAMP"

    case "$SMB_URL" in
      //*/*) ;;
      *) fail "SMB_URL must look like //server/share: $SMB_URL" ;;
    esac

    case "$SMB_CREDENTIALS" in
      /*) ;;
      *) fail "SMB_CREDENTIALS must be an absolute path: $SMB_CREDENTIALS" ;;
    esac

    if [ ! -r "$SMB_CREDENTIALS" ]; then
      fail "SMB credentials file is not readable by this user: $SMB_CREDENTIALS"
    fi

    return
  fi

  case "$DEST_ROOT" in
    /*) ;;
    *) fail "DEST_ROOT must be an absolute path: $DEST_ROOT" ;;
  esac

  case "$SHARE_MOUNT" in
    /*) ;;
    *) fail "SHARE_MOUNT must be an absolute path: $SHARE_MOUNT" ;;
  esac

  if [ "$REQUIRE_MOUNT" != "0" ] && [ "$REQUIRE_MOUNT" != "1" ]; then
    fail "REQUIRE_MOUNT must be 0 or 1: $REQUIRE_MOUNT"
  fi

  if [ "$REQUIRE_MOUNT" = "1" ] && [ "$SHARE_MOUNT" != "/" ]; then
    case "$DEST_ROOT" in
      "$SHARE_MOUNT" | "$SHARE_MOUNT"/*) ;;
      *) fail "DEST_ROOT must be inside SHARE_MOUNT when REQUIRE_MOUNT=1: DEST_ROOT=$DEST_ROOT SHARE_MOUNT=$SHARE_MOUNT" ;;
    esac
  fi
}

is_path_mounted() {
  local mount_point="$1"

  [ -r /proc/mounts ] || return 1
  awk -v mount_point="$mount_point" '$2 == mount_point { found = 1 } END { exit found ? 0 : 1 }' /proc/mounts
}

mounted_source_for_path() {
  local mount_point="$1"

  [ -r /proc/mounts ] || return 0
  awk -v mount_point="$mount_point" '$2 == mount_point { print $1; exit }' /proc/mounts
}

is_mounted() {
  is_path_mounted "$SHARE_MOUNT"
}

check_mount() {
  if [ "$REQUIRE_MOUNT" = "1" ]; then
    if ! is_mounted; then
      fail "SHARE_MOUNT is not mounted: $SHARE_MOUNT"
    fi
    log "Confirmed mounted share: $SHARE_MOUNT"
  else
    warn "REQUIRE_MOUNT=0; skipping mounted-share check for $SHARE_MOUNT"
  fi
}

acquire_lock() {
  if [ "$DRY_RUN" = "1" ]; then
    log "DRY_RUN=1; would acquire lock: $LOCK_DIR"
    return
  fi

  if mkdir "$LOCK_DIR" 2>/dev/null; then
    LOCK_HELD=1
    log "Acquired backup lock: $LOCK_DIR"
  else
    fail "Another backup appears to be running; lock exists: $LOCK_DIR"
  fi
}

zeroclaw_running() {
  command -v ps >/dev/null 2>&1 || return 1
  ps 2>/dev/null | awk '
    /[z]eroclaw/ && $0 !~ /backup-zeroclaw-to-share\.sh/ { found = 1 }
    END { exit found ? 0 : 1 }
  '
}

detect_db_path() {
  local default_db="${ZC_DIR}/workspace/memory/brain.db"
  local found_db=""

  if [ -n "$DB_PATH" ]; then
    case "$DB_PATH" in
      /*) printf '%s\n' "$DB_PATH" ;;
      *) printf '%s/%s\n' "$PWD" "$DB_PATH" ;;
    esac
    return
  fi

  if [ -f "$default_db" ]; then
    printf '%s\n' "$default_db"
    return
  fi

  found_db="$(find "$ZC_DIR" -type f \( -name '*.db' -o -name '*.sqlite' -o -name '*.sqlite3' \) -print -quit 2>/dev/null || true)"
  printf '%s\n' "$found_db"
}

detect_zeroclaw_version() {
  local output=""

  if command -v zeroclaw >/dev/null 2>&1; then
    output="$(zeroclaw --version 2>/dev/null || true)"
  elif [ -x "${ZC_HOME}/.local/bin/zeroclaw" ]; then
    output="$("${ZC_HOME}/.local/bin/zeroclaw" --version 2>/dev/null || true)"
  elif [ -x "${ZC_HOME}/zeroclaw" ]; then
    output="$("${ZC_HOME}/zeroclaw" --version 2>/dev/null || true)"
  fi

  if [ -n "$output" ]; then
    printf '%s\n' "$output" | awk 'NR == 1 { print; exit }'
  else
    printf 'unavailable\n'
  fi
}

write_manifest() {
  local version="$1"
  local manifest_db_path="${DB_PATH:-not found}"

  {
    printf 'timestamp=%s\n' "$TIMESTAMP"
    printf 'host=%s\n' "$HOST"
    printf 'zc_user=%s\n' "$ZC_USER"
    printf 'zc_home=%s\n' "$ZC_HOME"
    printf 'zc_dir=%s\n' "$ZC_DIR"
    printf 'dest_root=%s\n' "$DEST_ROOT"
    printf 'share_mount=%s\n' "$SHARE_MOUNT"
    printf 'dest_mode=%s\n' "$DEST_MODE"
    printf 'smb_url=%s\n' "${SMB_URL:-}"
    printf 'smb_user=%s\n' "${SMB_USER:-}"
    if [ "$DEST_MODE" = "smbclient" ]; then
      printf 'smb_remote_path=%s\n' "$FINAL_DIR"
    fi
    printf 'retention_days=%s\n' "$RETENTION_DAYS"
    printf 'db_path=%s\n' "$manifest_db_path"
    printf 'zeroclaw_version=%s\n' "$version"
  } > "${TMP_DIR}/manifest.txt"
}

copy_config_if_present() {
  if [ -f "${ZC_DIR}/config.toml" ]; then
    cp "${ZC_DIR}/config.toml" "${TMP_DIR}/config.toml"
    log "Copied config.toml into backup directory"
  else
    warn "No config.toml found at ${ZC_DIR}/config.toml"
  fi
}

backup_sqlite_if_present() {
  local integrity_file="${TMP_DIR}/sqlite_integrity_check.txt"

  if [ -z "$DB_PATH" ] || [ ! -f "$DB_PATH" ]; then
    warn "No SQLite database found; continuing with full ZeroClaw directory backup only"
    {
      printf 'No SQLite database was found under %s.\n' "$ZC_DIR"
      printf 'Checked at %s on host %s.\n' "$TIMESTAMP" "$HOST"
    } > "${TMP_DIR}/WARNING-no-sqlite-db.txt"
    printf 'skipped: no SQLite database found\n' > "$integrity_file"
    return
  fi

  log "Backing up SQLite database with sqlite3 .backup: $DB_PATH"
  (
    cd "$TMP_DIR"
    sqlite3 "$DB_PATH" ".backup 'brain.db.backup'"

    log "Writing readable SQL dump: ${TMP_DIR}/brain.sql"
    sqlite3 "$DB_PATH" ".dump" > "brain.sql"

    log "Running SQLite integrity check on backup copy"
    sqlite3 "brain.db.backup" "PRAGMA integrity_check;" > "sqlite_integrity_check.txt"
  )

  if ! awk '
    NR == 1 && $0 == "ok" { ok = 1; next }
    { bad = 1 }
    END { exit (ok && !bad) ? 0 : 1 }
  ' "$integrity_file"; then
    fail "SQLite backup failed integrity check; see $integrity_file"
  fi

  log "SQLite integrity check passed"
}

create_full_tarball() {
  local zc_parent="${ZC_DIR%/*}"
  local zc_base="${ZC_DIR##*/}"

  if [ -z "$zc_parent" ]; then
    zc_parent="/"
  fi

  log "Creating full ZeroClaw tarball: ${TMP_DIR}/zeroclaw-full.tar.gz"
  tar -C "$zc_parent" -cf - "$zc_base" | gzip -c > "${TMP_DIR}/zeroclaw-full.tar.gz"
}

write_sha256sums() {
  log "Writing SHA256SUMS.txt"
  (
    cd "$TMP_DIR"
    find . -type f ! -name 'SHA256SUMS.txt' -exec sha256sum {} \;
  ) > "${TMP_DIR}/SHA256SUMS.txt"
}

is_timestamp_dir_name() {
  [[ "$1" =~ ^[0-9]{8}_[0-9]{6}$ ]]
}

cleanup_old_backups() {
  local old_dir
  local base

  log "Cleaning timestamped backups older than ${RETENTION_DAYS} days under ${DEST_HOST_DIR}"
  while IFS= read -r old_dir; do
    [ -n "$old_dir" ] || continue
    base="${old_dir##*/}"

    if is_timestamp_dir_name "$base"; then
      log "Removing old backup directory: $old_dir"
      rm -rf "$old_dir" || warn "Failed to remove old backup directory: $old_dir"
    else
      warn "Skipping non-timestamp directory during retention cleanup: $old_dir"
    fi
  done < <(find "$DEST_HOST_DIR" -mindepth 1 -maxdepth 1 -type d -mtime +"$RETENTION_DAYS" -print)
}

dry_run_summary() {
  log "DRY_RUN=1; no backup files will be written"
  if [ "$DEST_MODE" = "smbclient" ]; then
    log "Would create local temporary backup directory: /tmp/zeroclaw-backup.${HOST}.${TIMESTAMP}"
    log "Would upload backup files to SMB path: ${SMB_URL}/${HOST}/${TIMESTAMP}"
  else
    log "Would create temporary backup directory: $TMP_DIR"
    log "Would create final backup directory: $FINAL_DIR"
  fi
  log "Would archive ZeroClaw directory: $ZC_DIR"

  if [ -n "$DB_PATH" ] && [ -f "$DB_PATH" ]; then
    log "Would create SQLite backup and SQL dump from: $DB_PATH"
  else
    warn "Would continue without SQLite backup because no database was found"
  fi

  log "Would write manifest.txt and SHA256SUMS.txt"
  if [ "$DEST_MODE" = "smbclient" ]; then
    log "Would validate upload by listing remote directory: ${HOST}/${TIMESTAMP}"
    log "Would remove the local temporary backup only after upload validation succeeds"
  else
    log "Would clean timestamped backups older than ${RETENTION_DAYS} days under ${DEST_HOST_DIR}"
  fi
}

prepare_backup_inputs() {
  DB_PATH="$(detect_db_path)"

  if zeroclaw_running; then
    warn "ZeroClaw appears to be running; SQLite backup is safe, but the full tarball may capture live file state"
  fi
}

create_backup_artifacts() {
  local zeroclaw_version

  zeroclaw_version="$(detect_zeroclaw_version)"

  write_manifest "$zeroclaw_version"
  copy_config_if_present
  backup_sqlite_if_present
  create_full_tarball
  write_sha256sums
}

run_mounted_backup() {
  check_mount

  if [ "$DRY_RUN" = "1" ]; then
    acquire_lock
    dry_run_summary
    return
  fi

  acquire_lock

  if [ -e "$FINAL_DIR" ]; then
    fail "Final backup directory already exists: $FINAL_DIR"
  fi

  if [ -e "$TMP_DIR" ]; then
    fail "Temporary backup directory already exists: $TMP_DIR"
  fi

  mkdir -p "$DEST_HOST_DIR"
  mkdir "$TMP_DIR"
  TMP_CREATED=1

  create_backup_artifacts

  log "Promoting temporary backup into place: $FINAL_DIR"
  mv "$TMP_DIR" "$FINAL_DIR"
  FINALIZED=1

  cleanup_old_backups

  log "Backup completed successfully: $FINAL_DIR"
  log "Backups contain config.toml when present; protect this share as sensitive storage"
}

smbclient_run() {
  local command_string="$1"

  if [ -n "$SMB_USER" ]; then
    smbclient "$SMB_URL" -A "$SMB_CREDENTIALS" -U "$SMB_USER" -c "$command_string"
  else
    smbclient "$SMB_URL" -A "$SMB_CREDENTIALS" -c "$command_string"
  fi
}

upload_backup_artifacts_smbclient() {
  local remote_host_dir="$HOST"
  local remote_backup_dir="${HOST}/${TIMESTAMP}"
  local file
  local base
  local uploaded_count=0

  log "Uploading backup artifacts to SMB share: $SMB_URL"
  log "Using SMB credentials file: $SMB_CREDENTIALS"
  smbclient_run "mkdir ${remote_host_dir}" >/dev/null 2>&1 || true

  if ! smbclient_run "cd ${remote_host_dir}" >/dev/null; then
    warn "Unable to access remote host directory after mkdir: $remote_host_dir"
    return 1
  fi

  if smbclient_run "cd ${remote_backup_dir}" >/dev/null 2>&1; then
    warn "Remote timestamp directory already exists: $remote_backup_dir"
    return 1
  fi

  if ! smbclient_run "mkdir ${remote_backup_dir}"; then
    warn "Failed to create remote backup directory: $remote_backup_dir"
    return 1
  fi

  while IFS= read -r file; do
    [ -n "$file" ] || continue
    base="${file##*/}"
    log "Uploading artifact: $base"
    if ! smbclient_run "lcd ${TMP_DIR}; cd ${remote_backup_dir}; put ${base}"; then
      warn "Failed to upload artifact: $base"
      return 1
    fi
    uploaded_count=$((uploaded_count + 1))
  done < <(find "$TMP_DIR" -maxdepth 1 -type f -print)

  if [ "$uploaded_count" -eq 0 ]; then
    warn "No backup artifacts were found to upload from $TMP_DIR"
    return 1
  fi

  log "Validating upload by listing remote directory: $remote_backup_dir"
  smbclient_run "cd ${remote_backup_dir}; ls"
}

remove_uploaded_local_tmp() {
  local expected_tmp="/tmp/zeroclaw-backup.${HOST}.${TIMESTAMP}"

  if [ "$TMP_DIR" != "$expected_tmp" ]; then
    fail "Refusing to remove unexpected local temp path: $TMP_DIR"
  fi

  log "Removing local temporary backup after successful SMB upload: $TMP_DIR"
  rm -rf "$TMP_DIR"
  TMP_CREATED=0
}

run_smbclient_backup() {
  TMP_DIR="/tmp/zeroclaw-backup.${HOST}.${TIMESTAMP}"
  FINAL_DIR="${SMB_URL}/${HOST}/${TIMESTAMP}"
  PRESERVE_TMP_ON_ERROR=1

  if [ "$DRY_RUN" = "1" ]; then
    acquire_lock
    dry_run_summary
    return
  fi

  acquire_lock

  if [ -e "$TMP_DIR" ]; then
    fail "Local temporary backup directory already exists: $TMP_DIR"
  fi

  mkdir "$TMP_DIR"
  TMP_CREATED=1

  create_backup_artifacts

  if ! upload_backup_artifacts_smbclient; then
    warn "SMB upload failed; local backup retained at: $TMP_DIR"
    return 1
  fi

  remove_uploaded_local_tmp
  FINALIZED=1

  log "SMB upload backup completed successfully: $FINAL_DIR"
  log "Backups contain config.toml when present; protect the SMB share as sensitive storage"
}

run_backup() {
  refresh_derived_paths
  validate_or_install_deps
  validate_settings
  prepare_backup_inputs

  if [ "$DEST_MODE" = "smbclient" ]; then
    run_smbclient_backup
  else
    run_mounted_backup
  fi
}

prompt_value() {
  local prompt="$1"
  local default="$2"
  local answer

  if [ -n "$default" ]; then
    printf '%s [%s]: ' "$prompt" "$default" >&2
  else
    printf '%s: ' "$prompt" >&2
  fi

  if ! IFS= read -r answer; then
    fail "Input cancelled"
  fi

  if [ -z "$answer" ]; then
    printf '%s\n' "$default"
  else
    printf '%s\n' "$answer"
  fi
}

prompt_yes_no() {
  local prompt="$1"
  local default="$2"
  local answer
  local suffix

  case "$default" in
    yes) suffix="Y/n" ;;
    no) suffix="y/N" ;;
    *) suffix="y/n" ;;
  esac

  while true; do
    printf '%s [%s]: ' "$prompt" "$suffix" >&2
    if ! IFS= read -r answer; then
      fail "Input cancelled"
    fi

    if [ -z "$answer" ]; then
      answer="$default"
    fi

    case "$answer" in
      [Yy] | [Yy][Ee][Ss]) return 0 ;;
      [Nn] | [Nn][Oo]) return 1 ;;
      *) printf 'Please answer yes or no.\n' >&2 ;;
    esac
  done
}

prompt_protocol() {
  local answer

  while true; do
    printf 'Backup share protocol: 1) NFS, recommended for Linux-to-TrueNAS  2) SMB/CIFS [1]: ' >&2
    if ! IFS= read -r answer; then
      fail "Input cancelled"
    fi

    case "$answer" in
      "" | 1 | [Nn][Ff][Ss]) printf 'NFS\n'; return ;;
      2 | [Ss][Mm][Bb] | [Cc][Ii][Ff][Ss]) printf 'SMB\n'; return ;;
      *) printf 'Please choose NFS or SMB.\n' >&2 ;;
    esac
  done
}

prompt_secret() {
  local prompt="$1"
  local answer

  printf '%s: ' "$prompt" >&2
  if ! IFS= read -r -s answer; then
    printf '\n' >&2
    fail "Input cancelled"
  fi
  printf '\n' >&2
  printf '%s\n' "$answer"
}

ensure_no_whitespace() {
  local value="$1"
  local label="$2"

  case "$value" in
    *[[:space:]]*) fail "$label cannot contain whitespace: $value" ;;
  esac
}

show_truenas_troubleshooting() {
  warn "TrueNAS mount or write test failed. Common causes:"
  warn "  - wrong TrueNAS IP/hostname"
  warn "  - NFS service not enabled on TrueNAS"
  warn "  - NFS export path wrong"
  warn "  - SMB share name wrong"
  warn "  - SMB credentials wrong"
  warn "  - local firewall/network issue"
  warn "  - permissions issue on the TrueNAS dataset/share"
}

SETUP_PROTOCOL=""
TRUENAS_HOST=""
LOCAL_MOUNT=""
SETUP_DEST_ROOT=""
NFS_EXPORT=""
SMB_SHARE=""
SMB_PASSWORD=""
INSTALL_CLIENT_TOOLS=0
PERSIST_FSTAB=0
TEST_WRITE=1
RUN_BACKUP_AFTER=0
WRITE_ENV_FILE=1

collect_truenas_config() {
  local default_dest

  SETUP_PROTOCOL="$(prompt_protocol)"
  TRUENAS_HOST="$(prompt_value "TrueNAS server IP or hostname" "")"
  LOCAL_MOUNT="$(prompt_value "Local mount path" "/mnt/truenas")"
  default_dest="${LOCAL_MOUNT%/}/zeroclaw-backups"
  SETUP_DEST_ROOT="$(prompt_value "Destination root for ZeroClaw backups" "$default_dest")"

  if [ "$SETUP_PROTOCOL" = "NFS" ]; then
    NFS_EXPORT="$(prompt_value "TrueNAS NFS export path" "/mnt/tank/backups/zeroclaw")"
    SMB_SHARE=""
    SMB_USER=""
    SMB_PASSWORD=""
  else
    SMB_SHARE="$(prompt_value "TrueNAS SMB share name" "zeroclaw-backups")"
    SMB_USER="$(prompt_value "SMB username" "$ZC_USER")"
    SMB_PASSWORD="$(prompt_secret "SMB password (input hidden)")"
    NFS_EXPORT=""
  fi

  INSTALL_CLIENT_TOOLS=0
  if prompt_yes_no "Install missing ${SETUP_PROTOCOL} client tools if needed" "yes"; then
    INSTALL_CLIENT_TOOLS=1
  fi

  PERSIST_FSTAB=0
  if prompt_yes_no "Make this mount persistent in /etc/fstab" "no"; then
    PERSIST_FSTAB=1
  fi

  TEST_WRITE=0
  if prompt_yes_no "Test the mount with a temporary write/delete file" "yes"; then
    TEST_WRITE=1
  fi

  WRITE_ENV_FILE=0
  if prompt_yes_no "Write non-secret backup settings to ${BACKUP_ENV_FILE}" "yes"; then
    WRITE_ENV_FILE=1
  fi

  RUN_BACKUP_AFTER=0
  if prompt_yes_no "Run a ZeroClaw backup immediately after successful setup" "no"; then
    RUN_BACKUP_AFTER=1
  fi

  TRUENAS_HOST="$(trim_space "$TRUENAS_HOST")"
  LOCAL_MOUNT="$(trim_trailing_slashes "$(trim_space "$LOCAL_MOUNT")")"
  SETUP_DEST_ROOT="$(trim_trailing_slashes "$(trim_space "$SETUP_DEST_ROOT")")"
  NFS_EXPORT="$(trim_trailing_slashes "$(trim_space "$NFS_EXPORT")")"
  SMB_SHARE="$(trim_space "$SMB_SHARE")"
  SMB_USER="$(trim_space "$SMB_USER")"

  [ -n "$TRUENAS_HOST" ] || fail "TrueNAS server IP or hostname is required"
  [ -n "$LOCAL_MOUNT" ] || fail "Local mount path is required"
  [ -n "$SETUP_DEST_ROOT" ] || fail "Destination root is required"

  case "$LOCAL_MOUNT" in
    /*) ;;
    *) fail "Local mount path must be absolute: $LOCAL_MOUNT" ;;
  esac

  case "$SETUP_DEST_ROOT" in
    "$LOCAL_MOUNT" | "$LOCAL_MOUNT"/*) ;;
    *) fail "Destination root must be inside local mount path: $SETUP_DEST_ROOT" ;;
  esac

  ensure_no_whitespace "$TRUENAS_HOST" "TrueNAS host"
  ensure_no_whitespace "$LOCAL_MOUNT" "Local mount path"
  ensure_no_whitespace "$SETUP_DEST_ROOT" "Destination root"

  if [ "$SETUP_PROTOCOL" = "NFS" ]; then
    [ -n "$NFS_EXPORT" ] || fail "NFS export path is required"
    case "$NFS_EXPORT" in
      /*) ;;
      *) fail "NFS export path must be absolute: $NFS_EXPORT" ;;
    esac
    ensure_no_whitespace "$NFS_EXPORT" "NFS export path"
  else
    [ -n "$SMB_SHARE" ] || fail "SMB share name is required"
    [ -n "$SMB_USER" ] || fail "SMB username is required"
    [ -n "$SMB_PASSWORD" ] || fail "SMB password is required"
    ensure_no_whitespace "$SMB_SHARE" "SMB share name"
  fi
}

remote_target() {
  if [ "$SETUP_PROTOCOL" = "NFS" ]; then
    printf '%s:%s\n' "$TRUENAS_HOST" "$NFS_EXPORT"
  else
    printf '//%s/%s\n' "$TRUENAS_HOST" "$SMB_SHARE"
  fi
}

fstab_line() {
  local remote
  local options

  remote="$(remote_target)"

  if [ "$SETUP_PROTOCOL" = "NFS" ]; then
    printf '%s %s nfs defaults,_netdev,nofail 0 0\n' "$remote" "$LOCAL_MOUNT"
  else
    options="credentials=${SMB_CREDENTIALS_FILE},vers=3.0,uid=${ZC_USER},gid=${ZC_USER},file_mode=0600,dir_mode=0700,_netdev,nofail"
    printf '%s %s cifs %s 0 0\n' "$remote" "$LOCAL_MOUNT" "$options"
  fi
}

print_setup_summary() {
  local persistent="no"
  local run_now="no"
  local write_env="no"
  local test_write="no"
  local install_tools="no"

  [ "$PERSIST_FSTAB" -eq 1 ] && persistent="yes"
  [ "$RUN_BACKUP_AFTER" -eq 1 ] && run_now="yes"
  [ "$WRITE_ENV_FILE" -eq 1 ] && write_env="yes"
  [ "$TEST_WRITE" -eq 1 ] && test_write="yes"
  [ "$INSTALL_CLIENT_TOOLS" -eq 1 ] && install_tools="yes"

  printf '\nSelected TrueNAS backup configuration:\n'
  printf '  Protocol: %s\n' "$SETUP_PROTOCOL"
  printf '  TrueNAS host: %s\n' "$TRUENAS_HOST"
  if [ "$SETUP_PROTOCOL" = "NFS" ]; then
    printf '  Remote path/share: %s\n' "$NFS_EXPORT"
  else
    printf '  Remote path/share: //%s/%s\n' "$TRUENAS_HOST" "$SMB_SHARE"
    printf '  SMB username: %s\n' "$SMB_USER"
    printf '  SMB credentials file: %s\n' "$SMB_CREDENTIALS_FILE"
  fi
  printf '  Local mount: %s\n' "$LOCAL_MOUNT"
  printf '  Destination root: %s\n' "$SETUP_DEST_ROOT"
  printf '  Install missing client tools: %s\n' "$install_tools"
  printf '  Persistent fstab: %s\n' "$persistent"
  printf '  Test write/delete: %s\n' "$test_write"
  printf '  Write env file: %s\n' "$write_env"
  printf '  Run backup after setup: %s\n\n' "$run_now"
}

install_client_tools_if_needed() {
  local helper
  local package

  if [ "$SETUP_PROTOCOL" = "NFS" ]; then
    helper="mount.nfs"
    package="nfs-utils"
  else
    helper="mount.cifs"
    package="cifs-utils"
  fi

  if require_cmd "$helper"; then
    return
  fi

  warn "$helper was not found"

  if [ "$INSTALL_CLIENT_TOOLS" -ne 1 ]; then
    warn "Continuing without installing $package; mount may fail"
    return
  fi

  if prompt_yes_no "Install Alpine package ${package} now" "yes"; then
    install_alpine_packages "$package"
  else
    warn "Continuing without installing $package; mount may fail"
  fi
}

write_smb_credentials() {
  if [ "$SETUP_PROTOCOL" != "SMB" ]; then
    return
  fi

  log "SMB credentials will be stored in $SMB_CREDENTIALS_FILE with mode 600"
  if ! prompt_yes_no "Write the SMB credentials file now" "no"; then
    warn "Cannot mount SMB share without credentials file"
    return 1
  fi

  run_privileged mkdir -p /etc/smbcredentials || return 1
  run_privileged chmod 700 /etc/smbcredentials || return 1

  if ! {
    printf 'username=%s\n' "$SMB_USER"
    printf 'password=%s\n' "$SMB_PASSWORD"
  } | run_privileged tee "$SMB_CREDENTIALS_FILE" >/dev/null; then
    return 1
  fi

  run_privileged chmod 600 "$SMB_CREDENTIALS_FILE" || return 1
}

ensure_mount_path() {
  if [ -d "$LOCAL_MOUNT" ]; then
    return
  fi

  log "Creating local mount path: $LOCAL_MOUNT"
  run_privileged mkdir -p "$LOCAL_MOUNT"
}

mount_truenas_share() {
  local remote
  local mounted_source
  local options

  remote="$(remote_target)"
  mounted_source="$(mounted_source_for_path "$LOCAL_MOUNT")"

  if [ -n "$mounted_source" ]; then
    if [ "$mounted_source" = "$remote" ]; then
      log "Share is already mounted: $remote on $LOCAL_MOUNT"
      return 0
    fi

    warn "$LOCAL_MOUNT is already mounted from $mounted_source, expected $remote"
    return 1
  fi

  log "Mounting $remote at $LOCAL_MOUNT"
  if [ "$SETUP_PROTOCOL" = "NFS" ]; then
    run_privileged mount -t nfs "$remote" "$LOCAL_MOUNT"
  else
    options="credentials=${SMB_CREDENTIALS_FILE},vers=3.0,uid=${ZC_USER},gid=${ZC_USER},file_mode=0600,dir_mode=0700"
    run_privileged mount -t cifs "$remote" "$LOCAL_MOUNT" -o "$options"
  fi
}

validate_truenas_mount() {
  local test_file

  if ! is_path_mounted "$LOCAL_MOUNT"; then
    warn "Mount validation failed: $LOCAL_MOUNT is not mounted"
    return 1
  fi

  log "Mount validation passed: $(mounted_source_for_path "$LOCAL_MOUNT") on $LOCAL_MOUNT"

  if [ "$TEST_WRITE" -ne 1 ]; then
    warn "Write/delete test was skipped by user choice"
    return 0
  fi

  test_file="${LOCAL_MOUNT}/.zeroclaw-backup-test.${TIMESTAMP}.$$"
  log "Testing write/delete access with a temporary file"
  if touch "$test_file" && rm "$test_file"; then
    log "Write/delete test passed"
    return 0
  fi

  warn "Write/delete test failed at $LOCAL_MOUNT"
  rm -f "$test_file" 2>/dev/null || true
  return 1
}

attempt_truenas_setup() {
  install_client_tools_if_needed || return 1
  ensure_mount_path || return 1
  write_smb_credentials || return 1
  mount_truenas_share || return 1
  validate_truenas_mount || return 1
}

fstab_exact_line_exists() {
  local line="$1"

  [ -r /etc/fstab ] || return 1
  awk -v line="$line" '$0 == line { found = 1 } END { exit found ? 0 : 1 }' /etc/fstab
}

fstab_conflicting_lines() {
  local remote="$1"
  local mount_point="$2"

  [ -r /etc/fstab ] || return 0
  awk -v remote="$remote" -v mount_point="$mount_point" '
    $0 ~ /^[[:space:]]*#/ || NF < 2 { next }
    $1 == remote || $2 == mount_point { print }
  ' /etc/fstab
}

configure_fstab_if_requested() {
  local line
  local remote
  local conflicts
  local backup_path

  if [ "$PERSIST_FSTAB" -ne 1 ]; then
    return
  fi

  line="$(fstab_line)"
  remote="$(remote_target)"

  printf '\nProposed /etc/fstab line:\n%s\n\n' "$line"

  if fstab_exact_line_exists "$line"; then
    log "Matching /etc/fstab entry already exists; not adding a duplicate"
    return
  fi

  conflicts="$(fstab_conflicting_lines "$remote" "$LOCAL_MOUNT")"
  if [ -n "$conflicts" ]; then
    warn "An /etc/fstab entry already references this remote target or mount path:"
    printf '%s\n' "$conflicts"
    warn "Skipping /etc/fstab update to avoid a duplicate or conflicting entry"
    return
  fi

  if ! prompt_yes_no "Append this exact line to /etc/fstab" "no"; then
    warn "Skipping /etc/fstab update"
    return
  fi

  backup_path="/etc/fstab.bak.$(date '+%Y%m%d_%H%M%S')"

  if [ -e /etc/fstab ]; then
    log "Creating /etc/fstab backup: $backup_path"
    run_privileged cp /etc/fstab "$backup_path" || fail "Failed to back up /etc/fstab"
  else
    warn "/etc/fstab does not exist; no backup file was created"
  fi

  log "Appending TrueNAS mount to /etc/fstab"
  if ! printf '%s\n' "$line" | run_privileged tee -a /etc/fstab >/dev/null; then
    fail "Failed to append /etc/fstab entry"
  fi
}

write_backup_env_if_requested() {
  local env_dir

  if [ "$WRITE_ENV_FILE" -ne 1 ]; then
    return
  fi

  if [ -e "$BACKUP_ENV_FILE" ]; then
    warn "Env file already exists: $BACKUP_ENV_FILE"
    if ! prompt_yes_no "Overwrite this non-secret backup env file" "no"; then
      warn "Skipping env file update"
      return
    fi
  fi

  env_dir="${BACKUP_ENV_FILE%/*}"
  if [ "$env_dir" = "$BACKUP_ENV_FILE" ]; then
    env_dir="."
  fi

  mkdir -p "$env_dir"

  log "Writing non-secret backup settings to $BACKUP_ENV_FILE"
  (
    umask 077
    {
      printf '# ZeroClaw backup settings generated by setup-zeroclaw-truenas-backup.\n'
      printf '# This file intentionally does not contain SMB passwords.\n'
      printf 'DEST_ROOT=%s\n' "$SETUP_DEST_ROOT"
      printf 'SHARE_MOUNT=%s\n' "$LOCAL_MOUNT"
      printf 'REQUIRE_MOUNT=1\n'
      printf 'RETENTION_DAYS=%s\n' "$RETENTION_DAYS"
    } > "$BACKUP_ENV_FILE"
  )
}

apply_setup_backup_settings() {
  DEST_ROOT="$SETUP_DEST_ROOT"
  SHARE_MOUNT="$LOCAL_MOUNT"
  REQUIRE_MOUNT=1
  refresh_derived_paths
}

print_setup_success() {
  local script_path="$0"

  printf '\nTrueNAS backup target is ready.\n'
  printf 'Use this command for future backups:\n'
  printf '  DEST_ROOT=%s SHARE_MOUNT=%s REQUIRE_MOUNT=1 %s\n' "$SETUP_DEST_ROOT" "$LOCAL_MOUNT" "$script_path"

  if [ "$WRITE_ENV_FILE" -eq 1 ]; then
    printf '\nBecause %s was written, you can also run:\n' "$BACKUP_ENV_FILE"
    printf '  %s\n' "$script_path"
  fi
}

setup_truenas_wizard() {
  printf 'ZeroClaw TrueNAS backup setup\n'
  printf 'This wizard helps mount a TrueNAS share before backups run.\n'
  printf 'The backup script still refuses to write to an unmounted share when REQUIRE_MOUNT=1.\n\n'

  while true; do
    collect_truenas_config
    print_setup_summary

    if prompt_yes_no "Apply this TrueNAS setup" "yes"; then
      break
    fi

    printf 'Okay, let us re-enter the setup values.\n\n'
  done

  while true; do
    if attempt_truenas_setup; then
      break
    fi

    show_truenas_troubleshooting

    if ! prompt_yes_no "Retry mount/test now" "yes"; then
      fail "TrueNAS setup did not complete"
    fi

    if prompt_yes_no "Change connection settings before retrying" "yes"; then
      collect_truenas_config
      print_setup_summary
      if ! prompt_yes_no "Apply this updated TrueNAS setup" "yes"; then
        fail "TrueNAS setup cancelled"
      fi
    fi
  done

  configure_fstab_if_requested
  write_backup_env_if_requested
  apply_setup_backup_settings
  print_setup_success

  if [ "$RUN_BACKUP_AFTER" -eq 1 ]; then
    printf '\n'
    if prompt_yes_no "Run the ZeroClaw backup now" "no"; then
      run_backup
    else
      warn "Backup was not run; setup completed only"
    fi
  fi
}

main() {
  case "${1:-}" in
    --setup-truenas)
      shift
      if [ "$#" -ne 0 ]; then
        usage
        fail "--setup-truenas does not accept extra arguments"
      fi
      setup_truenas_wizard
      ;;
    --smbclient-upload)
      shift
      if [ "$#" -ne 0 ]; then
        usage
        fail "--smbclient-upload does not accept extra arguments"
      fi
      DEST_MODE=smbclient
      run_backup
      ;;
    --help | -h)
      usage
      ;;
    "")
      run_backup
      ;;
    *)
      usage
      fail "Unknown argument: $1"
      ;;
  esac
}

main "$@"

#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

# Backup a ZeroClaw install to a mounted share. The SQLite database is copied
# with sqlite3's native .backup command so this is safe to run while SQLite is
# active. The full tarball may still reflect live file state if ZeroClaw is
# running.

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
LOCK_DIR="${LOCK_DIR:-/tmp/zeroclaw-backup.lock}"

REQUIRED_COMMANDS=(bash sqlite3 tar gzip find sha256sum awk)
ALPINE_PACKAGES=(bash sqlite tar gzip findutils coreutils)
ALPINE_INSTALL_COMMAND="sudo apk add --no-cache bash sqlite tar gzip findutils coreutils"

trim_trailing_slashes() {
  local value="$1"

  while [ "$value" != "/" ] && [ "${value%/}" != "$value" ]; do
    value="${value%/}"
  done

  printf '%s\n' "$value"
}

ZC_HOME="$(trim_trailing_slashes "$ZC_HOME")"
ZC_DIR="$(trim_trailing_slashes "$ZC_DIR")"
DEST_ROOT="$(trim_trailing_slashes "$DEST_ROOT")"
SHARE_MOUNT="$(trim_trailing_slashes "$SHARE_MOUNT")"

HOST="${HOST:-$(hostname 2>/dev/null || printf 'unknown-host')}"
TIMESTAMP="${TIMESTAMP:-$(date '+%Y%m%d_%H%M%S')}"
DEST_HOST_DIR="${DEST_ROOT}/${HOST}"
FINAL_DIR="${DEST_HOST_DIR}/${TIMESTAMP}"
TMP_DIR="${FINAL_DIR}.tmp"

LOCK_HELD=0
TMP_CREATED=0
FINALIZED=0

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
    log "Removing incomplete temporary backup: $TMP_DIR"
    rm -rf "$TMP_DIR" || true
  fi

  if [ "$LOCK_HELD" = "1" ]; then
    rmdir "$LOCK_DIR" 2>/dev/null || true
  fi

  exit "$status"
}

trap cleanup EXIT

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
}

contains_missing_command() {
  local missing="$1"
  local command_name="$2"

  case $'\n'"$missing"$'\n' in
    *$'\n'"$command_name"$'\n'*) return 0 ;;
    *) return 1 ;;
  esac
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

  if contains_missing_command "$missing" "sqlite3"; then
    log "Install sqlite3 on Alpine with:"
    log "  sudo apk add --no-cache sqlite"
  fi

  log "Full recommended Alpine package command:"
  log "  $ALPINE_INSTALL_COMMAND"
}

is_alpine_linux() {
  [ -f /etc/alpine-release ] || require_cmd apk
}

install_deps_alpine() {
  local missing="$1"

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

  if [ "${EUID:-1}" -eq 0 ]; then
    log "AUTO_INSTALL_DEPS=1; installing missing Alpine backup dependencies with apk"
    apk add --no-cache "${ALPINE_PACKAGES[@]}"
  elif require_cmd sudo; then
    log "AUTO_INSTALL_DEPS=1; installing missing Alpine backup dependencies with sudo apk"
    sudo apk add --no-cache "${ALPINE_PACKAGES[@]}"
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

  case "$DEST_ROOT" in
    /*) ;;
    *) fail "DEST_ROOT must be an absolute path: $DEST_ROOT" ;;
  esac

  case "$SHARE_MOUNT" in
    /*) ;;
    *) fail "SHARE_MOUNT must be an absolute path: $SHARE_MOUNT" ;;
  esac

  [[ "$RETENTION_DAYS" =~ ^[0-9]+$ ]] || fail "RETENTION_DAYS must be a non-negative integer: $RETENTION_DAYS"

  if [ "$REQUIRE_MOUNT" != "0" ] && [ "$REQUIRE_MOUNT" != "1" ]; then
    fail "REQUIRE_MOUNT must be 0 or 1: $REQUIRE_MOUNT"
  fi

  if [ "$DRY_RUN" != "0" ] && [ "$DRY_RUN" != "1" ]; then
    fail "DRY_RUN must be 0 or 1: $DRY_RUN"
  fi

  if [ ! -d "$ZC_DIR" ]; then
    fail "ZeroClaw directory does not exist: $ZC_DIR"
  fi

  if [ "$REQUIRE_MOUNT" = "1" ] && [ "$SHARE_MOUNT" != "/" ]; then
    case "$DEST_ROOT" in
      "$SHARE_MOUNT" | "$SHARE_MOUNT"/*) ;;
      *) fail "DEST_ROOT must be inside SHARE_MOUNT when REQUIRE_MOUNT=1: DEST_ROOT=$DEST_ROOT SHARE_MOUNT=$SHARE_MOUNT" ;;
    esac
  fi
}

is_mounted() {
  [ -r /proc/mounts ] || return 1
  awk -v mount_point="$SHARE_MOUNT" '$2 == mount_point { found = 1 } END { exit found ? 0 : 1 }' /proc/mounts
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
  log "Would create temporary backup directory: $TMP_DIR"
  log "Would create final backup directory: $FINAL_DIR"
  log "Would archive ZeroClaw directory: $ZC_DIR"

  if [ -n "$DB_PATH" ] && [ -f "$DB_PATH" ]; then
    log "Would create SQLite backup and SQL dump from: $DB_PATH"
  else
    warn "Would continue without SQLite backup because no database was found"
  fi

  log "Would write manifest.txt and SHA256SUMS.txt"
  log "Would clean timestamped backups older than ${RETENTION_DAYS} days under ${DEST_HOST_DIR}"
}

main() {
  local zeroclaw_version

  validate_or_install_deps
  validate_settings
  check_mount

  DB_PATH="$(detect_db_path)"

  if zeroclaw_running; then
    warn "ZeroClaw appears to be running; SQLite backup is safe, but the full tarball may capture live file state"
  fi

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

  zeroclaw_version="$(detect_zeroclaw_version)"

  write_manifest "$zeroclaw_version"
  copy_config_if_present
  backup_sqlite_if_present
  create_full_tarball
  write_sha256sums

  log "Promoting temporary backup into place: $FINAL_DIR"
  mv "$TMP_DIR" "$FINAL_DIR"
  FINALIZED=1

  cleanup_old_backups

  log "Backup completed successfully: $FINAL_DIR"
  log "Backups contain config.toml when present; protect this share as sensitive storage"
}

main "$@"

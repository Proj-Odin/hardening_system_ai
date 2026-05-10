#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

# Generic Alpine-first restore companion for scripts/backup-app-to-share.sh.
# It restores from SMB with smbclient and never requires CIFS/NFS mounts.

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

trim_space() {
  local value="$1"

  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s\n' "$value"
}

trim_trailing_slashes() {
  local value="$1"

  while [ "$value" != "/" ] && [ "${value%/}" != "$value" ]; do
    value="${value%/}"
  done

  printf '%s\n' "$value"
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1
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

run_privileged_best_effort() {
  if [ "${EUID:-1}" -eq 0 ]; then
    "$@" || return 1
  elif require_cmd sudo; then
    sudo "$@" || return 1
  else
    return 1
  fi
}

is_alpine_linux() {
  [ -f /etc/alpine-release ] || require_cmd apk
}

apk_package_for_command() {
  case "$1" in
    bash) printf 'bash\n' ;;
    smbclient) printf 'samba-client\n' ;;
    tar) printf 'tar\n' ;;
    gzip) printf 'gzip\n' ;;
    find) printf 'findutils\n' ;;
    sha256sum | mktemp | stat | id | sort) printf 'coreutils\n' ;;
    sqlite3) printf 'sqlite\n' ;;
    awk | sed | grep) return 1 ;;
    *) return 1 ;;
  esac
}

unique_append() {
  local value="$1"
  shift
  local existing

  for existing in "$@"; do
    if [ "$existing" = "$value" ]; then
      return 1
    fi
  done

  return 0
}

missing_commands() {
  local cmd

  for cmd in "$@"; do
    if ! require_cmd "$cmd"; then
      printf '%s\n' "$cmd"
    fi
  done
}

missing_to_apk_packages() {
  local missing="$1"
  local cmd
  local package
  local packages=()

  while IFS= read -r cmd; do
    [ -n "$cmd" ] || continue
    if package="$(apk_package_for_command "$cmd")"; then
      if unique_append "$package" "${packages[@]}"; then
        packages+=("$package")
      fi
    fi
  done <<< "$missing"

  printf '%s\n' "${packages[@]}"
}

print_alpine_install_help() {
  local missing="$1"
  local cmd
  local package
  local packages=()

  log "Missing required command(s):"
  while IFS= read -r cmd; do
    [ -n "$cmd" ] || continue
    log "  - $cmd"
  done <<< "$missing"

  while IFS= read -r package; do
    [ -n "$package" ] || continue
    packages+=("$package")
  done < <(missing_to_apk_packages "$missing")

  if [ "${#packages[@]}" -gt 0 ]; then
    log "Manual Alpine install command:"
    log "  sudo apk add --no-cache $(join_words "${packages[@]}")"
  fi
}

install_missing_alpine_packages() {
  local missing="$1"
  local package
  local packages=()

  if ! is_alpine_linux; then
    print_alpine_install_help "$missing"
    fail "AUTO_INSTALL_DEPS=1 is Alpine-focused and will not attempt apt/dnf/yum installs"
  fi

  if ! require_cmd apk; then
    print_alpine_install_help "$missing"
    fail "Alpine Linux detected, but apk was not found in PATH"
  fi

  while IFS= read -r package; do
    [ -n "$package" ] || continue
    packages+=("$package")
  done < <(missing_to_apk_packages "$missing")

  if [ "${#packages[@]}" -eq 0 ]; then
    print_alpine_install_help "$missing"
    fail "No Alpine package mapping is available for one or more missing command(s)"
  fi

  log "AUTO_INSTALL_DEPS=1; installing missing Alpine restore dependencies"
  if ! run_privileged apk add --no-cache "${packages[@]}"; then
    print_alpine_install_help "$missing"
    fail "Failed to install Alpine restore dependencies"
  fi
}

ensure_commands() {
  local missing

  missing="$(missing_commands "$@")"
  if [ -z "$missing" ]; then
    return
  fi

  if [ "$AUTO_INSTALL_DEPS" = "1" ]; then
    install_missing_alpine_packages "$missing"
    missing="$(missing_commands "$@")"
    if [ -z "$missing" ]; then
      log "Dependency validation passed after Alpine package installation"
      return
    fi
  fi

  print_alpine_install_help "$missing"
  fail "Install missing dependencies, or rerun with AUTO_INSTALL_DEPS=1 on Alpine Linux"
}

normalize_remote_root() {
  local value="$1"

  value="$(trim_trailing_slashes "$value")"
  while [ "${value#/}" != "$value" ]; do
    value="${value#/}"
  done

  printf '%s\n' "$value"
}

join_remote_path() {
  local prefix="$1"
  local suffix="$2"

  if [ -n "$prefix" ]; then
    printf '%s/%s\n' "$prefix" "$suffix"
  else
    printf '%s\n' "$suffix"
  fi
}

safe_component() {
  local value="$1"
  local label="$2"

  if [[ ! "$value" =~ ^[A-Za-z0-9._-]+$ ]]; then
    fail "$label must contain only letters, numbers, dots, underscores, and dashes: $value"
  fi
}

validate_remote_root() {
  local value="$1"
  local component
  local components=()

  [ -n "$value" ] || return 0

  case "$value" in
    *//* | */ | /*)
      fail "SMB_REMOTE_ROOT must be a relative SMB path without empty components: $value"
      ;;
  esac

  IFS=/ read -r -a components <<< "$value"
  for component in "${components[@]}"; do
    case "$component" in
      "" | "." | "..")
        fail "SMB_REMOTE_ROOT cannot contain empty, '.', or '..' components: $value"
        ;;
    esac
    safe_component "$component" "SMB_REMOTE_ROOT component"
  done
}

short_hostname() {
  hostname -s 2>/dev/null || hostname 2>/dev/null || printf 'unknown-host'
}

usage() {
  cat <<'USAGE'
Usage:
  restore-app-from-share.sh
  restore-app-from-share.sh --help

Restore a backup created by scripts/backup-app-to-share.sh from SMB using
smbclient. Set BACKUP_TIMESTAMP for an exact restore, or RESTORE_LATEST=1 to
select the newest timestamp for APP_NAME/BACKUP_HOST.

Actual restores require RESTORE_CONFIRM=1. DRY_RUN=1 prints actions only.
USAGE
}

validate_boolean() {
  local value="$1"
  local name="$2"

  case "$value" in
    0 | 1) ;;
    *) fail "$name must be 0 or 1: $value" ;;
  esac
}

validate_settings() {
  [ -n "$SMB_SHARE" ] || fail "SMB_SHARE is required, for example: //server/share"
  [ -n "$SMB_CREDS" ] || fail "SMB_CREDS is required, for example: /etc/smbcredentials/truenas-zeroclaw"

  safe_component "$APP_NAME" "APP_NAME"
  safe_component "$BACKUP_HOST" "BACKUP_HOST"
  [ -z "$BACKUP_TIMESTAMP" ] || safe_component "$BACKUP_TIMESTAMP" "BACKUP_TIMESTAMP"
  validate_remote_root "$SMB_REMOTE_ROOT"

  case "$APP_HOME" in
    /*) ;;
    *) fail "APP_HOME must be an absolute path: $APP_HOME" ;;
  esac

  case "$APP_DIR" in
    /*) ;;
    *) fail "APP_DIR must be an absolute path: $APP_DIR" ;;
  esac

  case "$SMB_SHARE" in
    //*/*) ;;
    *) fail "SMB_SHARE must look like //server/share: $SMB_SHARE" ;;
  esac

  case "$SMB_SHARE" in
    *[[:space:]]*) fail "SMB_SHARE cannot contain whitespace: $SMB_SHARE" ;;
  esac

  case "$SMB_CREDS" in
    /*) ;;
    *) fail "SMB_CREDS must be an absolute path: $SMB_CREDS" ;;
  esac

  validate_boolean "$DRY_RUN" "DRY_RUN"
  validate_boolean "$AUTO_INSTALL_DEPS" "AUTO_INSTALL_DEPS"
  validate_boolean "$KEEP_STAGING" "KEEP_STAGING"
  validate_boolean "$RESTORE_LATEST" "RESTORE_LATEST"
  validate_boolean "$RESTORE_CONFIRM" "RESTORE_CONFIRM"
  validate_boolean "$ALLOW_RUNNING" "ALLOW_RUNNING"
  validate_boolean "$PRE_RESTORE_BACKUP" "PRE_RESTORE_BACKUP"
  validate_boolean "$FORCE" "FORCE"

  if [ -z "$BACKUP_TIMESTAMP" ] && [ "$RESTORE_LATEST" != "1" ]; then
    fail "Set BACKUP_TIMESTAMP, or set RESTORE_LATEST=1"
  fi

  if [ "$DRY_RUN" = "0" ] && [ "$RESTORE_CONFIRM" != "1" ]; then
    fail "RESTORE_CONFIRM=1 is required for an actual restore"
  fi
}

check_smb_credentials() {
  local mode
  local group_digit
  local world_digit

  if [ ! -f "$SMB_CREDS" ]; then
    fail "SMB credentials file does not exist: $SMB_CREDS"
  fi

  if [ ! -r "$SMB_CREDS" ]; then
    log "ERROR: SMB credentials file is not readable by this user: $SMB_CREDS"
    log "Copy it into a readable location with:"
    log "  sudo install -o ${APP_USER} -g ${APP_USER} -m 600 /etc/smbcredentials/truenas-zeroclaw $SMB_CREDS"
    exit 1
  fi

  mode="$(stat -c '%a' "$SMB_CREDS" 2>/dev/null || true)"
  if [[ "$mode" =~ ^[0-7]+$ ]] && [ "${#mode}" -ge 3 ]; then
    group_digit="${mode: -2:1}"
    world_digit="${mode: -1}"

    if [ "$group_digit" -ge 4 ] || [ "$world_digit" -ge 4 ]; then
      fail "SMB credentials file must not be group/world readable; fix with: chmod 600 $SMB_CREDS"
    fi
  else
    warn "Could not verify SMB credentials file mode; ensure it is chmod 600"
  fi
}

check_app_user() {
  if ! id "$APP_USER" >/dev/null 2>&1; then
    fail "APP_USER does not exist: $APP_USER"
  fi
}

ensure_app_home() {
  local parent

  if [ -d "$APP_HOME" ]; then
    return
  fi

  if [ "$DRY_RUN" = "1" ]; then
    log "DRY_RUN=1; would create APP_HOME: $APP_HOME"
    return
  fi

  log "Creating APP_HOME: $APP_HOME"
  run_privileged mkdir -p "$APP_HOME"

  if ! run_privileged_best_effort chown "$APP_USER:$APP_USER" "$APP_HOME"; then
    warn "Could not chown APP_HOME to ${APP_USER}:${APP_USER}; continuing"
  fi

  chmod 700 "$APP_HOME" 2>/dev/null || warn "Could not chmod 700 APP_HOME: $APP_HOME"

  parent="${APP_DIR%/*}"
  if [ "$parent" != "$APP_HOME" ] && [ ! -d "$parent" ]; then
    log "Creating APP_DIR parent: $parent"
    run_privileged mkdir -p "$parent"
  fi
}

smbclient_run() {
  local command_string="$1"

  smbclient "$SMB_SHARE" -A "$SMB_CREDS" -c "$command_string"
}

check_smb_connectivity() {
  log "Checking SMB connectivity: $SMB_SHARE"
  if ! smbclient_run 'ls' >/dev/null; then
    fail "smbclient could not connect to $SMB_SHARE with credentials file $SMB_CREDS"
  fi
}

remote_dir_exists() {
  local remote_dir="$1"

  smbclient_run "cd ${remote_dir}; ls" >/dev/null 2>&1
}

remote_listing() {
  local remote_dir="$1"

  smbclient_run "cd ${remote_dir}; ls" 2>/dev/null || true
}

remote_entry_exists() {
  local remote_dir="$1"
  local name="$2"
  local listing

  listing="$(remote_listing "$remote_dir")"
  printf '%s\n' "$listing" | awk -v name="$name" '$1 == name { found = 1 } END { exit found ? 0 : 1 }'
}

list_remote_files() {
  local remote_dir="$1"
  local listing

  listing="$(remote_listing "$remote_dir")"
  printf '%s\n' "$listing" | awk '
    $1 == "." || $1 == ".." { next }
    $1 ~ /^[A-Za-z0-9._-]+$/ && $2 !~ /D/ { print $1 }
  '
}

latest_timestamp_under() {
  local remote_parent="$1"
  local listing

  listing="$(remote_listing "$remote_parent")"
  printf '%s\n' "$listing" | awk '
    $1 ~ /^[0-9]{8}_[0-9]{6}$/ {
      if ($1 > latest) {
        latest = $1
      }
    }
    END {
      if (latest != "") {
        print latest
      } else {
        exit 1
      }
    }
  '
}

add_candidate_parent() {
  local root="$1"
  local parent
  local existing

  if [ -n "$root" ]; then
    parent="$(join_remote_path "$root" "$APP_NAME")"
  else
    parent="$APP_NAME"
  fi
  parent="$(join_remote_path "$parent" "$BACKUP_HOST")"

  for existing in "${CANDIDATE_PARENTS[@]}"; do
    if [ "$existing" = "$parent" ]; then
      return
    fi
  done

  CANDIDATE_PARENTS+=("$parent")
}

build_candidate_parents() {
  CANDIDATE_PARENTS=()

  add_candidate_parent "$SMB_REMOTE_ROOT"
  add_candidate_parent ""

  if [ -n "$SMB_SHARE_BASENAME" ]; then
    add_candidate_parent "$SMB_SHARE_BASENAME"
  fi
}

select_backup() {
  local parent
  local candidate_dir
  local latest

  build_candidate_parents

  if [ -n "$BACKUP_TIMESTAMP" ]; then
    for parent in "${CANDIDATE_PARENTS[@]}"; do
      candidate_dir="$(join_remote_path "$parent" "$BACKUP_TIMESTAMP")"
      if remote_dir_exists "$candidate_dir"; then
        REMOTE_PARENT_DIR="$parent"
        REMOTE_BACKUP_DIR="$candidate_dir"
        log "Using remote backup path: ${SMB_SHARE}/${REMOTE_BACKUP_DIR}"
        return
      fi
    done

    fail "Backup timestamp was not found for ${APP_NAME}/${BACKUP_HOST}: $BACKUP_TIMESTAMP"
  fi

  if [ "$RESTORE_LATEST" = "1" ]; then
    for parent in "${CANDIDATE_PARENTS[@]}"; do
      if ! remote_dir_exists "$parent"; then
        continue
      fi

      if latest="$(latest_timestamp_under "$parent")"; then
        BACKUP_TIMESTAMP="$latest"
        REMOTE_PARENT_DIR="$parent"
        REMOTE_BACKUP_DIR="$(join_remote_path "$parent" "$BACKUP_TIMESTAMP")"
        log "Selected latest backup timestamp: $BACKUP_TIMESTAMP"
        log "Using remote backup path: ${SMB_SHARE}/${REMOTE_BACKUP_DIR}"
        return
      fi
    done
  fi

  fail "Could not select a backup under any candidate remote path for ${APP_NAME}/${BACKUP_HOST}"
}

create_staging_dir() {
  local template="/tmp/${APP_NAME}-restore-${BACKUP_HOST}-${BACKUP_TIMESTAMP}.XXXXXX"

  if ! STAGING_DIR="$(mktemp -d "$template")"; then
    fail "Failed to create local restore staging directory under /tmp"
  fi

  STAGING_CREATED=1
  log "Created local restore staging directory: $STAGING_DIR"
}

download_file() {
  local remote_dir="$1"
  local name="$2"
  local local_dir="$3"
  local required="$4"

  mkdir -p "$local_dir"

  if ! remote_entry_exists "$remote_dir" "$name"; then
    if [ "$required" = "1" ]; then
      fail "Required remote backup artifact is missing: ${remote_dir}/${name}"
    fi
    return
  fi

  log "Downloading artifact: ${remote_dir}/${name}"
  if ! smbclient_run "lcd ${local_dir}; cd ${remote_dir}; get ${name}"; then
    if [ "$required" = "1" ]; then
      fail "Failed to download required artifact: ${remote_dir}/${name}"
    fi
    warn "Failed to download optional artifact: ${remote_dir}/${name}"
  fi
}

download_directory_files() {
  local remote_dir="$1"
  local local_dir="$2"
  local name

  if ! remote_dir_exists "$remote_dir"; then
    return
  fi

  mkdir -p "$local_dir"

  while IFS= read -r name; do
    [ -n "$name" ] || continue
    download_file "$remote_dir" "$name" "$local_dir" 1
  done < <(list_remote_files "$remote_dir")
}

download_backup() {
  local tar_name="${APP_NAME}-full.tar.gz"

  create_staging_dir

  download_file "$REMOTE_BACKUP_DIR" "manifest.txt" "$STAGING_DIR" 0
  download_file "$REMOTE_BACKUP_DIR" "SHA256SUMS.txt" "$STAGING_DIR" 1
  download_file "$REMOTE_BACKUP_DIR" "$tar_name" "$STAGING_DIR" 1
  download_file "$REMOTE_BACKUP_DIR" "sqlite_integrity_check.txt" "$STAGING_DIR" 0
  download_file "$REMOTE_BACKUP_DIR" "${APP_NAME}-extra-paths.tar.gz" "$STAGING_DIR" 0
  download_file "$REMOTE_BACKUP_DIR" "extra-paths.txt" "$STAGING_DIR" 0
  download_directory_files "${REMOTE_BACKUP_DIR}/configs" "${STAGING_DIR}/configs"
  download_directory_files "${REMOTE_BACKUP_DIR}/sqlite" "${STAGING_DIR}/sqlite"
}

print_manifest_if_present() {
  if [ -f "${STAGING_DIR}/manifest.txt" ]; then
    log "Backup manifest:"
    sed 's/^/  /' "${STAGING_DIR}/manifest.txt"
  else
    warn "manifest.txt was not present in the downloaded backup"
  fi
}

validate_sqlite_integrity_file() {
  local file="${STAGING_DIR}/sqlite_integrity_check.txt"
  local db_count
  local ok_count

  [ -f "$file" ] || return

  log "SQLite integrity report:"
  sed 's/^/  /' "$file"

  if ! awk '
    /^$/ { next }
    /^database=/ { db_count++; next }
    /^backup=/ { next }
    /^ok$/ { ok_count++; next }
    /^No SQLite databases were found/ { no_db = 1; next }
    /^Checked at / { next }
    /^skipped:/ { no_db = 1; next }
    { bad = 1; print "unexpected sqlite integrity line: " $0 > "/dev/stderr" }
    END {
      if (bad) {
        exit 1
      }
      if (db_count > 0 && ok_count < db_count) {
        exit 1
      }
      exit 0
    }
  ' "$file"; then
    fail "sqlite_integrity_check.txt did not contain the expected ok-style integrity results"
  fi
}

validate_downloaded_backup() {
  local tar_name="${APP_NAME}-full.tar.gz"

  if [ ! -f "${STAGING_DIR}/SHA256SUMS.txt" ]; then
    fail "SHA256SUMS.txt is missing from downloaded backup"
  fi

  if [ ! -f "${STAGING_DIR}/${tar_name}" ]; then
    fail "${tar_name} is missing from downloaded backup"
  fi

  log "Verifying SHA256SUMS.txt before restore"
  (
    cd "$STAGING_DIR"
    sha256sum -c SHA256SUMS.txt
  ) || fail "SHA256SUMS.txt validation failed; refusing restore"

  print_manifest_if_present
  validate_sqlite_integrity_file
}

app_appears_running() {
  if require_cmd pgrep; then
    pgrep -f "$APP_NAME" >/dev/null 2>&1
    return
  fi

  ps 2>/dev/null | awk -v name="$APP_NAME" '
    $0 ~ name && $0 !~ /restore-app-from-share\.sh/ && $0 !~ /restore-zeroclaw-from-share\.sh/ { found = 1 }
    END { exit found ? 0 : 1 }
  '
}

run_stop_cmd_if_requested() {
  if [ -z "$STOP_CMD" ]; then
    return
  fi

  if [ "$DRY_RUN" = "1" ]; then
    log "DRY_RUN=1; would run STOP_CMD: $STOP_CMD"
    return
  fi

  log "Running STOP_CMD before restore"
  bash -c "$STOP_CMD"
}

check_running_app_guard() {
  if [ "$ALLOW_RUNNING" = "1" ]; then
    warn "ALLOW_RUNNING=1; skipping running app guard"
    return
  fi

  if app_appears_running; then
    fail "$APP_NAME appears to be running; stop it first, set STOP_CMD, or set ALLOW_RUNNING=1"
  fi
}

create_pre_restore_backup() {
  local app_parent="${APP_DIR%/*}"
  local app_base="${APP_DIR##*/}"

  PRE_RESTORE_BACKUP_PATH=""

  if [ ! -d "$APP_DIR" ]; then
    return
  fi

  if [ "$PRE_RESTORE_BACKUP" != "1" ]; then
    warn "PRE_RESTORE_BACKUP=0; no pre-restore tarball will be created"
    return
  fi

  PRE_RESTORE_BACKUP_PATH="${APP_HOME}/pre-restore-${APP_NAME}-${RESTORE_RUN_TS}.tar.gz"
  log "Creating pre-restore backup: $PRE_RESTORE_BACKUP_PATH"
  tar -C "$app_parent" -cf - "$app_base" | gzip -c > "$PRE_RESTORE_BACKUP_PATH"
}

move_existing_app_dir_if_needed() {
  local moved_path

  if [ ! -d "$APP_DIR" ]; then
    return
  fi

  if [ "$FORCE" = "1" ]; then
    warn "FORCE=1; extracting over existing APP_DIR after pre-restore backup"
    return
  fi

  moved_path="${APP_DIR}.pre-restore.${RESTORE_RUN_TS}"
  if [ -e "$moved_path" ]; then
    fail "Refusing to move APP_DIR because target already exists: $moved_path"
  fi

  log "Moving existing APP_DIR to: $moved_path"
  mv "$APP_DIR" "$moved_path"
  MOVED_APP_DIR="$moved_path"
}

restore_tarball() {
  local tar_name="${APP_NAME}-full.tar.gz"
  local restore_parent="${APP_DIR%/*}"

  log "Extracting ${tar_name} into: $restore_parent"
  mkdir -p "$restore_parent"
  tar -xzf "${STAGING_DIR}/${tar_name}" -C "$restore_parent"

  if [ ! -d "$APP_DIR" ]; then
    fail "Restore extraction completed, but APP_DIR does not exist afterward: $APP_DIR"
  fi
}

restore_explicit_config_copy() {
  local source="${STAGING_DIR}/configs/config.toml"
  local target="${APP_DIR}/config.toml"

  if [ ! -f "$source" ]; then
    return
  fi

  if [ -f "$target" ]; then
    cp "$target" "${target}.pre-config-restore.${RESTORE_RUN_TS}"
  fi

  log "Restoring explicit configs/config.toml to: $target"
  cp "$source" "$target"
}

manifest_db_paths() {
  local manifest="${STAGING_DIR}/manifest.txt"

  [ -f "$manifest" ] || return 1

  awk -F= '
    $1 == "sqlite_db" && $2 != "" { print substr($0, index($0, "=") + 1) }
    $1 == "db_path" && $2 != "" && $2 != "not found" { print substr($0, index($0, "=") + 1) }
  ' "$manifest"
}

apply_sqlite_backups() {
  local db_paths=()
  local backup_files=()
  local db_path
  local backup_file
  local index
  local parent
  local applied=0

  SQLITE_RESTORE_STATUS="skipped"

  if [ ! -d "${STAGING_DIR}/sqlite" ]; then
    warn "No sqlite/ directory was downloaded; SQLite backup files skipped"
    return
  fi

  while IFS= read -r db_path; do
    [ -n "$db_path" ] || continue
    db_paths+=("$db_path")
  done < <(manifest_db_paths || true)

  while IFS= read -r backup_file; do
    [ -n "$backup_file" ] || continue
    backup_files+=("$backup_file")
  done < <(find "${STAGING_DIR}/sqlite" -maxdepth 1 -type f -name '*.backup' -print | sort)

  if [ "${#backup_files[@]}" -eq 0 ]; then
    warn "No sqlite/*.backup files were downloaded; SQLite restore skipped"
    return
  fi

  if [ "${#db_paths[@]}" -eq 0 ]; then
    warn "manifest.txt did not contain parseable sqlite_db paths; SQLite restore skipped to avoid guessing"
    return
  fi

  if [ "${#db_paths[@]}" -ne "${#backup_files[@]}" ]; then
    warn "SQLite manifest path count (${#db_paths[@]}) does not match backup file count (${#backup_files[@]}); SQLite restore skipped"
    return
  fi

  for index in "${!backup_files[@]}"; do
    db_path="${db_paths[$index]}"
    backup_file="${backup_files[$index]}"

    case "$db_path" in
      "$APP_DIR"/*) ;;
      *)
        warn "Skipping SQLite restore outside APP_DIR: $db_path"
        continue
        ;;
    esac

    parent="${db_path%/*}"
    mkdir -p "$parent"

    if [ -f "$db_path" ]; then
      cp "$db_path" "${db_path}.pre-sqlite-restore.${RESTORE_RUN_TS}"
    fi

    log "Restoring SQLite backup ${backup_file##*/} to: $db_path"
    cp "$backup_file" "$db_path"
    applied=$((applied + 1))

    if require_cmd sqlite3; then
      sqlite3 "$db_path" "PRAGMA integrity_check;" | awk '
        NR == 1 && $0 == "ok" { ok = 1; next }
        { bad = 1 }
        END { exit (ok && !bad) ? 0 : 1 }
      ' || fail "Restored SQLite database failed integrity check: $db_path"
    else
      warn "sqlite3 is not available; restored DB integrity check skipped for $db_path"
    fi
  done

  if [ "$applied" -gt 0 ]; then
    SQLITE_RESTORE_STATUS="applied ${applied} SQLite backup file(s)"
  else
    SQLITE_RESTORE_STATUS="skipped"
  fi
}

fix_permissions() {
  log "Applying conservative permissions to: $APP_DIR"
  chmod 700 "$APP_DIR" 2>/dev/null || warn "Could not chmod 700 APP_DIR: $APP_DIR"

  find "$APP_DIR" -type f \( \
    -name '.env' -o \
    -name '*secret*' -o \
    -name '*secrets*' -o \
    -name 'config.toml' -o \
    -name 'config.yaml' -o \
    -name 'config.yml' -o \
    -name 'settings.toml' -o \
    -name 'settings.yaml' \
  \) -exec chmod 600 {} \; 2>/dev/null || warn "Could not chmod some config/secret files"

  if run_privileged_best_effort chown -R "$APP_USER:$APP_USER" "$APP_DIR"; then
    return
  fi

  if run_privileged_best_effort chown -R "$APP_USER" "$APP_DIR"; then
    warn "Restored ownership to user $APP_USER; group differed or was unavailable"
  else
    warn "Could not chown APP_DIR to $APP_USER; check ownership manually"
  fi
}

run_start_cmd_if_requested() {
  if [ -z "$START_CMD" ]; then
    return
  fi

  log "Running START_CMD after successful restore"
  bash -c "$START_CMD"
}

restore_backup() {
  run_stop_cmd_if_requested
  check_running_app_guard
  create_pre_restore_backup
  move_existing_app_dir_if_needed
  restore_tarball
  restore_explicit_config_copy
  apply_sqlite_backups
  fix_permissions
  run_start_cmd_if_requested
}

dry_run_summary() {
  log "DRY_RUN=1; no files will be downloaded or restored"
  log "Would restore app: $APP_NAME"
  log "Would use remote backup path: ${SMB_SHARE}/${REMOTE_BACKUP_DIR}"
  log "Would create local staging directory: /tmp/${APP_NAME}-restore-${BACKUP_HOST}-${BACKUP_TIMESTAMP}.XXXXXX"
  log "Would verify SHA256SUMS.txt before restore"
  log "Would restore tarball into parent of APP_DIR: ${APP_DIR%/*}"
  if [ -d "$APP_DIR" ]; then
    log "Would create pre-restore backup of existing APP_DIR when PRE_RESTORE_BACKUP=1: $APP_DIR"
    if [ "$FORCE" = "0" ]; then
      log "Would move existing APP_DIR aside before extraction"
    else
      log "Would extract over existing APP_DIR because FORCE=1"
    fi
  fi
  if [ -n "$STOP_CMD" ]; then
    log "Would run STOP_CMD before restore: $STOP_CMD"
  fi
  if [ -n "$START_CMD" ]; then
    log "Would run START_CMD after restore: $START_CMD"
  fi
}

print_summary() {
  log "Restore completed successfully"
  log "Restored APP_DIR: $APP_DIR"
  log "Backup timestamp restored: $BACKUP_TIMESTAMP"
  log "SQLite backup files: $SQLITE_RESTORE_STATUS"

  if [ -n "$PRE_RESTORE_BACKUP_PATH" ]; then
    log "Pre-restore backup: $PRE_RESTORE_BACKUP_PATH"
  else
    log "Pre-restore backup: not created"
  fi

  if [ -n "$MOVED_APP_DIR" ]; then
    log "Previous APP_DIR moved to: $MOVED_APP_DIR"
  fi

  if [ "$KEEP_STAGING" = "1" ] && [ -n "$STAGING_DIR" ]; then
    log "Restore staging retained at: $STAGING_DIR"
  fi

  if [ -z "$START_CMD" ]; then
    log "Start command suggestion: run the app's normal start command after reviewing the restored files"
    log "Check command suggestion: inspect app logs and run any app-specific health check"
  fi
}

cleanup() {
  local status=$?

  if [ "$STAGING_CREATED" = "1" ] && [ -n "$STAGING_DIR" ] && [ -d "$STAGING_DIR" ]; then
    if [ "$status" -ne 0 ]; then
      warn "Leaving restore staging directory in place after failure: $STAGING_DIR"
    elif [ "$KEEP_STAGING" = "1" ]; then
      log "KEEP_STAGING=1; leaving restore staging directory in place: $STAGING_DIR"
    else
      rm -rf -- "$STAGING_DIR" || true
    fi
  fi

  exit "$status"
}

run_restore_flow() {
  validate_settings

  if [ "$DRY_RUN" = "0" ] && [ "$RESTORE_CONFIRM" != "1" ]; then
    fail "RESTORE_CONFIRM=1 is required for an actual restore"
  fi

  ensure_commands "${BASE_COMMANDS[@]}"
  check_smb_credentials
  ensure_commands smbclient
  check_app_user
  ensure_app_home
  check_smb_connectivity
  select_backup

  if [ "$DRY_RUN" = "1" ]; then
    dry_run_summary
    return
  fi

  download_backup
  validate_downloaded_backup
  restore_backup
  print_summary
}

APP_NAME="${APP_NAME:-zeroclaw}"
APP_USER="${APP_USER:-admin}"
APP_HOME="${APP_HOME:-/home/${APP_USER}}"
APP_DIR="${APP_DIR:-${APP_HOME}/.zeroclaw}"
SMB_SHARE="${SMB_SHARE:-}"
SMB_CREDS="${SMB_CREDS:-}"
SMB_REMOTE_ROOT="${SMB_REMOTE_ROOT:-zeroclaw-backups}"
BACKUP_HOST="${BACKUP_HOST:-$(short_hostname)}"
BACKUP_TIMESTAMP="${BACKUP_TIMESTAMP:-}"
RESTORE_LATEST="${RESTORE_LATEST:-0}"
RESTORE_CONFIRM="${RESTORE_CONFIRM:-0}"
DRY_RUN="${DRY_RUN:-0}"
AUTO_INSTALL_DEPS="${AUTO_INSTALL_DEPS:-0}"
KEEP_STAGING="${KEEP_STAGING:-0}"
STOP_CMD="${STOP_CMD:-}"
START_CMD="${START_CMD:-}"
ALLOW_RUNNING="${ALLOW_RUNNING:-0}"
PRE_RESTORE_BACKUP="${PRE_RESTORE_BACKUP:-1}"
FORCE="${FORCE:-0}"

APP_HOME="$(trim_trailing_slashes "$APP_HOME")"
APP_DIR="$(trim_trailing_slashes "$APP_DIR")"
SMB_SHARE="$(trim_trailing_slashes "$SMB_SHARE")"
SMB_REMOTE_ROOT="$(normalize_remote_root "$SMB_REMOTE_ROOT")"
SMB_SHARE_BASENAME="${SMB_SHARE##*/}"
RESTORE_RUN_TS="$(date '+%Y%m%d_%H%M%S')"

BASE_COMMANDS=(bash tar gzip find awk sed grep sha256sum mktemp stat id sort)
CANDIDATE_PARENTS=()
STAGING_DIR=""
STAGING_CREATED=0
REMOTE_PARENT_DIR=""
REMOTE_BACKUP_DIR=""
PRE_RESTORE_BACKUP_PATH=""
MOVED_APP_DIR=""
SQLITE_RESTORE_STATUS="skipped"

trap cleanup EXIT

main() {
  case "${1:-}" in
    --help | -h)
      usage
      return
      ;;
    "")
      ;;
    *)
      usage
      fail "Unknown argument: $1"
      ;;
  esac

  run_restore_flow
}

main "$@"

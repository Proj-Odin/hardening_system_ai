#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

# Generic Alpine-first backup engine for apps that need safe no-mount SMB
# uploads to TrueNAS-style shares. App-specific wrappers set APP_* defaults.

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

is_alpine_linux() {
  [ -f /etc/alpine-release ] || require_cmd apk
}

apk_package_for_command() {
  case "$1" in
    bash) printf 'bash\n' ;;
    sqlite3) printf 'sqlite\n' ;;
    smbclient) printf 'samba-client\n' ;;
    tar) printf 'tar\n' ;;
    gzip) printf 'gzip\n' ;;
    find) printf 'findutils\n' ;;
    sha256sum) printf 'coreutils\n' ;;
    awk) return 1 ;;
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
  local packages=()
  local package

  while IFS= read -r package; do
    [ -n "$package" ] || continue
    packages+=("$package")
  done < <(missing_to_apk_packages "$missing")

  log "Missing required command(s):"
  while IFS= read -r cmd; do
    [ -n "$cmd" ] || continue
    log "  - $cmd"
  done <<< "$missing"

  if [ "${#packages[@]}" -gt 0 ]; then
    log "Manual Alpine install command:"
    log "  sudo apk add --no-cache $(join_words "${packages[@]}")"
  fi
}

install_missing_alpine_packages() {
  local missing="$1"
  local packages=()
  local package

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

  log "AUTO_INSTALL_DEPS=1; installing missing Alpine backup dependencies"
  if ! run_privileged apk add --no-cache "${packages[@]}"; then
    print_alpine_install_help "$missing"
    fail "Failed to install Alpine backup dependencies"
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

normalize_smb_remote_root() {
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

sanitize_filename() {
  local value="$1"

  value="${value//[^A-Za-z0-9._-]/_}"
  while [ "${value#__}" != "$value" ]; do
    value="${value#__}"
  done
  [ -n "$value" ] || value="file"
  printf '%s\n' "$value"
}

relative_or_absolute_path() {
  local path="$1"

  case "$path" in
    /*) printf '%s\n' "$path" ;;
    *) printf '%s/%s\n' "$APP_DIR" "$path" ;;
  esac
}

list_values() {
  local value="$1"
  local line

  value="${value//$'\r'/}"
  while IFS= read -r line || [ -n "$line" ]; do
    line="$(trim_space "$line")"
    [ -n "$line" ] || continue
    printf '%s\n' "$line"
  done <<< "$value"
}

add_unique_path() {
  local candidate="$1"
  local existing

  [ -n "$candidate" ] || return 0

  for existing in "${DISCOVERED_DBS[@]}"; do
    if [ "$existing" = "$candidate" ]; then
      return 0
    fi
  done

  DISCOVERED_DBS+=("$candidate")
}

read_mount_field() {
  awk -v mount_point="$1" -v field="$2" '
    function unescape_mount_field(value) {
      gsub(/\\040/, " ", value)
      gsub(/\\011/, "\t", value)
      gsub(/\\012/, "\n", value)
      gsub(/\\134/, sprintf("%c", 92), value)
      return value
    }
    unescape_mount_field($2) == mount_point {
      print unescape_mount_field($field)
      found = 1
      exit
    }
    END { exit found ? 0 : 1 }
  ' "$MOUNTS_FILE"
}

is_path_mounted() {
  local mount_point="$1"

  read_mount_field "$mount_point" 2 >/dev/null
}

mounted_source_for_path() {
  local mount_point="$1"

  read_mount_field "$mount_point" 1 || true
}

check_mount() {
  if [ "$REQUIRE_MOUNT" = "1" ]; then
    if ! is_path_mounted "$SHARE_MOUNT"; then
      fail "SHARE_MOUNT is not mounted: $SHARE_MOUNT"
    fi
    log "Confirmed mounted share: $(mounted_source_for_path "$SHARE_MOUNT") on $SHARE_MOUNT"
  else
    warn "REQUIRE_MOUNT=0; skipping mounted-share check for $SHARE_MOUNT"
  fi
}

app_running() {
  command -v ps >/dev/null 2>&1 || return 1
  ps 2>/dev/null | awk -v name="$APP_NAME" '
    $0 ~ name && $0 !~ /backup-app-to-share\.sh/ && $0 !~ /backup-zeroclaw-to-share\.sh/ && $0 !~ /backup-hermes-to-share\.sh/ { found = 1 }
    END { exit found ? 0 : 1 }
  '
}

detect_app_version() {
  local output=""
  local version_path

  if [ -n "$APP_VERSION_COMMAND" ] && command -v "$APP_VERSION_COMMAND" >/dev/null 2>&1; then
    output="$("$APP_VERSION_COMMAND" --version 2>/dev/null || true)"
  fi

  if [ -z "$output" ]; then
    while IFS= read -r version_path; do
      [ -n "$version_path" ] || continue
      if [ -x "$version_path" ]; then
        output="$("$version_path" --version 2>/dev/null || true)"
        [ -n "$output" ] && break
      fi
    done < <(list_values "$APP_VERSION_PATHS")
  fi

  if [ -z "$output" ] && [ "$APP_GIT_VERSION" = "1" ] && [ -d "${APP_DIR}/.git" ] && require_cmd git; then
    output="$(git -C "$APP_DIR" rev-parse HEAD 2>/dev/null || true)"
  fi

  if [ -n "$output" ]; then
    printf '%s\n' "$output" | awk 'NR == 1 { print; exit }'
  else
    printf 'unknown\n'
  fi
}

discover_sqlite_databases() {
  local candidate
  local path

  DISCOVERED_DBS=()

  while IFS= read -r candidate; do
    [ -n "$candidate" ] || continue
    path="$(relative_or_absolute_path "$candidate")"
    if [ -f "$path" ]; then
      add_unique_path "$path"
    fi
  done < <(list_values "$APP_SQLITE_CANDIDATES")

  while IFS= read -r path; do
    [ -n "$path" ] || continue
    add_unique_path "$path"
  done < <(find "$APP_DIR" -type f \( -name '*.db' -o -name '*.sqlite' -o -name '*.sqlite3' \) -print 2>/dev/null || true)
}

copy_config_files() {
  local config
  local path
  local base
  local dest
  local copied=0

  while IFS= read -r config; do
    [ -n "$config" ] || continue
    path="$(relative_or_absolute_path "$config")"

    if [ ! -f "$path" ]; then
      continue
    fi

    mkdir -p "${STAGING_DIR}/configs"
    base="$(sanitize_filename "${path##*/}")"
    dest="${STAGING_DIR}/configs/${base}"

    if [ -e "$dest" ]; then
      dest="${STAGING_DIR}/configs/$(sanitize_filename "${path#/}")"
    fi

    cp "$path" "$dest"
    CONFIG_FILES_COPIED+=("$path")
    copied=$((copied + 1))
    log "Copied config file into backup: $path"
  done < <(list_values "$APP_CONFIG_FILES")

  if [ "$copied" -eq 0 ]; then
    warn "No configured app config files were found"
  fi
}

create_extra_paths_tarball() {
  local extra
  local path
  local names_file="${STAGING_DIR}/extra-paths.txt"
  local count=0

  while IFS= read -r extra; do
    [ -n "$extra" ] || continue
    path="$(relative_or_absolute_path "$extra")"
    if [ -e "$path" ]; then
      printf '%s\n' "$path" >> "$names_file"
      EXTRA_PATHS_INCLUDED+=("$path")
      count=$((count + 1))
    fi
  done < <(list_values "$APP_EXTRA_PATHS")

  if [ "$count" -eq 0 ]; then
    rm -f "$names_file"
    return
  fi

  log "Creating extra paths tarball: ${STAGING_DIR}/${APP_NAME}-extra-paths.tar.gz"
  tar -czf "${STAGING_DIR}/${APP_NAME}-extra-paths.tar.gz" -T "$names_file"
}

backup_sqlite_databases() {
  local db
  local index=0
  local stem
  local backup_file
  local sql_file
  local result

  if [ "${#DISCOVERED_DBS[@]}" -eq 0 ]; then
    {
      printf 'No SQLite databases were found under %s.\n' "$APP_DIR"
      printf 'Checked at %s on host %s.\n' "$TIMESTAMP" "$HOST"
    } > "${STAGING_DIR}/sqlite_integrity_check.txt"
    return
  fi

  mkdir -p "${STAGING_DIR}/sqlite"
  : > "${STAGING_DIR}/sqlite_integrity_check.txt"

  for db in "${DISCOVERED_DBS[@]}"; do
    index=$((index + 1))
    stem="$(printf '%03d-%s' "$index" "$(sanitize_filename "${db##*/}")")"
    backup_file="${stem}.backup"
    sql_file="${stem}.sql"

    log "Backing up SQLite database with sqlite3 .backup: $db"
    (
      cd "${STAGING_DIR}/sqlite"
      sqlite3 "$db" ".backup '${backup_file}'"
      sqlite3 "$db" ".dump" > "$sql_file"
      sqlite3 "$backup_file" "PRAGMA integrity_check;" > "${stem}.integrity"
    )

    result="$(cat "${STAGING_DIR}/sqlite/${stem}.integrity")"
    {
      printf '%s\n' "database=$db"
      printf '%s\n' "backup=sqlite/${backup_file}"
      printf '%s\n' "$result"
      printf '\n'
    } >> "${STAGING_DIR}/sqlite_integrity_check.txt"

    if ! awk '
      NR == 1 && $0 == "ok" { ok = 1; next }
      { bad = 1 }
      END { exit (ok && !bad) ? 0 : 1 }
    ' "${STAGING_DIR}/sqlite/${stem}.integrity"; then
      fail "SQLite backup failed integrity check for $db; see ${STAGING_DIR}/sqlite_integrity_check.txt"
    fi

    rm -f "${STAGING_DIR}/sqlite/${stem}.integrity"
  done

  log "SQLite integrity checks passed for ${#DISCOVERED_DBS[@]} database(s)"
}

create_full_tarball() {
  local app_parent="${APP_DIR%/*}"
  local app_base="${APP_DIR##*/}"

  if [ -z "$app_parent" ]; then
    app_parent="/"
  fi

  log "Creating full app tarball: ${STAGING_DIR}/${APP_NAME}-full.tar.gz"
  tar -C "$app_parent" -cf - "$app_base" | gzip -c > "${STAGING_DIR}/${APP_NAME}-full.tar.gz"
}

write_manifest() {
  local version="$1"
  local db
  local config
  local extra

  {
    printf 'timestamp=%s\n' "$TIMESTAMP"
    printf 'app_name=%s\n' "$APP_NAME"
    printf 'app_version=%s\n' "$version"
    printf 'host=%s\n' "$HOST"
    printf 'app_user=%s\n' "$APP_USER"
    printf 'app_home=%s\n' "$APP_HOME"
    printf 'app_dir=%s\n' "$APP_DIR"
    printf 'dest_mode=%s\n' "$DEST_MODE"
    printf 'retention_days=%s\n' "$RETENTION_DAYS"
    printf 'clean_local_after_upload=%s\n' "$CLEAN_LOCAL_AFTER_UPLOAD"
    if [ "$DEST_MODE" = "smbclient" ]; then
      printf 'smb_share=%s\n' "$SMB_SHARE"
      printf 'smb_remote_root=%s\n' "$SMB_REMOTE_ROOT"
      printf 'smb_remote_path=%s\n' "$FINAL_DIR"
    else
      printf 'dest_root=%s\n' "$DEST_ROOT"
      printf 'share_mount=%s\n' "$SHARE_MOUNT"
    fi
    printf 'sqlite_count=%s\n' "${#DISCOVERED_DBS[@]}"
    if [ "${#DISCOVERED_DBS[@]}" -eq 0 ]; then
      printf 'sqlite_status=not found\n'
    else
      for db in "${DISCOVERED_DBS[@]}"; do
        printf 'sqlite_db=%s\n' "$db"
      done
    fi
    for config in "${CONFIG_FILES_COPIED[@]}"; do
      printf 'config_file=%s\n' "$config"
    done
    for extra in "${EXTRA_PATHS_INCLUDED[@]}"; do
      printf 'extra_path=%s\n' "$extra"
    done
  } > "${STAGING_DIR}/manifest.txt"
}

write_sha256sums() {
  log "Writing SHA256SUMS.txt"
  (
    cd "$STAGING_DIR"
    find . -type f ! -name 'SHA256SUMS.txt' -exec sha256sum {} \;
  ) > "${STAGING_DIR}/SHA256SUMS.txt"
}

create_backup_artifacts() {
  local version

  CONFIG_FILES_COPIED=()
  EXTRA_PATHS_INCLUDED=()
  version="$(detect_app_version)"

  copy_config_files
  backup_sqlite_databases
  create_full_tarball
  create_extra_paths_tarball
  write_manifest "$version"
  write_sha256sums
}

collect_upload_files() {
  local file
  local rel

  UPLOAD_FILES=()
  for rel in \
    "manifest.txt" \
    "SHA256SUMS.txt" \
    "${APP_NAME}-full.tar.gz" \
    "sqlite_integrity_check.txt" \
    "${APP_NAME}-extra-paths.tar.gz" \
    "extra-paths.txt"; do
    if [ -f "${STAGING_DIR}/${rel}" ]; then
      UPLOAD_FILES+=("$rel")
    fi
  done

  for rel in configs sqlite; do
    if [ -d "${STAGING_DIR}/${rel}" ]; then
      while IFS= read -r file; do
        [ -n "$file" ] || continue
        UPLOAD_FILES+=("${file#${STAGING_DIR}/}")
      done < <(find "${STAGING_DIR}/${rel}" -type f -print | sort)
    fi
  done
}

smbclient_run() {
  local command_string="$1"

  smbclient "$SMB_SHARE" -A "$SMB_CREDS" -c "$command_string"
}

ensure_smb_remote_dir() {
  local remote_dir="$1"
  local current=""
  local component
  local components=()

  [ -n "$remote_dir" ] || return 0

  IFS=/ read -r -a components <<< "$remote_dir"
  for component in "${components[@]}"; do
    [ -n "$component" ] || return 1
    current="$(join_remote_path "$current" "$component")"
    smbclient_run "mkdir ${current}" >/dev/null 2>&1 || true

    if ! smbclient_run "cd ${current}" >/dev/null 2>&1; then
      warn "Unable to access remote SMB directory after mkdir: $current"
      return 1
    fi
  done
}

remote_dir_for_relative_file() {
  local rel="$1"
  local subdir="${rel%/*}"

  if [ "$subdir" = "$rel" ]; then
    printf '%s\n' "$REMOTE_BACKUP_DIR"
  else
    printf '%s/%s\n' "$REMOTE_BACKUP_DIR" "$subdir"
  fi
}

upload_relative_file_smbclient() {
  local rel="$1"
  local local_dir
  local base
  local remote_dir

  case "$rel" in
    "" | /* | *..*)
      fail "Refusing unsafe relative upload path: $rel"
      ;;
  esac

  local_dir="${STAGING_DIR}/${rel%/*}"
  if [ "$local_dir" = "${STAGING_DIR}/${rel}" ]; then
    local_dir="$STAGING_DIR"
  fi
  base="${rel##*/}"
  remote_dir="$(remote_dir_for_relative_file "$rel")"

  ensure_smb_remote_dir "$remote_dir" || return 1
  log "Uploading artifact: $rel"
  if ! smbclient_run "lcd ${local_dir}; cd ${remote_dir}; put ${base}"; then
    warn "Failed to upload artifact: $rel"
    return 1
  fi
}

validate_smb_upload_listing() {
  local rel
  local remote_dir
  local base
  local listing

  for rel in "${UPLOAD_FILES[@]}"; do
    remote_dir="$(remote_dir_for_relative_file "$rel")"
    base="${rel##*/}"

    if ! listing="$(smbclient_run "cd ${remote_dir}; ls" 2>&1)"; then
      warn "Failed to list remote SMB backup directory: $remote_dir"
      printf '%s\n' "$listing"
      return 1
    fi

    if ! printf '%s\n' "$listing" | awk -v name="$base" '$1 == name { found = 1 } END { exit found ? 0 : 1 }'; then
      warn "Remote SMB listing did not include uploaded artifact: $rel"
      return 1
    fi
  done
}

upload_smbclient() {
  collect_upload_files

  if [ "${#UPLOAD_FILES[@]}" -eq 0 ]; then
    fail "No backup artifacts were found to upload from $STAGING_DIR"
  fi

  log "Uploading backup artifacts to SMB share: $SMB_SHARE"
  log "Using SMB credentials file: $SMB_CREDS"
  ensure_smb_remote_dir "$REMOTE_PARENT_DIR" || return 1

  if smbclient_run "cd ${REMOTE_BACKUP_DIR}" >/dev/null 2>&1; then
    warn "Remote timestamp directory already exists: $REMOTE_BACKUP_DIR"
    return 1
  fi

  if ! smbclient_run "cd ${REMOTE_PARENT_DIR}; mkdir ${TIMESTAMP}"; then
    warn "Failed to create remote backup directory: $REMOTE_BACKUP_DIR"
    return 1
  fi

  for rel in "${UPLOAD_FILES[@]}"; do
    upload_relative_file_smbclient "$rel" || return 1
  done

  log "Validating SMB upload with remote directory listings"
  validate_smb_upload_listing
}

create_secure_tmp_staging_dir() {
  local template="/tmp/${APP_NAME}-backup-${HOST}-${TIMESTAMP}.XXXXXX"

  if ! STAGING_DIR="$(mktemp -d "$template")"; then
    fail "Failed to create secure local staging directory under /tmp"
  fi

  STAGING_CREATED=1
  log "Created local staging directory: $STAGING_DIR"
}

create_mounted_staging_dir() {
  STAGING_DIR="${DEST_HOST_DIR}/.${TIMESTAMP}.tmp.$$"

  if [ -e "$FINAL_DIR" ]; then
    fail "Final backup directory already exists: $FINAL_DIR"
  fi

  if [ -e "$STAGING_DIR" ]; then
    fail "Temporary backup directory already exists: $STAGING_DIR"
  fi

  mkdir -p "$DEST_HOST_DIR"
  mkdir "$STAGING_DIR"
  STAGING_CREATED=1
  log "Created mounted staging directory: $STAGING_DIR"
}

promote_mounted_backup() {
  log "Promoting temporary backup into place: $FINAL_DIR"
  mv "$STAGING_DIR" "$FINAL_DIR"
  FINALIZED=1
}

cleanup_old_mounted_backups() {
  local old_dir
  local base

  log "Cleaning timestamped backups older than ${RETENTION_DAYS} days under ${DEST_HOST_DIR}"
  while IFS= read -r old_dir; do
    [ -n "$old_dir" ] || continue
    base="${old_dir##*/}"

    if [[ "$base" =~ ^[0-9]{8}_[0-9]{6}$ ]]; then
      log "Removing old backup directory: $old_dir"
      rm -rf -- "$old_dir" || warn "Failed to remove old backup directory: $old_dir"
    else
      warn "Skipping non-timestamp directory during retention cleanup: $old_dir"
    fi
  done < <(find "$DEST_HOST_DIR" -mindepth 1 -maxdepth 1 -type d -mtime +"$RETENTION_DAYS" -print 2>/dev/null || true)
}

cleanup_uploaded_local_tmp_if_requested() {
  local expected_prefix="/tmp/${APP_NAME}-backup-${HOST}-${TIMESTAMP}."

  if [ "$CLEAN_LOCAL_AFTER_UPLOAD" != "1" ]; then
    log "Leaving local staging directory in place after successful SMB upload: $STAGING_DIR"
    return
  fi

  case "$STAGING_DIR" in
    "$expected_prefix"*) ;;
    *) fail "Refusing to remove unexpected local staging path: $STAGING_DIR" ;;
  esac

  log "Removing local staging directory after successful SMB upload: $STAGING_DIR"
  rm -rf -- "$STAGING_DIR"
  STAGING_CREATED=0
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
    fail "Another ${APP_NAME} backup appears to be running; lock exists: $LOCK_DIR"
  fi
}

cleanup() {
  local status=$?

  if [ "$status" -ne 0 ] && [ "$STAGING_CREATED" = "1" ] && [ "$FINALIZED" != "1" ] && [ -n "${STAGING_DIR:-}" ] && [ -d "$STAGING_DIR" ]; then
    if [ "$PRESERVE_STAGING_ON_ERROR" = "1" ]; then
      warn "Leaving local backup staging directory in place after failure: $STAGING_DIR"
    else
      log "Removing incomplete temporary backup: $STAGING_DIR"
      rm -rf -- "$STAGING_DIR" || true
    fi
  fi

  if [ "$LOCK_HELD" = "1" ]; then
    rmdir "$LOCK_DIR" 2>/dev/null || true
  fi

  exit "$status"
}

usage() {
  cat <<'USAGE'
Usage:
  backup-app-to-share.sh
  backup-app-to-share.sh --smbclient-upload
  backup-app-to-share.sh --mounted
  backup-app-to-share.sh --help

Default DEST_MODE=smbclient creates a secure local staging directory under /tmp
and uploads known backup artifacts to SMB with smbclient. Mounted mode is
available with DEST_MODE=mounted for hosts where a share is already mounted.
USAGE
}

refresh_derived_paths() {
  APP_HOME="$(trim_trailing_slashes "$APP_HOME")"
  APP_DIR="$(trim_trailing_slashes "$APP_DIR")"
  DEST_ROOT="$(trim_trailing_slashes "$DEST_ROOT")"
  SHARE_MOUNT="$(trim_trailing_slashes "$SHARE_MOUNT")"
  SMB_SHARE="$(trim_trailing_slashes "$SMB_SHARE")"
  SMB_REMOTE_ROOT="$(normalize_smb_remote_root "$SMB_REMOTE_ROOT")"

  if [ "$DEST_MODE" = "smbclient" ]; then
    REMOTE_PARENT_DIR="$(join_remote_path "$SMB_REMOTE_ROOT" "$APP_NAME")"
    REMOTE_PARENT_DIR="$(join_remote_path "$REMOTE_PARENT_DIR" "$HOST")"
    REMOTE_BACKUP_DIR="$(join_remote_path "$REMOTE_PARENT_DIR" "$TIMESTAMP")"
    FINAL_DIR="${SMB_SHARE}/${REMOTE_BACKUP_DIR}"
  else
    DEST_HOST_DIR="${DEST_ROOT}/${APP_NAME}/${HOST}"
    FINAL_DIR="${DEST_HOST_DIR}/${TIMESTAMP}"
  fi
}

validate_common_settings() {
  safe_component "$APP_NAME" "APP_NAME"
  safe_component "$HOST" "SMB_HOST_DIR/host"
  safe_component "$TIMESTAMP" "TIMESTAMP"

  case "$APP_HOME" in
    /*) ;;
    *) fail "APP_HOME must be an absolute path: $APP_HOME" ;;
  esac

  case "$APP_DIR" in
    /*) ;;
    *) fail "APP_DIR must be an absolute path: $APP_DIR" ;;
  esac

  if [ ! -d "$APP_DIR" ]; then
    fail "APP_DIR does not exist: $APP_DIR"
  fi

  [[ "$RETENTION_DAYS" =~ ^[0-9]+$ ]] || fail "RETENTION_DAYS must be a non-negative integer: $RETENTION_DAYS"

  case "$DEST_MODE" in
    smbclient | mounted) ;;
    *) fail "DEST_MODE must be smbclient or mounted: $DEST_MODE" ;;
  esac

  case "$DRY_RUN" in
    0 | 1) ;;
    *) fail "DRY_RUN must be 0 or 1: $DRY_RUN" ;;
  esac

  case "$AUTO_INSTALL_DEPS" in
    0 | 1) ;;
    *) fail "AUTO_INSTALL_DEPS must be 0 or 1: $AUTO_INSTALL_DEPS" ;;
  esac

  case "$CLEAN_LOCAL_AFTER_UPLOAD" in
    0 | 1) ;;
    *) fail "CLEAN_LOCAL_AFTER_UPLOAD must be 0 or 1: $CLEAN_LOCAL_AFTER_UPLOAD" ;;
  esac
}

validate_smb_settings() {
  [ -n "$SMB_SHARE" ] || fail "SMB_SHARE is required when DEST_MODE=smbclient"
  [ -n "$SMB_CREDS" ] || fail "SMB_CREDS is required when DEST_MODE=smbclient"
  validate_remote_root "$SMB_REMOTE_ROOT"

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

  if [ "$DRY_RUN" = "0" ] && [ ! -r "$SMB_CREDS" ]; then
    log "ERROR: SMB credentials file is not readable by this user: $SMB_CREDS"
    log "Copy it to a user-readable root-owned source with:"
    log "  sudo install -o ${APP_USER} -g ${APP_USER} -m 600 /etc/smbcredentials/truenas-zeroclaw $SMB_CREDS"
    exit 1
  fi
}

validate_mounted_settings() {
  case "$DEST_ROOT" in
    /*) ;;
    *) fail "DEST_ROOT must be an absolute path: $DEST_ROOT" ;;
  esac

  case "$SHARE_MOUNT" in
    /*) ;;
    *) fail "SHARE_MOUNT must be an absolute path: $SHARE_MOUNT" ;;
  esac

  case "$REQUIRE_MOUNT" in
    0 | 1) ;;
    *) fail "REQUIRE_MOUNT must be 0 or 1: $REQUIRE_MOUNT" ;;
  esac

  if [ "$REQUIRE_MOUNT" = "1" ] && [ "$SHARE_MOUNT" != "/" ]; then
    case "$DEST_ROOT" in
      "$SHARE_MOUNT" | "$SHARE_MOUNT"/*) ;;
      *) fail "DEST_ROOT must be inside SHARE_MOUNT when REQUIRE_MOUNT=1: DEST_ROOT=$DEST_ROOT SHARE_MOUNT=$SHARE_MOUNT" ;;
    esac
  fi
}

validate_settings() {
  validate_common_settings

  if [ "$DEST_MODE" = "smbclient" ]; then
    validate_smb_settings
  else
    validate_mounted_settings
  fi
}

prepare_backup_inputs() {
  discover_sqlite_databases

  if app_running; then
    warn "$APP_NAME appears to be running; SQLite backup is safe, but the full tarball may capture live file state"
  fi
}

dry_run_summary() {
  log "DRY_RUN=1; no backup files or remote directories will be written"
  log "Would back up app directory: $APP_DIR"
  log "Would stage backup files under: /tmp/${APP_NAME}-backup-${HOST}-${TIMESTAMP}.XXXXXX"

  if [ "$DEST_MODE" = "smbclient" ]; then
    log "Would upload explicit backup artifacts to SMB path: $FINAL_DIR"
    log "Would not require SHARE_MOUNT to be mounted"
  else
    log "Would create mounted backup directory: $FINAL_DIR"
    log "Would skip mounted-share write because this is a dry run"
  fi

  if [ "${#DISCOVERED_DBS[@]}" -eq 0 ]; then
    warn "Would continue without SQLite backup because no database was found"
  else
    log "Would back up ${#DISCOVERED_DBS[@]} SQLite database(s) with sqlite3 .backup"
  fi

  log "Would create manifest.txt, ${APP_NAME}-full.tar.gz, sqlite_integrity_check.txt, and SHA256SUMS.txt"
  log "Would copy configured config files into configs/ when present"
}

run_smbclient_backup() {
  PRESERVE_STAGING_ON_ERROR=1
  acquire_lock

  if [ "$DRY_RUN" = "1" ]; then
    dry_run_summary
    return
  fi

  create_secure_tmp_staging_dir
  create_backup_artifacts

  if ! upload_smbclient; then
    warn "SMB upload failed; local backup retained at: $STAGING_DIR"
    return 1
  fi

  FINALIZED=1
  cleanup_uploaded_local_tmp_if_requested

  log "SMB upload backup completed successfully: $FINAL_DIR"
  log "Backups may contain API keys, tokens, and app secrets; protect this share as sensitive storage"
}

run_mounted_backup() {
  acquire_lock

  if [ "$DRY_RUN" = "1" ]; then
    dry_run_summary
    return
  fi

  check_mount
  create_mounted_staging_dir
  create_backup_artifacts
  promote_mounted_backup
  cleanup_old_mounted_backups

  log "Mounted-share backup completed successfully: $FINAL_DIR"
  log "Backups may contain API keys, tokens, and app secrets; protect this share as sensitive storage"
}

run_backup() {
  refresh_derived_paths
  validate_settings
  ensure_commands "${BASE_COMMANDS[@]}"

  if [ "$DEST_MODE" = "smbclient" ] && [ "$DRY_RUN" = "0" ]; then
    ensure_commands smbclient
  fi

  prepare_backup_inputs

  if [ "$DRY_RUN" = "0" ] && [ "${#DISCOVERED_DBS[@]}" -gt 0 ]; then
    ensure_commands sqlite3
  fi

  if [ "$DEST_MODE" = "smbclient" ]; then
    run_smbclient_backup
  else
    run_mounted_backup
  fi
}

short_hostname() {
  hostname -s 2>/dev/null || hostname 2>/dev/null || printf 'unknown-host'
}

APP_NAME="${APP_NAME:-app}"
APP_USER="${APP_USER:-admin}"
APP_HOME="${APP_HOME:-/home/${APP_USER}}"
APP_DIR="${APP_DIR:-${APP_HOME}/${APP_NAME}}"
APP_CONFIG_FILES="${APP_CONFIG_FILES:-}"
APP_SQLITE_CANDIDATES="${APP_SQLITE_CANDIDATES:-}"
APP_EXTRA_PATHS="${APP_EXTRA_PATHS:-}"
APP_VERSION_COMMAND="${APP_VERSION_COMMAND:-$APP_NAME}"
APP_VERSION_PATHS="${APP_VERSION_PATHS:-}"
APP_GIT_VERSION="${APP_GIT_VERSION:-0}"
DEST_MODE="${DEST_MODE:-smbclient}"
RETENTION_DAYS="${RETENTION_DAYS:-30}"
CLEAN_LOCAL_AFTER_UPLOAD="${CLEAN_LOCAL_AFTER_UPLOAD:-0}"
AUTO_INSTALL_DEPS="${AUTO_INSTALL_DEPS:-0}"
DRY_RUN="${DRY_RUN:-0}"
SMB_SHARE="${SMB_SHARE:-}"
SMB_CREDS="${SMB_CREDS:-/home/${APP_USER}/.smbcredentials/truenas-${APP_NAME}}"
SMB_REMOTE_ROOT="${SMB_REMOTE_ROOT:-}"
SMB_HOST_DIR="${SMB_HOST_DIR:-$(short_hostname)}"
DEST_ROOT="${DEST_ROOT:-/mnt/truenas}"
SHARE_MOUNT="${SHARE_MOUNT:-/mnt/truenas}"
REQUIRE_MOUNT="${REQUIRE_MOUNT:-1}"
TIMESTAMP="${TIMESTAMP:-$(date '+%Y%m%d_%H%M%S')}"
HOST="$SMB_HOST_DIR"
LOCK_DIR="${LOCK_DIR:-/tmp/${APP_NAME}-backup.lock}"
MOUNTS_FILE="/proc/self/mounts"
[ -r "$MOUNTS_FILE" ] || MOUNTS_FILE="/proc/mounts"

BASE_COMMANDS=(bash tar gzip find awk sha256sum)
DISCOVERED_DBS=()
CONFIG_FILES_COPIED=()
EXTRA_PATHS_INCLUDED=()
UPLOAD_FILES=()
STAGING_DIR=""
DEST_HOST_DIR=""
FINAL_DIR=""
REMOTE_PARENT_DIR=""
REMOTE_BACKUP_DIR=""
LOCK_HELD=0
STAGING_CREATED=0
FINALIZED=0
PRESERVE_STAGING_ON_ERROR=0

trap cleanup EXIT

main() {
  case "${1:-}" in
    --smbclient-upload)
      shift
      DEST_MODE=smbclient
      ;;
    --mounted)
      shift
      DEST_MODE=mounted
      ;;
    --setup-truenas)
      usage
      fail "The interactive mount setup wizard is no longer part of the generic engine; use docs/app-backup-to-truenas.md and prefer DEST_MODE=smbclient on Alpine/LXC hosts"
      ;;
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

  if [ "$#" -ne 0 ]; then
    usage
    fail "Unexpected extra argument(s): $*"
  fi

  run_backup
}

main "$@"

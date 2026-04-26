#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

APP_NAME="${APP_NAME:-zeroclaw}"
APP_USER="${APP_USER:-admin}"
APP_HOME="${APP_HOME:-/home/${APP_USER}}"
APP_DIR="${APP_DIR:-${APP_HOME}/.zeroclaw}"
APP_VERSION_COMMAND="${APP_VERSION_COMMAND:-zeroclaw}"
APP_GIT_VERSION="${APP_GIT_VERSION:-0}"

if [ -z "${APP_VERSION_PATHS:-}" ]; then
  APP_VERSION_PATHS="$(printf '%s\n' \
    "/home/admin/.cargo/bin/zeroclaw" \
    "${APP_HOME}/.local/bin/zeroclaw")"
fi

if [ -z "${APP_CONFIG_FILES:-}" ]; then
  APP_CONFIG_FILES="$(printf '%s\n' \
    "${APP_DIR}/config.toml")"
fi

if [ -z "${APP_SQLITE_CANDIDATES:-}" ]; then
  APP_SQLITE_CANDIDATES="$(printf '%s\n' \
    "${APP_DIR}/workspace/memory/brain.db")"
fi

export APP_NAME
export APP_USER
export APP_HOME
export APP_DIR
export APP_CONFIG_FILES
export APP_SQLITE_CANDIDATES
export APP_VERSION_COMMAND
export APP_VERSION_PATHS
export APP_GIT_VERSION

exec "${SCRIPT_DIR}/backup-app-to-share.sh" "$@"

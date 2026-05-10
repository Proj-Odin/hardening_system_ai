#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

APP_NAME="${APP_NAME:-hermes}"
APP_USER="${APP_USER:-admin}"
APP_HOME="${APP_HOME:-/home/${APP_USER}}"

if [ -z "${APP_DIR:-}" ]; then
  for candidate in \
    "${APP_HOME}/hermes" \
    "${APP_HOME}/.hermes" \
    "/opt/hermes" \
    "/srv/hermes"; do
    if [ -d "$candidate" ]; then
      APP_DIR="$candidate"
      break
    fi
  done
  APP_DIR="${APP_DIR:-${APP_HOME}/hermes}"
fi

APP_VERSION_COMMAND="${APP_VERSION_COMMAND:-hermes}"
APP_GIT_VERSION="${APP_GIT_VERSION:-1}"

if [ -z "${APP_CONFIG_FILES:-}" ]; then
  APP_CONFIG_FILES="$(printf '%s\n' \
    "${APP_DIR}/.env" \
    "${APP_DIR}/config.toml" \
    "${APP_DIR}/config.yaml" \
    "${APP_DIR}/config.yml" \
    "${APP_DIR}/settings.toml" \
    "${APP_DIR}/settings.yaml" \
    "${APP_DIR}/docker-compose.yml")"
fi

if [ -z "${APP_SQLITE_CANDIDATES:-}" ]; then
  APP_SQLITE_CANDIDATES=""
fi

export APP_NAME
export APP_USER
export APP_HOME
export APP_DIR
export APP_CONFIG_FILES
export APP_SQLITE_CANDIDATES
export APP_VERSION_COMMAND
export APP_GIT_VERSION

exec "${SCRIPT_DIR}/backup-app-to-share.sh" "$@"

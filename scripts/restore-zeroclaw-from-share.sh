#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

APP_NAME="${APP_NAME:-zeroclaw}"
APP_USER="${APP_USER:-admin}"
APP_HOME="${APP_HOME:-/home/${APP_USER}}"
APP_DIR="${APP_DIR:-${APP_HOME}/.zeroclaw}"
SMB_REMOTE_ROOT="${SMB_REMOTE_ROOT:-zeroclaw-backups}"

export APP_NAME
export APP_USER
export APP_HOME
export APP_DIR
export SMB_REMOTE_ROOT

exec "${SCRIPT_DIR}/restore-app-from-share.sh" "$@"

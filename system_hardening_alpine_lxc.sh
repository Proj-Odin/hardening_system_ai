#!/usr/bin/env sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
export HARDENING_TARGET_PRESET=lxc

exec bash "$SCRIPT_DIR/system_hardening_alpine.sh" "$@"

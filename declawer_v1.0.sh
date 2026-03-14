#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# UNSUPPORTED SCRIPT - BLOCKED BY DEFAULT
# ============================================================
# WARNING:
# This file is a legacy declawer/bootstrap path and is NOT an approved
# installer for the ZeroClaw stack.
#
# To prevent accidental deployment drift, this script always fails closed.
# Do not bypass this guard in production.
#
# ZeroClaw official site: https://www.zeroclawlabs.ai/
# ZeroClaw official repo: https://github.com/zeroclaw-labs/zeroclaw
# ============================================================

cat >&2 <<'EOF'
========================================================================
BLOCKED: declawer_v1.0.sh is unsupported for ZeroClaw.

Reason:
- This legacy script was derived from a different gateway bootstrap flow.
- A complete, verified dependency/flag/runtime mapping to ZeroClaw has NOT
  been validated in this repository.
- Running it may create inconsistent users, services, firewall rules, and
  runtime settings.

Required action:
1) Use the maintained hardening workflow in system_hardening.sh.
2) Follow ZeroClaw official docs for gateway installation/runtime setup.
3) If a replacement bootstrap is needed, create a new script with a
   fully verified mapping and explicit test coverage.
========================================================================
EOF

exit 1

#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

python3 -m pip install --upgrade pip pip-tools
python3 -m piptools compile \
  --generate-hashes \
  --resolver=backtracking \
  --output-file "${SCRIPT_DIR}/requirements.lock" \
  "${SCRIPT_DIR}/requirements.in"

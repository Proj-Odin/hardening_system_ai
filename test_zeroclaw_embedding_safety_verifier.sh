#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_FILE="$(mktemp)"
trap 'rm -f "${OUT_FILE}"' EXIT

start_ts="$(date +%s)"
set +e
LITELLM_BASE_URL="http://127.0.0.1:9/v1" \
LITELLM_CLIENT_KEY="test-key" \
CURL_CONNECT_TIMEOUT=1 \
CURL_MAX_TIME=2 \
CURL_RETRY=0 \
timeout 8 bash "${ROOT_DIR}/scripts/verify-zeroclaw-embedding-safety.sh" >"${OUT_FILE}" 2>&1
status=$?
set -e
end_ts="$(date +%s)"
elapsed=$((end_ts - start_ts))

if [[ "${status}" -eq 124 ]]; then
  echo "FAIL: verifier hung instead of respecting curl timeouts" >&2
  cat "${OUT_FILE}" >&2
  exit 1
fi

if [[ "${status}" -eq 0 ]]; then
  echo "FAIL: verifier unexpectedly succeeded against an unreachable endpoint" >&2
  cat "${OUT_FILE}" >&2
  exit 1
fi

if [[ "${elapsed}" -gt 8 ]]; then
  echo "FAIL: verifier took ${elapsed}s, expected bounded completion" >&2
  cat "${OUT_FILE}" >&2
  exit 1
fi

if ! grep -Eq 'unreachable|timed out|HTTP 000' "${OUT_FILE}"; then
  echo "FAIL: verifier did not print a clear unreachable/timeout message" >&2
  cat "${OUT_FILE}" >&2
  exit 1
fi

echo "ZeroClaw embedding verifier timeout test passed."

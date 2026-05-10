#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

APP_USER="${APP_USER:-zeroclaw}"
APP_HOME="${APP_HOME:-}"
SOURCE_DIR="${SOURCE_DIR:-}"
APPLY=0

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage: patch-zeroclaw-sanitize-embeddings.sh [options]

This is an optional source-patch planning helper. It does not patch ZeroClaw
runtime code unless --apply is passed, and even --apply only writes a local
review plan into the source tree.

Options:
  --user USER          ZeroClaw account. Default: zeroclaw.
  --source-dir PATH    ZeroClaw source path. Default: /home/USER/.zeroclaw/src.
  --apply              Write EMBEDDING_SANITIZATION_PATCH_PLAN.md into source-dir.
  -h, --help           Show this help.
EOF
}

die_arg() {
  die "$1 requires a value"
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --user)
        shift
        [ "$#" -gt 0 ] || die_arg "--user"
        APP_USER="$1"
        ;;
      --source-dir)
        shift
        [ "$#" -gt 0 ] || die_arg "--source-dir"
        SOURCE_DIR="$1"
        ;;
      --apply) APPLY=1 ;;
      -h|--help)
        usage
        exit 0
        ;;
      *) die "Unknown option: $1" ;;
    esac
    shift
  done
}

resolve_source_dir() {
  if [ -z "$APP_HOME" ]; then
    APP_HOME="$(getent passwd "$APP_USER" 2>/dev/null | awk -F: '{print $6}' || true)"
    [ -n "$APP_HOME" ] || APP_HOME="/home/${APP_USER}"
  fi
  [ -n "$SOURCE_DIR" ] || SOURCE_DIR="${APP_HOME}/.zeroclaw/src"
}

print_plan() {
  cat <<'EOF'
Desired upstream/runtime fix for ZeroClaw embedding safety:

1. Split provider payload from memory payload.
   - Clone the original provider request before any memory processing.
   - Preserve the live text/image/multimodal payload for vision dispatch.

2. Add sanitize_for_embedding(input) -> string.
   - Keep normal text, assistant text, captions, OCR, and summaries that are already plain text.
   - Strip image_url fields, base64, raw bytes, Telegram file blobs/file IDs, binary data,
     provider-specific image markers, and non-text multimodal content array objects.
   - Optionally replace media with a short placeholder such as "[image attached]".
   - Enforce a max text length.
   - Return an empty string when no useful text remains.

3. Skip media-only embeddings.
   - Do not call the embedding provider when sanitization leaves empty text.
   - Log: "Skipping embedding: no text content after media sanitization".
   - Do not fail the user chat/image request.

4. Add tests.
   - Text-only: embedder receives text.
   - Image-only: embedder is skipped and provider still receives image.
   - Text+image: provider receives text+image, embedder receives text only, original payload is not mutated.
   - Base64/image_url: never reaches /v1/embeddings.
   - Telegram image message: memory autosave does not corrupt provider input.
   - Embedding provider failure: chat/image request still completes unless memory is explicitly required.
EOF
}

write_plan() {
  [ -d "$SOURCE_DIR" ] || die "ZeroClaw source directory not found: $SOURCE_DIR"
  local plan_file
  plan_file="${SOURCE_DIR}/EMBEDDING_SANITIZATION_PATCH_PLAN.md"
  {
    printf '# ZeroClaw Embedding Sanitization Patch Plan\n\n'
    print_plan
  } > "$plan_file"
  printf 'Wrote source patch plan: %s\n' "$plan_file"
  printf 'No ZeroClaw runtime files were modified by this helper.\n'
}

main() {
  parse_args "$@"
  resolve_source_dir
  if [ "$APPLY" -eq 1 ]; then
    write_plan
  else
    printf 'ZeroClaw source path: %s\n\n' "$SOURCE_DIR"
    print_plan
    printf '\nRun with --apply to write this plan into the source tree for review.\n'
  fi
}

main "$@"

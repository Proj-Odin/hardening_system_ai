#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

APP_USER="${APP_USER:-zeroclaw}"
APP_HOME="${APP_HOME:-}"
CONFIG_FILE="${CONFIG_FILE:-}"
MODE=""
YES=0
GEMMA_DIMS="${GEMMA_DIMS:-}"

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2
}

warn() {
  printf '[WARN] %s\n' "$*" >&2
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage: configure-zeroclaw-safe-embeddings.sh [mode] [options]

Modes:
  --disable-embeddings             Set [memory].embedding_provider = "none".
  --enable-text-embeddings         Enable LiteLLM embed-nomic text embeddings.
  --enable-text-embeddings-gemma   Enable LiteLLM embed-embeddinggemma text embeddings.

Options:
  --user USER                      ZeroClaw account. Default: zeroclaw.
  --config PATH                    Config path. Default: /home/USER/.zeroclaw/config.toml.
  --embedding-dimensions N         Dimension to use with --enable-text-embeddings-gemma.
  --yes                            Non-interactive mode.
  -h, --help                       Show this help.
EOF
}

die_arg() {
  die "$1 requires a value"
}

set_mode() {
  [ -z "$MODE" ] || die "Choose only one mode."
  MODE="$1"
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --disable-embeddings) set_mode "disable" ;;
      --enable-text-embeddings) set_mode "nomic" ;;
      --enable-text-embeddings-gemma) set_mode "gemma" ;;
      --user)
        shift
        [ "$#" -gt 0 ] || die_arg "--user"
        APP_USER="$1"
        ;;
      --config)
        shift
        [ "$#" -gt 0 ] || die_arg "--config"
        CONFIG_FILE="$1"
        ;;
      --embedding-dimensions)
        shift
        [ "$#" -gt 0 ] || die_arg "--embedding-dimensions"
        GEMMA_DIMS="$1"
        ;;
      --yes) YES=1 ;;
      -h|--help)
        usage
        exit 0
        ;;
      *) die "Unknown option: $1" ;;
    esac
    shift
  done
}

resolve_paths() {
  [ -n "$MODE" ] || die "Choose a mode. See --help."
  if [ -z "$APP_HOME" ]; then
    APP_HOME="$(getent passwd "$APP_USER" 2>/dev/null | awk -F: '{print $6}' || true)"
    [ -n "$APP_HOME" ] || APP_HOME="/home/${APP_USER}"
  fi
  [ -n "$CONFIG_FILE" ] || CONFIG_FILE="${APP_HOME}/.zeroclaw/config.toml"
  [ -f "$CONFIG_FILE" ] || die "ZeroClaw config not found: $CONFIG_FILE"
}

confirm_enable_warning() {
  case "$MODE" in
    nomic|gemma)
      warn "Do not enable text embeddings for image/multimodal workflows unless ZeroClaw sanitizes memory input before embedding."
      if [ "$YES" -eq 0 ] && [ -t 0 ]; then
        local answer
        read -r -p "Continue enabling text embeddings? [y/N]: " answer
        case "$answer" in
          y|Y|yes|YES) ;;
          *) die "User declined enabling embeddings." ;;
        esac
      elif [ "$YES" -eq 0 ]; then
        die "Confirmation required. Rerun with --yes after reviewing the warning."
      fi
      ;;
  esac
}

prompt_gemma_dimensions() {
  [ "$MODE" = "gemma" ] || return 0
  if [ -z "$GEMMA_DIMS" ] && [ -t 0 ] && [ "$YES" -eq 0 ]; then
    read -r -p "Embedding dimensions for embed-embeddinggemma: " GEMMA_DIMS
  fi
  [ -n "$GEMMA_DIMS" ] || die "Pass --embedding-dimensions for embed-embeddinggemma until the deployed model dimension is confirmed."
  case "$GEMMA_DIMS" in
    ''|*[!0-9]*) die "--embedding-dimensions must be a positive integer" ;;
  esac
  [ "$GEMMA_DIMS" -gt 0 ] || die "--embedding-dimensions must be positive"
}

backup_config() {
  local backup
  backup="${CONFIG_FILE}.bak.$(date '+%Y%m%d_%H%M%S')"
  cp -p "$CONFIG_FILE" "$backup"
  log "Backed up config: $backup"
}

stat_owner_mode() {
  CONFIG_OWNER_GROUP="$(stat -c '%u:%g' "$CONFIG_FILE" 2>/dev/null || printf '')"
  CONFIG_MODE="$(stat -c '%a' "$CONFIG_FILE" 2>/dev/null || printf '')"
}

set_memory_config() {
  local provider="$1"
  local model="${2:-}"
  local dims="${3:-}"
  local set_model=0
  local tmp
  tmp="${CONFIG_FILE}.tmp.$$"
  [ -z "$model" ] || set_model=1

  awk \
    -v provider="$provider" \
    -v model="$model" \
    -v dims="$dims" \
    -v set_model="$set_model" '
      function emit_missing() {
        if (!wrote_provider) {
          print "embedding_provider = \"" provider "\""
        }
        if (set_model && !wrote_model) {
          print "embedding_model = \"" model "\""
        }
        if (set_model && !wrote_dims) {
          print "embedding_dimensions = " dims
        }
      }
      BEGIN {
        in_memory = 0
        saw_memory = 0
        wrote_provider = 0
        wrote_model = 0
        wrote_dims = 0
      }
      /^[[:space:]]*\[[^]]+\][[:space:]]*($|#)/ {
        if (in_memory) {
          emit_missing()
        }
        in_memory = ($0 ~ /^[[:space:]]*\[memory\][[:space:]]*($|#)/)
        if (in_memory) {
          saw_memory = 1
          wrote_provider = 0
          wrote_model = 0
          wrote_dims = 0
        }
        print
        next
      }
      in_memory && /^[[:space:]]*embedding_provider[[:space:]]*=/ {
        print "embedding_provider = \"" provider "\""
        wrote_provider = 1
        next
      }
      in_memory && set_model && /^[[:space:]]*embedding_model[[:space:]]*=/ {
        print "embedding_model = \"" model "\""
        wrote_model = 1
        next
      }
      in_memory && set_model && /^[[:space:]]*embedding_dimensions[[:space:]]*=/ {
        print "embedding_dimensions = " dims
        wrote_dims = 1
        next
      }
      { print }
      END {
        if (in_memory) {
          emit_missing()
        } else if (!saw_memory) {
          print ""
          print "[memory]"
          emit_missing()
        }
      }
    ' "$CONFIG_FILE" > "$tmp"

  if [ -n "${CONFIG_OWNER_GROUP:-}" ]; then
    chown "$CONFIG_OWNER_GROUP" "$tmp" 2>/dev/null || true
  fi
  if [ -n "${CONFIG_MODE:-}" ]; then
    chmod "$CONFIG_MODE" "$tmp" 2>/dev/null || true
  fi
  mv "$tmp" "$CONFIG_FILE"
}

toml_section_value() {
  local section="$1"
  local key="$2"
  awk -v section="$section" -v key="$key" '
    /^[[:space:]]*\[[^]]+\][[:space:]]*($|#)/ {
      current = $0
      sub(/^[[:space:]]*\[/, "", current)
      sub(/\][[:space:]]*($|#).*/, "", current)
      in_section = (current == section)
      next
    }
    in_section && $0 ~ "^[[:space:]]*" key "[[:space:]]*=" {
      sub(/^[^=]*=/, "")
      sub(/[[:space:]]+#.*$/, "")
      gsub(/^[[:space:]]+|[[:space:]]+$/, "")
      gsub(/^"|"$/, "")
      print
      exit
    }
  ' "$CONFIG_FILE"
}

detect_multimodal_enabled() {
  awk '
    /^[[:space:]]*\[[^]]+\][[:space:]]*($|#)/ {
      current = $0
      sub(/^[[:space:]]*\[/, "", current)
      sub(/\][[:space:]]*($|#).*/, "", current)
      in_risky = (current == "multimodal" || current == "media_pipeline" || current == "vision")
      next
    }
    in_risky && /^[[:space:]]*enabled[[:space:]]*=[[:space:]]*true[[:space:]]*($|#)/ { found = 1 }
    in_risky && /^[[:space:]]*vision_(provider|model)[[:space:]]*=/ { found = 1 }
    END { if (found) print "true" }
  ' "$CONFIG_FILE"
}

print_risk_if_needed() {
  local backend provider multimodal
  backend="$(toml_section_value memory backend)"
  provider="$(toml_section_value memory embedding_provider)"
  multimodal="$(detect_multimodal_enabled)"
  if [ "$backend" = "sqlite" ] && [ -n "$provider" ] && [ "$provider" != "none" ] && [ "$multimodal" = "true" ]; then
    warn "Risk: text embedder may receive image/multimodal payloads unless ZeroClaw sanitizes memory input."
  fi
}

print_result() {
  printf 'Updated %s\n' "$CONFIG_FILE"
  printf '[memory]\n'
  printf 'backend = %s\n' "$(toml_section_value memory backend)"
  printf 'auto_save = %s\n' "$(toml_section_value memory auto_save)"
  printf 'embedding_provider = %s\n' "$(toml_section_value memory embedding_provider)"
  printf 'embedding_model = %s\n' "$(toml_section_value memory embedding_model)"
  printf 'embedding_dimensions = %s\n' "$(toml_section_value memory embedding_dimensions)"
}

main() {
  parse_args "$@"
  resolve_paths
  confirm_enable_warning
  prompt_gemma_dimensions
  backup_config
  stat_owner_mode

  case "$MODE" in
    disable)
      set_memory_config "none"
      ;;
    nomic)
      set_memory_config "litellm" "embed-nomic" "768"
      ;;
    gemma)
      set_memory_config "litellm" "embed-embeddinggemma" "$GEMMA_DIMS"
      ;;
    *) die "Internal mode error" ;;
  esac

  print_result
  print_risk_if_needed
}

main "$@"

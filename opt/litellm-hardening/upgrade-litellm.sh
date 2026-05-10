#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"

usage() {
    cat <<'EOF'
Usage: upgrade-litellm.sh --version TAG --digest SHA256 [--env-file PATH] [--dry-run]

Performs a controlled container upgrade:
- backup current state
- update exact image tag and digest in the runtime env file
- cosign verify the new image
- deploy
- auto-rollback on validation failure
EOF
}

ENV_FILE="${DEFAULT_ENV_FILE}"
NEW_VERSION=""
NEW_DIGEST=""
DRY_RUN="${DRY_RUN:-false}"
CLI_DRY_RUN=false

main() {
    local backup_dir
    local previous_tag
    local previous_digest

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --env-file)
                ENV_FILE="$2"
                shift 2
                ;;
            --version)
                NEW_VERSION="$2"
                shift 2
                ;;
            --digest)
                NEW_DIGEST="$2"
                shift 2
                ;;
            --help|-h)
                usage
                exit 0
                ;;
            --dry-run)
                DRY_RUN=true
                CLI_DRY_RUN=true
                shift
                ;;
            *)
                die "Unknown argument: $1"
                ;;
        esac
    done

    require_root
    [[ -n "${NEW_VERSION}" ]] || die "--version is required."
    [[ -n "${NEW_DIGEST}" ]] || die "--digest is required."
    [[ "${NEW_DIGEST}" == sha256:* ]] || die "--digest must begin with sha256:."

    load_env_file "${ENV_FILE}"
    if bool_is_true "${CLI_DRY_RUN}"; then
        DRY_RUN=true
    fi
    umask 077
    if bool_is_true "${DRY_RUN}"; then
        printf 'DRY RUN: would upgrade LiteLLM image from %s@%s to %s@%s\n' "${LITELLM_IMAGE_TAG}" "${LITELLM_IMAGE_DIGEST}" "${NEW_VERSION}" "${NEW_DIGEST}"
        return 0
    fi
    backup_dir="$("${SCRIPT_DIR}/backup-litellm.sh" --env-file "${ENV_FILE}" --name pre-upgrade)"
    previous_tag="${LITELLM_IMAGE_TAG}"
    previous_digest="${LITELLM_IMAGE_DIGEST}"

    set_or_update_env "${ENV_FILE}" "LITELLM_IMAGE_TAG" "${NEW_VERSION}"
    set_or_update_env "${ENV_FILE}" "LITELLM_IMAGE_DIGEST" "${NEW_DIGEST}"

    if ! "${SCRIPT_DIR}/harden-litellm.sh" --env-file "${ENV_FILE}"; then
        warn "Upgrade failed. Rolling back."
        set_or_update_env "${ENV_FILE}" "LITELLM_IMAGE_TAG" "${previous_tag}"
        set_or_update_env "${ENV_FILE}" "LITELLM_IMAGE_DIGEST" "${previous_digest}"
        "${SCRIPT_DIR}/rollback-litellm.sh" --env-file "${ENV_FILE}" --backup-dir "${backup_dir}"
        die "Upgrade failed and rollback was invoked."
    fi
}

main "$@"

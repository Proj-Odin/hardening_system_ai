#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"

usage() {
    cat <<'EOF'
Usage: rollback-litellm.sh [--env-file PATH] [--backup-dir PATH] [--restore-database] [--dry-run]

Restores files from a previous backup and restarts the previously active service when possible.
EOF
}

ENV_FILE="${DEFAULT_ENV_FILE}"
BACKUP_DIR=""
RESTORE_DATABASE=false
DRY_RUN="${DRY_RUN:-false}"
CLI_DRY_RUN=false

restore_file_tree() {
    local source_root="$1"
    local relative_path
    local source_path
    local destination_path

    [[ -d "${source_root}" ]] || return 0
    while IFS= read -r relative_path; do
        ensure_directory "/${relative_path}" 0755 root root
    done < <(cd "${source_root}" && find . -type d -mindepth 1 -print | sed 's#^\./##')

    while IFS= read -r relative_path; do
        source_path="${source_root}/${relative_path}"
        destination_path="/${relative_path}"
        ensure_directory "$(dirname -- "${destination_path}")" 0755 root root
        cp -a "${source_path}" "${destination_path}"
    done < <(cd "${source_root}" && find . \( -type f -o -type l \) -mindepth 1 -print | sed 's#^\./##')
}

latest_backup_dir() {
    [[ -d "${BACKUP_ROOT}" ]] || return 1
    find "${BACKUP_ROOT}" -mindepth 1 -maxdepth 1 -type d | sort | tail -n 1
}

main() {
    local metadata_file
    local runtime_mode
    local backup_database_url
    local backup_env_file

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --env-file)
                ENV_FILE="$2"
                shift 2
                ;;
            --backup-dir)
                BACKUP_DIR="$2"
                shift 2
                ;;
            --restore-database)
                RESTORE_DATABASE=true
                shift
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

    if [[ -f "${ENV_FILE}" ]]; then
        load_env_file "${ENV_FILE}"
    else
        export BACKUP_ROOT="${DEFAULT_BACKUP_ROOT}"
    fi
    if bool_is_true "${CLI_DRY_RUN}"; then
        DRY_RUN=true
    fi
    umask 077

    if [[ -z "${BACKUP_DIR}" ]]; then
        BACKUP_DIR="$(latest_backup_dir)" || die "No backup directories found."
    fi
    [[ -d "${BACKUP_DIR}" ]] || die "Backup directory does not exist: ${BACKUP_DIR}"

    backup_env_file="${BACKUP_DIR}/files/${ENV_FILE#/}"
    assert_safe_salt_key_restore "${ENV_FILE}" "${backup_env_file}"

    if bool_is_true "${DRY_RUN}"; then
        printf 'DRY RUN: would restore LiteLLM files from %s\n' "${BACKUP_DIR}"
        if [[ "${RESTORE_DATABASE}" == true ]]; then
            printf 'DRY RUN: would restore the LiteLLM database dump if present.\n'
        fi
        return 0
    fi

    systemctl disable --now litellm-compose.service >/dev/null 2>&1 || true
    systemctl disable --now litellm-venv.service >/dev/null 2>&1 || true

    restore_file_tree "${BACKUP_DIR}/files"
    systemctl daemon-reload

    metadata_file="${BACKUP_DIR}/metadata.env"
    if [[ -f "${metadata_file}" ]]; then
        # shellcheck disable=SC1090
        . "${metadata_file}"
        runtime_mode="${BACKUP_RUNTIME_MODE:-legacy}"
    else
        runtime_mode="legacy"
    fi

    case "${runtime_mode}" in
        container)
            systemctl enable --now litellm-compose.service
            ;;
        venv)
            systemctl enable --now litellm-venv.service
            ;;
        legacy|none)
            if [[ -f "${metadata_file}" ]]; then
                while IFS='=' read -r key value; do
                    [[ "${key}" == PREEXISTING_SERVICE_* ]] || continue
                    [[ -n "${value}" ]] || continue
                    systemctl enable --now "${value}" || true
                done < "${metadata_file}"
            fi
            ;;
    esac

    if [[ "${RESTORE_DATABASE}" == true && -f "${BACKUP_DIR}/db/litellm-data.dump" ]]; then
        backup_database_url="$(discover_database_url 2>/dev/null || true)"
        [[ -n "${backup_database_url}" ]] || die "Cannot restore database without DATABASE_URL."
        require_command pg_restore
        pg_restore --clean --if-exists --no-owner --dbname "${backup_database_url}" "${BACKUP_DIR}/db/litellm-data.dump"
    fi
}

main "$@"

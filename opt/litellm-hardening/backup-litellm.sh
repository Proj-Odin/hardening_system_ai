#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"

usage() {
    cat <<'EOF'
Usage: backup-litellm.sh [--env-file PATH] [--name LABEL] [--dry-run]

Creates a root-only backup of LiteLLM-related files, systemd units, compose state,
and optional PostgreSQL metadata.
EOF
}

ENV_FILE="${DEFAULT_ENV_FILE}"
BACKUP_LABEL=""
DRY_RUN="${DRY_RUN:-false}"
CLI_DRY_RUN=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --env-file)
            ENV_FILE="$2"
            shift 2
            ;;
        --name)
            BACKUP_LABEL="$2"
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

main() {
    local backup_dir
    local metadata_file
    local service_name
    local fragment_path
    local dropin_dirs
    local container_entry
    local container_name
    local container_image
    local database_url
    local runtime_mode

    require_root
    umask 077

    if [[ -f "${ENV_FILE}" ]]; then
        load_env_file "${ENV_FILE}"
    else
        export BACKUP_ROOT="${DEFAULT_BACKUP_ROOT}"
        export STATE_ROOT="${DEFAULT_STATE_ROOT}"
        export DATA_ROOT="${DEFAULT_DATA_ROOT}"
    fi
    if bool_is_true "${CLI_DRY_RUN}"; then
        DRY_RUN=true
    fi

    backup_dir="${BACKUP_ROOT}/$(date +%Y%m%d_%H%M%S)"
    if [[ -n "${BACKUP_LABEL}" ]]; then
        backup_dir="${backup_dir}-${BACKUP_LABEL}"
    fi

    if bool_is_true "${DRY_RUN}"; then
        printf 'DRY RUN: would create backup directory %s\n' "${backup_dir}"
        printf 'DRY RUN: would back up %s\n' "${ENV_FILE}"
        printf 'DRY RUN: would capture LiteLLM-related systemd units, containers, and optional PostgreSQL metadata.\n'
        return 0
    fi

    ensure_directory "${backup_dir}" 0700 root root
    ensure_directory "${backup_dir}/services" 0700 root root
    ensure_directory "${backup_dir}/containers" 0700 root root
    ensure_directory "${backup_dir}/db" 0700 root root

    runtime_mode="$(determine_runtime_mode)"
    metadata_file="${backup_dir}/metadata.env"

    cat > "${metadata_file}" <<EOF
BACKUP_CREATED_AT=$(timestamp)
BACKUP_SOURCE_ENV_FILE=${ENV_FILE}
BACKUP_RUNTIME_MODE=${runtime_mode}
EOF
    chmod 0600 "${metadata_file}"
    chown root:root "${metadata_file}"

    backup_absolute_path "${ENV_FILE}" "${backup_dir}"
    backup_absolute_path "${DEFAULT_CONFIG_FILE}" "${backup_dir}"
    backup_absolute_path "${DEFAULT_ACTIVE_COMPOSE_FILE}" "${backup_dir}"
    backup_absolute_path "/etc/systemd/system/litellm-compose.service" "${backup_dir}"
    backup_absolute_path "/etc/systemd/system/litellm-venv.service" "${backup_dir}"
    backup_absolute_path "${DEFAULT_NGINX_SITE}" "${backup_dir}"
    backup_absolute_path "${DEFAULT_NGINX_LINK}" "${backup_dir}"
    backup_absolute_path "${TOOLKIT_ROOT}/compose/litellm.compose.yaml" "${backup_dir}"
    backup_absolute_path "${TOOLKIT_ROOT}/compose/litellm-ui.compose.yaml" "${backup_dir}"

    while IFS= read -r service_name; do
        [[ -n "${service_name}" ]] || continue
        printf 'PREEXISTING_SERVICE_%s=%s\n' "${service_name//[^A-Za-z0-9_]/_}" "${service_name}" >> "${metadata_file}"
        systemctl cat "${service_name}" > "${backup_dir}/services/${service_name}.unit.txt" 2>/dev/null || true
        fragment_path="$(systemctl show -p FragmentPath --value "${service_name}" 2>/dev/null || true)"
        [[ -n "${fragment_path}" ]] && backup_absolute_path "${fragment_path}" "${backup_dir}"
        dropin_dirs="$(systemctl show -p DropInPaths --value "${service_name}" 2>/dev/null || true)"
        if [[ -n "${dropin_dirs}" ]]; then
            while IFS= read -r dropin_path; do
                [[ -n "${dropin_path}" ]] && backup_absolute_path "${dropin_path}" "${backup_dir}"
            done <<< "${dropin_dirs}"
        fi
    done < <(list_litellm_systemd_units)

    while IFS= read -r container_entry; do
        [[ -n "${container_entry}" ]] || continue
        container_name="${container_entry%%|*}"
        container_image="${container_entry#*|}"
        printf 'CONTAINER_%s=%s\n' "${container_name//[^A-Za-z0-9_]/_}" "${container_image}" >> "${metadata_file}"
        "${CONTAINER_CMD[@]}" inspect "${container_name}" > "${backup_dir}/containers/${container_name}.inspect.json" 2>/dev/null || true
    done < <(list_litellm_containers || true)

    database_url="$(discover_database_url 2>/dev/null || true)"
    if [[ -n "${database_url}" ]] && command -v pg_dump >/dev/null 2>&1; then
        pg_dump --schema-only --file "${backup_dir}/db/litellm-schema.sql" "${database_url}" >/dev/null 2>&1 || warn "Schema-only pg_dump failed."
        if bool_is_true "${ROLLBACK_RESTORE_DATABASE:-false}"; then
            pg_dump --format=custom --file "${backup_dir}/db/litellm-data.dump" "${database_url}" >/dev/null 2>&1 || warn "Full pg_dump failed."
        fi
    fi

    printf '%s\n' "${backup_dir}"
}

main "$@"

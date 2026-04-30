#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"

usage() {
    cat <<'EOF'
Usage: harden-litellm.sh [--env-file PATH] [--mode auto|container|interim|venv] [--skip-backup] [--dry-run]

Default behavior:
- preserve existing LiteLLM master/salt keys if they can be discovered
- generate LITELLM_SALT_KEY once only when no LiteLLM state exists yet
- prefer verified, digest-pinned container deployment
- fall back to interim hardening if migration is unsafe right now
- refuse the venv path until a hash-locked requirements file exists
EOF
}

ENV_FILE="${DEFAULT_ENV_FILE}"
MODE_OVERRIDE=""
SKIP_BACKUP=false
DRY_RUN="${DRY_RUN:-false}"
CLI_DRY_RUN=false

ensure_runtime_layout() {
    ensure_directory "$(dirname -- "${ENV_FILE}")" 0750 root root
    ensure_directory "${BACKUP_ROOT}" 0700 root root
    ensure_directory "${STATE_ROOT}" 0750 root root
    ensure_directory "${STATE_ROOT}/cosign" 0750 root root
    ensure_directory "${DATA_ROOT}" 0755 root root
    ensure_directory "${LITELLM_MIGRATION_DIR}" 0750 "${LITELLM_RUNTIME_UID}" "${LITELLM_RUNTIME_GID}"
    ensure_directory "${XDG_CACHE_HOME}" 0750 "${LITELLM_RUNTIME_UID}" "${LITELLM_RUNTIME_GID}"
    if bool_is_true "${ENABLE_UI:-false}"; then
        ensure_directory "${LITELLM_UI_PATH}" 0750 "${LITELLM_RUNTIME_UID}" "${LITELLM_RUNTIME_GID}"
        ensure_directory "${LITELLM_ASSETS_PATH}" 0750 "${LITELLM_RUNTIME_UID}" "${LITELLM_RUNTIME_GID}"
    fi
}

preserve_or_create_secrets() {
    local discovered_master=""

    discovered_master="$(discover_existing_secret "LITELLM_MASTER_KEY" 2>/dev/null || true)"
    if [[ -z "${LITELLM_MASTER_KEY:-}" && -n "${discovered_master}" ]]; then
        if bool_is_true "${DRY_RUN}"; then
            log "DRY RUN: would write the existing LiteLLM master key into ${ENV_FILE}."
        else
            set_or_update_env "${ENV_FILE}" "LITELLM_MASTER_KEY" "${discovered_master}"
        fi
        export LITELLM_MASTER_KEY="${discovered_master}"
    fi

    assert_nonempty "LITELLM_MASTER_KEY"
    assert_master_key_shape
    salt_key_preflight_guard "${ENV_FILE}"
}

enforce_required_settings() {
    assert_required_setting "USE_PRISMA_MIGRATE" "True"
    assert_required_setting "LITELLM_MODE" "PRODUCTION"
    validate_bind_safety
    validate_backend_network_safety
    [[ "${MAX_IMAGE_URL_DOWNLOAD_SIZE_MB:-0}" == "0" ]] || warn "MAX_IMAGE_URL_DOWNLOAD_SIZE_MB is not 0. Remote image URL fetches increase data exposure risk."
}

sync_static_assets() {
    local compose_variant
    local nginx_template

    compose_variant="${DEFAULT_API_COMPOSE_FILE}"
    nginx_template="${DEFAULT_NGINX_API_TEMPLATE}"
    if bool_is_true "${ENABLE_UI:-false}"; then
        compose_variant="${DEFAULT_UI_COMPOSE_FILE}"
        nginx_template="${DEFAULT_NGINX_UI_TEMPLATE}"
    fi

    if bool_is_true "${DRY_RUN}"; then
        log "DRY RUN: would install ${compose_variant} as ${DEFAULT_ACTIVE_COMPOSE_FILE} with mode 0640."
        log "DRY RUN: would lock ${DEFAULT_CONFIG_FILE} to mode 0640."
        log "DRY RUN: would install systemd unit files for compose and venv modes."
        if bool_is_true "${ENABLE_NGINX:-false}"; then
            log "DRY RUN: would render the minimal Nginx proxy config from ${nginx_template}."
        fi
        return 0
    fi

    safe_copy_file "${compose_variant}" "${DEFAULT_ACTIVE_COMPOSE_FILE}" 0640 root root
    safe_copy_file "${DEFAULT_COMPOSE_UNIT_SOURCE}" "/etc/systemd/system/litellm-compose.service" 0644 root root
    safe_copy_file "${DEFAULT_VENV_UNIT_SOURCE}" "/etc/systemd/system/litellm-venv.service" 0644 root root
    chmod 0640 "${DEFAULT_CONFIG_FILE}"
    chown root:root "${DEFAULT_CONFIG_FILE}"

    if bool_is_true "${ENABLE_NGINX:-false}"; then
        require_command nginx
        render_nginx_template \
            "${nginx_template}" \
            "${DEFAULT_NGINX_SITE}" \
            "${LITELLM_BIND_ADDRESS}" \
            "${LITELLM_BIND_PORT}" \
            "${SERVER_NAME}" \
            "${TLS_CERT_FILE}" \
            "${TLS_KEY_FILE}"
        chmod 0640 "${DEFAULT_NGINX_SITE}"
        chown root:root "${DEFAULT_NGINX_SITE}"
        ln -sfn "${DEFAULT_NGINX_SITE}" "${DEFAULT_NGINX_LINK}"
        nginx -t >/dev/null
        systemctl enable --now nginx >/dev/null 2>&1 || true
        systemctl reload nginx
    fi
}

backup_if_enabled() {
    if [[ "${SKIP_BACKUP}" == false ]]; then
        if bool_is_true "${DRY_RUN}"; then
            log "DRY RUN: would create a LiteLLM backup before applying changes."
            return 0
        fi
        "${SCRIPT_DIR}/backup-litellm.sh" --env-file "${ENV_FILE}" >/dev/null
    fi
}

decide_mode() {
    local requested_mode="${MODE_OVERRIDE:-${DEPLOYMENT_MODE:-auto}}"
    local legacy_service

    case "${requested_mode}" in
        container|interim|venv)
            printf '%s\n' "${requested_mode}"
            return 0
            ;;
        auto)
            ;;
        *)
            die "Unsupported mode: ${requested_mode}"
            ;;
    esac

    if command -v docker >/dev/null 2>&1 || command -v podman >/dev/null 2>&1; then
        printf 'container\n'
        return 0
    fi

    legacy_service="$(choose_legacy_service 2>/dev/null || true)"
    if [[ -n "${legacy_service}" ]]; then
        printf 'interim\n'
        return 0
    fi

    if bool_is_true "${ALLOW_VENV_FALLBACK:-false}"; then
        printf 'venv\n'
        return 0
    fi

    die "No safe deployment mode could be selected."
}

disable_legacy_service() {
    local service_name="$1"
    [[ -n "${service_name}" ]] || return 0
    systemctl disable --now "${service_name}"
}

restore_legacy_service() {
    local service_name="$1"
    [[ -n "${service_name}" ]] || return 0
    systemctl enable --now "${service_name}"
}

deploy_container() {
    local legacy_service=""
    local stage_port="${LITELLM_STAGING_BIND_PORT}"
    local staged=false

    setup_container_runtime
    require_command cosign
    assert_nonempty "DATABASE_URL"
    if bool_is_true "${DRY_RUN}"; then
        log "DRY RUN: would verify $(get_image_tag_ref) and $(get_image_digest_ref) with cosign."
        sync_static_assets
        log "DRY RUN: would enable and start litellm-compose.service after validation."
        return 0
    fi
    verify_image_signature
    sync_static_assets
    systemctl daemon-reload

    legacy_service="$(choose_legacy_service 2>/dev/null || true)"

    if [[ -n "${legacy_service}" && "${legacy_service}" != "litellm-compose.service" ]] && systemctl is-active --quiet "${legacy_service}" 2>/dev/null; then
        if port_is_listening "${LITELLM_BIND_PORT}"; then
            log "Starting staged container validation on ${LITELLM_BIND_ADDRESS}:${stage_port}"
            env LITELLM_BIND_PORT="${stage_port}" "${COMPOSE_CMD[@]}" -p "${COMPOSE_PROJECT_NAME:-litellm}" -f "${DEFAULT_ACTIVE_COMPOSE_FILE}" up -d --remove-orphans
            if ! http_health_ok "http://${LITELLM_BIND_ADDRESS}:${stage_port}/health"; then
                compose_wrapper "${DEFAULT_ACTIVE_COMPOSE_FILE}" down || true
                die "Staged container validation failed before cutover."
            fi
            staged=true
        fi
    elif [[ -z "${legacy_service}" ]] && port_is_listening "${LITELLM_BIND_PORT}"; then
        die "Port ${LITELLM_BIND_PORT} is already in use by a non-LiteLLM process. Refusing cutover."
    fi

    if [[ "${staged}" == true ]]; then
        disable_legacy_service "${legacy_service}"
        compose_wrapper "${DEFAULT_ACTIVE_COMPOSE_FILE}" down
    fi

    if service_exists "litellm-venv.service" && systemctl is-active --quiet "litellm-venv.service" 2>/dev/null; then
        systemctl disable --now litellm-venv.service
    fi

    if ! systemctl enable --now litellm-compose.service; then
        if [[ "${staged}" == true ]]; then
            restore_legacy_service "${legacy_service}"
        fi
        die "Failed to start litellm-compose.service"
    fi

    if ! "${SCRIPT_DIR}/validate-litellm.sh" --env-file "${ENV_FILE}"; then
        if [[ "${staged}" == true ]]; then
            systemctl disable --now litellm-compose.service || true
            restore_legacy_service "${legacy_service}"
        fi
        die "Container deployment validation failed."
    fi

    if [[ -n "${legacy_service}" && "${legacy_service}" != "litellm-compose.service" ]]; then
        systemctl disable "${legacy_service}" >/dev/null 2>&1 || true
    fi
}

deploy_venv() {
    local python_bin="${VENV_PYTHON_BIN}"

    bool_is_true "${ALLOW_VENV_FALLBACK:-false}" || die "ALLOW_VENV_FALLBACK is false."
    assert_python_version_floor
    lockfile_has_hashes "${LITELLM_REQUIREMENTS_LOCK}" || die "requirements.lock is missing hashes. Generate it first."
    assert_nonempty "DATABASE_URL"
    if bool_is_true "${DRY_RUN}"; then
        log "DRY RUN: would install the locked LiteLLM venv from ${LITELLM_REQUIREMENTS_LOCK}."
        sync_static_assets
        log "DRY RUN: would start litellm-venv.service."
        return 0
    fi

    require_command "${python_bin}"
    install_system_user_if_missing "litellm"
    ensure_directory "${VENV_DIR}" 0755 root root
    if [[ ! -x "${VENV_DIR}/bin/python" ]]; then
        "${python_bin}" -m venv "${VENV_DIR}"
    fi
    "${VENV_DIR}/bin/pip" install --require-hashes -r "${LITELLM_REQUIREMENTS_LOCK}"

    sync_static_assets
    systemctl daemon-reload
    systemctl disable --now litellm-compose.service >/dev/null 2>&1 || true
    systemctl enable --now litellm-venv.service
    "${SCRIPT_DIR}/validate-litellm.sh" --env-file "${ENV_FILE}"
}

apply_interim_hardening() {
    local legacy_service

    legacy_service="$(choose_legacy_service 2>/dev/null || true)"
    [[ -n "${legacy_service}" ]] || die "No legacy LiteLLM service detected for interim hardening."

    sync_static_assets
    if bool_is_true "${DRY_RUN}"; then
        log "DRY RUN: would write a systemd override for ${legacy_service} and optionally restart it."
        return 0
    fi
    write_legacy_override "${legacy_service}"
    systemctl daemon-reload

    if bool_is_true "${INTERIM_RESTART_SERVICE:-false}"; then
        systemctl restart "${legacy_service}"
    fi

    systemctl is-active --quiet "${legacy_service}" || die "Legacy LiteLLM service is not active after interim hardening."
}

main() {
    local effective_mode

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --env-file)
                ENV_FILE="$2"
                shift 2
                ;;
            --mode)
                MODE_OVERRIDE="$2"
                shift 2
                ;;
            --skip-backup)
                SKIP_BACKUP=true
                shift
                ;;
            --dry-run)
                DRY_RUN=true
                CLI_DRY_RUN=true
                shift
                ;;
            --help|-h)
                usage
                exit 0
                ;;
            *)
                die "Unknown argument: $1"
                ;;
        esac
    done

    require_root
    bootstrap_env_file "${ENV_FILE}"
    load_env_file "${ENV_FILE}"
    if bool_is_true "${CLI_DRY_RUN}"; then
        DRY_RUN=true
    fi
    umask 077
    ensure_runtime_layout
    preserve_or_create_secrets
    enforce_required_settings
    backup_if_enabled

    effective_mode="$(decide_mode)"
    log "Selected deployment mode: ${effective_mode}"

    case "${effective_mode}" in
        container)
            deploy_container
            ;;
        venv)
            deploy_venv
            ;;
        interim)
            apply_interim_hardening
            ;;
        *)
            die "Unsupported effective mode: ${effective_mode}"
            ;;
    esac
}

main "$@"

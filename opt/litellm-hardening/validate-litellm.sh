#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"

usage() {
    cat <<'EOF'
Usage: validate-litellm.sh [--env-file PATH] [--preflight]

Checks:
- pinned image tag and digest or pinned Python package version
- cosign verification status
- LITELLM_SALT_KEY and LITELLM_MASTER_KEY presence
- USE_PRISMA_MIGRATE=True
- LITELLM_MODE=PRODUCTION
- service health
- listening ports
- file permissions
EOF
}

ENV_FILE="${DEFAULT_ENV_FILE}"
PREFLIGHT_ONLY=false
VALIDATION_ERRORS=0

pass() {
    printf 'PASS %s\n' "$1"
}

fail() {
    printf 'FAIL %s\n' "$1"
    VALIDATION_ERRORS=$((VALIDATION_ERRORS + 1))
}

record_result() {
    local description="$1"
    shift
    if "$@"; then
        pass "${description}"
    else
        fail "${description}"
    fi
}

check_file_mode() {
    local target_file="$1"
    local expected_mode="$2"
    local actual_mode

    [[ -f "${target_file}" ]] || return 1
    actual_mode="$(stat -c '%a' "${target_file}")"
    [[ "${actual_mode}" == "${expected_mode}" ]]
}

check_env_permissions() {
    check_file_mode "${ENV_FILE}" 600
}

check_config_permissions() {
    check_file_mode "${DEFAULT_CONFIG_FILE}" 640
}

check_compose_permissions() {
    [[ ! -f "${DEFAULT_ACTIVE_COMPOSE_FILE}" ]] || check_file_mode "${DEFAULT_ACTIVE_COMPOSE_FILE}" 640
}

check_image_download_limit() {
    [[ "${MAX_IMAGE_URL_DOWNLOAD_SIZE_MB:-}" == "0" ]]
}

check_backend_network_safety() {
    validate_backend_network_safety
}

check_disable_error_logs() {
    grep -Eq '^[[:space:]]*disable_error_logs:[[:space:]]*true' "${DEFAULT_CONFIG_FILE}"
}

check_privacy_logging_settings() {
    grep -Eq '^[[:space:]]*disable_spend_logs:[[:space:]]*true' "${DEFAULT_CONFIG_FILE}" && \
        grep -Eq '^[[:space:]]*disable_end_user_cost_tracking:[[:space:]]*true' "${DEFAULT_CONFIG_FILE}" && \
        grep -Eq '^[[:space:]]*store_prompts_in_spend_logs:[[:space:]]*false' "${DEFAULT_CONFIG_FILE}" && \
        grep -Eq '^[[:space:]]*cache:[[:space:]]*false' "${DEFAULT_CONFIG_FILE}"
}

check_enforce_user_param() {
    grep -Eq '^[[:space:]]*enforce_user_param:[[:space:]]*true' "${DEFAULT_CONFIG_FILE}"
}

check_cosign_status() {
    local stamp_file

    stamp_file="$(verification_stamp_path "${LITELLM_IMAGE_DIGEST}")"
    [[ -f "${stamp_file}" ]] || return 1

    if command -v cosign >/dev/null 2>&1; then
        cosign verify --key "${LITELLM_COSIGN_KEY_FILE}" "$(get_image_digest_ref)" >/dev/null 2>&1
    else
        return 0
    fi
}

check_container_image_pin() {
    [[ -n "${LITELLM_IMAGE_TAG:-}" ]] || return 1
    [[ -n "${LITELLM_IMAGE_DIGEST:-}" ]] || return 1
    [[ "${LITELLM_IMAGE_TAG}" != *latest* && "${LITELLM_IMAGE_TAG}" != "main-stable" ]]
}

check_venv_lock() {
    lockfile_has_hashes "${LITELLM_REQUIREMENTS_LOCK}"
}

check_venv_version() {
    local version

    [[ -x "${VENV_DIR}/bin/pip" ]] || return 1
    version="$("${VENV_DIR}/bin/pip" show litellm 2>/dev/null | awk '/^Version:/ {print $2}')"
    [[ "${version}" == "${LITELLM_EXPECTED_PYTHON_VERSION}" ]]
}

check_service_health_container() {
    service_exists "litellm-compose.service" || return 1
    systemctl is-active --quiet litellm-compose.service || return 1
    http_health_ok "http://${LITELLM_BIND_ADDRESS}:${LITELLM_BIND_PORT}/health"
}

check_service_health_venv() {
    service_exists "litellm-venv.service" || return 1
    systemctl is-active --quiet litellm-venv.service || return 1
    http_health_ok "http://${LITELLM_BIND_ADDRESS}:${LITELLM_BIND_PORT}/health"
}

check_listening_port() {
    port_is_listening "${LITELLM_BIND_PORT}"
}

main() {
    local runtime_mode

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --env-file)
                ENV_FILE="$2"
                shift 2
                ;;
            --preflight)
                PREFLIGHT_ONLY=true
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
    load_env_file "${ENV_FILE}"
    umask 077

    record_result "env file permissions are 0600" check_env_permissions
    record_result "config file permissions are 0640" check_config_permissions
    record_result "active compose file permissions are 0640 when present" check_compose_permissions
    record_result "LITELLM_MASTER_KEY is set" assert_nonempty LITELLM_MASTER_KEY
    record_result "LITELLM_MASTER_KEY starts with sk-" assert_master_key_shape
    record_result "salt key guard passes" salt_key_validation_guard "${ENV_FILE}"
    record_result "USE_PRISMA_MIGRATE=True" assert_required_setting USE_PRISMA_MIGRATE True
    record_result "LITELLM_MODE=PRODUCTION" assert_required_setting LITELLM_MODE PRODUCTION
    record_result "bind address is private or explicitly approved" validate_bind_safety
    record_result "backend hosts are internal-only unless explicitly approved" check_backend_network_safety
    record_result "MAX_IMAGE_URL_DOWNLOAD_SIZE_MB=0" check_image_download_limit
    record_result "error logging is disabled by default" check_disable_error_logs
    record_result "privacy-sensitive spend logging and cache settings are disabled in config" check_privacy_logging_settings
    record_result "enforce_user_param is enabled in config" check_enforce_user_param

    runtime_mode="$(determine_runtime_mode)"
    if [[ "${runtime_mode}" == "container" || ( "${PREFLIGHT_ONLY}" == true && ( "${DEPLOYMENT_MODE}" == "container" || "${DEPLOYMENT_MODE}" == "auto" ) ) ]]; then
        record_result "container image pin is exact" check_container_image_pin
        record_result "cosign verification stamp is present and valid" check_cosign_status
        if [[ "${PREFLIGHT_ONLY}" == false ]]; then
            record_result "container service is healthy" check_service_health_container
            record_result "configured port is listening" check_listening_port
        fi
    fi

    if [[ "${runtime_mode}" == "venv" || ( "${PREFLIGHT_ONLY}" == true && "${DEPLOYMENT_MODE}" == "venv" ) ]]; then
        record_result "venv lock file is pinned with hashes" check_venv_lock
        record_result "venv LiteLLM version matches pin" check_venv_version
        if [[ "${PREFLIGHT_ONLY}" == false ]]; then
            record_result "venv service is healthy" check_service_health_venv
            record_result "configured port is listening" check_listening_port
        fi
    fi

    if [[ "${VALIDATION_ERRORS}" -gt 0 ]]; then
        exit 1
    fi
}

main "$@"

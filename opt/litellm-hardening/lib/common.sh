#!/usr/bin/env bash
set -euo pipefail

COMMON_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TOOLKIT_ROOT="$(cd -- "${COMMON_DIR}/.." && pwd)"

DEFAULT_ENV_FILE="/etc/litellm-hardening/litellm.env"
DEFAULT_CONFIG_FILE="${TOOLKIT_ROOT}/litellm_config.yaml"
DEFAULT_API_COMPOSE_FILE="${TOOLKIT_ROOT}/compose/litellm.compose.yaml"
DEFAULT_UI_COMPOSE_FILE="${TOOLKIT_ROOT}/compose/litellm-ui.compose.yaml"
DEFAULT_ACTIVE_COMPOSE_FILE="${TOOLKIT_ROOT}/compose/active.compose.yaml"
DEFAULT_COMPOSE_UNIT_SOURCE="${TOOLKIT_ROOT}/systemd/litellm-compose.service"
DEFAULT_VENV_UNIT_SOURCE="${TOOLKIT_ROOT}/systemd/litellm-venv.service"
DEFAULT_NGINX_API_TEMPLATE="${TOOLKIT_ROOT}/reverse-proxy/nginx-litellm.conf"
DEFAULT_NGINX_UI_TEMPLATE="${TOOLKIT_ROOT}/reverse-proxy/nginx-litellm-ui.conf"
DEFAULT_NGINX_SITE="/etc/nginx/sites-available/litellm.conf"
DEFAULT_NGINX_LINK="/etc/nginx/sites-enabled/litellm.conf"
DEFAULT_BACKUP_ROOT="/var/backups/litellm-hardening"
DEFAULT_STATE_ROOT="/var/lib/litellm-hardening"
DEFAULT_DATA_ROOT="/var/lib/litellm"

SIGNED_KEY_COMMIT="0112e53046018d726492c814b3644b7d376029d0"
CONTAINER_CMD=()
COMPOSE_CMD=()
SALT_STATE_EVIDENCE=""
SALT_STATE_ERRORS=""

timestamp() {
    date -u +"%Y-%m-%dT%H:%M:%SZ"
}

log() {
    printf '[%s] %s\n' "$(timestamp)" "$*" >&2
}

warn() {
    printf '[%s] WARN: %s\n' "$(timestamp)" "$*" >&2
}

die() {
    printf '[%s] ERROR: %s\n' "$(timestamp)" "$*" >&2
    exit 1
}

require_root() {
    [[ "${EUID}" -eq 0 ]] || die "Run this script as root."
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

bool_is_true() {
    case "${1:-}" in
        1|true|TRUE|yes|YES|on|ON)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

lower() {
    printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]'
}

version_ge() {
    local candidate="$1"
    local minimum="$2"
    [[ "$(printf '%s\n%s\n' "${candidate}" "${minimum}" | sort -V | head -n 1)" == "${minimum}" ]]
}

ensure_directory() {
    local path="$1"
    local mode="$2"
    local owner="${3:-root}"
    local group="${4:-root}"

    install -d -m "${mode}" -o "${owner}" -g "${group}" "${path}"
}

safe_copy_file() {
    local source_file="$1"
    local destination_file="$2"
    local mode="$3"
    local owner="${4:-root}"
    local group="${5:-root}"

    [[ -f "${source_file}" ]] || die "Source file does not exist: ${source_file}"
    install -d -m 0755 -o root -g root "$(dirname -- "${destination_file}")"
    if [[ -f "${destination_file}" ]] && cmp -s "${source_file}" "${destination_file}"; then
        chmod "${mode}" "${destination_file}"
        chown "${owner}:${group}" "${destination_file}"
        return 0
    fi
    install -m "${mode}" -o "${owner}" -g "${group}" "${source_file}" "${destination_file}"
}

set_or_update_env() {
    local env_file="$1"
    local key="$2"
    local value="$3"
    local tmp_file

    ensure_directory "$(dirname -- "${env_file}")" 0750 root root
    touch "${env_file}"
    chmod 0600 "${env_file}"
    chown root:root "${env_file}"

    tmp_file="$(mktemp)"
    awk -v env_key="${key}" -v env_value="${value}" '
        BEGIN {
            replaced = 0
        }
        $0 ~ "^[[:space:]]*" env_key "=" {
            print env_key "=" env_value
            replaced = 1
            next
        }
        {
            print
        }
        END {
            if (replaced == 0) {
                print env_key "=" env_value
            }
        }
    ' "${env_file}" > "${tmp_file}"
    mv "${tmp_file}" "${env_file}"
    chmod 0600 "${env_file}"
    chown root:root "${env_file}"
}

read_env_value_from_file() {
    local env_file="$1"
    local key="$2"

    [[ -f "${env_file}" ]] || return 1
    awk -v env_key="${key}" '
        BEGIN {
            found = 0
            single_quote = sprintf("%c", 39)
        }
        /^[[:space:]]*#/ {
            next
        }
        $0 ~ "^[[:space:]]*" env_key "[[:space:]]*=" {
            line = $0
            sub("^[[:space:]]*" env_key "[[:space:]]*=[[:space:]]*", "", line)
            sub(/[[:space:]]*#.*/, "", line)
            if (line ~ /^".*"$/) {
                line = substr(line, 2, length(line) - 2)
            } else if (line ~ ("^" single_quote ".*" single_quote "$")) {
                line = substr(line, 2, length(line) - 2)
            }
            print line
            found = 1
            exit
        }
        END {
            if (found == 0) {
                exit 1
            }
        }
    ' "${env_file}"
}

append_multiline_var() {
    local var_name="$1"
    local line="$2"
    local current_value="${!var_name:-}"

    if [[ -n "${current_value}" ]]; then
        printf -v "${var_name}" '%s\n%s' "${current_value}" "${line}"
    else
        printf -v "${var_name}" '%s' "${line}"
    fi
}

bootstrap_env_file() {
    local env_file="${1:-${DEFAULT_ENV_FILE}}"

    if [[ -f "${env_file}" ]]; then
        return 0
    fi

    if bool_is_true "${DRY_RUN:-false}"; then
        die "DRY RUN: ${env_file} does not exist. Create it from .env.example before running a dry-run preview."
    fi

    ensure_directory "$(dirname -- "${env_file}")" 0750 root root
    install -m 0600 -o root -g root "${TOOLKIT_ROOT}/.env.example" "${env_file}"
    die "Created ${env_file}. Set required secrets and rerun."
}

load_env_file() {
    local env_file="${1:-${DEFAULT_ENV_FILE}}"

    [[ -f "${env_file}" ]] || die "Missing env file: ${env_file}"
    set -a
    # shellcheck disable=SC1090
    . "${env_file}"
    set +a

    export LITELLM_ENV_FILE="${env_file}"
    export BACKUP_ROOT="${BACKUP_ROOT:-${DEFAULT_BACKUP_ROOT}}"
    export STATE_ROOT="${STATE_ROOT:-${DEFAULT_STATE_ROOT}}"
    export DATA_ROOT="${DATA_ROOT:-${DEFAULT_DATA_ROOT}}"
}

sed_escape() {
    printf '%s' "$1" | sed -e 's/[\/&]/\\&/g'
}

render_nginx_template() {
    local template="$1"
    local destination="$2"
    local upstream_host="$3"
    local upstream_port="$4"
    local server_name="$5"
    local tls_cert="$6"
    local tls_key="$7"
    local tmp_file

    tmp_file="$(mktemp)"
    sed \
        -e "s/__UPSTREAM_HOST__/$(sed_escape "${upstream_host}")/g" \
        -e "s/__UPSTREAM_PORT__/$(sed_escape "${upstream_port}")/g" \
        -e "s/__SERVER_NAME__/$(sed_escape "${server_name}")/g" \
        -e "s#__TLS_CERT_FILE__#$(sed_escape "${tls_cert}")#g" \
        -e "s#__TLS_KEY_FILE__#$(sed_escape "${tls_key}")#g" \
        "${template}" > "${tmp_file}"
    install -m 0644 -o root -g root "${tmp_file}" "${destination}"
    rm -f "${tmp_file}"
}

setup_container_runtime() {
    local runtime="${CONTAINER_RUNTIME:-docker}"

    case "${runtime}" in
        docker)
            CONTAINER_CMD=(docker)
            COMPOSE_CMD=(docker compose)
            ;;
        podman)
            CONTAINER_CMD=(podman)
            COMPOSE_CMD=(podman compose)
            ;;
        *)
            die "Unsupported CONTAINER_RUNTIME=${runtime}. Use docker or podman."
            ;;
    esac

    require_command "${CONTAINER_CMD[0]}"
}

compose_wrapper() {
    local compose_file="$1"
    shift
    "${COMPOSE_CMD[@]}" -p "${COMPOSE_PROJECT_NAME:-litellm}" -f "${compose_file}" "$@"
}

get_image_tag_ref() {
    printf '%s:%s' "${LITELLM_IMAGE_REPO}" "${LITELLM_IMAGE_TAG}"
}

get_image_digest_ref() {
    printf '%s@%s' "${LITELLM_IMAGE_REPO}" "${LITELLM_IMAGE_DIGEST}"
}

verification_stamp_path() {
    local digest="$1"
    printf '%s/cosign/%s.verified' "${STATE_ROOT}" "${digest#sha256:}"
}

write_verification_stamp() {
    local digest="$1"
    local verified_ref="$2"
    local stamp_file

    ensure_directory "${STATE_ROOT}/cosign" 0750 root root
    stamp_file="$(verification_stamp_path "${digest}")"
    cat > "${stamp_file}" <<EOF
VERIFIED_AT=$(timestamp)
IMAGE_REF=${verified_ref}
IMAGE_DIGEST=${digest}
SIGNING_KEY_FILE=${LITELLM_COSIGN_KEY_FILE}
SIGNING_KEY_COMMIT=${LITELLM_SIGNING_KEY_COMMIT:-${SIGNED_KEY_COMMIT}}
EOF
    chmod 0640 "${stamp_file}"
    chown root:root "${stamp_file}"
}

validate_bind_safety() {
    case "${LITELLM_BIND_ADDRESS:-127.0.0.1}" in
        0.0.0.0|::)
            bool_is_true "${ALLOW_PUBLIC_BIND:-false}" || die "Refusing public bind on ${LITELLM_BIND_ADDRESS}. Set ALLOW_PUBLIC_BIND=true only after review."
            ;;
    esac
}

extract_authority_host() {
    local value="$1"
    local authority=""
    local host=""

    [[ -n "${value}" ]] || return 1
    authority="${value#*://}"
    authority="${authority##*@}"
    authority="${authority%%/*}"
    authority="${authority%%\?*}"

    if [[ "${authority}" == \[*\]* ]]; then
        host="${authority#\[}"
        host="${host%%]*}"
    else
        host="${authority%%:*}"
    fi

    [[ -n "${host}" ]] || return 1
    printf '%s' "${host}"
}

host_is_private_or_local() {
    local host
    host="$(lower "${1:-}")"

    case "${host}" in
        ""|localhost|localhost.localdomain|127.*|::1|unix|socket|postgres|redis)
            return 0
            ;;
        10.*|192.168.*)
            return 0
            ;;
        172.1[6-9].*|172.2[0-9].*|172.3[0-1].*)
            return 0
            ;;
        fd*|fc*)
            return 0
            ;;
        *.local|*.internal|*.lan|*.home.arpa|*.localdomain)
            return 0
            ;;
    esac

    if [[ "${host}" != *.* ]]; then
        return 0
    fi

    return 1
}

validate_backend_host_safety() {
    local backend_name="$1"
    local host_value="$2"

    [[ -n "${host_value}" ]] || return 0
    if host_is_private_or_local "${host_value}"; then
        return 0
    fi

    bool_is_true "${ALLOW_NONPRIVATE_BACKEND_HOSTS:-false}" || die "${backend_name} host '${host_value}' does not look internal/private. Set ALLOW_NONPRIVATE_BACKEND_HOSTS=true only after review."
}

validate_backend_network_safety() {
    local database_host=""

    if [[ -n "${DATABASE_URL:-}" ]]; then
        database_host="$(extract_authority_host "${DATABASE_URL}" 2>/dev/null || true)"
        validate_backend_host_safety "DATABASE_URL" "${database_host}"
    fi

    if [[ -n "${REDIS_HOST:-}" ]]; then
        validate_backend_host_safety "REDIS_HOST" "${REDIS_HOST}"
    fi
}

port_is_listening() {
    local port="$1"

    ss -ltnH "( sport = :${port} )" 2>/dev/null | grep -q .
}

http_health_ok() {
    local url="$1"
    require_command curl
    curl -fsS --max-time 10 "${url}" >/dev/null
}

backup_absolute_path() {
    local source_path="$1"
    local backup_dir="$2"
    local destination_path

    [[ -e "${source_path}" ]] || return 0
    destination_path="${backup_dir}/files/${source_path#/}"
    ensure_directory "$(dirname -- "${destination_path}")" 0700 root root
    cp -a "${source_path}" "${destination_path}"
}

list_litellm_systemd_units() {
    local unit execstart fragment combined

    systemctl list-unit-files --type=service --no-legend 2>/dev/null | awk '{print $1}' | while IFS= read -r unit; do
        [[ -n "${unit}" ]] || continue
        if [[ "$(lower "${unit}")" == *litellm* ]]; then
            printf '%s\n' "${unit}"
            continue
        fi
        execstart="$(systemctl show -p ExecStart --value "${unit}" 2>/dev/null || true)"
        fragment="$(systemctl show -p FragmentPath --value "${unit}" 2>/dev/null || true)"
        combined="$(lower "${execstart} ${fragment}")"
        if [[ "${combined}" == *litellm* ]]; then
            printf '%s\n' "${unit}"
        fi
    done | sort -u
}

choose_legacy_service() {
    local preferred="${LEGACY_SERVICE_NAME:-}"
    local discovered active_unit

    if [[ -n "${preferred}" ]]; then
        printf '%s\n' "${preferred}"
        return 0
    fi

    while IFS= read -r active_unit; do
        [[ -n "${active_unit}" ]] || continue
        if [[ "${active_unit}" == "litellm-compose.service" || "${active_unit}" == "litellm-venv.service" ]]; then
            continue
        fi
        if systemctl is-active --quiet "${active_unit}" 2>/dev/null; then
            printf '%s\n' "${active_unit}"
            return 0
        fi
        discovered="${active_unit}"
    done < <(list_litellm_systemd_units)

    if [[ -n "${discovered:-}" ]]; then
        printf '%s\n' "${discovered}"
        return 0
    fi

    return 1
}

list_litellm_containers() {
    if [[ "${#CONTAINER_CMD[@]}" -eq 0 ]]; then
        if command -v docker >/dev/null 2>&1; then
            CONTAINER_CMD=(docker)
        elif command -v podman >/dev/null 2>&1; then
            CONTAINER_CMD=(podman)
        else
            return 0
        fi
    fi

    if ! command -v "${CONTAINER_CMD[0]}" >/dev/null 2>&1; then
        return 0
    fi
    "${CONTAINER_CMD[@]}" ps -a --format '{{.Names}}|{{.Image}}' 2>/dev/null | awk -F'|' '
        BEGIN {
            IGNORECASE = 1
        }
        $0 ~ /litellm/ {
            print $1 "|" $2
        }
    '
}

candidate_search_paths() {
    local base

    for base in /etc /opt; do
        [[ -d "${base}" ]] || continue
        find "${base}" -maxdepth 4 -type f \
            \( -name '*litellm*' -o -name '*.env' -o -name '*.service' -o -name 'config.yaml' \) \
            2>/dev/null
    done
}

candidate_search_paths_excluding() {
    local exclude_file="$1"
    local file

    while IFS= read -r file; do
        [[ "${file}" == "${exclude_file}" ]] && continue
        printf '%s\n' "${file}"
    done < <(candidate_search_paths)
}

discover_assignment_from_files() {
    local key="$1"
    local file value

    while IFS= read -r file; do
        [[ -f "${file}" ]] || continue
        value="$(sed -n -E "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*['\"]?([^'\"[:space:]]+)['\"]?.*$/\1/p" "${file}" | head -n 1)"
        if [[ -n "${value}" ]]; then
            printf '%s' "${value}"
            return 0
        fi
    done < <(candidate_search_paths)

    return 1
}

discover_assignment_from_files_excluding() {
    local key="$1"
    local exclude_file="$2"
    local file value

    while IFS= read -r file; do
        [[ -f "${file}" ]] || continue
        value="$(sed -n -E "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*['\"]?([^'\"[:space:]]+)['\"]?.*$/\1/p" "${file}" | head -n 1)"
        if [[ -n "${value}" ]]; then
            printf '%s' "${value}"
            return 0
        fi
    done < <(candidate_search_paths_excluding "${exclude_file}")

    return 1
}

discover_existing_secret() {
    local key="$1"
    local value container_name

    if [[ -n "${!key:-}" ]]; then
        printf '%s' "${!key}"
        return 0
    fi

    if value="$(discover_assignment_from_files "${key}" 2>/dev/null)"; then
        printf '%s' "${value}"
        return 0
    fi

    while IFS= read -r container_name; do
        [[ -n "${container_name}" ]] || continue
        container_name="${container_name%%|*}"
        value="$("${CONTAINER_CMD[@]}" inspect "${container_name}" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null | sed -n -E "s/^${key}=//p" | head -n 1 || true)"
        if [[ -n "${value}" ]]; then
            printf '%s' "${value}"
            return 0
        fi
    done < <(list_litellm_containers)

    return 1
}

discover_existing_secret_outside_env() {
    local key="$1"
    local env_file_to_skip="$2"
    local value container_name

    if value="$(discover_assignment_from_files_excluding "${key}" "${env_file_to_skip}" 2>/dev/null)"; then
        printf '%s' "${value}"
        return 0
    fi

    while IFS= read -r container_name; do
        [[ -n "${container_name}" ]] || continue
        container_name="${container_name%%|*}"
        value="$("${CONTAINER_CMD[@]}" inspect "${container_name}" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null | sed -n -E "s/^${key}=//p" | head -n 1 || true)"
        if [[ -n "${value}" ]]; then
            printf '%s' "${value}"
            return 0
        fi
    done < <(list_litellm_containers)

    return 1
}

discover_database_url() {
    if [[ -n "${DATABASE_URL:-}" ]]; then
        printf '%s' "${DATABASE_URL}"
        return 0
    fi
    discover_existing_secret "DATABASE_URL"
}

config_contains_models() {
    local config_file="$1"

    [[ -f "${config_file}" ]] || return 1
    grep -Eq '^[[:space:]]*-[[:space:]]*model_name:' "${config_file}" || \
        grep -Eq '^[[:space:]]*api_key:' "${config_file}"
}

reset_salt_state_checks() {
    SALT_STATE_EVIDENCE=""
    SALT_STATE_ERRORS=""
}

inspect_config_state_for_salt_guard() {
    local file
    local matched_file=0

    while IFS= read -r file; do
        [[ -f "${file}" ]] || continue
        if ! grep -Iq . "${file}" 2>/dev/null; then
            continue
        fi

        matched_file=0

        if grep -Eq '^[[:space:]]*-[[:space:]]*model_name:[[:space:]]*[^[:space:]#]+' "${file}"; then
            append_multiline_var "SALT_STATE_EVIDENCE" "Config file ${file} contains one or more configured LiteLLM models."
            matched_file=1
        fi

        if grep -Eq '^[[:space:]]*(api_key|credential_name|credential_id|credential|encrypted_config|encrypted_credentials):[[:space:]]*[^[:space:]#]+' "${file}"; then
            append_multiline_var "SALT_STATE_EVIDENCE" "Config file ${file} contains LiteLLM credentials or encrypted configuration entries."
            matched_file=1
        fi

        if [[ "${matched_file}" -eq 0 ]] && grep -Eq '^[[:space:]]*litellm_params:[[:space:]]*$' "${file}"; then
            append_multiline_var "SALT_STATE_EVIDENCE" "Config file ${file} contains LiteLLM deployment parameters that should be reviewed before inventing a new salt key."
        fi
    done < <(candidate_search_paths)
}

inspect_database_state_for_salt_guard() {
    local database_url="$1"
    local candidate_tables=""
    local table
    local has_rows
    local query_rc=0

    [[ -n "${database_url}" ]] || return 0

    if ! command -v psql >/dev/null 2>&1; then
        append_multiline_var "SALT_STATE_ERRORS" "DATABASE_URL is set but psql is not installed, so the LiteLLM database cannot be inspected safely."
        return 0
    fi

    candidate_tables="$(psql "${database_url}" -Atc "
        SELECT DISTINCT table_name
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND (
            table_name ILIKE 'litellm%%'
            OR table_name ILIKE '%%proxy%%model%%'
            OR table_name ILIKE '%%credential%%'
            OR table_name ILIKE '%%config%%'
            OR column_name = 'model_name'
            OR column_name ILIKE '%%credential%%'
            OR column_name ILIKE '%%encrypted%%'
            OR column_name = 'api_key'
          )
        ORDER BY table_name;
    " 2>/dev/null)" || query_rc=$?

    if [[ "${query_rc}" -ne 0 ]]; then
        append_multiline_var "SALT_STATE_ERRORS" "DATABASE_URL is set but the LiteLLM state inspection query failed, so encrypted state cannot be ruled out safely."
        return 0
    fi

    while IFS= read -r table; do
        [[ -n "${table}" ]] || continue
        has_rows="$(psql "${database_url}" -Atc "SELECT CASE WHEN EXISTS (SELECT 1 FROM public.\"${table}\" LIMIT 1) THEN '1' ELSE '0' END;" 2>/dev/null || true)"
        if [[ -z "${has_rows}" ]]; then
            append_multiline_var "SALT_STATE_ERRORS" "Database table public.${table} could not be inspected safely."
            continue
        fi
        if [[ "${has_rows}" == "1" ]]; then
            append_multiline_var "SALT_STATE_EVIDENCE" "Database table public.${table} already has LiteLLM-related rows."
        fi
    done <<< "${candidate_tables}"
}

collect_litellm_state_evidence() {
    local database_url=""

    reset_salt_state_checks
    inspect_config_state_for_salt_guard
    database_url="$(discover_database_url 2>/dev/null || true)"
    inspect_database_state_for_salt_guard "${database_url}"
}

database_has_litellm_state() {
    local database_url="$1"
    local tables table has_rows

    [[ -n "${database_url}" ]] || return 1
    command -v psql >/dev/null 2>&1 || return 1

    tables="$(psql "${database_url}" -Atc "SELECT tablename FROM pg_tables WHERE schemaname='public' AND tablename ILIKE 'litellm%';" 2>/dev/null || true)"
    [[ -n "${tables}" ]] || return 1

    while IFS= read -r table; do
        [[ -n "${table}" ]] || continue
        if [[ "${table}" =~ (Model|Credential|Key|Team|User|Config|Provider|Deployment|Spend|Budget|Verification) ]]; then
            has_rows="$(psql "${database_url}" -Atc "SELECT CASE WHEN EXISTS (SELECT 1 FROM public.\"${table}\" LIMIT 1) THEN '1' ELSE '0' END;" 2>/dev/null || true)"
            if [[ "${has_rows}" == "1" ]]; then
                return 0
            fi
        fi
    done <<< "${tables}"

    return 1
}

existing_litellm_state_detected() {
    collect_litellm_state_evidence
    [[ -n "${SALT_STATE_EVIDENCE}" ]]
}

lockfile_has_hashes() {
    local lock_file="$1"
    [[ -f "${lock_file}" ]] || return 1
    grep -Eq '^litellm(\[proxy\])?==' "${lock_file}" && grep -q -- '--hash=sha256:' "${lock_file}"
}

install_system_user_if_missing() {
    local user_name="$1"

    if id -u "${user_name}" >/dev/null 2>&1; then
        return 0
    fi
    useradd --system --home-dir /var/lib/litellm --shell /usr/sbin/nologin "${user_name}"
}

service_exists() {
    systemctl list-unit-files --type=service --no-legend 2>/dev/null | awk '{print $1}' | grep -Fxq "$1"
}

determine_runtime_mode() {
    if service_exists "litellm-compose.service" && systemctl is-active --quiet litellm-compose.service 2>/dev/null; then
        printf 'container'
        return 0
    fi
    if service_exists "litellm-venv.service" && systemctl is-active --quiet litellm-venv.service 2>/dev/null; then
        printf 'venv'
        return 0
    fi
    if choose_legacy_service >/dev/null 2>&1; then
        printf 'legacy'
        return 0
    fi
    printf 'none'
}

verify_image_signature() {
    local tag_ref
    local digest_ref
    local actual_digest

    require_command cosign
    [[ -f "${LITELLM_COSIGN_KEY_FILE}" ]] || die "Cosign public key file not found: ${LITELLM_COSIGN_KEY_FILE}"
    setup_container_runtime
    tag_ref="$(get_image_tag_ref)"
    digest_ref="$(get_image_digest_ref)"

    log "Pulling ${tag_ref}"
    "${CONTAINER_CMD[@]}" pull "${tag_ref}" >/dev/null

    log "Verifying ${tag_ref} with cosign"
    cosign verify --key "${LITELLM_COSIGN_KEY_FILE}" "${tag_ref}" >/dev/null

    actual_digest="$("${CONTAINER_CMD[@]}" image inspect "${tag_ref}" --format '{{range .RepoDigests}}{{println .}}{{end}}' 2>/dev/null | awk -F@ -v repo="${LITELLM_IMAGE_REPO}" '$1 == repo {print $2; exit}')"
    [[ -n "${actual_digest}" ]] || die "Unable to resolve digest for ${tag_ref}"
    [[ "${actual_digest}" == "${LITELLM_IMAGE_DIGEST}" ]] || die "Digest mismatch for ${tag_ref}. Expected ${LITELLM_IMAGE_DIGEST}, got ${actual_digest}"

    log "Verifying ${digest_ref} with cosign"
    cosign verify --key "${LITELLM_COSIGN_KEY_FILE}" "${digest_ref}" >/dev/null
    write_verification_stamp "${actual_digest}" "${tag_ref}"
}

assert_required_setting() {
    local key="$1"
    local expected="$2"
    local actual="${!key:-}"

    [[ "${actual}" == "${expected}" ]] || die "${key} must be ${expected}. Current value: ${actual:-<unset>}"
}

assert_nonempty() {
    local key="$1"
    [[ -n "${!key:-}" ]] || die "Required setting is empty: ${key}"
}

assert_master_key_shape() {
    [[ "${LITELLM_MASTER_KEY:-}" == sk-* ]] || die "LITELLM_MASTER_KEY must start with sk-"
}

assert_python_version_floor() {
    version_ge "${LITELLM_EXPECTED_PYTHON_VERSION}" "1.83.0" || die "LITELLM_EXPECTED_PYTHON_VERSION must be >= 1.83.0"
}

print_salt_key_missing_state_error() {
    local env_file="$1"

    cat >&2 <<EOF
ERROR: Refusing to continue because LITELLM_SALT_KEY is missing.

LiteLLM state already appears to exist:
${SALT_STATE_EVIDENCE}

Why this is dangerous:
- LiteLLM uses LITELLM_SALT_KEY to encrypt and decrypt stored credentials and related configuration.
- Inventing a new salt key after models, credentials, or encrypted config already exist can break decryption.
- This toolkit will not guess or silently create a replacement key in that situation.

Required operator action:
- Recover the original LITELLM_SALT_KEY from the current deployment, secret manager, or a known-good backup.
- Write that exact key into ${env_file}.
- Keep ${env_file} mode at 0600.
- Re-run validation and deployment only after the original salt key is restored.
EOF
}

print_salt_key_unknown_state_error() {
    local env_file="$1"

    cat >&2 <<EOF
ERROR: Refusing to continue because LITELLM_SALT_KEY is missing and LiteLLM state could not be inspected safely.

Inspection problems:
${SALT_STATE_ERRORS}

Why this is dangerous:
- If LiteLLM already has encrypted credentials or configuration in its database, inventing a new salt key later can break decryption.
- Because the existing state could not be ruled out safely, this toolkit fails closed instead of guessing.

Required operator action:
- Fix database access or install the required inspection tooling.
- Confirm whether LiteLLM already has models, credentials, or encrypted config.
- Restore the original LITELLM_SALT_KEY if one already exists.
- Only rerun deployment after the missing-information problem is resolved.
EOF
}

print_salt_key_missing_no_state_error() {
    local env_file="$1"

    cat >&2 <<EOF
ERROR: LITELLM_SALT_KEY is missing from ${env_file}.

No existing LiteLLM state was detected, so generating a salt key would be safe,
but validation and service start still refuse to proceed until that key is actually written.

Run /opt/litellm-hardening/harden-litellm.sh to generate and persist the salt key once,
or write the desired salt key into ${env_file} manually with mode 0600.
EOF
}

print_salt_key_not_in_runtime_env_error() {
    local env_file="$1"

    cat >&2 <<EOF
ERROR: LITELLM_SALT_KEY was discovered elsewhere on the system, but it is missing from ${env_file}.

The runtime env file is the single source of truth for this toolkit.
Validation and service start refuse to proceed until that exact existing salt key is written into ${env_file} with mode 0600.
EOF
}

print_salt_key_mismatch_error() {
    local env_file="$1"

    cat >&2 <<EOF
ERROR: Refusing to continue because more than one LiteLLM salt key was detected.

Runtime env file: ${env_file}
Detected issue: the salt key in the runtime env file does not match a salt key discovered elsewhere on the system.

Why this is dangerous:
- LiteLLM must use one stable LITELLM_SALT_KEY for encrypting and decrypting stored credentials.
- Multiple competing salt keys make it unsafe to guess which deployment state is authoritative.

Required operator action:
- Determine which LITELLM_SALT_KEY is the original production key.
- Remove or reconcile the conflicting value.
- Re-run validation only after one exact salt key remains.
EOF
}

print_salt_key_restore_error() {
    local current_env_file="$1"
    local backup_env_file="$2"

    cat >&2 <<EOF
ERROR: Refusing rollback because it would silently change LITELLM_SALT_KEY.

Current runtime env file: ${current_env_file}
Backup runtime env file: ${backup_env_file}

The rollback script will not overwrite, clear, or inject a different LiteLLM salt key automatically.
Review both env files, restore the correct original salt key manually, and rerun rollback only after they match.
EOF
}

salt_key_preflight_guard() {
    local env_file="${1:-${DEFAULT_ENV_FILE}}"
    local current_env_salt=""
    local external_salt=""
    local generated_salt=""

    current_env_salt="$(read_env_value_from_file "${env_file}" "LITELLM_SALT_KEY" 2>/dev/null || true)"
    external_salt="$(discover_existing_secret_outside_env "LITELLM_SALT_KEY" "${env_file}" 2>/dev/null || true)"

    if [[ -n "${current_env_salt}" && -n "${external_salt}" && "${current_env_salt}" != "${external_salt}" ]]; then
        print_salt_key_mismatch_error "${env_file}"
        return 1
    fi

    if [[ -n "${current_env_salt}" ]]; then
        export LITELLM_SALT_KEY="${current_env_salt}"
        chmod 0600 "${env_file}"
        chown root:root "${env_file}"
        return 0
    fi

    if [[ -n "${external_salt}" ]]; then
        if bool_is_true "${DRY_RUN:-false}"; then
            log "DRY RUN: would write the existing LiteLLM salt key into ${env_file}."
        else
            set_or_update_env "${env_file}" "LITELLM_SALT_KEY" "${external_salt}"
            chmod 0600 "${env_file}"
            chown root:root "${env_file}"
        fi
        export LITELLM_SALT_KEY="${external_salt}"
        return 0
    fi

    collect_litellm_state_evidence
    if [[ -n "${SALT_STATE_EVIDENCE}" ]]; then
        print_salt_key_missing_state_error "${env_file}"
        return 1
    fi

    if [[ -n "${SALT_STATE_ERRORS}" ]]; then
        print_salt_key_unknown_state_error "${env_file}"
        return 1
    fi

    if ! bool_is_true "${AUTO_GENERATE_SALT_KEY:-false}"; then
        print_salt_key_missing_no_state_error "${env_file}"
        return 1
    fi

    require_command openssl
    generated_salt="sk-$(openssl rand -hex 32)"
    if bool_is_true "${DRY_RUN:-false}"; then
        log "DRY RUN: would generate and store a new LiteLLM salt key in ${env_file}."
        return 0
    fi
    set_or_update_env "${env_file}" "LITELLM_SALT_KEY" "${generated_salt}"
    chmod 0600 "${env_file}"
    chown root:root "${env_file}"
    export LITELLM_SALT_KEY="${generated_salt}"
    log "Generated and stored a new LiteLLM salt key in ${env_file}."
    return 0
}

salt_key_validation_guard() {
    local env_file="${1:-${DEFAULT_ENV_FILE}}"
    local current_env_salt=""
    local external_salt=""

    current_env_salt="$(read_env_value_from_file "${env_file}" "LITELLM_SALT_KEY" 2>/dev/null || true)"
    external_salt="$(discover_existing_secret_outside_env "LITELLM_SALT_KEY" "${env_file}" 2>/dev/null || true)"

    if [[ -n "${current_env_salt}" && -n "${external_salt}" && "${current_env_salt}" != "${external_salt}" ]]; then
        print_salt_key_mismatch_error "${env_file}"
        return 1
    fi

    if [[ -n "${current_env_salt}" ]]; then
        return 0
    fi

    if [[ -n "${external_salt}" ]]; then
        print_salt_key_not_in_runtime_env_error "${env_file}"
        return 1
    fi

    collect_litellm_state_evidence
    if [[ -n "${SALT_STATE_EVIDENCE}" ]]; then
        print_salt_key_missing_state_error "${env_file}"
        return 1
    fi

    if [[ -n "${SALT_STATE_ERRORS}" ]]; then
        print_salt_key_unknown_state_error "${env_file}"
        return 1
    fi

    print_salt_key_missing_no_state_error "${env_file}"
    return 1
}

assert_safe_salt_key_restore() {
    local current_env_file="$1"
    local backup_env_file="$2"
    local current_salt=""
    local backup_salt=""

    [[ -f "${backup_env_file}" ]] || return 0

    current_salt="$(read_env_value_from_file "${current_env_file}" "LITELLM_SALT_KEY" 2>/dev/null || true)"
    backup_salt="$(read_env_value_from_file "${backup_env_file}" "LITELLM_SALT_KEY" 2>/dev/null || true)"

    if [[ "${current_salt}" == "${backup_salt}" ]]; then
        return 0
    fi

    if [[ -n "${current_salt}" || -n "${backup_salt}" ]]; then
        print_salt_key_restore_error "${current_env_file}" "${backup_env_file}"
        return 1
    fi

    return 0
}

write_legacy_override() {
    local service_name="$1"
    local destination_dir="/etc/systemd/system/${service_name}.d"
    local destination_file="${destination_dir}/override.conf"

    ensure_directory "${destination_dir}" 0755 root root
    cat > "${destination_file}" <<'EOF'
[Service]
EnvironmentFile=/etc/litellm-hardening/litellm.env
UMask=0077
NoNewPrivileges=true
PrivateTmp=true
ProtectControlGroups=true
ProtectKernelTunables=true
ProtectKernelModules=true
LockPersonality=true
RestrictRealtime=true
RestrictNamespaces=true
RestrictSUIDSGID=true
SystemCallArchitectures=native
SystemCallFilter=@system-service
EOF
    chmod 0644 "${destination_file}"
    chown root:root "${destination_file}"
}

#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

run_prepare_queue_case() {
    SCRIPT_PATH="${ROOT_DIR}/system_hardening.sh" bash -lc '
        set -euo pipefail
        source "${SCRIPT_PATH}"
        log() { :; }
        warn() { :; }

        PROFILE="docker-host"
        INSTALL_DOCKER=1
        PKG_QUEUE=()

        prepare_package_queue
        queue_text=" ${PKG_QUEUE[*]} "

        [[ "${queue_text}" == *" gnupg "* ]] || {
            echo "FAIL prepare queue: gnupg prerequisite was not queued" >&2
            exit 1
        }
        [[ "${queue_text}" != *" docker.io "* ]] || {
            echo "FAIL prepare queue: docker.io should be installed through install_docker_stack" >&2
            exit 1
        }
        [[ "${queue_text}" != *" docker-compose-plugin "* ]] || {
            echo "FAIL prepare queue: docker-compose-plugin must not be blindly queued" >&2
            exit 1
        }
    '
}

run_compose_fallback_case() {
    SCRIPT_PATH="${ROOT_DIR}/system_hardening.sh" bash -lc '
        set -euo pipefail
        source "${SCRIPT_PATH}"

        temp_dir="$(mktemp -d)"
        trap "rm -rf \"${temp_dir}\"" EXIT
        mkdir -p "${temp_dir}/bin" "${temp_dir}/sources"

        LOGFILE="${temp_dir}/hardening.log"
        FAKE_APT_LOG="${temp_dir}/apt.log"
        export FAKE_APT_LOG

        OS_RELEASE_FILE="${temp_dir}/os-release"
        DOCKER_APT_KEYRING_DIR="${temp_dir}/keyrings"
        DOCKER_APT_SOURCE_FILE="${temp_dir}/sources/docker.list"

        cat > "${OS_RELEASE_FILE}" <<EOF
ID=ubuntu
VERSION_ID="24.04"
VERSION_CODENAME=noble
PRETTY_NAME="Ubuntu 24.04 LTS"
EOF

        cat > "${temp_dir}/bin/apt-cache" <<'"'"'EOF'"'"'
#!/usr/bin/env bash
if [[ "${1:-}" == "show" ]]; then
    case "${2:-}" in
        ca-certificates|curl|gnupg|apt-transport-https|docker-ce|docker-ce-cli|containerd.io|docker-buildx-plugin|docker-compose-v2)
            exit 0
            ;;
        docker-compose-plugin|docker.io)
            exit 100
            ;;
    esac
fi
exit 100
EOF

        cat > "${temp_dir}/bin/apt-get" <<'"'"'EOF'"'"'
#!/usr/bin/env bash
printf "%s\n" "$*" >> "${FAKE_APT_LOG}"
exit 0
EOF

        cat > "${temp_dir}/bin/curl" <<'"'"'EOF'"'"'
#!/usr/bin/env bash
out=""
while [[ "$#" -gt 0 ]]; do
    case "$1" in
        -o)
            out="$2"
            shift 2
            ;;
        *)
            shift
            ;;
    esac
done
[[ -n "${out}" ]] || exit 0
mkdir -p "$(dirname "${out}")"
printf "fake docker key\n" > "${out}"
EOF

        cat > "${temp_dir}/bin/dpkg" <<'"'"'EOF'"'"'
#!/usr/bin/env bash
if [[ "${1:-}" == "--print-architecture" ]]; then
    echo "amd64"
    exit 0
fi
exit 1
EOF

        cat > "${temp_dir}/bin/docker" <<'"'"'EOF'"'"'
#!/usr/bin/env bash
echo "docker intentionally unavailable in test" >&2
exit 127
EOF

        chmod +x "${temp_dir}/bin/"*
        PATH="${temp_dir}/bin:${PATH}"

        command() {
            if [[ "$#" -ge 2 && "$1" == "-v" && "$2" == "docker" ]]; then
                return 1
            fi
            builtin command "$@"
        }

        log() { printf "LOG: %s\n" "$*" >> "${LOGFILE}"; }
        warn() { printf "WARN: %s\n" "$*" >> "${LOGFILE}"; }
        backup_config() { :; }

        install_docker_stack || true

        if grep -q "docker-compose-plugin" "${FAKE_APT_LOG}"; then
            echo "FAIL fallback: unavailable docker-compose-plugin was passed to apt-get" >&2
            exit 1
        fi
        grep -q "docker-compose-v2" "${FAKE_APT_LOG}" || {
            echo "FAIL fallback: docker-compose-v2 fallback was not installed" >&2
            exit 1
        }
        grep -q "docker-ce" "${FAKE_APT_LOG}" || {
            echo "FAIL fallback: official Docker Engine packages were not selected" >&2
            exit 1
        }

        expected_repo="deb [arch=amd64 signed-by=${DOCKER_APT_KEYRING_DIR}/docker.asc] https://download.docker.com/linux/ubuntu noble stable"
        repo_count="$(grep -Fxc "${expected_repo}" "${DOCKER_APT_SOURCE_FILE}")"
        [[ "${repo_count}" -eq 1 ]] || {
            echo "FAIL fallback: Docker apt repo was not written idempotently" >&2
            exit 1
        }
    '
}

run_ubuntu_official_plugin_case() {
    SCRIPT_PATH="${ROOT_DIR}/system_hardening.sh" bash -lc '
        set -euo pipefail
        source "${SCRIPT_PATH}"

        temp_dir="$(mktemp -d)"
        trap "rm -rf \"${temp_dir}\"" EXIT
        mkdir -p "${temp_dir}/bin" "${temp_dir}/sources"

        LOGFILE="${temp_dir}/hardening.log"
        FAKE_APT_LOG="${temp_dir}/apt.log"
        export FAKE_APT_LOG

        OS_RELEASE_FILE="${temp_dir}/os-release"
        DOCKER_APT_KEYRING_DIR="${temp_dir}/keyrings"
        DOCKER_APT_SOURCE_FILE="${temp_dir}/sources/docker.list"

        cat > "${OS_RELEASE_FILE}" <<EOF
ID=ubuntu
VERSION_ID="24.04"
VERSION_CODENAME=noble
UBUNTU_CODENAME=noble
PRETTY_NAME="Ubuntu 24.04 LTS"
EOF

        cat > "${temp_dir}/bin/apt-cache" <<'"'"'EOF'"'"'
#!/usr/bin/env bash
if [[ "${1:-}" == "show" ]]; then
    case "${2:-}" in
        ca-certificates|curl|gnupg|apt-transport-https|docker-ce|docker-ce-cli|containerd.io|docker-buildx-plugin|docker-compose-plugin)
            exit 0
            ;;
        docker-compose-v2|docker.io)
            exit 100
            ;;
    esac
fi
exit 100
EOF

        cat > "${temp_dir}/bin/apt-get" <<'"'"'EOF'"'"'
#!/usr/bin/env bash
printf "%s\n" "$*" >> "${FAKE_APT_LOG}"
exit 0
EOF

        cat > "${temp_dir}/bin/curl" <<'"'"'EOF'"'"'
#!/usr/bin/env bash
out=""
while [[ "$#" -gt 0 ]]; do
    case "$1" in
        -o)
            out="$2"
            shift 2
            ;;
        *)
            shift
            ;;
    esac
done
[[ -n "${out}" ]] || exit 0
mkdir -p "$(dirname "${out}")"
printf "fake docker key\n" > "${out}"
EOF

        cat > "${temp_dir}/bin/dpkg" <<'"'"'EOF'"'"'
#!/usr/bin/env bash
if [[ "${1:-}" == "--print-architecture" ]]; then
    echo "amd64"
    exit 0
fi
exit 1
EOF

        cat > "${temp_dir}/bin/docker" <<'"'"'EOF'"'"'
#!/usr/bin/env bash
echo "docker intentionally unavailable in test" >&2
exit 127
EOF

        chmod +x "${temp_dir}/bin/"*
        PATH="${temp_dir}/bin:${PATH}"

        command() {
            if [[ "$#" -ge 2 && "$1" == "-v" && "$2" == "docker" ]]; then
                return 1
            fi
            builtin command "$@"
        }

        log() { printf "LOG: %s\n" "$*" >> "${LOGFILE}"; }
        warn() { printf "WARN: %s\n" "$*" >> "${LOGFILE}"; }
        backup_config() { :; }

        install_docker_stack || true
        ensure_docker_apt_repo

        grep -q "docker-compose-plugin" "${FAKE_APT_LOG}" || {
            echo "FAIL ubuntu plugin: docker-compose-plugin was not installed when available" >&2
            exit 1
        }
        if grep -q "docker-compose-v2" "${FAKE_APT_LOG}"; then
            echo "FAIL ubuntu plugin: fallback docker-compose-v2 was installed even though docker-compose-plugin was available" >&2
            exit 1
        fi
        grep -q "docker-ce docker-ce-cli containerd.io" "${FAKE_APT_LOG}" || {
            echo "FAIL ubuntu plugin: official Docker Engine package set was not selected" >&2
            exit 1
        }

        expected_repo="deb [arch=amd64 signed-by=${DOCKER_APT_KEYRING_DIR}/docker.asc] https://download.docker.com/linux/ubuntu noble stable"
        repo_count="$(grep -Fxc "${expected_repo}" "${DOCKER_APT_SOURCE_FILE}")"
        [[ "${repo_count}" -eq 1 ]] || {
            echo "FAIL ubuntu plugin: Docker apt repo was duplicated or missing" >&2
            exit 1
        }
    '
}

run_prepare_queue_case
run_ubuntu_official_plugin_case
run_compose_fallback_case

echo "Docker package flow tests passed."

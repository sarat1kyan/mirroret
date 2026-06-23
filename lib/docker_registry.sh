#!/usr/bin/env bash
# Docker registry management for mirroret.
# Source this file; do not execute it directly.
# Requires logging.sh, common.sh, backup.sh, distro.sh.
#
# MIRRORET_DOCKER_BACKEND=auto|native|container
#   auto      — try native first, fall back to container
#   native    — use OS package (docker-distribution on RHEL, docker-registry on Debian)
#   container — use the registry:2 Docker/Podman container (previous behaviour)
#
# MIRRORET_DOCKER_IMAGES_FILE
#   Path to a plain-text file listing images to sync (one per line, # for comments).
#   When unset the default list in write_docker_sync_script is used.

MIRRORET_DOCKER_CONTAINER_NAME="${MIRRORET_DOCKER_CONTAINER_NAME:-mirroret-registry}"
MIRRORET_DOCKER_BACKEND="${MIRRORET_DOCKER_BACKEND:-auto}"
MIRRORET_DOCKER_IMAGES_FILE="${MIRRORET_DOCKER_IMAGES_FILE:-}"

# ── Container runtime detection ───────────────────────────────────────────────

# _detect_container_runtime — set CONTAINER_CMD to 'podman' or 'docker'.
# On RHEL, podman-docker provides a 'docker' shim; we detect that and use
# podman directly so we can also generate a proper systemd unit for it.
_detect_container_runtime() {
    if check_command docker; then
        # Detect the podman-docker compatibility shim.
        if docker --version 2>/dev/null | grep -qi "podman"; then
            info "Detected podman-docker shim. Using 'podman' as container runtime."
            CONTAINER_CMD="podman"
        else
            CONTAINER_CMD="docker"
        fi
    elif check_command podman; then
        info "Docker not found; using Podman directly."
        CONTAINER_CMD="podman"
    else
        die "No container runtime found. Install Docker CE or Podman."
    fi
    export CONTAINER_CMD
}

# _start_docker_daemon — ensure the Docker daemon is running (real Docker only).
_start_docker_daemon() {
    [[ "${CONTAINER_CMD}" != "docker" ]] && return 0
    if ! systemctl is-active --quiet docker 2>/dev/null; then
        info "Starting Docker daemon."
        xrun systemctl enable --now docker
    fi
}

# _container_exists / _container_is_running — runtime-agnostic wrappers.
_container_exists() {
    "${CONTAINER_CMD}" ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$1"
}
_container_is_running() {
    "${CONTAINER_CMD}" ps --format '{{.Names}}' 2>/dev/null | grep -qx "$1"
}

# _generate_podman_systemd_unit — create and enable a systemd unit for the
# registry container so it survives reboots when using Podman.
_generate_podman_systemd_unit() {
    local container="$1"
    local unit_file="/etc/systemd/system/${container}.service"

    info "Generating systemd unit for Podman container: ${container}"

    # Podman 4+ supports 'podman generate systemd'; Podman 5+ prefers
    # 'podman systemd generate' but keeps the old subcommand as well.
    if podman generate systemd --name --restart-policy=always \
            --new "$container" > "$unit_file" 2>/dev/null; then
        xrun systemctl daemon-reload
        xrun systemctl enable --now "${container}.service"
        success "Systemd unit enabled: ${container}.service"
    else
        warn "Could not generate systemd unit for ${container}."
        warn "The container is running but will NOT auto-start after reboot."
        warn "Run: podman generate systemd --name --new ${container} > /etc/systemd/system/${container}.service"
        warn "Then: systemctl daemon-reload && systemctl enable --now ${container}.service"
    fi
}

# ── Native backend helpers ────────────────────────────────────────────────────

# _native_registry_info — set NATIVE_PKG, NATIVE_SERVICE, NATIVE_CONF_DIR
# based on the current distro type.
_native_registry_info() {
    local distro_type="${DISTRO_TYPE:-}"
    if [[ -z "${distro_type}" ]] && declare -f detect_distro >/dev/null 2>&1; then
        detect_distro >/dev/null 2>&1 || true
        distro_type="${DISTRO_TYPE:-}"
    fi

    case "${distro_type}" in
        rhel)
            NATIVE_PKG="docker-distribution"
            NATIVE_SERVICE="docker-distribution"
            NATIVE_CONF_DIR="/etc/docker-distribution/registry"
            NATIVE_CONF_FILE="${NATIVE_CONF_DIR}/config.yml"
            ;;
        debian)
            NATIVE_PKG="docker-registry"
            NATIVE_SERVICE="docker-registry"
            NATIVE_CONF_DIR="/etc/docker/registry"
            NATIVE_CONF_FILE="${NATIVE_CONF_DIR}/config.yml"
            ;;
        *)
            die "Cannot use native Docker registry backend: unknown distro type '${distro_type}'. Set MIRRORET_DOCKER_BACKEND=container."
            ;;
    esac
    export NATIVE_PKG NATIVE_SERVICE NATIVE_CONF_DIR NATIVE_CONF_FILE
}

# _is_native_registry_available — true if the native OS package is present.
_is_native_registry_available() {
    _native_registry_info 2>/dev/null || return 1
    check_command "${NATIVE_SERVICE}" 2>/dev/null \
        || [[ -f "${NATIVE_CONF_FILE}" ]] \
        || { "${PKG_MGR:-apt-get}" list --installed 2>/dev/null | grep -q "^${NATIVE_PKG}" 2>/dev/null; } \
        || rpm -q "${NATIVE_PKG}" 2>/dev/null \
        || dpkg -l "${NATIVE_PKG}" 2>/dev/null | grep -q '^ii'
}

_setup_native_registry() {
    local backup_id="$1"
    local base_dir="${MIRRORET_BASE_DIR}"
    local registry_port="${MIRRORET_DOCKER_REGISTRY_PORT:-5000}"

    _native_registry_info

    info "Installing native registry package: ${NATIVE_PKG}"
    xrun ${PKG_MGR_INSTALL} "${NATIVE_PKG}"

    backup_file "$backup_id" "${NATIVE_CONF_FILE}"

    if [[ "${DRY_RUN}" == "1" ]]; then
        info "[DRY-RUN] would write native registry config to ${NATIVE_CONF_FILE}"
        return 0
    fi

    mkdir -p "${NATIVE_CONF_DIR}" "${base_dir}/docker/registry"

    cat > "${NATIVE_CONF_FILE}" <<REG_CONF
version: 0.1
log:
  fields:
    service: registry
storage:
  cache:
    blobdescriptor: inmemory
  filesystem:
    rootdirectory: ${base_dir}/docker/registry
http:
  addr: :${registry_port}
  headers:
    X-Content-Type-Options: [nosniff]
proxy:
  remoteurl: https://registry-1.docker.io
health:
  storagedriver:
    enabled: true
    interval: 10s
    threshold: 3
REG_CONF

    xrun systemctl daemon-reload
    xrun systemctl enable --now "${NATIVE_SERVICE}"
    success "Native Docker registry running on port ${registry_port} (service: ${NATIVE_SERVICE})."
}

# ── Container backend (preserved original) ───────────────────────────────────

_setup_container_registry() {
    local backup_id="$1"
    local base_dir="${MIRRORET_BASE_DIR}"
    local registry_port="${MIRRORET_DOCKER_REGISTRY_PORT:-5000}"

    _detect_container_runtime
    _start_docker_daemon

    backup_file "$backup_id" "/etc/docker/registry/config.yml"

    if [[ "${DRY_RUN}" == "1" ]]; then
        info "[DRY-RUN] would configure container registry on port ${registry_port}"
        return 0
    fi

    mkdir -p /etc/docker/registry
    mkdir -p "${base_dir}/docker/registry"

    cat > /etc/docker/registry/config.yml <<REG_CONF
version: 0.1
log:
  fields:
    service: registry
storage:
  cache:
    blobdescriptor: inmemory
  filesystem:
    rootdirectory: ${base_dir}/docker/registry
http:
  addr: :${registry_port}
  headers:
    X-Content-Type-Options: [nosniff]
proxy:
  remoteurl: https://registry-1.docker.io
health:
  storagedriver:
    enabled: true
    interval: 10s
    threshold: 3
REG_CONF

    if _container_is_running "${MIRRORET_DOCKER_CONTAINER_NAME}"; then
        info "Registry container already running. Restarting to pick up config changes."
        xrun "${CONTAINER_CMD}" restart "${MIRRORET_DOCKER_CONTAINER_NAME}"
    elif _container_exists "${MIRRORET_DOCKER_CONTAINER_NAME}"; then
        info "Registry container exists but stopped. Starting."
        xrun "${CONTAINER_CMD}" start "${MIRRORET_DOCKER_CONTAINER_NAME}"
    else
        info "Creating Docker registry container (runtime: ${CONTAINER_CMD})."
        xrun "${CONTAINER_CMD}" run -d \
            --name "${MIRRORET_DOCKER_CONTAINER_NAME}" \
            --restart=always \
            -p "${registry_port}:${registry_port}" \
            -v "${base_dir}/docker/registry:/var/lib/registry" \
            -v "/etc/docker/registry/config.yml:/etc/docker/registry/config.yml:ro" \
            registry:2
    fi

    # For Podman, --restart=always is not backed by a daemon process, so
    # generate a proper systemd unit to ensure the container survives reboots.
    if [[ "${CONTAINER_CMD}" == "podman" ]]; then
        _generate_podman_systemd_unit "${MIRRORET_DOCKER_CONTAINER_NAME}"
    fi

    success "Docker registry running on port ${registry_port} (runtime: ${CONTAINER_CMD})."
}

# ── Public API ────────────────────────────────────────────────────────────────

# setup_docker_registry <backup_id> — deploy the Docker registry.
# Selects native or container backend based on MIRRORET_DOCKER_BACKEND.
setup_docker_registry() {
    local backup_id="$1"
    local registry_port="${MIRRORET_DOCKER_REGISTRY_PORT:-5000}"
    local insecure="${MIRRORET_DOCKER_INSECURE:-0}"
    local backend="${MIRRORET_DOCKER_BACKEND:-auto}"
    local base_dir="${MIRRORET_BASE_DIR}"

    section "Setting Up Docker Registry (backend: ${backend})"

    if [[ "${insecure}" == "1" ]]; then
        warn_insecure "Docker registry running in INSECURE mode (no TLS)."
        warn_insecure "The generated client config will use insecure-registries."
        warn_insecure "Do NOT use this in production. See docs/SECURITY.md for TLS setup."
    fi

    case "${backend}" in
        native)
            _setup_native_registry "${backup_id}"
            ;;
        container)
            _setup_container_registry "${backup_id}"
            ;;
        auto)
            if _is_native_registry_available 2>/dev/null; then
                info "Native registry package available — using native backend."
                _setup_native_registry "${backup_id}"
            else
                info "Native registry not available — using container backend."
                _setup_container_registry "${backup_id}"
            fi
            ;;
        *)
            die "Unknown MIRRORET_DOCKER_BACKEND value: '${backend}'. Use auto, native, or container."
            ;;
    esac

    write_docker_sync_script "${base_dir}/scripts/sync-docker-images.sh"

    success "Docker registry ready on port ${registry_port}."
}

# generate_docker_client_config <output_file> — write daemon.json for clients.
generate_docker_client_config() {
    local output_file="$1"
    local server_ip="${MIRRORET_SERVER_IP}"
    local registry_port="${MIRRORET_DOCKER_REGISTRY_PORT:-5000}"
    local insecure="${MIRRORET_DOCKER_INSECURE:-0}"

    section "Generating Docker client config"

    if [[ "${DRY_RUN}" == "1" ]]; then
        info "[DRY-RUN] would write Docker client config to: ${output_file}"
        return 0
    fi

    if [[ "${insecure}" == "1" ]]; then
        warn_insecure "Docker client config: insecure-registries enabled for ${server_ip}:${registry_port}"

        cat > "$output_file" <<DOCKER_EOF
{
  "insecure-registries": ["${server_ip}:${registry_port}"]
}
DOCKER_EOF

    else
        cat > "$output_file" <<DOCKER_EOF
{
  "registry-mirrors": ["https://${server_ip}:${registry_port}"]
}
DOCKER_EOF
        info "Docker client config: TLS mode. Ensure a valid certificate is configured on the server."
        info "See docs/SECURITY.md for TLS setup."
    fi

    success "Docker client config written: ${output_file}"
}

# write_docker_sync_script <output_file> — generate the image pre-seed sync script.
# If MIRRORET_DOCKER_IMAGES_FILE is set, images are read from that file.
# Otherwise the built-in default list is used.
write_docker_sync_script() {
    local output_file="$1"
    local base_dir="${MIRRORET_BASE_DIR}"
    local registry_port="${MIRRORET_DOCKER_REGISTRY_PORT:-5000}"
    local runtime="${CONTAINER_CMD:-docker}"
    local images_file="${MIRRORET_DOCKER_IMAGES_FILE:-}"

    if [[ "${DRY_RUN}" == "1" ]]; then
        info "[DRY-RUN] would write Docker sync script to: ${output_file}"
        return 0
    fi

    mkdir -p "$(dirname "${output_file}")"

    # Build the IMAGES array literal for the generated script.
    local images_block
    if [[ -n "${images_file}" && -f "${images_file}" ]]; then
        # Read image list from file; strip comments and blank lines.
        images_block=""
        while IFS= read -r line; do
            line="${line%%#*}"       # strip inline comments
            line="${line// /}"       # strip spaces
            [[ -z "${line}" ]] && continue
            images_block+="    \"${line}\""$'\n'
        done < "${images_file}"
        info "Docker image list loaded from: ${images_file}"
    else
        images_block='    "ubuntu:22.04"
    "debian:12"
    "nginx:stable"
    "python:3.11-slim"
    "node:20-slim"
    "redis:7"
    "postgres:16"'
    fi

    local tmp
    tmp="$(mktemp_file)"
    cat > "$tmp" <<SYNC_HEADER
#!/usr/bin/env bash
set -Eeuo pipefail

# Docker image pre-seed sync script — generated by mirroret.
# Pulls images from Docker Hub and pushes them to the local registry.
#
# To customise the image list, create a text file (one image per line, # for
# comments) and set MIRRORET_DOCKER_IMAGES_FILE=/path/to/list.txt before
# running install.sh, or edit the IMAGES array below directly.
#
# The registry also operates in pull-through cache mode: any image pulled by
# a configured client that is NOT in the list will be transparently fetched
# from Docker Hub and cached locally.

LOCAL_REGISTRY="localhost:${registry_port}"
CONTAINER_CMD="${runtime}"
LOG_DIR="${base_dir}/logs"
LOG_FILE="\${LOG_DIR}/sync-docker-\$(date +%Y%m%d-%H%M%S).log"
mkdir -p "\$LOG_DIR"

echo "Starting Docker image sync: \$(date)" | tee -a "\$LOG_FILE"

IMAGES=(
${images_block}
)

failed=0
for image in "\${IMAGES[@]}"; do
    echo "Syncing \${image}..." | tee -a "\$LOG_FILE"

    if "\${CONTAINER_CMD}" pull "\$image" 2>&1 | tee -a "\$LOG_FILE"; then
        "\${CONTAINER_CMD}" tag "\$image" "\${LOCAL_REGISTRY}/\${image}"
        if "\${CONTAINER_CMD}" push "\${LOCAL_REGISTRY}/\${image}" 2>&1 | tee -a "\$LOG_FILE"; then
            echo "  OK: \${image}" | tee -a "\$LOG_FILE"
        else
            echo "  PUSH FAILED: \${image}" | tee -a "\$LOG_FILE"
            (( failed += 1 )) || true
        fi
    else
        echo "  PULL FAILED: \${image}" | tee -a "\$LOG_FILE"
        (( failed += 1 )) || true
    fi
done

echo "Docker sync completed: \$(date) (\${failed} failures)" | tee -a "\$LOG_FILE"
exit "\${failed}"
SYNC_HEADER

    mv "$tmp" "$output_file"
    chmod +x "$output_file"
    success "Docker sync script written: ${output_file}"
}

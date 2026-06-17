#!/usr/bin/env bash
# Docker registry management for mirroret.
# Source this file; do not execute it directly.
# Requires logging.sh, common.sh, backup.sh.

MIRRORET_DOCKER_CONTAINER_NAME="${MIRRORET_DOCKER_CONTAINER_NAME:-mirroret-registry}"

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
        die "No container runtime found. Install Docker CE (https://docs.docker.com/engine/install/) or Podman."
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

# setup_docker_registry <backup_id> — deploy the Docker registry container.
setup_docker_registry() {
    local backup_id="$1"
    local base_dir="${MIRRORET_BASE_DIR}"
    local registry_port="${MIRRORET_DOCKER_REGISTRY_PORT:-5000}"
    local insecure="${MIRRORET_DOCKER_INSECURE:-0}"

    section "Setting Up Docker Registry"

    _detect_container_runtime

    # Warn loudly if insecure mode is enabled.
    if [[ "${insecure}" == "1" ]]; then
        warn_insecure "Docker registry running in INSECURE mode (no TLS)."
        warn_insecure "The generated client config will use insecure-registries."
        warn_insecure "Do NOT use this in production. Set up TLS before production deployment."
        warn_insecure "See docs/SECURITY.md for TLS configuration."
    fi

    backup_file "$backup_id" "/etc/docker/registry/config.yml"

    if [[ "${DRY_RUN}" == "1" ]]; then
        info "[DRY-RUN] would configure Docker registry on port ${registry_port}"
        return 0
    fi

    _start_docker_daemon

    mkdir -p /etc/docker/registry
    mkdir -p "${base_dir}/docker/registry"

    # Write registry config. Includes a pull-through proxy stanza so
    # `docker pull ubuntu` transparently fetches from Docker Hub when the
    # image isn't already in the local registry.
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

    # Idempotent container management.
    # Port mapping: both sides use ${registry_port} because config.yml
    # tells the daemon to listen on that port inside the container.
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

    # Write the image sync script now that the container exists.
    write_docker_sync_script "${base_dir}/scripts/sync-docker-images.sh"

    success "Docker registry running on port ${registry_port} (runtime: ${CONTAINER_CMD})."
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
        # TLS mode — use registry-mirrors so `docker pull` transparently
        # hits the mirror. Requires a valid certificate on the server.
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

# write_docker_sync_script <output_file> — generate the image sync script.
write_docker_sync_script() {
    local output_file="$1"
    local base_dir="${MIRRORET_BASE_DIR}"
    local registry_port="${MIRRORET_DOCKER_REGISTRY_PORT:-5000}"
    local runtime="${CONTAINER_CMD:-docker}"

    if [[ "${DRY_RUN}" == "1" ]]; then
        info "[DRY-RUN] would write Docker sync script to: ${output_file}"
        return 0
    fi

    # Write the script with literal placeholders first, then substitute.
    # Using printf to avoid sed delimiter collisions with base_dir values.
    local tmp
    tmp="$(mktemp_file)"
    cat > "$tmp" <<'SYNC_EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

# Docker image sync script for mirroret.
# Pulls images from Docker Hub and pushes them to the local registry.
# Edit IMAGES to control what is mirrored.

LOCAL_REGISTRY="localhost:__REGISTRY_PORT__"
CONTAINER_CMD="__RUNTIME__"
LOG_DIR="__BASE_DIR__/logs"
LOG_FILE="${LOG_DIR}/sync-docker-$(date +%Y%m%d-%H%M%S).log"
mkdir -p "$LOG_DIR"

echo "Starting Docker image sync: $(date)" | tee -a "$LOG_FILE"

IMAGES=(
    "ubuntu:22.04"
    "debian:12"
    "nginx:stable"
    "python:3.11-slim"
    "node:20-slim"
    "redis:7"
    "postgres:16"
)

failed=0
for image in "${IMAGES[@]}"; do
    echo "Syncing ${image}..." | tee -a "$LOG_FILE"

    if "${CONTAINER_CMD}" pull "$image" 2>&1 | tee -a "$LOG_FILE"; then
        "${CONTAINER_CMD}" tag "$image" "${LOCAL_REGISTRY}/${image}"
        if "${CONTAINER_CMD}" push "${LOCAL_REGISTRY}/${image}" 2>&1 | tee -a "$LOG_FILE"; then
            echo "  OK: ${image}" | tee -a "$LOG_FILE"
        else
            echo "  PUSH FAILED: ${image}" | tee -a "$LOG_FILE"
            (( failed += 1 )) || true
        fi
    else
        echo "  PULL FAILED: ${image}" | tee -a "$LOG_FILE"
        (( failed += 1 )) || true
    fi
done

echo "Docker sync completed: $(date) (${failed} failures)" | tee -a "$LOG_FILE"
exit "${failed}"
SYNC_EOF

    # Substitute using printf-based replacement to safely handle any path.
    local content
    content="$(cat "$tmp")"
    content="${content//__REGISTRY_PORT__/${registry_port}}"
    content="${content//__BASE_DIR__/${base_dir}}"
    content="${content//__RUNTIME__/${runtime}}"
    printf '%s\n' "$content" > "$output_file"
    rm -f "$tmp"

    chmod +x "$output_file"
    success "Docker sync script written: ${output_file}"
}

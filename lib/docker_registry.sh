#!/usr/bin/env bash
# Docker registry management for mirroret.
# Source this file; do not execute it directly.
# Requires logging.sh, common.sh, backup.sh.

MIRRORET_DOCKER_CONTAINER_NAME="${MIRRORET_DOCKER_CONTAINER_NAME:-mirroret-registry}"

# setup_docker_registry <backup_id> — deploy the Docker registry container.
setup_docker_registry() {
    local backup_id="$1"
    local base_dir="${MIRRORET_BASE_DIR}"
    local registry_port="${MIRRORET_DOCKER_REGISTRY_PORT:-5000}"
    local insecure="${MIRRORET_DOCKER_INSECURE:-0}"

    section "Setting Up Docker Registry"

    require_command docker

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
health:
  storagedriver:
    enabled: true
    interval: 10s
    threshold: 3
REG_CONF

    # Idempotent container management.
    if container_is_running "${MIRRORET_DOCKER_CONTAINER_NAME}"; then
        info "Docker registry container already running. Restarting to pick up config changes."
        xrun docker restart "${MIRRORET_DOCKER_CONTAINER_NAME}"
    elif container_exists "${MIRRORET_DOCKER_CONTAINER_NAME}"; then
        info "Docker registry container exists but stopped. Starting."
        xrun docker start "${MIRRORET_DOCKER_CONTAINER_NAME}"
    else
        info "Creating Docker registry container."
        xrun docker run -d \
            --name "${MIRRORET_DOCKER_CONTAINER_NAME}" \
            --restart=always \
            -p "${registry_port}:5000" \
            -v "${base_dir}/docker/registry:/var/lib/registry" \
            -v "/etc/docker/registry/config.yml:/etc/docker/registry/config.yml:ro" \
            registry:2
    fi

    success "Docker registry running on port ${registry_port}."
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
        # TLS mode — no insecure-registries entry.
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

    if [[ "${DRY_RUN}" == "1" ]]; then
        info "[DRY-RUN] would write Docker sync script to: ${output_file}"
        return 0
    fi

    cat > "$output_file" <<'SYNC_EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

# Docker image sync script for mirroret.
# Pulls images from Docker Hub and pushes them to the local registry.
# Edit IMAGES to control what is mirrored.

LOCAL_REGISTRY="localhost:REGISTRY_PORT"
LOG_DIR="BASE_DIR/logs"
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

    if docker pull "$image" 2>&1 | tee -a "$LOG_FILE"; then
        docker tag "$image" "${LOCAL_REGISTRY}/${image}"
        if docker push "${LOCAL_REGISTRY}/${image}" 2>&1 | tee -a "$LOG_FILE"; then
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

    # Substitute actual values.
    sed -i "s|REGISTRY_PORT|${registry_port}|g" "$output_file"
    sed -i "s|BASE_DIR|${base_dir}|g" "$output_file"

    chmod +x "$output_file"
    success "Docker sync script written: ${output_file}"
}

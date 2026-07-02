#!/usr/bin/env bash
# Docker registry management for mirroret.
# Source this file; do not execute it directly.
# Requires logging.sh, common.sh, backup.sh, distro.sh.
#
# Operating modes (MIRRORET_DOCKER_MODE):
#   cache  — pull-through cache: registry transparently proxies upstream
#            and caches every pulled layer. Pre-seed/push is NOT possible
#            in this mode (the registry rejects pushes). This is the
#            default — it is the most useful mode for offline-warming a
#            cache from connected clients.
#   hosted — local registry: accepts docker push from the mirror server
#            and clients. No upstream proxy. Use this when you want to
#            mirror a curated set of images and serve them air-gapped.
#            The generated sync-docker-images.sh runs only in this mode.
#
# Backend (MIRRORET_DOCKER_BACKEND):
#   auto      — try native OS package first, fall back to container
#   native    — OS package (docker-distribution on RHEL, docker-registry
#               on Debian). No container runtime required at runtime.
#   container — registry:2 container via Docker or Podman.
#
# Other knobs:
#   MIRRORET_DOCKER_UPSTREAM_URL   upstream when MODE=cache (default Docker Hub)
#   MIRRORET_DOCKER_IMAGES_FILE    path to plain-text image list (MODE=hosted)

MIRRORET_DOCKER_CONTAINER_NAME="${MIRRORET_DOCKER_CONTAINER_NAME:-mirroret-registry}"
MIRRORET_DOCKER_BACKEND="${MIRRORET_DOCKER_BACKEND:-auto}"
MIRRORET_DOCKER_MODE="${MIRRORET_DOCKER_MODE:-cache}"
MIRRORET_DOCKER_UPSTREAM_URL="${MIRRORET_DOCKER_UPSTREAM_URL:-https://registry-1.docker.io}"
MIRRORET_DOCKER_IMAGES_FILE="${MIRRORET_DOCKER_IMAGES_FILE:-}"

# ── Proxy propagation helpers ────────────────────────────────────────────────
# The registry container (cache mode) must reach the upstream, and the
# native docker-distribution / docker-registry services likewise. On hosts
# behind a corporate proxy, systemd starts services with a MINIMAL env
# (systemd does not read /etc/environment for services), so we have to
# inject the proxy explicitly into both the container run and the native
# service drop-in.

# _docker_proxy_run_args — print the `-e HTTP_PROXY=... -e HTTPS_PROXY=... -e NO_PROXY=...`
# argument list for `podman run` / `docker run`. Empty when no proxy env is set.
_docker_proxy_run_args() {
    local args=""
    # Read whichever case the operator has. Uppercase wins if both set.
    local http_p="${HTTP_PROXY:-${http_proxy:-}}"
    local https_p="${HTTPS_PROXY:-${https_proxy:-}}"
    local no_p="${NO_PROXY:-${no_proxy:-}}"
    [[ -n "$http_p"  ]] && args+=" -e HTTP_PROXY=${http_p} -e http_proxy=${http_p}"
    [[ -n "$https_p" ]] && args+=" -e HTTPS_PROXY=${https_p} -e https_proxy=${https_p}"
    [[ -n "$no_p"    ]] && args+=" -e NO_PROXY=${no_p} -e no_proxy=${no_p}"
    printf '%s' "${args}"
}

# _write_service_proxy_dropin <service-name> — write a systemd drop-in that
# injects proxy env into the given service. No-op if no proxy env is set.
_write_service_proxy_dropin() {
    local svc="$1"
    local http_p="${HTTP_PROXY:-${http_proxy:-}}"
    local https_p="${HTTPS_PROXY:-${https_proxy:-}}"
    local no_p="${NO_PROXY:-${no_proxy:-}}"

    if [[ -z "$http_p" && -z "$https_p" && -z "$no_p" ]]; then
        debug "No proxy env in installer shell — skipping ${svc} proxy drop-in."
        return 0
    fi

    local dir="/etc/systemd/system/${svc}.service.d"
    local file="${dir}/proxy.conf"

    if [[ "${DRY_RUN:-0}" == "1" ]]; then
        info "[DRY-RUN] would write ${file} with proxy env for ${svc}"
        return 0
    fi

    mkdir -p "$dir"
    {
        printf '[Service]\n'
        [[ -n "$http_p"  ]] && printf 'Environment="HTTP_PROXY=%s"\n'  "$http_p"  \
                             && printf 'Environment="http_proxy=%s"\n' "$http_p"
        [[ -n "$https_p" ]] && printf 'Environment="HTTPS_PROXY=%s"\n' "$https_p" \
                             && printf 'Environment="https_proxy=%s"\n' "$https_p"
        [[ -n "$no_p"    ]] && printf 'Environment="NO_PROXY=%s"\n'   "$no_p"    \
                             && printf 'Environment="no_proxy=%s"\n'  "$no_p"
    } > "$file"
    info "Wrote proxy drop-in for ${svc}: ${file}"
}

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
        # No runtime found — attempt to auto-install Podman (BaseOS on
        # RHEL/Rocky/Alma, universe on Ubuntu).
        info "No container runtime found — attempting to install podman..."
        # shellcheck disable=SC2086  # PKG_MGR_INSTALL is intentionally word-split
        ${PKG_MGR_INSTALL} podman 2>/dev/null || true
        if check_command podman; then
            info "Podman installed successfully."
            CONTAINER_CMD="podman"
        else
            die "No container runtime found. Install Docker CE or Podman and re-run install.sh."
        fi
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

# _emit_registry_config <path> — write the registry config.yml at <path>.
# Embeds the proxy block ONLY when MIRRORET_DOCKER_MODE=cache.
_emit_registry_config() {
    local conf_file="$1"
    local base_dir="${MIRRORET_BASE_DIR}"
    local registry_port="${MIRRORET_DOCKER_REGISTRY_PORT:-5000}"
    local mode="${MIRRORET_DOCKER_MODE:-cache}"

    mkdir -p "$(dirname "${conf_file}")"

    {
        cat <<HEAD
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
HEAD

        if [[ "${mode}" == "cache" ]]; then
            cat <<PROXY
# Pull-through cache mode (MIRRORET_DOCKER_MODE=cache).
# A registry in proxy mode REJECTS pushes — do not use this with the
# pre-seed sync script. Switch to MIRRORET_DOCKER_MODE=hosted if you
# want to push images into the mirror.
proxy:
  remoteurl: ${MIRRORET_DOCKER_UPSTREAM_URL}
PROXY
        else
            cat <<HOSTED
# Hosted mode (MIRRORET_DOCKER_MODE=hosted).
# No upstream proxy — the registry only serves images that have been
# explicitly pushed to it. sync-docker-images.sh handles the pre-seed.
HOSTED
        fi

        cat <<TAIL
health:
  storagedriver:
    enabled: true
    interval: 10s
    threshold: 3
TAIL
    } > "${conf_file}"
}

_setup_native_registry() {
    local backup_id="$1"

    _native_registry_info

    info "Installing native registry package: ${NATIVE_PKG}"
    # shellcheck disable=SC2086  # PKG_MGR_INSTALL is intentionally word-split
    xrun ${PKG_MGR_INSTALL} "${NATIVE_PKG}"

    backup_file "$backup_id" "${NATIVE_CONF_FILE}"

    if [[ "${DRY_RUN}" == "1" ]]; then
        info "[DRY-RUN] would write native registry config to ${NATIVE_CONF_FILE}"
        return 0
    fi

    mkdir -p "${NATIVE_CONF_DIR}" "${MIRRORET_BASE_DIR}/docker/registry"
    _emit_registry_config "${NATIVE_CONF_FILE}"

    # Native services run under systemd with a minimal env — they won't
    # inherit the operator's shell HTTP_PROXY. Drop in an Environment
    # override so cache mode can actually reach the upstream.
    _write_service_proxy_dropin "${NATIVE_SERVICE}"

    xrun systemctl daemon-reload
    xrun systemctl enable --now "${NATIVE_SERVICE}"
    success "Native Docker registry running (mode: ${MIRRORET_DOCKER_MODE}, service: ${NATIVE_SERVICE})."
}

# ── Container backend ────────────────────────────────────────────────────────

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

    mkdir -p /etc/docker/registry "${base_dir}/docker/registry"
    _emit_registry_config "/etc/docker/registry/config.yml"

    if _container_is_running "${MIRRORET_DOCKER_CONTAINER_NAME}"; then
        info "Registry container already running. Restarting to pick up config changes."
        xrun "${CONTAINER_CMD}" restart "${MIRRORET_DOCKER_CONTAINER_NAME}"
    elif _container_exists "${MIRRORET_DOCKER_CONTAINER_NAME}"; then
        info "Registry container exists but stopped. Starting."
        xrun "${CONTAINER_CMD}" start "${MIRRORET_DOCKER_CONTAINER_NAME}"
    else
        info "Creating Docker registry container (runtime: ${CONTAINER_CMD}, mode: ${MIRRORET_DOCKER_MODE})."
        # Propagate the installer shell's proxy env into the container.
        # Cache mode NEEDS this to reach the upstream; hosted mode doesn't
        # dial out on start, but the -e flags are harmless there.
        local proxy_args
        proxy_args="$(_docker_proxy_run_args)"
        [[ -n "${proxy_args}" ]] && info "Passing proxy env into container: ${proxy_args}"
        # shellcheck disable=SC2086  # proxy_args must be word-split into -e/name/value triples
        xrun "${CONTAINER_CMD}" run -d \
            --name "${MIRRORET_DOCKER_CONTAINER_NAME}" \
            --restart=always \
            -p "${registry_port}:${registry_port}" \
            -v "${base_dir}/docker/registry:/var/lib/registry" \
            -v "/etc/docker/registry/config.yml:/etc/docker/registry/config.yml:ro" \
            ${proxy_args} \
            registry:2
    fi

    # For Podman, --restart=always is not backed by a daemon process, so
    # generate a proper systemd unit to ensure the container survives reboots.
    if [[ "${CONTAINER_CMD}" == "podman" ]]; then
        _generate_podman_systemd_unit "${MIRRORET_DOCKER_CONTAINER_NAME}"
        # Belt+suspenders: even though the -e flags at run time get baked
        # into the generated unit, drop in an explicit Environment override
        # in case podman regenerates the ExecStart without them.
        _write_service_proxy_dropin "${MIRRORET_DOCKER_CONTAINER_NAME}"
        xrun systemctl daemon-reload || true
        xrun systemctl restart "${MIRRORET_DOCKER_CONTAINER_NAME}.service" || true
    fi

    success "Docker registry running (mode: ${MIRRORET_DOCKER_MODE}, runtime: ${CONTAINER_CMD})."
}

# ── Public API ────────────────────────────────────────────────────────────────

# setup_docker_registry <backup_id> — deploy the Docker registry.
# Selects native or container backend based on MIRRORET_DOCKER_BACKEND
# and embeds proxy or hosted config based on MIRRORET_DOCKER_MODE.
setup_docker_registry() {
    local backup_id="$1"
    local registry_port="${MIRRORET_DOCKER_REGISTRY_PORT:-5000}"
    local insecure="${MIRRORET_DOCKER_INSECURE:-0}"
    local backend="${MIRRORET_DOCKER_BACKEND:-auto}"
    local mode="${MIRRORET_DOCKER_MODE:-cache}"
    local base_dir="${MIRRORET_BASE_DIR}"

    case "${mode}" in
        cache|hosted) ;;
        *) die "Unknown MIRRORET_DOCKER_MODE value: '${mode}'. Use cache or hosted." ;;
    esac

    section "Setting Up Docker Registry (mode: ${mode}, backend: ${backend})"

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

    # Only generate the pre-seed sync script in hosted mode. A cache-mode
    # registry rejects pushes, so writing the script would just produce
    # confusing failures on first cron run.
    if [[ "${mode}" == "hosted" ]]; then
        write_docker_sync_script "${base_dir}/scripts/sync-docker-images.sh"
    else
        # If a stale hosted-mode sync script exists from a previous run,
        # neutralise it so cron does not call it.
        local stale="${base_dir}/scripts/sync-docker-images.sh"
        if [[ "${DRY_RUN}" != "1" ]] && [[ -f "${stale}" ]]; then
            mv "${stale}" "${stale}.cache-mode-disabled"
            info "Cache mode: disabled stale pre-seed script -> ${stale}.cache-mode-disabled"
        fi
    fi

    success "Docker registry ready on port ${registry_port}."
}

# has_docker_sync_script — true when a usable sync script exists for sync-all.
has_docker_sync_script() {
    [[ "${MIRRORET_DOCKER_MODE:-cache}" == "hosted" ]] \
        && [[ -x "${MIRRORET_BASE_DIR}/scripts/sync-docker-images.sh" ]]
}

# generate_docker_client_config <output_file> — write daemon.json for clients.
generate_docker_client_config() {
    local output_file="$1"
    local server_ip="${MIRRORET_SERVER_IP}"
    local registry_port="${MIRRORET_DOCKER_REGISTRY_PORT:-5000}"
    local insecure="${MIRRORET_DOCKER_INSECURE:-0}"
    local mode="${MIRRORET_DOCKER_MODE:-cache}"

    section "Generating Docker client config"

    if [[ "${DRY_RUN}" == "1" ]]; then
        info "[DRY-RUN] would write Docker client config to: ${output_file}"
        return 0
    fi

    # registry-mirrors is the right field for cache (pull-through) mode;
    # in hosted mode clients pull explicitly from <server>:<port>/<image>,
    # so we emit a comment rather than misconfiguring the daemon.
    local registry_url scheme="https"
    [[ "${insecure}" == "1" ]] && scheme="http"
    registry_url="${scheme}://${server_ip}:${registry_port}"

    if [[ "${mode}" == "cache" ]]; then
        if [[ "${insecure}" == "1" ]]; then
            warn_insecure "Docker client config: insecure-registries enabled for ${server_ip}:${registry_port}"
            cat > "$output_file" <<DOCKER_EOF
{
  "registry-mirrors": ["${registry_url}"],
  "insecure-registries": ["${server_ip}:${registry_port}"]
}
DOCKER_EOF
        else
            cat > "$output_file" <<DOCKER_EOF
{
  "registry-mirrors": ["${registry_url}"]
}
DOCKER_EOF
            info "Docker client config: TLS mode. Ensure a valid certificate is configured on the server."
            info "See docs/SECURITY.md for TLS setup."
        fi
    else
        if [[ "${insecure}" == "1" ]]; then
            warn_insecure "Docker client config: insecure-registries enabled for ${server_ip}:${registry_port}"
            cat > "$output_file" <<DOCKER_EOF
{
  "_comment": "Hosted-mode mirror: pull with docker pull ${server_ip}:${registry_port}/<image>",
  "insecure-registries": ["${server_ip}:${registry_port}"]
}
DOCKER_EOF
        else
            cat > "$output_file" <<DOCKER_EOF
{
  "_comment": "Hosted-mode mirror: pull with docker pull ${server_ip}:${registry_port}/<image>"
}
DOCKER_EOF
            info "Docker client config: hosted mode. Pull explicitly with docker pull ${server_ip}:${registry_port}/<image>."
        fi
    fi

    success "Docker client config written: ${output_file}"
}

# write_docker_sync_script <output_file> — generate the image pre-seed sync script.
# ONLY called in hosted mode. In cache mode the registry rejects pushes
# and there is nothing to pre-seed.
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

    # Upgrade safety: don't clobber operator edits.
    if ! preserve_user_customization "${output_file}"; then
        return 0
    fi

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

${MIRRORET_MANAGED_MARKER}
# To customize the image list, set MIRRORET_DOCKER_IMAGES_FILE=/path
# before running install.sh — do NOT edit this file directly.

# Docker image pre-seed sync script — generated by mirroret.
# REQUIRES MIRRORET_DOCKER_MODE=hosted at install time.
# Pulls images from the configured upstream and pushes them to the
# local registry. The local registry must be in hosted mode — cache-
# mode registries reject pushes.

LOCAL_REGISTRY="localhost:${registry_port}"
CONTAINER_CMD="${runtime}"
LOG_DIR="${base_dir}/logs"
LOG_FILE="\${LOG_DIR}/sync-docker-\$(date +%Y%m%d-%H%M%S).log"
mkdir -p "\$LOG_DIR"

# Log to file AND console without losing the exit code from the pipeline.
exec > >(tee -a "\$LOG_FILE") 2>&1

echo "Starting Docker image sync: \$(date)"

if ! command -v "\${CONTAINER_CMD}" >/dev/null 2>&1; then
    echo "ERROR: container runtime '\${CONTAINER_CMD}' not found on this host."
    echo "Install docker or podman, or set MIRRORET_DOCKER_MODE=cache to disable pre-seed."
    exit 2
fi

IMAGES=(
${images_block}
)

failed=0
for image in "\${IMAGES[@]}"; do
    echo "Syncing \${image}..."
    if ! "\${CONTAINER_CMD}" pull "\$image"; then
        echo "  PULL FAILED: \${image}"
        failed=\$(( failed + 1 ))
        continue
    fi
    if ! "\${CONTAINER_CMD}" tag "\$image" "\${LOCAL_REGISTRY}/\${image}"; then
        echo "  TAG FAILED: \${image}"
        failed=\$(( failed + 1 ))
        continue
    fi
    if ! "\${CONTAINER_CMD}" push "\${LOCAL_REGISTRY}/\${image}"; then
        echo "  PUSH FAILED: \${image}"
        failed=\$(( failed + 1 ))
        continue
    fi
    echo "  OK: \${image}"
done

echo "Docker sync completed: \$(date) (\${failed} failures)"
exit "\${failed}"
SYNC_HEADER

    mv "$tmp" "$output_file"
    chmod +x "$output_file"
    success "Docker sync script written: ${output_file}"
}

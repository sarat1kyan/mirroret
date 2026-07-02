#!/usr/bin/env bash
# Verdaccio npm registry setup for mirroret.
# Source this file; do not execute it directly.
# Requires logging.sh, common.sh, backup.sh, systemd.sh.
#
# MIRRORET_NPM_PACKAGES_FILE  path to a text file listing packages to sync
#                             (one per line, # for comments). Uses built-in
#                             default list when unset.
# MIRRORET_NPM_ALLOW_ANON_PUBLISH=1   allow unauthenticated publish to Verdaccio
#                             (useful in isolated networks with no auth needed).
# MIRRORET_APPROVAL_ENABLED=1  download tarballs to staging/npm/ instead of
#                             publishing directly; admin promotes via approval.sh.
#
# NOTE: npm auto-publish via verdaccio has limitations. Verdaccio must be
# running and reachable on localhost before the sync script can publish.
# Scoped packages (@org/pkg) require the registry to have the scope configured.
# See docs/OPERATIONS.md for the full npm mirroring workflow.

MIRRORET_NPM_USER="${MIRRORET_NPM_USER:-mirroret-npm}"
MIRRORET_NPM_PACKAGES_FILE="${MIRRORET_NPM_PACKAGES_FILE:-}"
MIRRORET_NPM_ALLOW_ANON_PUBLISH="${MIRRORET_NPM_ALLOW_ANON_PUBLISH:-0}"

# setup_npm_registry <backup_id> — install Verdaccio and create systemd unit.
setup_npm_registry() {
    local backup_id="$1"
    local base_dir="${MIRRORET_BASE_DIR}"
    local npm_port="${MIRRORET_NPM_PORT:-4873}"

    section "Setting Up npm Registry (Verdaccio)"

    _ensure_npm_user
    _install_verdaccio
    _write_verdaccio_config "$backup_id" "$base_dir"
    _write_verdaccio_unit "$backup_id" "$base_dir" "$npm_port"
    systemd_daemon_reload
    enable_and_start verdaccio
    _write_npm_sync_script "$base_dir"

    success "Verdaccio configured on port ${npm_port}."
}

_ensure_npm_user() {
    if ! id "${MIRRORET_NPM_USER}" &>/dev/null; then
        if [[ "${DRY_RUN}" == "1" ]]; then
            info "[DRY-RUN] would create system user: ${MIRRORET_NPM_USER}"
            return 0
        fi
        xrun useradd --system --no-create-home --shell /usr/sbin/nologin "${MIRRORET_NPM_USER}"
        info "Created system user: ${MIRRORET_NPM_USER}"
    else
        debug "System user already exists: ${MIRRORET_NPM_USER}"
    fi
}

_install_verdaccio() {
    if check_command verdaccio; then
        info "Verdaccio already installed."
        return 0
    fi

    # Ensure npm is available; attempt auto-install if it is not.
    if ! check_command npm; then
        info "npm not found — attempting to install nodejs and npm..."
        if [[ "${DISTRO_TYPE}" == "rhel" ]]; then
            # RHEL 8 requires the AppStream module to be enabled first.
            dnf module enable nodejs -y 2>/dev/null || true
        fi
        # shellcheck disable=SC2086  # PKG_MGR_INSTALL intentionally word-split
        xrun ${PKG_MGR_INSTALL} nodejs npm \
            || die "npm installation failed. Install nodejs and npm manually, then re-run install.sh."
    fi

    # Detect Node major version and pick a Verdaccio release that supports it.
    # Verdaccio 6.x requires Node >= 20 (as of writing).
    # Verdaccio 5.x supports Node 12 – 20 and is the safe pin for older hosts
    # like RHEL 9 default AppStream (which ships Node 16).
    local node_major=""
    if check_command node; then
        node_major="$(node -v 2>/dev/null | sed 's/^v//' | cut -d. -f1)"
    fi

    local verdaccio_pkg="verdaccio"
    if [[ -n "${node_major}" ]] && [[ "${node_major}" =~ ^[0-9]+$ ]] && [[ "${node_major}" -lt 18 ]]; then
        verdaccio_pkg="verdaccio@^5"
        warn "Node ${node_major} detected. Pinning to Verdaccio 5.x (last release compatible with Node < 18)."
        warn "For Verdaccio 6+, upgrade Node: sudo dnf module reset nodejs && sudo dnf module enable nodejs:20"
    elif [[ -n "${MIRRORET_VERDACCIO_VERSION:-}" ]]; then
        verdaccio_pkg="verdaccio@${MIRRORET_VERDACCIO_VERSION}"
        info "Verdaccio version override: ${verdaccio_pkg}"
    fi

    if [[ "${DRY_RUN}" == "1" ]]; then
        info "[DRY-RUN] would run: npm install -g ${verdaccio_pkg}"
        return 0
    fi
    info "Installing Verdaccio: ${verdaccio_pkg}"
    xrun npm install -g "${verdaccio_pkg}" \
        || die "Verdaccio install failed. Check proxy + npm config, then re-run."
    info "Verdaccio installed."
}

_write_verdaccio_config() {
    local backup_id="$1"
    local base_dir="$2"

    backup_file "$backup_id" "/etc/verdaccio/config.yaml"

    if [[ "${DRY_RUN}" == "1" ]]; then
        info "[DRY-RUN] would write Verdaccio config to /etc/verdaccio/config.yaml"
        return 0
    fi

    mkdir -p /etc/verdaccio
    # Create an empty htpasswd file so Verdaccio starts cleanly.
    touch /etc/verdaccio/htpasswd

    # Detect actual verdaccio plugin directory (varies by install method).
    local plugins_dir
    if [[ -d /usr/lib/verdaccio/plugins ]]; then
        plugins_dir="/usr/lib/verdaccio/plugins"
    elif check_command npm; then
        plugins_dir="$(npm root -g 2>/dev/null)/verdaccio/build/lib/plugin"
    fi

    # When anonymous publish is enabled, allow $all; otherwise require auth.
    local publish_who="\$authenticated"
    [[ "${MIRRORET_NPM_ALLOW_ANON_PUBLISH:-0}" == "1" ]] && publish_who="\$all"

    cat > /etc/verdaccio/config.yaml <<VERD_EOF
# Verdaccio configuration — generated by mirroret.
storage: ${base_dir}/npm/approved
${plugins_dir:+plugins: ${plugins_dir}}

auth:
  htpasswd:
    file: /etc/verdaccio/htpasswd
    max_users: 1000

uplinks:
  npmjs:
    url: https://registry.npmjs.org/
    timeout: 30s
    maxage: 10m

packages:
  '@*/*':
    access: \$all
    publish: ${publish_who}
    unpublish: ${publish_who}
    proxy: npmjs
  '**':
    access: \$all
    publish: ${publish_who}
    unpublish: ${publish_who}
    proxy: npmjs

server:
  keepAliveTimeout: 60

middlewares:
  audit:
    enabled: true

logs:
  - { type: stdout, format: pretty, level: warn }
VERD_EOF

    chown -R "${MIRRORET_NPM_USER}:" /etc/verdaccio
    success "Verdaccio config written."
}

_write_verdaccio_unit() {
    local backup_id="$1"
    local base_dir="$2"
    local npm_port="$3"

    local verdaccio_bin
    verdaccio_bin="$(command -v verdaccio 2>/dev/null || echo /usr/bin/verdaccio)"

    local unit_content="[Unit]
Description=Verdaccio npm Registry (mirroret)
After=network.target

[Service]
Type=simple
User=${MIRRORET_NPM_USER}
ExecStart=${verdaccio_bin} --config /etc/verdaccio/config.yaml --listen ${npm_port}
Restart=on-failure
RestartSec=5s
NoNewPrivileges=true
ProtectSystem=strict
ReadWritePaths=${base_dir}/npm /etc/verdaccio
PrivateTmp=true

[Install]
WantedBy=multi-user.target"

    write_systemd_unit "$backup_id" "verdaccio.service" "$unit_content"

    if [[ "${DRY_RUN}" != "1" ]]; then
        xrun chown -R "${MIRRORET_NPM_USER}:" "${base_dir}/npm"
    fi
}

_write_npm_sync_script() {
    local base_dir="$1"
    local sync_script="${base_dir}/scripts/sync-npm-packages.sh"
    local npm_port="${MIRRORET_NPM_PORT:-4873}"
    local approval="${MIRRORET_APPROVAL_ENABLED:-0}"
    local packages_file="${MIRRORET_NPM_PACKAGES_FILE:-}"
    local allow_anon="${MIRRORET_NPM_ALLOW_ANON_PUBLISH:-0}"

    if [[ "${DRY_RUN}" == "1" ]]; then
        info "[DRY-RUN] would write npm sync script: ${sync_script}"
        return 0
    fi

    mkdir -p "${base_dir}/scripts"

    # Upgrade safety: don't clobber operator edits.
    if ! preserve_user_customization "${sync_script}"; then
        return 0
    fi

    # Build the PACKAGES array literal.
    local packages_block
    if [[ -n "${packages_file}" && -f "${packages_file}" ]]; then
        packages_block=""
        while IFS= read -r line; do
            line="${line%%#*}"
            line="${line// /}"
            [[ -z "${line}" ]] && continue
            packages_block+="    \"${line}\""$'\n'
        done < "${packages_file}"
        info "npm package list loaded from: ${packages_file}"
    else
        packages_block='    "express"
    "lodash"
    "axios"
    "react"
    "webpack"
    "typescript"
    "eslint"'
    fi

    # Approval mode: download to staging, do NOT publish automatically.
    # Non-approval mode: download then publish to Verdaccio.
    local publish_block
    if [[ "${approval}" == "1" ]]; then
        publish_block="# Approval mode: tarballs land in staging. Run mirroret --approve-all-npm to promote."
    elif [[ "${allow_anon}" == "1" ]]; then
        publish_block='    tarball=$(ls -t "${WORK_DIR}/"*.tgz 2>/dev/null | head -1)
    if [[ -n "${tarball}" ]]; then
        if npm publish "${tarball}" --registry "${VERDACCIO_URL}"; then
            echo "  PUBLISHED: ${package}"
        else
            echo "  PUBLISH FAILED: ${package}"
            failed=$(( failed + 1 ))
        fi
    fi'
    else
        publish_block='    # Verdaccio requires authentication by default.
    # Set MIRRORET_NPM_ALLOW_ANON_PUBLISH=1 to enable anonymous publish,
    # or run: npm login --registry="${VERDACCIO_URL}" before syncing.
    tarball=$(ls -t "${WORK_DIR}/"*.tgz 2>/dev/null | head -1)
    if [[ -n "${tarball}" ]]; then
        if npm publish "${tarball}" --registry "${VERDACCIO_URL}"; then
            echo "  PUBLISHED: ${package}"
        else
            echo "  PUBLISH FAILED (auth required?): ${package}"
            failed=$(( failed + 1 ))
        fi
    fi'
    fi

    cat > "${sync_script}" <<SYNC_SCRIPT
#!/usr/bin/env bash
set -Eeuo pipefail

${MIRRORET_MANAGED_MARKER}
# To customize the package list, set MIRRORET_NPM_PACKAGES_FILE=/path
# before running install.sh — do NOT edit this file directly.

# npm package sync script — generated by mirroret.
# Downloads tarballs via 'npm pack' and (when approval is off) publishes them
# to Verdaccio.

VERDACCIO_URL="http://localhost:${npm_port}/"
# When approval mode is on, download to staging/npm (approval.sh promotes to approved/npm).
# When off, download to npm/staging as a temp area before publishing.
STAGING_DIR="${base_dir}/staging/npm"
WORK_DIR_DEFAULT="${base_dir}/npm/staging"
APPROVED_DIR="${base_dir}/npm/approved"
LOG_DIR="${base_dir}/logs"
LOG_FILE="\${LOG_DIR}/sync-npm-\$(date +%Y%m%d-%H%M%S).log"
APPROVAL_MODE="${approval}"

mkdir -p "\$LOG_DIR" "\$STAGING_DIR" "\$WORK_DIR_DEFAULT" "\$APPROVED_DIR"
exec > >(tee -a "\$LOG_FILE") 2>&1

echo "Starting npm package sync: \$(date)"

if ! command -v npm >/dev/null 2>&1; then
    echo "ERROR: npm not found on this host. Install nodejs + npm and re-run."
    exit 2
fi

PACKAGES=(
${packages_block}
)

# In approval mode: drop tarballs in staging/npm for admin review.
# Otherwise: use a temp work dir and publish directly.
if [[ "\${APPROVAL_MODE}" == "1" ]]; then
    WORK_DIR="\${STAGING_DIR}"
else
    WORK_DIR="\${WORK_DIR_DEFAULT}"
fi
failed=0

for package in "\${PACKAGES[@]}"; do
    echo "Processing \${package}..."
    pushd "\${WORK_DIR}" >/dev/null
    if npm pack "\${package}"; then
        echo "  DOWNLOADED: \${package}"
${publish_block}
    else
        echo "  DOWNLOAD FAILED: \${package}"
        failed=\$(( failed + 1 ))
    fi
    popd >/dev/null
done

echo "npm sync completed: \$(date) (\${failed} failures)"
if [[ "\${APPROVAL_MODE}" == "1" ]]; then
    echo "Tarballs in staging: \${STAGING_DIR}"
    echo "Approve with: install.sh --approve-all-npm"
fi
if [[ "\${failed}" -gt 0 ]]; then
    exit 1
fi
SYNC_SCRIPT

    chmod +x "${sync_script}"
    success "npm sync script written: ${sync_script}"
}

# generate_npm_client_config <output_file> — write .npmrc for clients.
generate_npm_client_config() {
    local output_file="$1"
    local server_ip="${MIRRORET_SERVER_IP}"
    local npm_port="${MIRRORET_NPM_PORT:-4873}"

    if [[ "${DRY_RUN}" == "1" ]]; then
        info "[DRY-RUN] would write npm client config to: ${output_file}"
        return 0
    fi

    cat > "$output_file" <<NPM_EOF
registry=http://${server_ip}:${npm_port}/
NPM_EOF

    success "npm client config written: ${output_file}"
}

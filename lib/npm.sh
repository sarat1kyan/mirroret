#!/usr/bin/env bash
# Verdaccio npm registry setup for mirroret.
# Source this file; do not execute it directly.
# Requires logging.sh, common.sh, backup.sh, systemd.sh.
#
# MIRRORET_NPM_PACKAGES_FILE path to a text file listing packages to sync
# (one per line, # for comments). Uses built-in
# default list when unset.
# MIRRORET_NPM_BIND_ADDR address Verdaccio listens on (default 0.0.0.0).
#                    A bare port makes Verdaccio bind "localhost", which
#                    resolves to [::1] on a dual-stack host, so every
#                    client gets connection refused.
# MIRRORET_NPM_ALLOW_ANON_PUBLISH=1 allow unauthenticated `npm publish` into
# Verdaccio. Only needed if humans publish
# in-house packages here. Pre-seeding does NOT
# need it any more: the sync script warms
# Verdaccio's cache by installing through it
# rather than publishing into it, which is why
# the old runs logged ENEEDAUTH on every
# package.
# MIRRORET_APPROVAL_ENABLED=1 download tarballs to staging/npm/ instead of
# publishing directly; admin promotes via approval.sh.
#
# NOTE: Verdaccio must be running and able to reach its npmjs uplink before
# the sync script can warm the cache; the script checks and says so. Once
# warmed, clients install from this server with no internet access.
# See docs/OPERATIONS.md for the full npm mirroring workflow.

MIRRORET_NPM_USER="${MIRRORET_NPM_USER:-mirroret-npm}"
MIRRORET_NPM_PACKAGES_FILE="${MIRRORET_NPM_PACKAGES_FILE:-}"
MIRRORET_NPM_ALLOW_ANON_PUBLISH="${MIRRORET_NPM_ALLOW_ANON_PUBLISH:-0}"
MIRRORET_NPM_BIND_ADDR="${MIRRORET_NPM_BIND_ADDR:-0.0.0.0}"
# MIRRORET_NPM_ALLOW_SELF_REGISTER=1 lets anyone reach the registry run
# `npm adduser` and then publish. Off by default: accounts are created by the
# operator (htpasswd) only.
MIRRORET_NPM_ALLOW_SELF_REGISTER="${MIRRORET_NPM_ALLOW_SELF_REGISTER:-0}"

# setup_npm_registry <backup_id> - install Verdaccio and create systemd unit.
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
        info "npm not found - attempting to install nodejs and npm..."
        if [[ "${DISTRO_TYPE}" == "rhel" ]]; then
            # RHEL 8 requires the AppStream module to be enabled first.
            dnf module enable nodejs -y 2>/dev/null || true
        fi
        # shellcheck disable=SC2086 # PKG_MGR_INSTALL intentionally word-split
        xrun ${PKG_MGR_INSTALL} nodejs npm \
            || die "npm installation failed. Install nodejs and npm manually, then re-run install.sh."
    fi

    # Detect Node major version and pick a Verdaccio release that supports it.
    #   Node < 18   -> verdaccio@^5   (last line that runs on Node 12-17)
    #   Node 18-19  -> verdaccio@~6.5 (6.6+ dropped Node 18)
    #   Node 20-21  -> verdaccio@~6.8 (6.9+ requires Node 22)
    #   Node >= 22  -> verdaccio      (latest)
    # A bare "verdaccio" on an older Node installs a release whose engines
    # field the host cannot satisfy and the unit crash-loops on start.
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
    elif [[ -n "${node_major}" ]] && [[ "${node_major}" =~ ^[0-9]+$ ]]; then
        if [[ "${node_major}" -lt 20 ]]; then
            verdaccio_pkg="verdaccio@~6.5"
        elif [[ "${node_major}" -lt 22 ]]; then
            verdaccio_pkg="verdaccio@~6.8"
        fi
        info "Node ${node_major} detected. Installing ${verdaccio_pkg}."
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

    # Approval mode must not proxy npmjs. With 'proxy: npmjs' Verdaccio
    # transparently fetches any package a client asks for, so the approved set
    # is bypassed entirely and the whole workflow is decorative. Dropping the
    # proxy makes the registry serve only what was explicitly published.
    # Cost: a package that was never approved returns 404 instead of being
    # fetched on demand. That is the point of approval mode.
    local proxy_line="    proxy: npmjs"
    local uplinks_block="uplinks:
  npmjs:
    url: https://registry.npmjs.org/
    timeout: 30s
    maxage: 10m
"
    if [[ "${MIRRORET_APPROVAL_ENABLED:-0}" == "1" ]]; then
        proxy_line=""
        uplinks_block="# uplinks intentionally omitted: MIRRORET_APPROVAL_ENABLED=1 means clients
# must only ever receive packages that an operator approved. An uplink here
# would let them pull straight from npmjs and silently defeat that.
uplinks: {}
"
        info "npm: approval mode ON - Verdaccio will NOT proxy npmjs."
        info "     Only packages promoted with 'mirroretctl approve npm' are installable."
    fi

    # Self-registration: -1 disables `npm adduser` entirely. With the default
    # 1000 anyone on the LAN could create an account and publish (the publish
    # ACL is \$authenticated, which self-registered users satisfy).
    local max_users="-1"
    if [[ "${MIRRORET_NPM_ALLOW_SELF_REGISTER:-0}" == "1" ]]; then
        max_users="1000"
        warn_insecure "npm: MIRRORET_NPM_ALLOW_SELF_REGISTER=1 - anyone reaching the registry can create an account and publish."
    fi

    # Verdaccio 6 ignores HTTP_PROXY/HTTPS_PROXY in its environment; the
    # uplink proxy has to be configured in config.yaml. Behind a corporate
    # proxy the Environment= lines in the unit alone leave every uplink fetch
    # timing out.
    local _hp="${HTTP_PROXY:-${http_proxy:-${MIRRORET_PROXY:-}}}"
    local _hsp="${HTTPS_PROXY:-${https_proxy:-${MIRRORET_PROXY:-}}}"
    local _np="${NO_PROXY:-${no_proxy:-${MIRRORET_NO_PROXY:-}}}"
    local proxy_block=""
    if [[ -n "${_hp}${_hsp}${_np}" ]]; then
        proxy_block="# Uplink proxy. Verdaccio 6 does not read HTTP_PROXY from the environment."$'\n'
        [[ -n "${_hp}" ]]  && proxy_block+="http_proxy: ${_hp}"$'\n'
        [[ -n "${_hsp}" ]] && proxy_block+="https_proxy: ${_hsp}"$'\n'
        [[ -n "${_np}" ]]  && proxy_block+="no_proxy: ${_np}"$'\n'
        info "Verdaccio uplink proxy configured in config.yaml."
    fi

    cat > /etc/verdaccio/config.yaml <<VERD_EOF
# Verdaccio configuration - generated by mirroret.
# listen must name a host. Without it Verdaccio binds localhost only, which
# resolves to [::1] on a dual-stack host and refuses every client.
listen: ${MIRRORET_NPM_BIND_ADDR:-0.0.0.0}:${npm_port}
storage: ${base_dir}/npm/approved
${plugins_dir:+plugins: ${plugins_dir}}

auth:
  htpasswd:
    file: /etc/verdaccio/htpasswd
    max_users: ${max_users}

${proxy_block}
${uplinks_block}
packages:
  '@*/*':
    access: \$all
    publish: ${publish_who}
    unpublish: ${publish_who}
${proxy_line}
  '**':
    access: \$all
    publish: ${publish_who}
    unpublish: ${publish_who}
${proxy_line}

server:
  keepAliveTimeout: 60

middlewares:
  audit:
    enabled: true

# Verdaccio 6 syntax. The array form under 'logs:' is deprecated (VERWAR002).
log: { type: stdout, format: pretty, level: warn }
VERD_EOF

    chown -R "${MIRRORET_NPM_USER}:" /etc/verdaccio
    success "Verdaccio config written."
}

# _resolve_verdaccio_bin - print an ABSOLUTE, EXISTING, EXECUTABLE path to
# the verdaccio binary, or print nothing.
#
# Search order:
# 1. PATH (covers the common case)
# 2. `npm bin -g` (npm < 9)
# 3. `npm prefix -g`/bin (npm >= 9 dropped `npm bin -g`)
# 4. `npm root -g`/verdaccio/bin/verdaccio (the package's own bin)
# 5. Well-known prefixes as a last resort
#
# Every candidate is checked with -x so we never emit a path that systemd
# will fail to exec.
_resolve_verdaccio_bin() {
    local c
    local -a candidates=()

    c="$(command -v verdaccio 2>/dev/null || true)"
    [[ -n "$c" ]] && candidates+=("$c")

    if check_command npm; then
        c="$(npm bin -g 2>/dev/null || true)"
        [[ -n "$c" ]] && candidates+=("${c}/verdaccio")

        c="$(npm prefix -g 2>/dev/null || true)"
        [[ -n "$c" ]] && candidates+=("${c}/bin/verdaccio")

        c="$(npm root -g 2>/dev/null || true)"
        [[ -n "$c" ]] && candidates+=("${c}/verdaccio/bin/verdaccio")
    fi

    candidates+=(
        /usr/local/bin/verdaccio
        /usr/bin/verdaccio
        /usr/lib/node_modules/verdaccio/bin/verdaccio
        /usr/local/lib/node_modules/verdaccio/bin/verdaccio
        /opt/node/bin/verdaccio
    )

    for c in "${candidates[@]}"; do
        [[ -n "$c" ]] || continue
        if [[ -x "$c" ]]; then
            printf '%s' "$c"
            return 0
        fi
    done
    return 1
}

_write_verdaccio_unit() {
    local backup_id="$1"
    local base_dir="$2"
    local npm_port="$3"

    # Resolve the real verdaccio binary. `command -v` alone is not enough:
    # npm -g installs into a prefix that is often absent from root's PATH
    # (on RHEL with the nodejs module it lands in /usr/local/bin), so the
    # old `|| echo /usr/bin/verdaccio` fallback wrote a path that does not
    # exist and the unit failed with status=203/EXEC on every restart.
    # `|| true` is required: _resolve_verdaccio_bin returns 1 when it finds
    # nothing, and under `set -e` with an ERR trap that aborts the script
    # from inside the assignment, before the empty-check can report anything
    # useful. See the same note in lib/pip.sh.
    local verdaccio_bin=""
    verdaccio_bin="$(_resolve_verdaccio_bin || true)"
    if [[ -z "${verdaccio_bin}" ]]; then
        if [[ "${DRY_RUN}" == "1" ]]; then
            info "[DRY-RUN] verdaccio is not installed yet; a real run would"
            info "          install it and use its path in the systemd unit."
            return 0
        fi
        die "Cannot locate the verdaccio binary. Install it with: npm install -g verdaccio"
    fi
    info "Verdaccio binary: ${verdaccio_bin}"

    # Verdaccio needs a writable HOME. The mirroret-npm user is created
    # with --no-create-home, and ProtectSystem=strict makes most of the
    # filesystem read-only - without an explicit HOME inside
    # ReadWritePaths, Verdaccio crash-loops on startup (systemd shows it
    # stuck in "activating").
    local npm_home="${base_dir}/npm"

    # Propagate proxy into the unit - systemd does NOT read /etc/environment,
    # so without this the npmjs uplink cannot reach the internet behind a
    # corporate proxy and every client `npm install` fails.
    local proxy_env=""
    local _hp="${HTTP_PROXY:-${http_proxy:-}}"
    local _hsp="${HTTPS_PROXY:-${https_proxy:-}}"
    local _np="${NO_PROXY:-${no_proxy:-}}"
    [[ -n "${_hp}" ]] && proxy_env+="
Environment=\"HTTP_PROXY=${_hp}\"
Environment=\"http_proxy=${_hp}\""
    [[ -n "${_hsp}" ]] && proxy_env+="
Environment=\"HTTPS_PROXY=${_hsp}\"
Environment=\"https_proxy=${_hsp}\""
    [[ -n "${_np}" ]] && proxy_env+="
Environment=\"NO_PROXY=${_np}\"
Environment=\"no_proxy=${_np}\""
    # Corporate CA for Node's TLS stack (Node ignores the OS store).
    if [[ -n "${MIRRORET_CA_BUNDLE:-}" ]] && [[ -f "${MIRRORET_CA_BUNDLE}" ]]; then
        proxy_env+="
Environment=\"NODE_EXTRA_CA_CERTS=${MIRRORET_CA_BUNDLE}\""
        info "Verdaccio will trust CA bundle: ${MIRRORET_CA_BUNDLE}"
    fi

    # An explicit host is required. "--listen 4873" binds localhost only,
    # which on a dual-stack host means [::1] and nothing else: the registry
    # answers on the server itself and refuses every client.
    local npm_bind="${MIRRORET_NPM_BIND_ADDR:-0.0.0.0}"

    local unit_content="[Unit]
Description=Verdaccio npm Registry (mirroret)
After=network.target

[Service]
Type=simple
User=${MIRRORET_NPM_USER}
Environment=\"HOME=${npm_home}\"${proxy_env}
ExecStart=${verdaccio_bin} --config /etc/verdaccio/config.yaml --listen ${npm_bind}:${npm_port}
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
    local min_free_gb="${MIRRORET_SYNC_MIN_FREE_GB:-10}"

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
            packages_block+=" \"${line}\""$'\n'
        done < "${packages_file}"
        info "npm package list loaded from: ${packages_file}"
    else
        packages_block=' "express"
    "lodash"
    "axios"
    "react"
    "webpack"
    "typescript"
    "eslint"'
    fi

    # How packages get into the registry.
    #
    # This used to run `npm pack` against npmjs and then `npm publish` into
    # Verdaccio. That fails with ENEEDAUTH on every package unless anonymous
    # publish is enabled, which on a 0.0.0.0 listener means anyone on the
    # network can publish into your registry.
    #
    # Warming the cache instead is both safer and more useful: asking
    # Verdaccio itself for the package makes it fetch from its npmjs uplink
    # and store the tarball in its own storage, so the package is served
    # offline afterwards - and `npm install` resolves the FULL dependency
    # tree, which `npm pack` never did. Pre-seeding express used to leave
    # its 50-odd dependencies missing.
    local seed_block
    if [[ "${approval}" == "1" ]]; then
        # Approval mode has no uplink (see _write_verdaccio_config), so
        # warming is impossible by design: tarballs are fetched from npmjs
        # into staging and an operator promotes them.
        seed_block='    if npm pack --loglevel=error --fetch-timeout=60000 --fetch-retries=3 \
            "${package}" >/dev/null; then
        echo " STAGED: ${package}"
    else
        echo " DOWNLOAD FAILED: ${package}"
        failed=$(( failed + 1 ))
    fi'
    else
        seed_block='    # Resolve and fetch the whole tree THROUGH Verdaccio so every
    # tarball lands in its storage and is later served offline.
    # --cache is essential: npm would otherwise satisfy most of the tree
    # from its OWN cache in root'"'"'s home and never ask Verdaccio for those
    # tarballs, leaving them missing from the mirror. Measured on express:
    # 21 of 66 tarballs reached Verdaccio with npm'"'"'s cache in play, 66 of 66
    # without.
    if npm install --prefix "${WORK_DIR}/warm" \
            --cache "${WORK_DIR}/npm-cache" \
            --registry "${VERDACCIO_URL}" \
            --no-audit --no-fund --loglevel=error \
            --fetch-timeout=60000 --fetch-retries=3 \
            --omit=dev --ignore-scripts \
            "${package}" >/dev/null 2>&1; then
        _n=$(find "${WORK_DIR}/warm/node_modules" -maxdepth 2 -name package.json 2>/dev/null | wc -l)
        echo " CACHED: ${package} (+ deps: ${_n})"
    else
        echo " CACHE FAILED: ${package}"
        echo "   Verdaccio could not reach its npmjs uplink, or the package"
        echo "   name is wrong. Check: journalctl -u verdaccio -n 50"
        failed=$(( failed + 1 ))
    fi'
    fi

    cat > "${sync_script}" <<SYNC_SCRIPT
#!/usr/bin/env bash
set -Eeuo pipefail

${MIRRORET_MANAGED_MARKER}
# To customize the package list, set MIRRORET_NPM_PACKAGES_FILE=/path
# before running install.sh - do NOT edit this file directly.

# npm package sync script - generated by mirroret.
#
# Pre-seeds the local Verdaccio registry by installing each package THROUGH
# it, which makes Verdaccio cache the tarball (and every dependency's
# tarball) in its own storage. After a successful run those packages install
# from this server with no internet access at all.

VERDACCIO_URL="http://localhost:${npm_port}/"
# When approval mode is on, download to staging/npm (approval.sh promotes to approved/npm).
# When off, download to npm/staging as a temp area before publishing.
STAGING_DIR="${base_dir}/staging/npm"
WORK_DIR_DEFAULT="${base_dir}/npm/staging"
APPROVED_DIR="${base_dir}/npm/approved"
LOG_DIR="${base_dir}/logs"
LOG_FILE="\${LOG_DIR}/sync-npm-\$(date +%Y%m%d-%H%M%S).log"
APPROVAL_MODE="${approval}"

MIN_FREE_GB="${min_free_gb}"
LOCK_FILE="/var/lock/mirroret-sync-npm.lock"
mkdir -p "\$LOG_DIR" "\$STAGING_DIR" "\$WORK_DIR_DEFAULT" "\$APPROVED_DIR"
# Single-instance lock - stop cron colliding with a manual run.
# Lock BEFORE redirecting stdout: redirecting first sends the
# "already running" message to the log only, so a manual run started during
# the nightly cron sync exits with no output at all.
exec 9>"\$LOCK_FILE" || { echo "ERROR: cannot open lock \$LOCK_FILE"; exit 2; }
if ! flock -n 9; then
    echo "ERROR: another npm sync is already running (lock: \$LOCK_FILE)."
    echo "       Nothing was started. Watch the running one with:"
    echo "         mirroretctl logs tail"
    exit 3
fi
exec > >(tee -a "\$LOG_FILE") 2>&1

$(mirroret_script_preamble)

echo "Starting npm package sync: \$(date)"

if ! command -v npm >/dev/null 2>&1; then
    echo "ERROR: npm not found on this host. Install nodejs + npm and re-run."
    exit 2
fi

_free_gb() { df -BG --output=avail "\$APPROVED_DIR" 2>/dev/null | tail -1 | tr -dc '0-9'; }
_check_disk() {
    local free; free="\$(_free_gb)"
    [[ -z "\$free" ]] && return 0
    if [[ "\$free" -lt "\$MIN_FREE_GB" ]]; then
        echo "ABORT: only \${free} GB free (floor: \${MIN_FREE_GB} GB)."
        return 1
    fi
    return 0
}
_check_disk || exit 4

# npm pack/publish are extremely chatty (one line per file in the tarball -
# lodash alone prints 1000+ lines). Quiet them down so the log stays useful.
export npm_config_loglevel=error
# Loopback must never go through the corporate proxy: the proxy cannot reach
# this host's localhost and every request to Verdaccio would 502.
export npm_config_noproxy="localhost,127.0.0.1\${no_proxy:+,\${no_proxy}}"

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

# Start from a clean work dir: a tarball or node_modules tree left by an
# earlier run would make the per-package result reporting lie.
if [[ "\${APPROVAL_MODE}" != "1" ]]; then
    rm -rf "\${WORK_DIR}/warm" "\${WORK_DIR}/npm-cache"
    mkdir -p "\${WORK_DIR}/warm" "\${WORK_DIR}/npm-cache"
    # npm refuses to install into a prefix with no package.json.
    printf '{"name":"mirroret-warm","version":"1.0.0","private":true}\\n' \\
        > "\${WORK_DIR}/warm/package.json"

    # The registry must be up before we can warm it through.
    if ! curl -fsS --noproxy '*' -o /dev/null --max-time 10 "\${VERDACCIO_URL}"; then
        echo "ERROR: Verdaccio is not answering on \${VERDACCIO_URL}."
        echo "       Start it first: sudo systemctl restart verdaccio"
        echo "       Then: sudo journalctl -u verdaccio -n 50 --no-pager"
        exit 5
    fi
else
    find "\${WORK_DIR}" -maxdepth 1 -name '*.tgz' -delete 2>/dev/null || true
fi

for package in "\${PACKAGES[@]}"; do
    if ! _check_disk; then
        echo "Stopping before \${package} - disk floor reached."
        failed=\$(( failed + 1 ))
        break
    fi
    echo "Processing \${package}..."
    pushd "\${WORK_DIR}" >/dev/null
${seed_block}
    popd >/dev/null
done

if [[ "\${APPROVAL_MODE}" != "1" ]]; then
    echo "Registry storage now holds: \$(find "\${APPROVED_DIR}" -name '*.tgz' 2>/dev/null | wc -l) tarball(s)"
    rm -rf "\${WORK_DIR}/warm" "\${WORK_DIR}/npm-cache"
fi

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

# generate_npm_client_config <output_file> - write .npmrc for clients.
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

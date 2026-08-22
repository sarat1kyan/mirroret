#!/usr/bin/env bash
# pypiserver setup for mirroret.
# Source this file; do not execute it directly.
# Requires logging.sh, common.sh, backup.sh, systemd.sh.

MIRRORET_PYPI_USER="${MIRRORET_PYPI_USER:-mirroret-pip}"

# setup_pip_repository <backup_id> - install pypiserver and create systemd unit.
setup_pip_repository() {
    local backup_id="$1"
    local base_dir="${MIRRORET_BASE_DIR}"
    local pip_port="${MIRRORET_PIP_PORT:-8081}"

    section "Setting Up pip Repository (pypiserver)"

    _ensure_pypi_user
    _install_pypiserver
    _write_pypiserver_unit "$backup_id" "$base_dir" "$pip_port"
    systemd_daemon_reload
    enable_and_start pypiserver
    _write_pip_sync_script "$base_dir"

    success "pypiserver configured on port ${pip_port}."
}

_ensure_pypi_user() {
    if ! id "${MIRRORET_PYPI_USER}" &>/dev/null; then
        if [[ "${DRY_RUN}" == "1" ]]; then
            info "[DRY-RUN] would create system user: ${MIRRORET_PYPI_USER}"
            return 0
        fi
        xrun useradd --system --no-create-home --shell /usr/sbin/nologin "${MIRRORET_PYPI_USER}"
        info "Created system user: ${MIRRORET_PYPI_USER}"
    else
        debug "System user already exists: ${MIRRORET_PYPI_USER}"
    fi
}

_install_pypiserver() {
    if check_command pypi-server; then
        info "pypiserver already installed."
        return 0
    fi

    # Prefer the distro package; fall back to pip in a venv.
    if [[ "${DISTRO_TYPE}" == "debian" ]]; then
        if apt-cache show python3-pypiserver &>/dev/null 2>&1; then
            xrun apt-get install -y --no-install-recommends python3-pypiserver
            return 0
        fi
    fi

    # Fall back: install into a dedicated virtualenv to avoid --break-system-packages.
    local venv_dir="/opt/mirroret-pypiserver"
    if [[ "${DRY_RUN}" == "1" ]]; then
        info "[DRY-RUN] would install pypiserver into venv: ${venv_dir}"
        return 0
    fi
    # Ensure python3 and venv support are available.
    if ! check_command python3; then
        info "python3 not found - attempting to install..."
        xrun ${PKG_MGR_INSTALL} python3 python3-pip \
            || die "python3 installation failed. Install python3 manually and re-run."
    fi
    # On Debian/Ubuntu, python3 -m venv needs the python3-venv package.
    if [[ "${DISTRO_TYPE}" == "debian" ]] && ! python3 -m venv --help &>/dev/null 2>&1; then
        info "python3-venv not available - installing..."
        xrun ${PKG_MGR_INSTALL} python3-venv python3-pip || true
    fi
    xrun python3 -m venv "$venv_dir"
    xrun "${venv_dir}/bin/pip" install --quiet pypiserver passlib
    # Create a wrapper in PATH.
    ln -sf "${venv_dir}/bin/pypi-server" /usr/local/bin/pypi-server
    info "pypiserver installed in virtualenv: ${venv_dir}"
}

# _resolve_pypiserver_bin - print an ABSOLUTE, EXISTING, EXECUTABLE path to
# pypi-server, or print nothing. The venv path is checked first because that
# is where _install_pypiserver puts it.
_resolve_pypiserver_bin() {
    local c
    local -a candidates=(
        "${MIRRORET_PYPI_VENV:-/opt/mirroret-pypiserver}/bin/pypi-server"
    )

    c="$(command -v pypi-server 2>/dev/null || true)"
    [[ -n "$c" ]] && candidates+=("$c")

    candidates+=(
        /usr/local/bin/pypi-server
        /usr/bin/pypi-server
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

_write_pypiserver_unit() {
    local backup_id="$1"
    local base_dir="$2"
    local pip_port="$3"

    # Same failure mode as verdaccio: a bare `command -v` plus a hardcoded
    # fallback can write a nonexistent path into the unit, which then fails
    # with status=203/EXEC on every restart. Resolve and verify.
    # `|| true` is required, not cosmetic: _resolve_pypiserver_bin returns 1
    # when it finds nothing, and under `set -e` with an ERR trap a failing
    # command substitution in an assignment aborts the whole script before
    # the empty-check below can produce its clear message. That made
    # `install.sh --dry-run` die on any host without pypiserver already
    # installed - i.e. every fresh server, which is exactly where a dry run
    # is most useful.
    local pypi_bin=""
    pypi_bin="$(_resolve_pypiserver_bin || true)"
    if [[ -z "${pypi_bin}" ]]; then
        if [[ "${DRY_RUN}" == "1" ]]; then
            # The install step was skipped by DRY_RUN, so of course the
            # binary is absent. Report the plan instead of failing.
            info "[DRY-RUN] pypiserver is not installed yet; a real run would"
            info "          install it and use its path in the systemd unit."
            return 0
        fi
        die "Cannot locate the pypi-server binary. Expected it in ${MIRRORET_PYPI_VENV:-/opt/mirroret-pypiserver}/bin/."
    fi
    info "pypiserver binary: ${pypi_bin}"

    # Serve approved/ (standard) or approved/ under the approval workflow root.
    # Both point to the same semantics; approval.sh promotes staging -> approved.
    local serve_dir="${base_dir}/pip/approved"
    if [[ "${MIRRORET_APPROVAL_ENABLED:-0}" == "1" ]]; then
        serve_dir="${base_dir}/approved/pip"
        mkdir -p "${base_dir}/staging/pip" "${base_dir}/approved/pip"
    fi
    # Always create staging/approved roots - ReadWritePaths requires them to exist
    # even when approval mode is off (ProtectSystem=strict mount namespace check).
    mkdir -p "${base_dir}/staging" "${base_dir}/approved"

    local unit_content="[Unit]
Description=PyPI Server (mirroret)
After=network.target

[Service]
Type=simple
User=${MIRRORET_PYPI_USER}
WorkingDirectory=${base_dir}/pip
ExecStart=${pypi_bin} run -p ${pip_port} --overwrite ${serve_dir}
Restart=on-failure
RestartSec=5s
NoNewPrivileges=true
ProtectSystem=strict
ReadWritePaths=${base_dir}/pip ${base_dir}/staging ${base_dir}/approved
PrivateTmp=true

[Install]
WantedBy=multi-user.target"

    write_systemd_unit "$backup_id" "pypiserver.service" "$unit_content"

    # Set correct ownership.
    if [[ "${DRY_RUN}" != "1" ]]; then
        xrun chown -R "${MIRRORET_PYPI_USER}:" "${base_dir}/pip"
    fi
}

_write_pip_sync_script() {
    local base_dir="$1"
    local sync_script="${base_dir}/scripts/sync-pip-packages.sh"
    local approval="${MIRRORET_APPROVAL_ENABLED:-0}"
    local min_free_gb="${MIRRORET_SYNC_MIN_FREE_GB:-10}"

    if [[ "${DRY_RUN}" == "1" ]]; then
        info "[DRY-RUN] would write pip sync script: ${sync_script}"
        return 0
    fi

    mkdir -p "${base_dir}/scripts"

    # Upgrade safety: don't clobber operator edits.
    if ! preserve_user_customization "${sync_script}"; then
        return 0
    fi

    # Destination depends on approval mode.
    local dest_dir
    if [[ "${approval}" == "1" ]]; then
        dest_dir="${base_dir}/staging/pip"
    else
        dest_dir="${base_dir}/pip/approved"
    fi

    # Wheel matrix: the interpreter/platform combinations client hosts
    # actually use. manylinux2014 covers glibc 2.17+, i.e. RHEL 8/9 and
    # every current Ubuntu/Debian.
    local pip_platforms="${MIRRORET_PIP_PLATFORMS:-3.9:manylinux2014_x86_64 3.11:manylinux2014_x86_64 3.12:manylinux2014_x86_64}"

    # Read package list from MIRRORET_PIP_PACKAGES_FILE when set; otherwise
    # fall back to a small, well-known default list.
    local packages_block
    if [[ -n "${MIRRORET_PIP_PACKAGES_FILE:-}" && -f "${MIRRORET_PIP_PACKAGES_FILE}" ]]; then
        packages_block=""
        while IFS= read -r line; do
            line="${line%%#*}"
            line="${line// /}"
            [[ -z "${line}" ]] && continue
            packages_block+=" \"${line}\""$'\n'
        done < "${MIRRORET_PIP_PACKAGES_FILE}"
        info "pip package list loaded from: ${MIRRORET_PIP_PACKAGES_FILE}"
    else
        packages_block=' "requests"
    "flask"
    "django"
    "numpy"
    "pandas"
    "pytest"
    "black"
    "pylint"
    "ansible"
    "boto3"
    "setuptools"
    "wheel"'
    fi

    cat > "${sync_script}" <<PIP_SYNC
#!/usr/bin/env bash
set -Eeuo pipefail

${MIRRORET_MANAGED_MARKER}
# To customize the package list, set MIRRORET_PIP_PACKAGES_FILE=/path
# before running install.sh - do NOT edit this file, or subsequent
# installs will leave your edits in place but skip mirroret updates.

# pip package sync script - generated by mirroret.
# Downloads packages from PyPI.

DEST_DIR="${dest_dir}"
LOG_DIR="${base_dir}/logs"
LOG_FILE="\${LOG_DIR}/sync-pip-\$(date +%Y%m%d-%H%M%S).log"
APPROVAL_MODE="${approval}"
MIN_FREE_GB="${min_free_gb}"
LOCK_FILE="/var/lock/mirroret-sync-pip.lock"
mkdir -p "\$LOG_DIR" "\$DEST_DIR"
# Single-instance lock - stop cron colliding with a manual run.
# Lock BEFORE redirecting stdout: redirecting first sends the
# "already running" message to the log only, so a manual run started during
# the nightly cron sync exits with no output at all.
exec 9>"\$LOCK_FILE" || { echo "ERROR: cannot open lock \$LOCK_FILE"; exit 2; }
if ! flock -n 9; then
    echo "ERROR: another pip sync is already running (lock: \$LOCK_FILE)."
    echo "       Nothing was started. Watch the running one with:"
    echo "         mirroretctl logs tail"
    exit 3
fi
exec > >(tee -a "\$LOG_FILE") 2>&1

$(mirroret_script_preamble)

echo "Starting pip package sync: \$(date)"

if ! command -v pip3 >/dev/null 2>&1; then
    echo "ERROR: pip3 not found. Install python3-pip and re-run."
    exit 2
fi

_free_gb() { df -BG --output=avail "\$DEST_DIR" 2>/dev/null | tail -1 | tr -dc '0-9'; }
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

PACKAGES=(
${packages_block}
)

# "pythonversion:platformtag" pairs to fetch wheels for, on top of whatever
# this host's own interpreter matches. Override with MIRRORET_PIP_PLATFORMS
# in /etc/mirroret/mirroret.conf (space separated, same syntax); set it to
# "-" to fetch only for this host.
PLATFORM_MATRIX=(${pip_platforms})
if [[ "\${MIRRORET_PIP_PLATFORMS:-}" == "-" ]]; then
    PLATFORM_MATRIX=()
elif [[ -n "\${MIRRORET_PIP_PLATFORMS:-}" ]]; then
    read -r -a PLATFORM_MATRIX <<< "\${MIRRORET_PIP_PLATFORMS}"
fi

failed=0
for package in "\${PACKAGES[@]}"; do
    if ! _check_disk; then
        echo "Stopping before \${package} - disk floor reached."
        failed=\$(( failed + 1 ))
        break
    fi
    echo "Downloading \${package}..."
    pkg_ok=1
    # Plain download: resolves dependencies and picks wheels/sdists for the
    # interpreter running here.
    if ! pip3 download --no-cache-dir --timeout 60 --retries 3 \\
            "\${package}" -d "\${DEST_DIR}"; then
        pkg_ok=0
    fi
    # Cross-platform wheels. A mirror serving a fleet needs the wheels those
    # clients will ask for, not only the ones matching the mirror server's
    # own Python and glibc. Without this a RHEL 9 mirror server hands
    # Ubuntu 22.04 clients nothing usable for anything with C extensions.
    for _spec in \${PLATFORM_MATRIX[@]+"\${PLATFORM_MATRIX[@]}"}; do
        _py="\${_spec%%:*}"
        _plat="\${_spec#*:}"
        # --only-binary is mandatory with --platform/--python-version.
        pip3 download --no-cache-dir --timeout 60 --retries 3 \\
            --only-binary=:all: --python-version "\${_py}" \\
            --platform "\${_plat}" \\
            "\${package}" -d "\${DEST_DIR}" >/dev/null 2>&1 \\
            || echo "   note: no \${_plat} / py\${_py} wheel for \${package} (source-only?)"
    done
    if [[ "\${pkg_ok}" == "1" ]]; then
        echo " OK: \${package}"
    else
        echo " FAILED: \${package}"
        failed=\$(( failed + 1 ))
    fi
done

echo "pip sync completed: \$(date) (\${failed} failures)"
if [[ "\${APPROVAL_MODE}" == "1" ]]; then
    echo "Packages in staging: \${DEST_DIR}"
    echo "Approve with: install.sh --approve-all-pip"
fi
if [[ "\${failed}" -gt 0 ]]; then
    exit 1
fi
PIP_SYNC

    chmod +x "${sync_script}"
    success "pip sync script written: ${sync_script}"
}

# generate_pip_client_config <output_file> - write pip.conf for clients.
generate_pip_client_config() {
    local output_file="$1"
    local server_ip="${MIRRORET_SERVER_IP}"
    local pip_port="${MIRRORET_PIP_PORT:-8081}"
    local insecure="${MIRRORET_PIP_INSECURE:-0}"

    if [[ "${DRY_RUN}" == "1" ]]; then
        info "[DRY-RUN] would write pip client config to: ${output_file}"
        return 0
    fi

    if [[ "${insecure}" == "1" ]]; then
        warn_insecure "pip client config: trusted-host set (certificate checking DISABLED)."
        warn_insecure "This is suitable for isolated lab environments ONLY."

        cat > "$output_file" <<PIP_EOF
[global]
index-url = http://${server_ip}:${pip_port}/simple/
trusted-host = ${server_ip}
PIP_EOF

    else
        # pypiserver serves plain HTTP. pip REFUSES to use an http:// index
        # unless the host is in trusted-host: it prints
        #   "The repository located at <ip> is not a trusted or secure host
        #    and is being ignored"
        # and then fails to find any package. So trusted-host is not an
        # "insecure mode" nicety here, it is required for the config to work
        # at all over HTTP. Omitting it produced a pip.conf that looked fine
        # and broke every client.
        #
        # trusted-host on a plain-HTTP index does not disable anything that
        # HTTP was protecting: there is no certificate to check. If you need
        # real transport security, serve the index over TLS (see
        # docs/SECURITY.md) and drop the trusted-host line.
        cat > "$output_file" <<PIP_EOF
[global]
index-url = http://${server_ip}:${pip_port}/simple/
# Required: pip ignores a plain-HTTP index unless its host is trusted.
trusted-host = ${server_ip}
PIP_EOF
        info "pip client config written (http + trusted-host, which pip requires for HTTP)."
        info "For TLS, front pypiserver with an nginx TLS proxy - see docs/SECURITY.md."
    fi

    success "pip client config written: ${output_file}"
}

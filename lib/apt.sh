#!/usr/bin/env bash
# APT repository configuration for mirroret.
# Source this file; do not execute it directly.
# Requires logging.sh, common.sh, distro.sh, backup.sh.
#
# MIRRORET_APT_MIRROR_TOOL=auto|apt-mirror|debmirror
#   auto        — try apt-mirror, then pip apt-mirror2, then debmirror
#   apt-mirror  — use apt-mirror (or apt-mirror2 via pip if not installed)
#   debmirror   — use debmirror
#
# After configure_apt_mirror() succeeds, MIRRORET_APT_DATA_PATH is exported
# pointing to the directory nginx should serve as /ubuntu.

MIRRORET_APT_MIRROR_TOOL="${MIRRORET_APT_MIRROR_TOOL:-auto}"
MIRRORET_APT_DATA_PATH="${MIRRORET_APT_DATA_PATH:-}"

# configure_apt_mirror <backup_id> — write APT mirror configuration.
configure_apt_mirror() {
    local backup_id="$1"
    local base_dir="${MIRRORET_BASE_DIR}"
    local codename
    codename="${MIRRORET_UBUNTU_CODENAME:-$(ubuntu_codename)}"
    local tool="${MIRRORET_APT_MIRROR_TOOL:-auto}"

    section "Configuring APT mirror (tool: ${tool})"
    info "Ubuntu codename: ${codename}"

    # Resolve which tool to actually use.
    local resolved_tool
    resolved_tool="$(_apt_resolve_tool "${tool}")"

    info "Using APT mirror tool: ${resolved_tool}"

    case "${resolved_tool}" in
        apt-mirror)  _configure_apt_mirror_classic "${backup_id}" "${base_dir}" "${codename}" ;;
        apt-mirror2) _configure_apt_mirror2        "${backup_id}" "${base_dir}" "${codename}" ;;
        debmirror)   _configure_debmirror          "${backup_id}" "${base_dir}" "${codename}" ;;
        *)           die "Unknown APT mirror tool: ${resolved_tool}" ;;
    esac

    export MIRRORET_APT_DATA_PATH
}

# _apt_resolve_tool <requested> — print the tool name that will actually be used.
_apt_resolve_tool() {
    local requested="$1"
    case "${requested}" in
        apt-mirror)
            if check_command apt-mirror; then
                echo "apt-mirror"; return
            fi
            # apt-mirror2 is a drop-in replacement installable via pip.
            if check_command apt-mirror2 || pip3 show apt-mirror2 &>/dev/null 2>&1; then
                echo "apt-mirror2"; return
            fi
            warn "apt-mirror not found and apt-mirror2 not available. Falling back to debmirror."
            echo "debmirror"
            ;;
        debmirror)
            echo "debmirror"
            ;;
        auto)
            if check_command apt-mirror; then
                echo "apt-mirror"; return
            fi
            if check_command apt-mirror2 || pip3 show apt-mirror2 &>/dev/null 2>&1; then
                echo "apt-mirror2"; return
            fi
            if check_command debmirror; then
                echo "debmirror"; return
            fi
            warn "No APT mirror tool found. Will attempt to install apt-mirror."
            echo "apt-mirror"
            ;;
        *)
            die "Unknown MIRRORET_APT_MIRROR_TOOL value: '${requested}'. Use auto, apt-mirror, or debmirror."
            ;;
    esac
}

_configure_apt_mirror_classic() {
    local backup_id="$1" base_dir="$2" codename="$3"
    local mirror_base="${base_dir}/debian/mirror"

    backup_file "$backup_id" "/etc/apt/mirror.list"

    if [[ "${DRY_RUN}" == "1" ]]; then
        info "[DRY-RUN] would write /etc/apt/mirror.list (apt-mirror, codename=${codename})"
        MIRRORET_APT_DATA_PATH="${mirror_base}/mirror/archive.ubuntu.com/ubuntu"
        return 0
    fi

    xrun apt-get install -y --no-install-recommends apt-mirror 2>/dev/null || true

    cat > /etc/apt/mirror.list <<MIRROR_EOF
############# config ##################
set base_path    ${mirror_base}
set mirror_path  \$base_path/mirror
set skel_path    \$base_path/skel
set var_path     \$base_path/var
set cleanscript  \$var_path/clean.sh
set defaultarch  ${MIRRORET_APT_ARCH:-amd64}
set postmirror_script \$var_path/postmirror.sh
set run_postmirror 0
set nthreads     ${MIRRORET_APT_THREADS:-10}
set _tilde 0
############# end config ##############

# Ubuntu ${codename}
deb http://archive.ubuntu.com/ubuntu ${codename} main restricted universe multiverse
deb http://archive.ubuntu.com/ubuntu ${codename}-updates main restricted universe multiverse
deb http://archive.ubuntu.com/ubuntu ${codename}-security main restricted universe multiverse

clean http://archive.ubuntu.com/ubuntu
MIRROR_EOF

    MIRRORET_APT_DATA_PATH="${mirror_base}/mirror/archive.ubuntu.com/ubuntu"
    success "apt-mirror configured (${codename})."
}

_configure_apt_mirror2() {
    local backup_id="$1" base_dir="$2" codename="$3"
    local mirror_base="${base_dir}/debian/mirror"
    local config_file="/etc/apt/mirror.list"

    backup_file "$backup_id" "${config_file}"

    if [[ "${DRY_RUN}" == "1" ]]; then
        info "[DRY-RUN] would write ${config_file} (apt-mirror2, codename=${codename})"
        MIRRORET_APT_DATA_PATH="${mirror_base}/mirror/archive.ubuntu.com/ubuntu"
        return 0
    fi

    # Install apt-mirror2 via pip into a venv if not already present.
    if ! check_command apt-mirror2; then
        local venv="/opt/mirroret-apt-mirror2"
        xrun python3 -m venv "${venv}"
        xrun "${venv}/bin/pip" install --quiet apt-mirror2
        ln -sf "${venv}/bin/apt-mirror2" /usr/local/bin/apt-mirror2
        info "apt-mirror2 installed in virtualenv: ${venv}"
    fi

    # apt-mirror2 is config-compatible with apt-mirror.
    cat > "${config_file}" <<MIRROR_EOF
############# config ##################
set base_path    ${mirror_base}
set mirror_path  \$base_path/mirror
set skel_path    \$base_path/skel
set var_path     \$base_path/var
set defaultarch  ${MIRRORET_APT_ARCH:-amd64}
set nthreads     ${MIRRORET_APT_THREADS:-10}
set _tilde 0
############# end config ##############

# Ubuntu ${codename}
deb http://archive.ubuntu.com/ubuntu ${codename} main restricted universe multiverse
deb http://archive.ubuntu.com/ubuntu ${codename}-updates main restricted universe multiverse
deb http://archive.ubuntu.com/ubuntu ${codename}-security main restricted universe multiverse

clean http://archive.ubuntu.com/ubuntu
MIRROR_EOF

    MIRRORET_APT_DATA_PATH="${mirror_base}/mirror/archive.ubuntu.com/ubuntu"
    success "apt-mirror2 configured (${codename})."
}

_configure_debmirror() {
    local backup_id="$1" base_dir="$2" codename="$3"
    local mirror_dir="${base_dir}/debian/debmirror"
    local script_file="${base_dir}/scripts/sync-apt-debmirror.sh"

    if [[ "${DRY_RUN}" == "1" ]]; then
        info "[DRY-RUN] would configure debmirror for ${codename} → ${mirror_dir}"
        MIRRORET_APT_DATA_PATH="${mirror_dir}"
        return 0
    fi

    # Install debmirror if needed.
    if ! check_command debmirror; then
        if [[ "${DISTRO_TYPE}" == "debian" ]]; then
            xrun apt-get install -y --no-install-recommends debmirror
        else
            die "debmirror is not available on RHEL-based systems. Set MIRRORET_APT_MIRROR_TOOL=apt-mirror."
        fi
    fi

    mkdir -p "${mirror_dir}" "${base_dir}/scripts"

    # Write a debmirror sync script (debmirror does not use a config file).
    cat > "${script_file}" <<DEBMIRROR_SCRIPT
#!/usr/bin/env bash
set -Eeuo pipefail
# debmirror sync script — generated by mirroret.
# TODO: Replace KEYRING_FILE with the actual Ubuntu archive keyring path on
# your system (/usr/share/keyrings/ubuntu-archive-keyring.gpg is typical).
# If you receive GPG errors, see docs/TROUBLESHOOTING.md#debmirror-gpg.

CODENAME="${codename}"
ARCH="${MIRRORET_APT_ARCH:-amd64}"
MIRROR_DIR="${mirror_dir}"
LOG_DIR="${base_dir}/logs"
LOG_FILE="\${LOG_DIR}/sync-apt-debmirror-\$(date +%Y%m%d-%H%M%S).log"
mkdir -p "\$LOG_DIR" "\$MIRROR_DIR"

KEYRING_FILE="/usr/share/keyrings/ubuntu-archive-keyring.gpg"
if [[ ! -f "\${KEYRING_FILE}" ]]; then
    echo "WARNING: Ubuntu archive keyring not found at \${KEYRING_FILE}" | tee -a "\$LOG_FILE"
    echo "Install it: apt-get install -y ubuntu-keyring" | tee -a "\$LOG_FILE"
    echo "Or set MIRRORET_APT_INSECURE=1 to skip GPG checks (lab use only)." | tee -a "\$LOG_FILE"
fi

echo "Starting debmirror sync: \$(date)" | tee -a "\$LOG_FILE"
debmirror \\
    --arch "\${ARCH}" \\
    --no-source \\
    --host archive.ubuntu.com \\
    --root /ubuntu \\
    --proto http \\
    --section main,restricted,universe,multiverse \\
    --dist "\${CODENAME},\${CODENAME}-updates,\${CODENAME}-security" \\
    --keyring "\${KEYRING_FILE}" \\
    "\${MIRROR_DIR}" 2>&1 | tee -a "\$LOG_FILE"
echo "debmirror sync done: \$(date)" | tee -a "\$LOG_FILE"
DEBMIRROR_SCRIPT

    chmod +x "${script_file}"
    MIRRORET_APT_DATA_PATH="${mirror_dir}"

    warn "debmirror requires the Ubuntu archive keyring. See ${script_file} and docs/TROUBLESHOOTING.md."
    success "debmirror configured (${codename}). Run: ${script_file}"
}

# generate_apt_client_config <output_file> — write an APT sources.list entry for clients.
# Uses GPG signing if MIRRORET_APT_KEYRING is set; otherwise requires explicit insecure opt-in.
generate_apt_client_config() {
    local output_file="$1"
    local server_ip="${MIRRORET_SERVER_IP}"
    local web_port="${MIRRORET_WEB_PORT:-8080}"
    local codename
    codename="${MIRRORET_UBUNTU_CODENAME:-$(ubuntu_codename)}"
    # Path must match the nginx location defined in nginx.sh (/ubuntu).
    local base_path="/ubuntu"
    local insecure="${MIRRORET_APT_INSECURE:-0}"

    section "Generating APT client config"

    if [[ "${DRY_RUN}" == "1" ]]; then
        info "[DRY-RUN] would write APT client config to: ${output_file}"
        return 0
    fi

    if [[ "${insecure}" == "1" ]]; then
        warn_insecure "APT client config generated with trusted=yes (signature checking DISABLED)."
        warn_insecure "This is suitable for isolated lab environments ONLY."
        warn_insecure "Set MIRRORET_APT_INSECURE=0 and configure a GPG keyring for production use."

        cat > "$output_file" <<APT_EOF
# Local Repository Server - INSECURE MODE (no GPG verification)
# WARNING: trusted=yes disables package signature checking.
# Do NOT use this in production without GPG signing.
deb [trusted=yes] http://${server_ip}:${web_port}${base_path} ${codename} main restricted universe multiverse
deb [trusted=yes] http://${server_ip}:${web_port}${base_path} ${codename}-updates main restricted universe multiverse
deb [trusted=yes] http://${server_ip}:${web_port}${base_path} ${codename}-security main restricted universe multiverse
APT_EOF

    elif [[ -n "${MIRRORET_APT_KEYRING:-}" ]]; then
        local signed_by="signed-by=${MIRRORET_APT_KEYRING}"
        cat > "$output_file" <<APT_EOF
# Local Repository Server
deb [${signed_by}] http://${server_ip}:${web_port}${base_path} ${codename} main restricted universe multiverse
deb [${signed_by}] http://${server_ip}:${web_port}${base_path} ${codename}-updates main restricted universe multiverse
deb [${signed_by}] http://${server_ip}:${web_port}${base_path} ${codename}-security main restricted universe multiverse
APT_EOF
        success "APT client config generated with GPG keyring: ${MIRRORET_APT_KEYRING}"

    else
        # No keyring configured and insecure not explicitly enabled.
        # Generate a placeholder that will not work until configured.
        cat > "$output_file" <<APT_EOF
# Local Repository Server - NOT READY
# Configure GPG signing before use:
#   Option A (production): Set MIRRORET_APT_KEYRING=/etc/apt/keyrings/mirroret.gpg
#   Option B (lab only):   Set MIRRORET_APT_INSECURE=1 (disables signature checking)
#
# Uncomment and configure after setting up GPG:
# deb [signed-by=/etc/apt/keyrings/mirroret.gpg] http://${server_ip}:${web_port}${base_path} ${codename} main restricted universe multiverse
APT_EOF
        warn "APT client config requires GPG configuration before use."
        warn "See docs/SECURITY.md for GPG signing setup."
    fi

    success "APT client config written: ${output_file}"
}

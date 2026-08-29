#!/usr/bin/env bash
# APT repository configuration for mirroret.
# Source this file; do not execute it directly.
# Requires logging.sh, common.sh, distro.sh, backup.sh.
#
# MIRRORET_APT_MIRROR_TOOL=auto|native|apt-mirror|debmirror
# auto - use the built-in native engine (default)
# native - engines/mirroret_apt.py: stdlib Python, no external
#              mirroring tool, works on RHEL/Debian/anything
# apt-mirror - legacy: apt-mirror (or apt-mirror2 via pip)
# debmirror - legacy: debmirror
#
# The native engine is the default because it is the only option that works
# on a non-Debian mirror server: apt-mirror is Perl and was dropped from
# Debian 12, and debmirror needs dpkg tooling. A RHEL mirror server could
# therefore not serve Ubuntu clients at all, which is the single biggest
# thing this file used to get wrong.
#
# MIRRORET_APT_FLAVOR=auto|ubuntu|debian
# auto - derive from OS_ID on the mirror server (default)
# ubuntu - force Ubuntu upstream
# debian - force Debian upstream
#
# MIRRORET_APT_UPSTREAM_HOST - override the upstream archive host
# (default: archive.ubuntu.com for ubuntu, deb.debian.org for debian).
#
# MIRRORET_APT_UPSTREAM_PATH - the path component on the upstream host
# that contains dists/ and pool/ (default: /ubuntu for ubuntu, /debian
# for debian).
#
# MIRRORET_APT_SECURITY_HOST - separate security archive (Debian uses
# security.debian.org). Empty disables the security suite.
#
# MIRRORET_APT_COMPONENTS - components to mirror
# (default: "main restricted universe multiverse" for ubuntu,
# "main contrib non-free non-free-firmware" for debian).
#
# After configure_apt_mirror() succeeds, MIRRORET_APT_DATA_PATH is exported
# pointing to the directory nginx should serve, and MIRRORET_APT_NGINX_PREFIX
# points to the URL prefix nginx should expose (/ubuntu or /debian).
#
# A note on signed-by: mirroret mirrors upstream packages whose Release
# files are signed by Ubuntu / Debian, NOT by mirroret. Pointing
# signed-by= at mirroret's own GPG key would cause clients to reject the
# Release file. So we point signed-by at the upstream keyring on the
# client by default. Set MIRRORET_APT_RESIGN=1 if you actually re-sign
# the mirrored Release with mirroret's key (advanced, not done here).

MIRRORET_APT_MIRROR_TOOL="${MIRRORET_APT_MIRROR_TOOL:-auto}"
MIRRORET_APT_DATA_PATH="${MIRRORET_APT_DATA_PATH:-}"
MIRRORET_APT_RESOLVED_TOOL="${MIRRORET_APT_RESOLVED_TOOL:-}"
MIRRORET_APT_FLAVOR="${MIRRORET_APT_FLAVOR:-auto}"
MIRRORET_APT_UPSTREAM_HOST="${MIRRORET_APT_UPSTREAM_HOST:-}"
MIRRORET_APT_UPSTREAM_PATH="${MIRRORET_APT_UPSTREAM_PATH:-}"
MIRRORET_APT_SECURITY_HOST="${MIRRORET_APT_SECURITY_HOST:-}"
MIRRORET_APT_COMPONENTS="${MIRRORET_APT_COMPONENTS:-}"
MIRRORET_APT_RESIGN="${MIRRORET_APT_RESIGN:-0}"
MIRRORET_APT_NGINX_PREFIX="${MIRRORET_APT_NGINX_PREFIX:-}"

# -- Flavor + upstream resolution ---------------------------------------------

# _apt_resolve_flavor - print 'ubuntu' or 'debian' based on flavor override / OS_ID.
_apt_resolve_flavor() {
    case "${MIRRORET_APT_FLAVOR:-auto}" in
        ubuntu|debian)
            echo "${MIRRORET_APT_FLAVOR}"
            return 0
            ;;
        auto)
            ;;
        *)
            die "Unknown MIRRORET_APT_FLAVOR: '${MIRRORET_APT_FLAVOR}'. Use auto, ubuntu, or debian."
            ;;
    esac

    case "${OS_ID:-}" in
        debian) echo "debian" ;;
        ubuntu|linuxmint|pop) echo "ubuntu" ;;
        *)
            # Fall back to ubuntu (the historical default) but make it visible.
            warn "Cannot auto-detect APT flavor from OS_ID='${OS_ID:-}'. Defaulting to ubuntu."
            warn "Override with MIRRORET_APT_FLAVOR=debian if mirroring Debian."
            echo "ubuntu"
            ;;
    esac
}

# _apt_upstream_for <flavor> - print "host path security_host" triple.
_apt_upstream_for() {
    local flavor="$1"
    local host path sec
    case "${flavor}" in
        ubuntu)
            host="${MIRRORET_APT_UPSTREAM_HOST:-archive.ubuntu.com}"
            path="${MIRRORET_APT_UPSTREAM_PATH:-/ubuntu}"
            # Ubuntu serves security from the main archive under -security
            # suites; no separate security host needed.
            sec="${MIRRORET_APT_SECURITY_HOST:-}"
            ;;
        debian)
            host="${MIRRORET_APT_UPSTREAM_HOST:-deb.debian.org}"
            path="${MIRRORET_APT_UPSTREAM_PATH:-/debian}"
            # Debian's security archive is a separate PATH on the CDN, not a
            # separate host: deb.debian.org/debian-security. The old default
            # of security.debian.org combined with path=/debian produced
            # http://security.debian.org/debian, which 404s for every
            # release from bullseye onward. See _apt_security_path.
            sec="${MIRRORET_APT_SECURITY_HOST:-deb.debian.org}"
            ;;
        *)
            die "_apt_upstream_for: unknown flavor '${flavor}'"
            ;;
    esac
    echo "${host}|${path}|${sec}"
}

# _apt_security_path <flavor> <main_path> - path of the security archive.
#
# Ubuntu serves -security from the same /ubuntu path on security.ubuntu.com.
# Debian serves it from /debian-security. Reusing the main path for Debian
# was a silent 404 on every security suite.
_apt_security_path() {
    local flavor="$1" main_path="$2"
    if [[ -n "${MIRRORET_APT_SECURITY_PATH:-}" ]]; then
        echo "${MIRRORET_APT_SECURITY_PATH}"
        return 0
    fi
    case "${flavor}" in
        debian) echo "/debian-security" ;;
        *) echo "${main_path}" ;;
    esac
}

# _apt_components <flavor> - default component list per flavor (overridable).
_apt_components() {
    local flavor="$1"
    if [[ -n "${MIRRORET_APT_COMPONENTS:-}" ]]; then
        echo "${MIRRORET_APT_COMPONENTS}"
        return 0
    fi
    case "${flavor}" in
        ubuntu) echo "main restricted universe multiverse" ;;
        debian) echo "main contrib non-free non-free-firmware" ;;
        *) die "_apt_components: unknown flavor '${flavor}'" ;;
    esac
}

# _apt_codename <flavor> - print the codename to mirror.
# Priority: env override > OS_CODENAME (if flavor matches the running OS)
# > known mapping.
_apt_codename() {
    local flavor="$1"
    case "${flavor}" in
        ubuntu)
            if [[ -n "${MIRRORET_UBUNTU_CODENAME:-}" ]]; then
                echo "${MIRRORET_UBUNTU_CODENAME}"
                return 0
            fi
            ;;
        debian)
            if [[ -n "${MIRRORET_DEBIAN_CODENAME:-}" ]]; then
                echo "${MIRRORET_DEBIAN_CODENAME}"
                return 0
            fi
            ;;
    esac

    if [[ "${OS_ID:-}" == "${flavor}" ]] && [[ -n "${OS_CODENAME:-}" ]]; then
        echo "${OS_CODENAME}"
        return 0
    fi

    case "${flavor}-${OS_VER:-}" in
        ubuntu-20.04) echo "focal" ;;
        ubuntu-22.04) echo "jammy" ;;
        ubuntu-24.04) echo "noble" ;;
        debian-11) echo "bullseye" ;;
        debian-12) echo "bookworm" ;;
        debian-13) echo "trixie" ;;
        *)
            if [[ "${flavor}" == "ubuntu" ]]; then
                die "Unknown Ubuntu version '${OS_VER:-}'. Set MIRRORET_UBUNTU_CODENAME."
            else
                die "Unknown Debian version '${OS_VER:-}'. Set MIRRORET_DEBIAN_CODENAME."
            fi
            ;;
    esac
}

# -- Public API ---------------------------------------------------------------

# configure_apt_mirror <backup_id> - write APT mirror configuration.
configure_apt_mirror() {
    local backup_id="$1"
    local base_dir="${MIRRORET_BASE_DIR}"

    # Resolve the tool FIRST. The native engine is target-driven and must
    # not go anywhere near _apt_resolve_flavor/_apt_codename: those derive
    # the thing to mirror from the mirror SERVER's own OS, which is how a
    # RHEL host ended up being told "Unknown Ubuntu version 9.8" instead of
    # simply mirroring Ubuntu.
    local resolved_tool
    resolved_tool="$(_apt_resolve_tool "${MIRRORET_APT_MIRROR_TOOL:-auto}")"
    MIRRORET_APT_RESOLVED_TOOL="${resolved_tool}"
    if [[ "${resolved_tool}" == "native" ]]; then
        _configure_apt_native "${backup_id}" "${base_dir}"
        export MIRRORET_APT_DATA_PATH MIRRORET_APT_RESOLVED_TOOL MIRRORET_APT_NGINX_PREFIX
        return 0
    fi

    local flavor
    flavor="$(_apt_resolve_flavor)"

    local codename
    codename="$(_apt_codename "${flavor}")"

    local upstream up_host up_path up_sec
    upstream="$(_apt_upstream_for "${flavor}")"
    up_host="${upstream%%|*}"
    upstream="${upstream#*|}"
    up_path="${upstream%%|*}"
    up_sec="${upstream#*|}"

    local components
    components="$(_apt_components "${flavor}")"

    # nginx URL prefix is /ubuntu or /debian - pinned to the flavor so we
    # can mirror more than one flavor concurrently in the future.
    MIRRORET_APT_NGINX_PREFIX="${MIRRORET_APT_NGINX_PREFIX:-/${flavor}}"

    local tool="${MIRRORET_APT_MIRROR_TOOL:-auto}"
    section "Configuring APT mirror (flavor: ${flavor}, tool: ${tool})"
    info "Codename: ${codename}"
    info "Upstream: ${up_host}${up_path}"
    [[ -n "${up_sec}" ]] && info "Security: ${up_sec}"
    info "Components: ${components}"
    info "Client nginx prefix: ${MIRRORET_APT_NGINX_PREFIX}"

    info "Using APT mirror tool: ${resolved_tool}"

    case "${resolved_tool}" in
        apt-mirror)
            _configure_apt_mirror_classic "${backup_id}" "${base_dir}" \
                "${flavor}" "${codename}" "${up_host}" "${up_path}" "${up_sec}" "${components}"
            ;;
        apt-mirror2)
            _configure_apt_mirror2 "${backup_id}" "${base_dir}" \
                "${flavor}" "${codename}" "${up_host}" "${up_path}" "${up_sec}" "${components}"
            ;;
        debmirror)
            _configure_debmirror "${backup_id}" "${base_dir}" \
                "${flavor}" "${codename}" "${up_host}" "${up_path}" "${up_sec}" "${components}"
            ;;
        *)
            die "Unknown APT mirror tool: ${resolved_tool}"
            ;;
    esac

    export MIRRORET_APT_DATA_PATH MIRRORET_APT_RESOLVED_TOOL MIRRORET_APT_NGINX_PREFIX
}

# _apt_resolve_tool <requested> - print the tool name that will actually be used.
_apt_resolve_tool() {
    local requested="$1"
    case "${requested}" in
        apt-mirror)
            if check_command apt-mirror; then
                echo "apt-mirror"; return
            fi
            if check_command apt-mirror2 || pip3 show apt-mirror2 &>/dev/null 2>&1; then
                echo "apt-mirror2"; return
            fi
            warn "apt-mirror not found and apt-mirror2 not available. Falling back to debmirror."
            echo "debmirror"
            ;;
        debmirror)
            echo "debmirror"
            ;;
        native)
            echo "native"
            ;;
        auto)
            # The built-in engine, always. It needs nothing but python3, it
            # runs on any distro, and it publishes a suite's Release file
            # only after every package that Release references is on disk -
            # neither apt-mirror nor debmirror does that.
            echo "native"
            ;;
        *)
            die "Unknown MIRRORET_APT_MIRROR_TOOL value: '${requested}'. Use auto, native, apt-mirror, or debmirror."
            ;;
    esac
}

# _apt_mirror_data_path <base> <flavor> <host> <path>
# Emit the path apt-mirror / apt-mirror2 store data under, which is
# determined by the upstream host + path.
_apt_mirror_data_path() {
    local base="$1" flavor="$2" host="$3" path="$4"
    # apt-mirror stores under <mirror>/<host>/<path-without-leading-slash>
    local trimmed="${path#/}"
    echo "${base}/${flavor}/mirror/mirror/${host}/${trimmed}"
}

_configure_apt_mirror_classic() {
    local backup_id="$1" base_dir="$2" flavor="$3" codename="$4"
    local host="$5" path="$6" sec_host="$7" components="$8"
    local mirror_base="${base_dir}/${flavor}/mirror"

    backup_file "$backup_id" "/etc/apt/mirror.list"

    if [[ "${DRY_RUN}" == "1" ]]; then
        info "[DRY-RUN] would write /etc/apt/mirror.list (apt-mirror, codename=${codename})"
        MIRRORET_APT_DATA_PATH="$(_apt_mirror_data_path "${base_dir}" "${flavor}" "${host}" "${path}")"
        return 0
    fi

    # shellcheck disable=SC2086 # PKG_MGR_INSTALL is intentionally word-split
    xrun apt-get install -y --no-install-recommends apt-mirror 2>/dev/null || true

    local main_url="http://${host}${path}"

    {
        printf '############# config ##################\n'
        printf 'set base_path %s\n' "${mirror_base}"
        printf 'set mirror_path $base_path/mirror\n'
        printf 'set skel_path $base_path/skel\n'
        printf 'set var_path $base_path/var\n'
        printf 'set cleanscript $var_path/clean.sh\n'
        printf 'set defaultarch %s\n' "${MIRRORET_APT_ARCH:-amd64}"
        printf 'set postmirror_script $var_path/postmirror.sh\n'
        printf 'set run_postmirror 0\n'
        printf 'set nthreads %s\n' "${MIRRORET_APT_THREADS:-10}"
        printf 'set _tilde 0\n'
        printf '############# end config ##############\n\n'
        printf '# %s %s\n' "${flavor}" "${codename}"
        printf 'deb %s %s %s\n' "${main_url}" "${codename}" "${components}"
        printf 'deb %s %s-updates %s\n' "${main_url}" "${codename}" "${components}"
        if [[ -n "${sec_host}" ]]; then
            local sec_path sec_url
            sec_path="$(_apt_security_path "${flavor}" "${path}")"
            sec_url="http://${sec_host}${sec_path}"
            printf 'deb %s %s-security %s\n' "${sec_url}" "${codename}" "${components}"
        else
            printf 'deb %s %s-security %s\n' "${main_url}" "${codename}" "${components}"
        fi
        printf '\nclean %s\n' "${main_url}"
        if [[ -n "${sec_host}" ]]; then
            printf 'clean http://%s%s\n' "${sec_host}" \
                "$(_apt_security_path "${flavor}" "${path}")"
        fi
    } > /etc/apt/mirror.list

    MIRRORET_APT_DATA_PATH="$(_apt_mirror_data_path "${base_dir}" "${flavor}" "${host}" "${path}")"
    success "apt-mirror configured (${flavor} ${codename})."
}

_configure_apt_mirror2() {
    local backup_id="$1" base_dir="$2" flavor="$3" codename="$4"
    local host="$5" path="$6" sec_host="$7" components="$8"
    local mirror_base="${base_dir}/${flavor}/mirror"
    local config_file="/etc/apt/mirror.list"

    backup_file "$backup_id" "${config_file}"

    if [[ "${DRY_RUN}" == "1" ]]; then
        info "[DRY-RUN] would write ${config_file} (apt-mirror2, codename=${codename})"
        MIRRORET_APT_DATA_PATH="$(_apt_mirror_data_path "${base_dir}" "${flavor}" "${host}" "${path}")"
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

    local main_url="http://${host}${path}"

    {
        printf '############# config ##################\n'
        printf 'set base_path %s\n' "${mirror_base}"
        printf 'set mirror_path $base_path/mirror\n'
        printf 'set skel_path $base_path/skel\n'
        printf 'set var_path $base_path/var\n'
        printf 'set defaultarch %s\n' "${MIRRORET_APT_ARCH:-amd64}"
        printf 'set nthreads %s\n' "${MIRRORET_APT_THREADS:-10}"
        printf 'set _tilde 0\n'
        printf '############# end config ##############\n\n'
        printf '# %s %s\n' "${flavor}" "${codename}"
        printf 'deb %s %s %s\n' "${main_url}" "${codename}" "${components}"
        printf 'deb %s %s-updates %s\n' "${main_url}" "${codename}" "${components}"
        if [[ -n "${sec_host}" ]]; then
            local sec_path sec_url
            sec_path="$(_apt_security_path "${flavor}" "${path}")"
            sec_url="http://${sec_host}${sec_path}"
            printf 'deb %s %s-security %s\n' "${sec_url}" "${codename}" "${components}"
        else
            printf 'deb %s %s-security %s\n' "${main_url}" "${codename}" "${components}"
        fi
        printf '\nclean %s\n' "${main_url}"
        if [[ -n "${sec_host}" ]]; then
            printf 'clean http://%s%s\n' "${sec_host}" \
                "$(_apt_security_path "${flavor}" "${path}")"
        fi
    } > "${config_file}"

    MIRRORET_APT_DATA_PATH="$(_apt_mirror_data_path "${base_dir}" "${flavor}" "${host}" "${path}")"
    success "apt-mirror2 configured (${flavor} ${codename})."
}

_configure_debmirror() {
    local backup_id="$1" base_dir="$2" flavor="$3" codename="$4"
    local host="$5" path="$6" sec_host="$7" components="$8"
    local mirror_dir="${base_dir}/${flavor}/debmirror"
    local script_file="${base_dir}/scripts/sync-apt-debmirror.sh"
    local comma_components="${components// /,}"

    if [[ "${DRY_RUN}" == "1" ]]; then
        info "[DRY-RUN] would configure debmirror for ${flavor} ${codename} -> ${mirror_dir}"
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

    # debmirror uses the upstream keyring for the flavor.
    local default_keyring
    case "${flavor}" in
        ubuntu) default_keyring="/usr/share/keyrings/ubuntu-archive-keyring.gpg" ;;
        debian) default_keyring="/usr/share/keyrings/debian-archive-keyring.gpg" ;;
        *) default_keyring="" ;;
    esac

    cat > "${script_file}" <<DEBMIRROR_SCRIPT
#!/usr/bin/env bash
set -Eeuo pipefail

# debmirror sync script - generated by mirroret.
# Flavor: ${flavor}
# Codename: ${codename}
# Upstream: ${host}${path}
# Security: ${sec_host:-(none)}
# If you see GPG errors, install the matching keyring or set
# MIRRORET_APT_INSECURE=1 (lab use only). See docs/TROUBLESHOOTING.md.

FLAVOR="${flavor}"
CODENAME="${codename}"
ARCH="${MIRRORET_APT_ARCH:-amd64}"
HOST="${host}"
ROOT="${path}"
SEC_HOST="${sec_host}"
# Debian's security archive lives under /debian-security, so the security
# pass needs its OWN root - reusing ROOT gives a 404 for every suite.
SEC_ROOT="$(_apt_security_path "${flavor}" "${path}")"
COMPONENTS="${comma_components}"
MIRROR_DIR="${mirror_dir}"
LOG_DIR="${base_dir}/logs"
LOG_FILE="\${LOG_DIR}/sync-apt-debmirror-\$(date +%Y%m%d-%H%M%S).log"
KEYRING_FILE="\${MIRRORET_APT_KEYRING_OVERRIDE:-${default_keyring}}"

mkdir -p "\$LOG_DIR" "\$MIRROR_DIR"
exec > >(tee -a "\$LOG_FILE") 2>&1

echo "Starting debmirror sync: \$(date)"

if [[ -n "\$KEYRING_FILE" && ! -f "\$KEYRING_FILE" ]]; then
    echo "ERROR: archive keyring not found at \$KEYRING_FILE"
    echo "Install the keyring (ubuntu-keyring or debian-archive-keyring),"
    echo "or override with MIRRORET_APT_KEYRING_OVERRIDE=/path/to/keyring.gpg,"
    echo "or set MIRRORET_APT_INSECURE=1 (lab use only)."
    exit 3
fi

main_status=0
sec_status=0

# Main + updates suites from the primary archive.
debmirror \\
    --arch "\${ARCH}" \\
    --no-source \\
    --host "\${HOST}" \\
    --root "\${ROOT}" \\
    --proto http \\
    --section "\${COMPONENTS}" \\
    --dist "\${CODENAME},\${CODENAME}-updates" \\
    --keyring "\${KEYRING_FILE}" \\
    "\${MIRROR_DIR}" || main_status=\$?

# Security suite. Debian routes through security.debian.org with a
# different root; Ubuntu serves it from the main archive.
if [[ -n "\${SEC_HOST}" ]]; then
    debmirror \\
        --arch "\${ARCH}" \\
        --no-source \\
        --host "\${SEC_HOST}" \\
        --root "\${SEC_ROOT}" \\
        --proto http \\
        --section "\${COMPONENTS}" \\
        --dist "\${CODENAME}-security" \\
        --keyring "\${KEYRING_FILE}" \\
        "\${MIRROR_DIR}" || sec_status=\$?
else
    debmirror \\
        --arch "\${ARCH}" \\
        --no-source \\
        --host "\${HOST}" \\
        --root "\${ROOT}" \\
        --proto http \\
        --section "\${COMPONENTS}" \\
        --dist "\${CODENAME}-security" \\
        --keyring "\${KEYRING_FILE}" \\
        "\${MIRROR_DIR}" || sec_status=\$?
fi

echo "debmirror sync done: \$(date) (main=\${main_status} security=\${sec_status})"
if [[ \$main_status -ne 0 || \$sec_status -ne 0 ]]; then
    exit 1
fi
DEBMIRROR_SCRIPT

    chmod +x "${script_file}"
    MIRRORET_APT_DATA_PATH="${mirror_dir}"

    success "debmirror configured (${flavor} ${codename}). Run: ${script_file}"
}

# -- Client config generation -------------------------------------------------

# generate_apt_client_config <output_file>
# Writes an APT sources.list entry for clients.
#
# signed-by behavior:
# * MIRRORET_APT_INSECURE=1 -> trusted=yes (lab only, warning printed)
# * MIRRORET_APT_RESIGN=1 -> signed-by=<MIRRORET_APT_KEYRING>
# (caller is responsible for actually re-signing the mirrored
# Release files with that key - mirroret does not do this today)
# * otherwise -> no signed-by override; rely on the client's existing
# upstream archive keyring (which signed the upstream Release).
generate_apt_client_config() {
    local output_file="$1"
    local server_ip="${MIRRORET_SERVER_IP}"
    local web_port="${MIRRORET_WEB_PORT:-8080}"
    local insecure="${MIRRORET_APT_INSECURE:-0}"
    local resign="${MIRRORET_APT_RESIGN:-0}"

    local flavor
    flavor="$(_apt_resolve_flavor)"

    local codename
    codename="$(_apt_codename "${flavor}")"

    local components
    components="$(_apt_components "${flavor}")"

    local base_path="${MIRRORET_APT_NGINX_PREFIX:-/${flavor}}"

    section "Generating APT client config (flavor: ${flavor})"

    if [[ "${DRY_RUN}" == "1" ]]; then
        info "[DRY-RUN] would write APT client config to: ${output_file}"
        return 0
    fi

    local url="http://${server_ip}:${web_port}${base_path}"

    if [[ "${insecure}" == "1" ]]; then
        warn_insecure "APT client config generated with trusted=yes (signature checking DISABLED)."
        warn_insecure "Use only in isolated lab environments."

        cat > "$output_file" <<APT_EOF
# mirroret APT client config - INSECURE MODE (no GPG verification).
# WARNING: trusted=yes disables package signature checking.
# Do NOT use this in production.
# Flavor: ${flavor} Codename: ${codename}
deb [trusted=yes] ${url} ${codename} ${components}
deb [trusted=yes] ${url} ${codename}-updates ${components}
deb [trusted=yes] ${url} ${codename}-security ${components}
APT_EOF

    elif [[ "${resign}" == "1" ]] && [[ -n "${MIRRORET_APT_KEYRING:-}" ]]; then
        warn "MIRRORET_APT_RESIGN=1 but mirroret does not yet re-sign mirrored Release files."
        warn "If you re-signed manually, this client config will work; if not, apt update will fail."

        cat > "$output_file" <<APT_EOF
# mirroret APT client config - locally re-signed.
# Flavor: ${flavor} Codename: ${codename}
deb [signed-by=${MIRRORET_APT_KEYRING}] ${url} ${codename} ${components}
deb [signed-by=${MIRRORET_APT_KEYRING}] ${url} ${codename}-updates ${components}
deb [signed-by=${MIRRORET_APT_KEYRING}] ${url} ${codename}-security ${components}
APT_EOF

    else
        cat > "$output_file" <<APT_EOF
# mirroret APT client config - relies on upstream ${flavor} archive keyring.
# The mirrored Release files are signed by the upstream archive, not by
# mirroret. The client only needs the standard ${flavor}-archive-keyring
# package (already present on stock systems).
# Flavor: ${flavor} Codename: ${codename}
deb ${url} ${codename} ${components}
deb ${url} ${codename}-updates ${components}
deb ${url} ${codename}-security ${components}
APT_EOF
    fi

    success "APT client config written: ${output_file}"
}

# -- Native engine ------------------------------------------------------------
#
# engines/mirroret_apt.py does the mirroring. This side only has to:
#   1. make sure the target specs exist,
#   2. generate a sync script that feeds those specs to the engine,
#   3. tell nginx where the data lives.
#
# There is deliberately no host-distro check anywhere in here.

# _apt_engine_path - absolute path to the installed APT engine.
_apt_engine_path() {
    echo "${MIRRORET_BASE_DIR}/engines/mirroret_apt.py"
}

# _configure_apt_native <backup_id> <base_dir>
_configure_apt_native() {
    local backup_id="$1" base_dir="$2"

    section "Configuring APT mirroring (native engine)"

    # targets.sh owns the catalog; it has already run in install.sh, but
    # calling it again is cheap and makes this function usable on its own.
    if [[ -z "${MIRRORET_APT_SPECS+set}" ]] && \
       declare -f generate_target_specs >/dev/null 2>&1; then
        generate_target_specs
    fi

    # ${arr[@]:-} yields one empty element for an unset array under set -u,
    # so filter empties rather than trusting the count.
    local -a real_specs=()
    local sp
    for sp in "${MIRRORET_APT_SPECS[@]:-}"; do
        [[ -n "${sp}" ]] && real_specs+=("${sp}")
    done

    if [[ ${#real_specs[@]} -eq 0 ]]; then
        warn "No APT targets configured - skipping APT mirror setup."
        warn "  Set MIRRORET_APT_TARGETS in /etc/mirroret/mirroret.conf, e.g.:"
        warn "    MIRRORET_APT_TARGETS=\"ubuntu:jammy ubuntu:noble debian:bookworm\""
        return 0
    fi

    # The first target decides the legacy /ubuntu or /debian nginx prefix and
    # MIRRORET_APT_DATA_PATH, both of which older docs and configs refer to.
    local first_dir
    first_dir="$(_apt_spec_field "${real_specs[0]}" dir)"
    MIRRORET_APT_NGINX_PREFIX="${MIRRORET_APT_NGINX_PREFIX:-/${first_dir}}"
    MIRRORET_APT_DATA_PATH="${base_dir}/apt/${first_dir}"

    local s
    for s in "${real_specs[@]}"; do
        info "  target: $(_apt_spec_field "${s}" id) -> ${base_dir}/apt/$(_apt_spec_field "${s}" dir)"
    done

    if [[ "${DRY_RUN}" == "1" ]]; then
        info "[DRY-RUN] would write ${base_dir}/scripts/sync-apt-repos.sh"
        return 0
    fi

    mkdir -p "${base_dir}/apt" "${base_dir}/scripts"
    _write_apt_native_sync_script "${base_dir}" "${real_specs[@]}"
    success "APT mirroring configured for ${#real_specs[@]} target(s)."
}

# _apt_spec_field <spec-file> <field> - read one top-level string from a spec.
# python3 is a hard requirement for the native engine anyway.
_apt_spec_field() {
    mirroret_json_field "$1" "$2"
}


# _write_apt_native_sync_script <base_dir> <spec...>
_write_apt_native_sync_script() {
    local base_dir="$1"; shift
    local -a specs=("$@")
    local sync_script="${base_dir}/scripts/sync-apt-repos.sh"

    if ! preserve_user_customization "${sync_script}"; then
        return 0
    fi

    local spec_args=""
    local s
    for s in "${specs[@]}"; do
        spec_args+=" --spec '${s}'"
    done

    cat > "${sync_script}" <<APT_SYNC
#!/usr/bin/env bash
set -Euo pipefail

${MIRRORET_MANAGED_MARKER}
# APT sync - generated by mirroret. Do NOT edit; change
# MIRRORET_APT_TARGETS in /etc/mirroret/mirroret.conf and re-run
# 'sudo mirroretctl upgrade'.
#
# Mirrors every configured APT target with engines/mirroret_apt.py. The
# engine publishes each suite's Release file only after every package that
# Release lists is on disk, so an interrupted run leaves the previously
# published tree serving rather than a Release full of 404s.

ENGINE="${base_dir}/engines/mirroret_apt.py"
LOG_DIR="${base_dir}/logs"
LOG_FILE="\${LOG_DIR}/sync-apt-\$(date +%Y%m%d-%H%M%S).log"
LOCK_FILE="/var/lock/mirroret-sync-apt.lock"
mkdir -p "\$LOG_DIR"

# The lock is taken BEFORE stdout is redirected into the log. Redirecting
# first sends "another sync is already running" to the log file only, so an
# operator who starts a sync while the nightly cron run is in progress sees
# the command exit with no output at all.
exec 9>"\$LOCK_FILE" || { echo "ERROR: cannot open lock \$LOCK_FILE"; exit 2; }
if ! flock -n 9; then
    echo "ERROR: another APT sync is already running (lock: \$LOCK_FILE)."
    echo "       Nothing was started. Watch the running one with:"
    echo "         mirroretctl logs tail"
    exit 3
fi
exec > >(tee -a "\$LOG_FILE") 2>&1
# Kill the whole process group on cancellation so no download thread keeps
# writing into the tree after the lock is released.
trap 'kill -- -\$\$ 2>/dev/null || true' INT TERM

$(mirroret_script_preamble)

echo "Starting APT sync: \$(date)"

if ! command -v python3 >/dev/null 2>&1; then
    echo "ERROR: python3 not found. The native APT engine needs python3."
    echo "       Install it (dnf install python3 / apt-get install python3),"
    echo "       or set MIRRORET_APT_MIRROR_TOOL=debmirror on a Debian host."
    exit 2
fi
if [[ ! -f "\$ENGINE" ]]; then
    echo "ERROR: engine not found at \$ENGINE."
    echo "       Re-run: sudo ./install.sh --upgrade"
    exit 2
fi

ARGS=()
[[ "\${MIRRORET_APT_DELETE:-1}" == "1" ]] && ARGS+=(--delete)
[[ "\${MIRRORET_APT_REQUIRE_SIGNATURE:-0}" == "1" ]] && ARGS+=(--require-signature)
[[ "\${MIRRORET_SYNC_ESTIMATE:-1}" == "0" ]] && ARGS+=(--no-estimate)
[[ -n "\${MIRRORET_APT_JOBS:-}" ]] && ARGS+=(--jobs "\${MIRRORET_APT_JOBS}")
[[ -n "\${MIRRORET_CA_BUNDLE:-}" ]] && ARGS+=(--ca-bundle "\${MIRRORET_CA_BUNDLE}")
[[ "\${MIRRORET_APT_ALL_COMPRESSIONS:-0}" == "1" ]] && ARGS+=(--all-index-compressions)

# Be a good neighbour on a shared box and a shared proxy.
NICE=""
if command -v nice >/dev/null 2>&1; then
    NICE="nice -n \${MIRRORET_SYNC_NICE:-10}"
    command -v ionice >/dev/null 2>&1 && NICE="ionice -c 2 -n 7 \${NICE}"
fi

rc=0
# shellcheck disable=SC2086 # NICE must word-split
timeout -k 60 "\${MIRRORET_SYNC_TIMEOUT:-12h}" \\
    \${NICE} python3 "\$ENGINE"${spec_args} \\
    --min-free-gb "\${MIRRORET_SYNC_MIN_FREE_GB:-10}" \\
    "\${ARGS[@]}" || rc=\$?

# Post-sync self-test: walk every published Release, confirm every file it
# lists is on disk with the right size. Cheap (megabytes of metadata, not
# gigabytes of packages), and it catches the "server publishes a suite it
# never fully mirrored" class of bug before a client does.
if [[ "\$rc" -eq 0 && -x "${base_dir}/scripts/verify-mirror.sh" ]]; then
    echo
    echo "=== integrity check ==="
    if ! "${base_dir}/scripts/verify-mirror.sh" --base-dir "${base_dir}"; then
        echo
        echo "WARN: integrity check failed on at least one suite (see above)."
        echo "      The sync itself succeeded; a client still hits 404 on the"
        echo "      files marked missing. Rerun the sync after root-causing."
        rc=4
    fi
fi

echo "APT sync finished: \$(date) (exit \${rc})"
exit "\${rc}"
APT_SYNC

    chmod +x "${sync_script}"
    success "APT sync script written: ${sync_script}"
}

# -- Per-target client configs -----------------------------------------------

# generate_apt_client_configs <config_dir>
#
# One sources.list AND one deb822 .sources per target. Ubuntu 24.04 and
# Debian 12 both ship deb822 by default, and a client that already migrated
# needs the .sources form.
#
# Neither form points signed-by at a mirroret key: the mirrored Release
# files carry the UPSTREAM signature, so the client verifies with the
# archive keyring it already has. Pointing signed-by at mirroret's own key
# would make every apt update fail.
generate_apt_client_configs() {
    local config_dir="$1"
    local server_ip="${MIRRORET_SERVER_IP}"
    local web_port="${MIRRORET_WEB_PORT:-8080}"
    local insecure="${MIRRORET_APT_INSECURE:-0}"

    local -a real_specs=()
    local sp
    for sp in "${MIRRORET_APT_SPECS[@]:-}"; do
        [[ -n "${sp}" ]] && real_specs+=("${sp}")
    done
    [[ ${#real_specs[@]} -eq 0 ]] && return 0

    section "Generating APT client configs (${#real_specs[@]} target(s))"

    if [[ "${DRY_RUN}" == "1" ]]; then
        info "[DRY-RUN] would write APT client configs to ${config_dir}/"
        return 0
    fi

    mkdir -p "${config_dir}"
    local first=1

    for sp in "${real_specs[@]}"; do
        local dir code comps keyring suites arches
        dir="$(_apt_spec_field "${sp}" dir)"
        code="$(_apt_spec_field "${sp}" codename)"
        comps="$(mirroret_json_field "${sp}" components)"
        keyring="$(mirroret_json_field "${sp}" keyrings)"
        keyring="${keyring%% *}"
        suites="$(mirroret_json_field "${sp}" suites)"
        # Pin the client to the arches this mirror actually published. Without
        # this, a client that has `dpkg --add-architecture i386` set (Steam,
        # Wine, 32-bit tooling) tries to fetch i386 indices from this mirror
        # and gets 404s - because we only mirrored amd64. Same story on ARM
        # hosts. Comma-separate for apt's arch= list syntax.
        arches="$(mirroret_json_field "${sp}" arches)"
        arches="${arches// /,}"

        local url="http://${server_ip}:${web_port}/${dir}"
        local list_file="${config_dir}/${dir}-${code}.list"
        local src_file="${config_dir}/${dir}-${code}.sources"

        local opts_body=""
        if [[ "${insecure}" == "1" ]]; then
            opts_body="trusted=yes"
        elif [[ -n "${keyring}" ]]; then
            opts_body="signed-by=${keyring}"
        fi
        [[ -n "${arches}" ]] && opts_body="${opts_body:+${opts_body} }arch=${arches}"
        local opts=""
        [[ -n "${opts_body}" ]] && opts="[${opts_body}] "

        {
            printf '# mirroret APT client config - %s %s\n' "${dir}" "${code}"
            printf '# Install as /etc/apt/sources.list.d/mirroret.list, then:\n'
            printf '#   sudo mv /etc/apt/sources.list /etc/apt/sources.list.disabled-by-mirroret\n'
            printf '#   sudo rm -f /etc/apt/sources.list.d/ubuntu.sources   # deb822 hosts\n'
            printf '#   sudo apt-get update\n'
            printf '# Leaving the upstream entries enabled means apt keeps\n'
            printf '# reaching the internet and this mirror is bypassed.\n'
            if [[ "${insecure}" == "1" ]]; then
                printf '# WARNING: trusted=yes - signature checking is DISABLED.\n'
            else
                printf '# Release files carry the upstream %s signature; the\n' "${dir}"
                printf '# client verifies them with its own archive keyring.\n'
            fi
            local suite
            for suite in ${suites}; do
                printf 'deb %s%s %s %s\n' "${opts}" "${url}" "${suite}" "${comps}"
            done
        } > "${list_file}"

        {
            printf '# mirroret APT client config (deb822) - %s %s\n' "${dir}" "${code}"
            printf '# Install as /etc/apt/sources.list.d/mirroret.sources\n'
            printf 'Types: deb\n'
            printf 'URIs: %s\n' "${url}"
            printf 'Suites: %s\n' "${suites}"
            printf 'Components: %s\n' "${comps}"
            if [[ "${insecure}" == "1" ]]; then
                printf 'Trusted: yes\n'
            elif [[ -n "${keyring}" ]]; then
                printf 'Signed-By: %s\n' "${keyring}"
            fi
            [[ -n "${arches}" ]] && printf 'Architectures: %s\n' "${arches//,/ }"
        } > "${src_file}"

        info "  ${list_file}"
        # Back-compat: the old single-target name that docs and
        # 'mirroretctl client verify' still refer to.
        if [[ "${first}" == "1" ]]; then
            cp -f "${list_file}" "${config_dir}/debian-client.list"
            first=0
        fi
    done

    success "APT client configs written to ${config_dir}/"
}

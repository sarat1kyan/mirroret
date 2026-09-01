#!/usr/bin/env bash
# GPG key management for mirroret (APT and RPM repository signing).
# Source this file; do not execute it directly.
# Requires logging.sh, common.sh.
#
# Variables:
# MIRRORET_GPG_AUTO=1 auto-generate a signing key if none exists
# MIRRORET_GPG_NAME Real Name field for generated key (default: mirroret)
# MIRRORET_GPG_EMAIL Email field for generated key (default: mirroret@localhost)
# MIRRORET_GPG_HOMEDIR gpg home dir (default: /etc/mirroret/gnupg)
# MIRRORET_GPG_KEYID fingerprint/id of key to use; auto-detected when empty
#
# After setup_gpg() succeeds:
# MIRRORET_GPG_KEYID set to the key fingerprint in use
# MIRRORET_APT_KEYRING set to BASE_DIR/config/mirroret.gpg (for apt.sh)

MIRRORET_GPG_AUTO="${MIRRORET_GPG_AUTO:-0}"
MIRRORET_GPG_NAME="${MIRRORET_GPG_NAME:-mirroret}"
MIRRORET_GPG_EMAIL="${MIRRORET_GPG_EMAIL:-mirroret@localhost}"
MIRRORET_GPG_HOMEDIR="${MIRRORET_GPG_HOMEDIR:-/etc/mirroret/gnupg}"
MIRRORET_GPG_KEYID="${MIRRORET_GPG_KEYID:-}"

# setup_gpg - provision GPG key and export public key for clients.
setup_gpg() {
    section "Setting Up GPG Signing"

    require_command gpg

    if [[ "${DRY_RUN}" == "1" ]]; then
        info "[DRY-RUN] would provision GPG key in ${MIRRORET_GPG_HOMEDIR}"
        return 0
    fi

    _gpg_prepare_homedir

    if [[ -z "${MIRRORET_GPG_KEYID}" ]]; then
        _gpg_find_or_generate_key
    else
        _gpg_verify_key "${MIRRORET_GPG_KEYID}"
    fi

    # No key found and MIRRORET_GPG_AUTO is off: signing stays disabled.
    # Say so plainly instead of announcing an empty key as "ready".
    if [[ -z "${MIRRORET_GPG_KEYID}" ]]; then
        warn "No GPG key configured - repository signing is disabled."
        warn "Set MIRRORET_GPG_AUTO=1 (or MIRRORET_GPG_KEYID) and re-run to enable it."
        return 0
    fi

    _gpg_export_public_key
    export MIRRORET_GPG_KEYID MIRRORET_APT_KEYRING
    success "GPG key ready: ${MIRRORET_GPG_KEYID}"
}

_gpg_prepare_homedir() {
    mkdir -p "${MIRRORET_GPG_HOMEDIR}"
    chmod 700 "${MIRRORET_GPG_HOMEDIR}"
    chown root:root "${MIRRORET_GPG_HOMEDIR}"
}

_gpg() {
    gpg --homedir "${MIRRORET_GPG_HOMEDIR}" --batch "$@"
}

_gpg_find_or_generate_key() {
    local existing
    existing=$(_gpg --list-secret-keys --with-colons 2>/dev/null \
        | awk -F: '$1=="fpr"{print $10; exit}')

    if [[ -n "${existing}" ]]; then
        info "Re-using existing GPG key: ${existing}"
        MIRRORET_GPG_KEYID="${existing}"
        return 0
    fi

    if [[ "${MIRRORET_GPG_AUTO}" != "1" ]]; then
        warn "No GPG key found. Set MIRRORET_GPG_AUTO=1 to generate one automatically."
        warn "GPG signing will not be configured."
        return 0
    fi

    _gpg_generate_key
}

_gpg_generate_key() {
    info "Generating GPG key (4096-bit RSA, no passphrase)..."
    _gpg --gen-key <<GPG_PARAMS
%no-protection
Key-Type: RSA
Key-Length: 4096
Subkey-Type: RSA
Subkey-Length: 4096
Name-Real: ${MIRRORET_GPG_NAME}
Name-Email: ${MIRRORET_GPG_EMAIL}
Expire-Date: 0
%commit
GPG_PARAMS

    MIRRORET_GPG_KEYID=$(_gpg --list-secret-keys --with-colons 2>/dev/null \
        | awk -F: '$1=="fpr"{print $10; exit}')

    [[ -n "${MIRRORET_GPG_KEYID}" ]] \
        || die "GPG key generation failed - no key found after generation."
    success "Generated GPG key: ${MIRRORET_GPG_KEYID}"
}

_gpg_verify_key() {
    local keyid="$1"
    _gpg --list-secret-keys "${keyid}" &>/dev/null \
        || die "GPG key not found in homedir ${MIRRORET_GPG_HOMEDIR}: ${keyid}"
    info "GPG key verified: ${keyid}"
}

_gpg_export_public_key() {
    [[ -z "${MIRRORET_GPG_KEYID}" ]] && return 0

    local base_dir="${MIRRORET_BASE_DIR}"
    local config_dir="${base_dir}/config"
    local armored_file="${config_dir}/GPG-KEY.asc"
    local gpg_file="${config_dir}/mirroret.gpg"

    mkdir -p "${config_dir}"

    # ASCII-armored export (human-readable, for docs + RHEL)
    _gpg --armor --export "${MIRRORET_GPG_KEYID}" > "${armored_file}"
    # Binary export (for APT signed-by)
    _gpg --export "${MIRRORET_GPG_KEYID}" > "${gpg_file}"

    chmod 644 "${armored_file}" "${gpg_file}"

    MIRRORET_APT_KEYRING="${gpg_file}"
    info "Public key exported: ${armored_file}"
    info "APT keyring: ${gpg_file}"
}

# get_gpg_apt_keyring - print the path to the binary GPG keyring for APT.
get_gpg_apt_keyring() {
    echo "${MIRRORET_APT_KEYRING:-${MIRRORET_BASE_DIR}/config/mirroret.gpg}"
}

# write_gpg_client_instructions <output_file>
# Write a shell snippet clients can run to import the GPG key.
write_gpg_client_instructions() {
    local output_file="$1"
    local server_ip="${MIRRORET_SERVER_IP}"
    local web_port="${MIRRORET_WEB_PORT:-8080}"

    cat > "${output_file}" <<CLIENT_EOF
#!/usr/bin/env bash
# Import the mirroret repository GPG public key.
# Run this once on each client before adding the APT/RPM repository.
set -euo pipefail

SERVER="http://${server_ip}:${web_port}"
KEY_URL="\${SERVER}/config/GPG-KEY.asc"

# APT (Debian/Ubuntu)
if command -v apt-get >/dev/null 2>&1; then
    echo "Importing GPG key for APT..."
    mkdir -p /etc/apt/keyrings
    # --batch --yes: never prompt, overwrite an existing keyring on re-run.
    if curl -fsSL "\${KEY_URL}" | gpg --batch --yes --dearmor -o /etc/apt/keyrings/mirroret.gpg; then
        chmod 644 /etc/apt/keyrings/mirroret.gpg
        echo "APT key imported: /etc/apt/keyrings/mirroret.gpg"
    else
        echo "ERROR: could not download or import the key from \${KEY_URL}" >&2
        rm -f /etc/apt/keyrings/mirroret.gpg
        exit 1
    fi
fi

# RPM (RHEL/Rocky/Alma/CentOS)
if command -v rpm >/dev/null 2>&1; then
    echo "Importing GPG key for RPM..."
    if rpm --import "\${KEY_URL}"; then
        echo "RPM key imported."
    else
        echo "ERROR: rpm --import failed for \${KEY_URL}" >&2
        exit 1
    fi
fi
CLIENT_EOF

    chmod 755 "${output_file}"
    info "GPG client import script: ${output_file}"
}

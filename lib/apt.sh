#!/usr/bin/env bash
# APT repository configuration for mirroret.
# Source this file; do not execute it directly.
# Requires logging.sh, common.sh, distro.sh, backup.sh.

# configure_apt_mirror <backup_id> — write apt-mirror configuration.
configure_apt_mirror() {
    local backup_id="$1"
    local base_dir="${MIRRORET_BASE_DIR}"
    local codename
    codename="${MIRRORET_UBUNTU_CODENAME:-$(ubuntu_codename)}"

    section "Configuring apt-mirror"
    info "Ubuntu codename: ${codename}"

    backup_file "$backup_id" "/etc/apt/mirror.list"

    if [[ "${DRY_RUN}" == "1" ]]; then
        info "[DRY-RUN] would write /etc/apt/mirror.list (codename=${codename})"
        return 0
    fi

    cat > /etc/apt/mirror.list <<MIRROR_EOF
############# config ##################
set base_path    ${base_dir}/debian/mirror
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

    success "apt-mirror configured (${codename})."
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

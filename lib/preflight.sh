#!/usr/bin/env bash
# Pre-flight checks for mirroret installation.
# Source this file; do not execute it directly.
# Requires logging.sh, common.sh, distro.sh.

# Minimum free disk space in GB for the repo base directory.
MIRRORET_MIN_DISK_GB="${MIRRORET_MIN_DISK_GB:-50}"

# run_preflight — execute all preflight checks.
# Exits with an error if any mandatory check fails.
run_preflight() {
    section "Running Pre-flight Checks"

    require_root
    _check_distro_detected
    _check_disk_space
    _check_write_permissions
    _check_required_network_tools

    success "All pre-flight checks passed."
}

_check_distro_detected() {
    if [[ -z "${DISTRO_TYPE:-}" ]]; then
        die "Distro not detected. Call detect_distro() before run_preflight()."
    fi
    info "Distribution: ${OS_ID} ${OS_VER} (${DISTRO_TYPE})"
}

_check_disk_space() {
    local base_dir="${MIRRORET_BASE_DIR:-/srv/mirroret}"
    # Find the nearest existing parent directory.
    local check_dir="$base_dir"
    while [[ ! -d "$check_dir" ]] && [[ "$check_dir" != "/" ]]; do
        check_dir="$(dirname "$check_dir")"
    done

    local avail_kb
    avail_kb="$(df -k "$check_dir" | awk 'NR==2 {print $4}')"
    local avail_gb=$(( avail_kb / 1024 / 1024 ))

    info "Available disk space on ${check_dir}: ${avail_gb} GB"

    if [[ "$avail_gb" -lt "${MIRRORET_MIN_DISK_GB}" ]]; then
        warn "Available disk space (${avail_gb} GB) is below minimum (${MIRRORET_MIN_DISK_GB} GB)."
        warn "A full mirror requires 200–500 GB. Set MIRRORET_MIN_DISK_GB=0 to skip this check."
        if ! confirm "Continue anyway?"; then
            die "Aborted: insufficient disk space."
        fi
    else
        success "Disk space OK: ${avail_gb} GB available."
    fi
}

_check_write_permissions() {
    local base_dir="${MIRRORET_BASE_DIR:-/srv/mirroret}"
    # Check the nearest existing parent.
    local check_dir="$base_dir"
    while [[ ! -d "$check_dir" ]] && [[ "$check_dir" != "/" ]]; do
        check_dir="$(dirname "$check_dir")"
    done

    if [[ ! -w "$check_dir" ]]; then
        die "No write permission on ${check_dir}. Run as root."
    fi
    success "Write permissions OK on ${check_dir}."
}

_check_required_network_tools() {
    local missing=()
    for cmd in curl wget; do
        check_command "$cmd" || missing+=("$cmd")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        warn "Recommended tools not found: ${missing[*]}"
        warn "These may be needed by sync scripts."
    else
        success "Network tools present (curl, wget)."
    fi
}

# check_optional_commands — non-fatal check for optional tools.
check_optional_commands() {
    local optional=(shellcheck shfmt bats tree)
    for cmd in "${optional[@]}"; do
        if check_command "$cmd"; then
            debug "Optional command found: ${cmd}"
        else
            debug "Optional command not found: ${cmd} (not required)"
        fi
    done
}

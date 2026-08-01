#!/usr/bin/env bash
# Validation and status checks for mirroret.
# Source this file; do not execute it directly.
# Requires logging.sh, common.sh, distro.sh.

# run_validation - comprehensive validation of the current installation.
# Prints a status report and exits non-zero if any critical check fails.
run_validation() {
    section "Mirroret Installation Validation"

    local failures=0 rc=0

    _check_commands; rc=$?; failures=$(( failures + rc ))
    _check_distro; rc=$?; failures=$(( failures + rc ))
    _check_disk_space_validation; rc=$?; failures=$(( failures + rc ))
    _check_directories; rc=$?; failures=$(( failures + rc ))
    _check_nginx_config; rc=$?; failures=$(( failures + rc ))
    _check_services; rc=$?; failures=$(( failures + rc ))
    _check_repo_metadata; rc=$?; failures=$(( failures + rc ))
    _check_client_configs; rc=$?; failures=$(( failures + rc ))

    echo ""
    if [[ "$failures" -eq 0 ]]; then
        success "Validation complete: no issues found."
    else
        warn "Validation complete: ${failures} issue(s) found."
        warn "Review the output above and consult docs/TROUBLESHOOTING.md."
    fi

    return "$failures"
}

# print_status - quick status overview of running services.
print_status() {
    section "Mirroret Status"

    echo ""
    echo "Services:"
    for svc in nginx pypiserver verdaccio; do
        if check_command systemctl; then
            check_service_status "$svc"
        fi
    done

    echo ""
    echo "Docker registry:"
    _status_registry

    echo ""
    echo "Disk usage:"
    local base_dir="${MIRRORET_BASE_DIR:-/srv/mirroret}"
    if [[ -d "$base_dir" ]]; then
        du -sh "${base_dir}"/* 2>/dev/null | while read -r size path; do
            echo " ${size} ${path}"
        done
    else
        warn " Base directory not found: ${base_dir}"
    fi

    echo ""
    echo "Cron jobs:"
    crontab -l 2>/dev/null | grep -i "mirroret\|sync" || echo " (none found)"
}

# _status_registry - report the registry regardless of how it is run.
# The old code only ever asked `docker`, so a native docker-distribution
# service or a podman-managed container always showed "not running".
_status_registry() {
    local name="${MIRRORET_DOCKER_CONTAINER_NAME:-mirroret-registry}"
    local reported=0

    # Native OS-package services.
    local svc
    for svc in docker-distribution docker-registry; do
        if check_command systemctl && \
           systemctl list-unit-files --full --no-legend "${svc}.service" 2>/dev/null \
             | grep -q "${svc}.service"; then
            if service_is_active "$svc"; then
                success " ${svc}: running"
            else
                warn " ${svc}: not running"
            fi
            reported=1
        fi
    done

    # Container under whichever runtime is present.
    local rt
    for rt in podman docker; do
        check_command "$rt" || continue
        if "$rt" ps --format '{{.Names}}' 2>/dev/null | grep -qx "$name"; then
            success " ${name}: running (${rt})"
            reported=1
        elif "$rt" ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$name"; then
            warn " ${name}: exists but stopped (${rt})"
            reported=1
        fi
    done

    # Podman-generated unit.
    if [[ "$reported" -eq 0 ]] && check_command systemctl && \
       systemctl list-unit-files --full --no-legend "${name}.service" 2>/dev/null \
         | grep -q "${name}.service"; then
        if service_is_active "$name"; then
            success " ${name}.service: running"
        else
            warn " ${name}.service: not running"
        fi
        reported=1
    fi

    [[ "$reported" -eq 0 ]] && info " no registry backend detected"
    return 0
}

# -- Private check functions --------------------------------------------------

_check_commands() {
    local fail=0
    local required=(nginx curl)
    local optional=(apt-mirror createrepo reposync docker pypi-server verdaccio npm)

    for cmd in "${required[@]}"; do
        if check_command "$cmd"; then
            success "command: ${cmd}"
        else
            warn "command not found: ${cmd} (required)"
            (( fail += 1 )) || true
        fi
    done

    for cmd in "${optional[@]}"; do
        if check_command "$cmd"; then
            success "command: ${cmd}"
        else
            info "command not found: ${cmd} (optional)"
        fi
    done

    return "$fail"
}

_check_distro() {
    if [[ -f /etc/os-release ]]; then
        # shellcheck source=/dev/null
        . /etc/os-release
        success "distro: ${ID} ${VERSION_ID}"
        return 0
    fi
    warn "Cannot detect distribution."
    return 1
}

_check_disk_space_validation() {
    local base_dir="${MIRRORET_BASE_DIR:-/srv/mirroret}"
    local check_dir="$base_dir"
    while [[ ! -d "$check_dir" ]] && [[ "$check_dir" != "/" ]]; do
        check_dir="$(dirname "$check_dir")"
    done

    local avail_kb
    avail_kb="$(df -k "$check_dir" | awk 'NR==2 {print $4}')"
    local avail_gb=$(( avail_kb / 1024 / 1024 ))

    if [[ "$avail_gb" -lt 10 ]]; then
        warn "Disk space critically low: ${avail_gb} GB available on ${check_dir}"
        return 1
    fi
    success "disk space: ${avail_gb} GB available on ${check_dir}"
    return 0
}

_check_directories() {
    local fail=0
    local base_dir="${MIRRORET_BASE_DIR:-/srv/mirroret}"
    local expected_dirs=(
        "debian/mirror"
        "debian/approved"
        "redhat/mirror"
        "redhat/approved"
        "pip/approved"
        "docker/registry"
        "npm/approved"
        "logs"
        "scripts"
        "config"
    )

    for dir in "${expected_dirs[@]}"; do
        local full="${base_dir}/${dir}"
        if [[ -d "$full" ]]; then
            success "directory: ${full}"
        else
            warn "directory missing: ${full}"
            (( fail += 1 )) || true
        fi
    done

    return "$fail"
}

_check_nginx_config() {
    local fail=0
    if ! check_command nginx; then
        warn "nginx not installed."
        return 1
    fi

    if nginx -t &>/dev/null; then
        success "nginx config: valid"
    else
        warn "nginx config: INVALID"
        nginx -t 2>&1 | while IFS= read -r line; do warn " $line"; done
        (( fail += 1 )) || true
    fi

    if service_is_active nginx; then
        success "nginx: running"
    else
        warn "nginx: not running"
        (( fail += 1 )) || true
    fi

    return "$fail"
}

_check_services() {
    local fail=0
    for svc in pypiserver verdaccio; do
        if check_command systemctl && systemctl list-unit-files "${svc}.service" &>/dev/null; then
            if service_is_active "$svc"; then
                success "service ${svc}: running"
            else
                warn "service ${svc}: not running"
                (( fail += 1 )) || true
            fi
        else
            info "service ${svc}: not configured"
        fi
    done
    return "$fail"
}

_check_repo_metadata() {
    local fail=0
    local base_dir="${MIRRORET_BASE_DIR:-/srv/mirroret}"

    # Check for APT metadata.
    local apt_approved="${base_dir}/debian/approved"
    if [[ -d "$apt_approved" ]]; then
        if find "$apt_approved" -name "Packages.gz" 2>/dev/null | grep -q .; then
            success "APT metadata: found"
        else
            warn "APT metadata: Packages.gz not found in ${apt_approved}"
            warn " Run: dpkg-scanpackages ${apt_approved} | gzip > ${apt_approved}/Packages.gz"
            (( fail += 1 )) || true
        fi
    fi

    # Check for RPM metadata.
    # reposync writes into redhat/mirror/<flavor>/<ver>/<repo>/repodata,
    # NOT redhat/approved. Checking the wrong path made --check return
    # non-zero after a perfectly good sync.
    local rpm_approved="${base_dir}/redhat/mirror"
    if [[ -d "$rpm_approved" ]]; then
        if find "$rpm_approved" -name "repomd.xml" 2>/dev/null | grep -q .; then
            success "RPM metadata: found"
        else
            warn "RPM metadata: repomd.xml not found in ${rpm_approved}"
            warn " Run a sync first: ${base_dir}/scripts/sync-redhat-repos.sh"
            (( fail += 1 )) || true
        fi
    fi

    return "$fail"
}

_check_client_configs() {
    local fail=0
    local base_dir="${MIRRORET_BASE_DIR:-/srv/mirroret}"
    local config_dir="${base_dir}/config"

    if [[ ! -d "$config_dir" ]]; then
        warn "config directory missing: ${config_dir}"
        return 1
    fi

    local expected_configs=(
        "debian-client.list"
        "redhat-client.repo"
        "pip.conf"
        ".npmrc"
        "docker-daemon.json"
    )

    for cfg in "${expected_configs[@]}"; do
        if [[ -f "${config_dir}/${cfg}" ]]; then
            success "client config: ${cfg}"
        else
            info "client config not found: ${cfg} (may not be enabled)"
        fi
    done

    return "$fail"
}

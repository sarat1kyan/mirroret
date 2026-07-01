#!/usr/bin/env bash
# Pre-flight checks for mirroret installation.
# Source this file; do not execute it directly.
# Requires logging.sh, common.sh, distro.sh.
#
# Each individual check is exposed so scripts/mirroret-debug.sh can reuse
# them in read-only mode. All probes default to non-fatal warnings unless
# the failure makes installation literally impossible.

# Minimum free disk space in GB for the repo base directory.
MIRRORET_MIN_DISK_GB="${MIRRORET_MIN_DISK_GB:-50}"

# Set MIRRORET_PREFLIGHT_NETWORK=1 to enable optional outbound HTTPS probes
# during install (off by default for fast/offline installs).
MIRRORET_PREFLIGHT_NETWORK="${MIRRORET_PREFLIGHT_NETWORK:-0}"

# run_preflight — execute all preflight checks.
# Exits with an error if any mandatory check fails. Warnings do not abort.
run_preflight() {
    section "Running Pre-flight Checks"

    require_root
    _pf_check_distro_detected
    _pf_check_systemd
    _pf_check_selinux_mode
    _pf_check_disk_space
    _pf_check_write_permissions
    _pf_check_required_network_tools
    _pf_check_dns
    _pf_check_proxy_env
    _pf_check_ca_hints
    _pf_check_port_conflicts
    _pf_check_rhel_subscription
    [[ "${MIRRORET_PREFLIGHT_NETWORK}" == "1" ]] && _pf_check_outbound_https

    success "Pre-flight checks complete."
}

# ── individual checks ───────────────────────────────────────────────────────

_pf_check_distro_detected() {
    if [[ -z "${DISTRO_TYPE:-}" ]]; then
        die "Distro not detected. Call detect_distro() before run_preflight()."
    fi
    info "Distribution: ${OS_ID} ${OS_VER} (${DISTRO_TYPE})"
}

_pf_check_systemd() {
    if [[ ! -d /run/systemd/system ]] && ! check_command systemctl; then
        warn "systemd not detected. Mirroret depends on systemd for service management."
        warn "If this is a container or non-systemd host, services will not auto-start."
        return 0
    fi
    if check_command systemctl; then
        local state
        state="$(systemctl is-system-running 2>/dev/null || true)"
        case "${state}" in
            running|degraded|starting|"")
                info "systemd: ${state:-detected}"
                ;;
            offline|unknown)
                warn "systemd reports state '${state}'. Service operations may not work."
                ;;
            *)
                info "systemd: ${state}"
                ;;
        esac
    fi
}

_pf_check_selinux_mode() {
    local mode
    mode="$(selinux_mode)"
    case "${mode}" in
        enforcing)
            info "SELinux: enforcing"
            if ! check_command setsebool || ! check_command semanage; then
                warn "SELinux is enforcing but policycoreutils tools are missing."
                warn "nginx may 502 on proxied locations and 403 on data files."
                warn "Install: policycoreutils-python-utils"
            fi
            ;;
        permissive)
            info "SELinux: permissive (contexts applied for future enforcing mode)"
            ;;
        disabled|absent)
            debug "SELinux: ${mode}"
            ;;
    esac
}

_pf_check_disk_space() {
    local base_dir="${MIRRORET_BASE_DIR:-/srv/mirroret}"
    local check_dir="$base_dir"
    while [[ ! -d "$check_dir" ]] && [[ "$check_dir" != "/" ]]; do
        check_dir="$(dirname "$check_dir")"
    done

    local avail_kb
    avail_kb="$(df -k "$check_dir" 2>/dev/null | awk 'NR==2 {print $4}')"
    if [[ -z "${avail_kb}" ]]; then
        warn "Could not determine disk space on ${check_dir}."
        return 0
    fi
    local avail_gb=$(( avail_kb / 1024 / 1024 ))

    info "Available disk space on ${check_dir}: ${avail_gb} GB"

    if [[ "${MIRRORET_MIN_DISK_GB}" -gt 0 ]] && [[ "$avail_gb" -lt "${MIRRORET_MIN_DISK_GB}" ]]; then
        warn "Available disk space (${avail_gb} GB) is below minimum (${MIRRORET_MIN_DISK_GB} GB)."
        warn "A full mirror requires 200–500 GB. Set MIRRORET_MIN_DISK_GB=0 to skip this check."
        if ! confirm "Continue anyway?"; then
            die "Aborted: insufficient disk space."
        fi
    else
        success "Disk space OK: ${avail_gb} GB available."
    fi
}

_pf_check_write_permissions() {
    local base_dir="${MIRRORET_BASE_DIR:-/srv/mirroret}"
    local check_dir="$base_dir"
    while [[ ! -d "$check_dir" ]] && [[ "$check_dir" != "/" ]]; do
        check_dir="$(dirname "$check_dir")"
    done

    if [[ ! -w "$check_dir" ]]; then
        die "No write permission on ${check_dir}. Run as root."
    fi
    success "Write permissions OK on ${check_dir}."
}

_pf_check_required_network_tools() {
    local missing=()
    for cmd in curl wget; do
        check_command "$cmd" || missing+=("$cmd")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        warn "Recommended tools not found: ${missing[*]}"
        warn "Sync scripts may fail until installed."
    else
        success "Network tools present (curl, wget)."
    fi
}

# _pf_resolve_one <host> — try to resolve a hostname via getent (which uses
# nsswitch — works with /etc/hosts, mDNS, systemd-resolved, etc).
_pf_resolve_one() {
    local host="$1"
    if check_command getent; then
        getent hosts "$host" 2>/dev/null | head -1 | awk '{print $1}'
    elif check_command host; then
        host "$host" 2>/dev/null | awk '/has address/ {print $4; exit}'
    elif check_command nslookup; then
        nslookup "$host" 2>/dev/null | awk '/^Address: / {print $2; exit}'
    else
        return 1
    fi
}

_pf_check_dns() {
    local hosts=()

    # Pick the hosts we'll actually need based on what's enabled.
    [[ "${MIRRORET_ENABLE_APT:-1}" == "1" ]] && case "${OS_ID:-}" in
        debian) hosts+=(deb.debian.org security.debian.org) ;;
        *)      hosts+=(archive.ubuntu.com) ;;
    esac
    [[ "${MIRRORET_ENABLE_RPM:-1}" == "1" ]] && case "${OS_ID:-}" in
        rocky|almalinux) hosts+=(dl.rockylinux.org repo.almalinux.org) ;;
        rhel) hosts+=(cdn.redhat.com) ;;
        ol)   hosts+=(yum.oracle.com) ;;
        centos) hosts+=(mirror.stream.centos.org) ;;
        fedora) hosts+=(dl.fedoraproject.org) ;;
    esac
    [[ "${MIRRORET_ENABLE_PIP:-1}" == "1" ]]    && hosts+=(pypi.org files.pythonhosted.org)
    [[ "${MIRRORET_ENABLE_DOCKER:-1}" == "1" ]] && hosts+=(registry-1.docker.io)
    [[ "${MIRRORET_ENABLE_NPM:-1}" == "1" ]]    && hosts+=(registry.npmjs.org)

    [[ ${#hosts[@]} -eq 0 ]] && return 0

    local failed=()
    for h in "${hosts[@]}"; do
        if ! _pf_resolve_one "$h" >/dev/null; then
            failed+=("$h")
        fi
    done
    if [[ ${#failed[@]} -gt 0 ]]; then
        warn "DNS resolution failed for: ${failed[*]}"
        warn "Sync will fail for these upstreams until DNS / /etc/hosts is fixed."
        warn "If you are behind a corporate proxy, see docs/PROXY_AND_CA.md."
    else
        success "DNS: resolved ${#hosts[@]} upstream host(s) successfully."
    fi
}

_pf_check_proxy_env() {
    local set_vars=()
    for v in http_proxy HTTP_PROXY https_proxy HTTPS_PROXY no_proxy NO_PROXY; do
        [[ -n "${!v:-}" ]] && set_vars+=("${v}=${!v}")
    done

    if [[ ${#set_vars[@]} -gt 0 ]]; then
        info "Proxy environment detected: ${set_vars[*]}"
        info "These variables WILL propagate to apt-get / dnf / pip / npm in this shell."
        info "They will NOT propagate to cron-driven sync jobs — see docs/PROXY_AND_CA.md."
        return 0
    fi

    # If the operator is using sudo, the original user's env was likely stripped.
    if [[ -n "${SUDO_USER:-}" ]] && [[ "${SUDO_USER}" != "root" ]]; then
        # Try to detect a proxy in the invoking user's environment files.
        local user_home
        user_home=$(getent passwd "${SUDO_USER}" 2>/dev/null | cut -d: -f6 || true)
        if [[ -n "${user_home}" ]] && \
           { grep -lE '(^|[^#])(http_proxy|https_proxy)=' "${user_home}/.bashrc" "${user_home}/.profile" "${user_home}/.bash_profile" 2>/dev/null | head -1 >/dev/null; }; then
            warn "Proxy variables present in ${SUDO_USER}'s shell rc but NOT in this sudo session."
            warn "Re-run with: sudo -E ./install.sh, or pass explicit env vars to sudo."
        fi
    fi
}

_pf_check_ca_hints() {
    local has_custom_ca=0
    # Common system-wide custom-CA drop-in locations.
    for d in /etc/pki/ca-trust/source/anchors /usr/local/share/ca-certificates; do
        if [[ -d "$d" ]] && find "$d" -maxdepth 1 -type f \( -name "*.crt" -o -name "*.pem" \) 2>/dev/null | grep -q .; then
            has_custom_ca=1
            info "Custom CA trust anchors found in: $d"
        fi
    done
    if [[ "${has_custom_ca}" == "1" ]]; then
        info "If you are behind TLS-inspecting middleware, ensure pip/npm/docker each trust your CA."
        info "See docs/PROXY_AND_CA.md for per-tool configuration."
    fi
}

_pf_check_port_conflicts() {
    local ports=("${MIRRORET_WEB_PORT:-8080}")
    [[ "${MIRRORET_ENABLE_PIP:-1}" == "1" ]]    && ports+=("${MIRRORET_PIP_PORT:-8081}")
    [[ "${MIRRORET_ENABLE_DOCKER:-1}" == "1" ]] && ports+=("${MIRRORET_DOCKER_REGISTRY_PORT:-5000}")
    [[ "${MIRRORET_ENABLE_NPM:-1}" == "1" ]]    && ports+=("${MIRRORET_NPM_PORT:-4873}")
    [[ "${MIRRORET_TLS_SELF_SIGNED:-0}" == "1" ]] && ports+=("${MIRRORET_TLS_PORT:-8443}")
    [[ -n "${MIRRORET_TLS_CERT:-}" ]]             && ports+=("${MIRRORET_TLS_PORT:-8443}")

    local conflicts=()
    if check_command ss; then
        for p in "${ports[@]}"; do
            if ss -H -lnt "sport = :${p}" 2>/dev/null | grep -q "LISTEN"; then
                conflicts+=("$p")
            fi
        done
    elif check_command netstat; then
        for p in "${ports[@]}"; do
            if netstat -lnt 2>/dev/null | awk '{print $4}' | grep -qE "[.:]${p}\$"; then
                conflicts+=("$p")
            fi
        done
    else
        debug "Neither ss nor netstat available — skipping port-conflict probe."
        return 0
    fi

    if [[ ${#conflicts[@]} -gt 0 ]]; then
        warn "Ports already in use by another process: ${conflicts[*]}"
        warn "Mirroret services will fail to start until those ports are free,"
        warn "or you override the relevant MIRRORET_*_PORT variables."
    fi
}

_pf_check_rhel_subscription() {
    [[ "${DISTRO_TYPE:-}" == "rhel" ]] || return 0
    [[ "${OS_ID:-}" == "rhel" ]]      || return 0

    if ! check_command subscription-manager; then
        warn "OS_ID=rhel but subscription-manager not found."
        warn "Package installation may fail without a valid Red Hat subscription."
        return 0
    fi

    local status
    status="$(subscription-manager status 2>/dev/null | grep -E '^Overall Status:' | awk -F: '{print $2}' | xargs || true)"
    case "${status}" in
        Current|"Simple Content Access"|Disabled)
            # `Current`             = classic entitlements OK
            # `Simple Content Access` = SCA org, no entitlements needed
            # `Disabled`            = subscription checks are turned off (SCA on some newer
            #                         RHEL builds)
            success "RHEL subscription: ${status}"
            ;;
        Registered)
            # RHEL 9 with SCA usually reports "Registered" when queried by a
            # non-root user OR when subscription-manager can't reach the CDN
            # right now. dnf actually still works in most of these cases.
            # Warn but don't scare the operator.
            info "RHEL subscription: Registered (SCA or partial state; dnf should still work)."
            ;;
        "Unknown"|"Not registered"|"Invalid"|"Expired"|"Insufficient")
            warn "RHEL subscription status: ${status}"
            warn "dnf install will likely fail until subscription is renewed."
            ;;
        "")
            warn "Could not determine RHEL subscription status."
            warn "Ensure subscription-manager is configured before running install.sh."
            ;;
        *)
            info "RHEL subscription status: ${status}"
            ;;
    esac
}

# _pf_probe_https <host> <path> — true if we get ANY HTTP response from the
# host's TLS endpoint. 200/301/401/403/404 all count as "reachable" — only
# a TLS handshake failure or connection refusal counts as "unreachable",
# because some upstreams legitimately serve 401 or 404 at /  (Docker
# registry returns 401 at /v2/, 404 at /; npm registry-side healthcheck is
# also picky). We do NOT use curl -f for that reason.
_pf_probe_https() {
    local host="$1" path="${2:-/}"
    local code
    code="$(curl --max-time 8 -sS -o /dev/null \
        -w '%{http_code}' "https://${host}${path}" 2>/dev/null)"
    # 000 = no HTTP response at all (TLS / network failure)
    [[ -n "$code" && "$code" != "000" ]]
}

_pf_check_outbound_https() {
    # Each entry is "host|path". Path defaults to / but we override for
    # endpoints that legitimately don't serve content at /.
    local targets=()
    [[ "${MIRRORET_ENABLE_PIP:-1}" == "1" ]]    && targets+=("pypi.org|/")
    [[ "${MIRRORET_ENABLE_NPM:-1}" == "1" ]]    && targets+=("registry.npmjs.org|/")
    [[ "${MIRRORET_ENABLE_DOCKER:-1}" == "1" ]] && targets+=("registry-1.docker.io|/v2/")
    [[ ${#targets[@]} -eq 0 ]] && return 0

    if ! check_command curl; then
        warn "curl not available — skipping outbound HTTPS probe."
        return 0
    fi

    local failed=() ok=()
    local t host path
    for t in "${targets[@]}"; do
        host="${t%%|*}"
        path="${t#*|}"
        if _pf_probe_https "$host" "$path"; then
            ok+=("$host")
        else
            failed+=("$host")
        fi
    done
    if [[ ${#failed[@]} -gt 0 ]]; then
        warn "Outbound HTTPS check failed for: ${failed[*]}"
        warn "If you are behind a proxy or TLS-inspecting MITM, see docs/PROXY_AND_CA.md."
    fi
    if [[ ${#ok[@]} -gt 0 ]]; then
        success "Outbound HTTPS reachable for: ${ok[*]}"
    fi
}

# Backwards-compat alias: older code called these by their underscore names.
_check_distro_detected() { _pf_check_distro_detected; }
_check_disk_space() { _pf_check_disk_space; }
_check_write_permissions() { _pf_check_write_permissions; }
_check_required_network_tools() { _pf_check_required_network_tools; }

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

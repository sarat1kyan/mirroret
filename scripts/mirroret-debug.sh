#!/usr/bin/env bash
# mirroret-debug.sh - read-only diagnostic snapshot.
#
# Prints a PASS/WARN/FAIL line for each check and ends with a short
# root-cause summary. Reads files, queries systemd, runs `nginx -t`, runs
# `getent hosts`, lists cron lines, and (only when --net is passed)
# attempts outbound HTTPS to upstream registries.
#
# Default mode is fully passive: no installs, no writes, no pushes, no
# pulls. Safe to run on a production host.
#
# Usage:
# sudo ./scripts/mirroret-debug.sh # passive snapshot
# sudo ./scripts/mirroret-debug.sh --net # also test outbound HTTPS
# sudo ./scripts/mirroret-debug.sh --bundle # write a tarball to /tmp
#
# Exit code is the number of FAIL lines (0 = clean).

set -Euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Source the lib modules we'll reuse, but with side-effect-safe defaults.
DRY_RUN=1
MIRRORET_NON_INTERACTIVE=1
LOG_LEVEL=INFO
export DRY_RUN MIRRORET_NON_INTERACTIVE LOG_LEVEL

# shellcheck source=../lib/logging.sh
source "${REPO_DIR}/lib/logging.sh"
# shellcheck source=../lib/common.sh
source "${REPO_DIR}/lib/common.sh"
# shellcheck source=../lib/distro.sh
source "${REPO_DIR}/lib/distro.sh"

# -- Output helpers ------------------------------------------------------------

# Terminal colors only if stdout is a TTY.
if [[ -t 1 ]]; then
    C_PASS="\033[32m"; C_WARN="\033[33m"; C_FAIL="\033[31m"; C_INFO="\033[36m"; C_OFF="\033[0m"
else
    C_PASS=""; C_WARN=""; C_FAIL=""; C_INFO=""; C_OFF=""
fi

PASS_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0
ROOT_CAUSE_HINTS=()

pass() {
    printf "${C_PASS}PASS${C_OFF} %s\n" "$*"
    PASS_COUNT=$(( PASS_COUNT + 1 ))
}
note() {
    printf "${C_INFO}NOTE${C_OFF} %s\n" "$*"
}
warning() {
    printf "${C_WARN}WARN${C_OFF} %s\n" "$*"
    WARN_COUNT=$(( WARN_COUNT + 1 ))
}
failure() {
    printf "${C_FAIL}FAIL${C_OFF} %s\n" "$*"
    FAIL_COUNT=$(( FAIL_COUNT + 1 ))
}
hint() {
    ROOT_CAUSE_HINTS+=("$*")
}
section_h() {
    printf "\n${C_INFO}== %s ==${C_OFF}\n" "$*"
}

# -- Argument parsing ----------------------------------------------------------
RUN_NET=0
DO_BUNDLE=0
for arg in "$@"; do
    case "$arg" in
        --net|--network) RUN_NET=1 ;;
        --bundle) DO_BUNDLE=1 ;;
        -h|--help)
            # Header block only: every comment line after the shebang, up to
            # the first non-comment line. A bare grep dumped every comment in
            # the file.
            awk 'NR==1{next} /^#/{sub(/^# ?/,"");print;next} {exit}' "$0"
            exit 0
            ;;
        *)
            echo "Unknown argument: $arg" >&2
            exit 2
            ;;
    esac
done

# -- Checks --------------------------------------------------------------------

check_user() {
    section_h "Privilege"
    if [[ "$(id -u)" -eq 0 ]]; then
        pass "Running as root"
    else
        warning "Not running as root; some checks will be partial"
        hint "Re-run with sudo for full diagnostics."
    fi
}

check_distro() {
    section_h "Distro"
    if [[ ! -f /etc/os-release ]]; then
        failure "/etc/os-release missing"
        hint "Cannot detect distro; install will refuse to proceed."
        return
    fi
    # shellcheck source=/dev/null
    . /etc/os-release
    pass "Distro: ${ID:-?} ${VERSION_ID:-?} (${PRETTY_NAME:-?})"
    case "${ID:-}" in
        ubuntu|debian|linuxmint|pop|rhel|centos|rocky|almalinux|ol|fedora)
            note "Recognised as a supported distro family."
            ;;
        *)
            warning "Distro ${ID:-?} is not in mirroret's supported list."
            hint "Set MIRRORET_APT_FLAVOR or MIRRORET_RPM_FLAVOR if mirroring a derivative."
            ;;
    esac
}

check_systemd() {
    section_h "systemd"
    if ! command -v systemctl >/dev/null 2>&1; then
        warning "systemctl not found - running on a non-systemd host"
        hint "mirroret manages services with systemd. Service state checks will be skipped."
        return
    fi
    local state
    state="$(systemctl is-system-running 2>/dev/null || true)"
    case "${state}" in
        running) pass "systemd: running" ;;
        degraded) warning "systemd: degraded - at least one unit has failed" ;;
        starting|maintenance) note "systemd: ${state}" ;;
        *) warning "systemd: ${state:-unknown}" ;;
    esac
}

check_selinux() {
    section_h "SELinux"
    local m
    m="$(selinux_mode)"
    case "$m" in
        enforcing)
            pass "SELinux: enforcing"
            if ! command -v setsebool >/dev/null 2>&1 || ! command -v semanage >/dev/null 2>&1; then
                warning "SELinux tools missing (semanage / setsebool)"
                hint "Install policycoreutils-python-utils. Without it, nginx will 502 on /pip /npm /v2."
            fi
            if command -v getsebool >/dev/null 2>&1; then
                local val
                val="$(getsebool httpd_can_network_connect 2>/dev/null | awk -F'-->' '{gsub(/ /, "", $2); print $2}')"
                if [[ "$val" == "on" ]]; then
                    pass "SELinux boolean httpd_can_network_connect = on"
                else
                    failure "SELinux boolean httpd_can_network_connect is OFF"
                    hint "Run: setsebool -P httpd_can_network_connect 1"
                fi
            fi
            ;;
        permissive)
            note "SELinux: permissive (policy loaded but not enforced)"
            ;;
        disabled|absent)
            note "SELinux: ${m}"
            ;;
    esac
}

check_disk() {
    section_h "Disk"
    local base_dir="${MIRRORET_BASE_DIR:-/srv/mirroret}"
    local check_dir="$base_dir"
    while [[ ! -d "$check_dir" ]] && [[ "$check_dir" != "/" ]]; do
        check_dir="$(dirname "$check_dir")"
    done
    local avail_kb avail_gb
    avail_kb="$(df -k "$check_dir" 2>/dev/null | awk 'NR==2 {print $4}')"
    if [[ -z "$avail_kb" ]]; then
        warning "Could not determine disk space on ${check_dir}"
        return
    fi
    avail_gb=$(( avail_kb / 1024 / 1024 ))
    if [[ "$avail_gb" -lt 10 ]]; then
        failure "Disk critically low on ${check_dir}: ${avail_gb} GB"
        hint "Free at least 50 GB on ${check_dir} or expand the volume."
    elif [[ "$avail_gb" -lt 50 ]]; then
        warning "Disk low on ${check_dir}: ${avail_gb} GB (recommended >= 50 GB)"
    else
        pass "Disk on ${check_dir}: ${avail_gb} GB available"
    fi
}

check_proxy_env() {
    section_h "Proxy environment"
    local found=0
    for v in http_proxy HTTP_PROXY https_proxy HTTPS_PROXY no_proxy NO_PROXY; do
        if [[ -n "${!v:-}" ]]; then
            note "${v}=${!v}"
            found=1
        fi
    done
    if [[ "$found" -eq 0 ]]; then
        note "No proxy env variables set in this shell."
    fi
    if [[ -n "${SUDO_USER:-}" ]] && [[ "${SUDO_USER}" != "root" ]]; then
        local user_home
        user_home="$(getent passwd "${SUDO_USER}" 2>/dev/null | cut -d: -f6 || true)"
        if [[ -n "${user_home}" ]] && \
           grep -lE '^[^#]*([hH][tT][tT][pP]_proxy|HTTPS?_proxy)=' \
               "${user_home}/.bashrc" "${user_home}/.profile" "${user_home}/.bash_profile" 2>/dev/null | head -1 >/dev/null; then
            if [[ "$found" -eq 0 ]]; then
                warning "Proxy variables exist in ${SUDO_USER}'s shell rc but NOT in this sudo session."
                hint "Run sudo with -E, e.g.: sudo -E ./install.sh"
            fi
        fi
    fi
}

check_ca_trust() {
    section_h "CA trust"
    local custom=0
    for d in /etc/pki/ca-trust/source/anchors /usr/local/share/ca-certificates; do
        if [[ -d "$d" ]] && find "$d" -maxdepth 1 -type f \( -name "*.crt" -o -name "*.pem" \) 2>/dev/null | grep -q .; then
            note "Custom CA anchors present in $d"
            custom=1
        fi
    done
    if [[ "$custom" -eq 0 ]]; then
        note "No custom CA anchors detected."
    fi
    # Rootless Podman per-user CA path
    if [[ -n "${SUDO_USER:-}" ]] && [[ "${SUDO_USER}" != "root" ]]; then
        local user_home
        user_home="$(getent passwd "${SUDO_USER}" 2>/dev/null | cut -d: -f6 || true)"
        if [[ -n "${user_home}" ]] && [[ -d "${user_home}/.config/containers/certs.d" ]]; then
            note "Rootless Podman CA dir present: ${user_home}/.config/containers/certs.d"
        fi
    fi
}

check_dns() {
    section_h "DNS"
    local hosts=()
    [[ "${MIRRORET_ENABLE_APT:-1}" == "1" ]] && case "${ID:-}" in
        debian) hosts+=(deb.debian.org) ;;
        *) hosts+=(archive.ubuntu.com) ;;
    esac
    [[ "${MIRRORET_ENABLE_RPM:-1}" == "1" ]] && case "${ID:-}" in
        rocky|almalinux) hosts+=(dl.rockylinux.org) ;;
        rhel) hosts+=(cdn.redhat.com) ;;
        ol) hosts+=(yum.oracle.com) ;;
        fedora) hosts+=(dl.fedoraproject.org) ;;
        centos) hosts+=(mirror.stream.centos.org) ;;
    esac
    [[ "${MIRRORET_ENABLE_PIP:-1}" == "1" ]] && hosts+=(pypi.org)
    [[ "${MIRRORET_ENABLE_DOCKER:-1}" == "1" ]] && hosts+=(registry-1.docker.io)
    [[ "${MIRRORET_ENABLE_NPM:-1}" == "1" ]] && hosts+=(registry.npmjs.org)
    [[ ${#hosts[@]} -eq 0 ]] && { note "Nothing to resolve."; return; }

    local fails=()
    for h in "${hosts[@]}"; do
        if ! getent hosts "$h" >/dev/null 2>&1; then
            fails+=("$h")
        fi
    done
    if [[ ${#fails[@]} -gt 0 ]]; then
        warning "DNS resolution failed for: ${fails[*]}"
        hint "Check /etc/resolv.conf, corporate DNS, and any proxy. See docs/PROXY_AND_CA.md."
    else
        pass "DNS resolved ${#hosts[@]} upstream host(s)"
    fi
}

check_ports() {
    section_h "Listening ports"
    local ports=("${MIRRORET_WEB_PORT:-8080}" "${MIRRORET_PIP_PORT:-8081}" "${MIRRORET_DOCKER_REGISTRY_PORT:-5000}" "${MIRRORET_NPM_PORT:-4873}")
    if ! command -v ss >/dev/null 2>&1 && ! command -v netstat >/dev/null 2>&1; then
        warning "Neither ss nor netstat available - cannot probe ports."
        return
    fi
    for p in "${ports[@]}"; do
        local who=""
        if command -v ss >/dev/null 2>&1; then
            who="$(ss -H -lntp "sport = :${p}" 2>/dev/null | head -1 || true)"
        else
            who="$(netstat -lntp 2>/dev/null | awk -v p="$p" '$4 ~ ":"p"$" {print; exit}')"
        fi
        if [[ -n "$who" ]]; then
            note "Port ${p} is listening: ${who}"
        else
            note "Port ${p}: free"
        fi
    done
}

check_services() {
    section_h "Services"
    if ! command -v systemctl >/dev/null 2>&1; then
        warning "systemctl missing - skipping."
        return
    fi
    for svc in nginx pypiserver verdaccio docker-distribution docker-registry mirroret-registry; do
        if systemctl list-unit-files --full --no-legend "${svc}.service" 2>/dev/null | grep -q "${svc}.service"; then
            local state
            state="$(systemctl is-active "$svc" 2>/dev/null || true)"
            case "${state}" in
                active)
                    pass "${svc}: active"
                    ;;
                inactive)
                    note "${svc}: inactive (not started)"
                    ;;
                failed)
                    failure "${svc}: failed"
                    hint "Check: journalctl -u ${svc} -n 100 --no-pager"
                    ;;
                *)
                    note "${svc}: ${state:-unknown}"
                    ;;
            esac
        fi
    done
}

check_nginx_config() {
    section_h "nginx config"
    if ! command -v nginx >/dev/null 2>&1; then
        note "nginx not installed."
        return
    fi
    if nginx -t >/dev/null 2>&1; then
        pass "nginx -t succeeds"
    else
        failure "nginx -t FAILED"
        hint "Run 'nginx -t' for detail. Common causes: missing log dir, port collision, bad cert paths."
    fi
}

check_repo_files() {
    section_h "Mirroret tree"
    local base="${MIRRORET_BASE_DIR:-/srv/mirroret}"
    if [[ ! -d "$base" ]]; then
        warning "${base} does not exist"
        hint "Has install.sh been run? Re-run sudo ./install.sh --check after install."
        return
    fi
    for d in scripts config logs engines; do
        if [[ -d "${base}/${d}" ]]; then
            pass "${base}/${d}: present"
        else
            warning "${base}/${d}: missing"
        fi
    done
}

# check_targets - which distributions this server mirrors, and whether each
# has actually synced.
#
# The failure this exists to catch is silence: a server configured with no
# APT target downloads no .deb and reports nothing wrong, because doing
# nothing is exactly what it was told to do.
check_targets() {
    section_h "Mirror targets"
    local base="${MIRRORET_BASE_DIR:-/srv/mirroret}"
    local tdir="${MIRRORET_TARGETS_DIR:-/etc/mirroret/targets}"

    if ! command -v python3 >/dev/null 2>&1; then
        failure "python3 is not installed. Both mirroring engines need it."
        hint "Install it: dnf install python3   (or apt-get install python3)"
        return
    fi
    pass "python3: $(python3 -V 2>&1)"

    local n_apt=0 n_rpm=0 f
    if [[ -d "$tdir" ]]; then
        for f in "$tdir"/apt-*.json; do [[ -f "$f" ]] && n_apt=$(( n_apt + 1 )); done
        for f in "$tdir"/rpm-*.json; do [[ -f "$f" ]] && n_rpm=$(( n_rpm + 1 )); done
    fi

    # APT
    if [[ "$n_apt" -gt 0 ]]; then
        local suites
        suites="$(find "${base}/apt" -mindepth 3 -maxdepth 3 -path '*/dists/*' \
                    -type d 2>/dev/null | wc -l | tr -d ' ')"
        local published=0 d
        while IFS= read -r d; do
            [[ -z "$d" ]] && continue
            if [[ -f "${d}/Release" ]] || [[ -f "${d}/InRelease" ]]; then
                published=$(( published + 1 ))
            fi
        done < <(find "${base}/apt" -mindepth 3 -maxdepth 3 -path '*/dists/*' \
                      -type d 2>/dev/null)
        if [[ "$published" -gt 0 ]]; then
            pass "APT: ${n_apt} target(s), ${published}/${suites} suite(s) published"
        else
            warning "APT: ${n_apt} target(s) configured but no suite published yet"
            hint "Run the first sync: sudo ${base}/scripts/sync-apt-repos.sh"
        fi
    elif [[ -f "${base}/scripts/sync-apt-debmirror.sh" ]] || [[ -f /etc/apt/mirror.list ]]; then
        note "APT: using a legacy mirroring tool (no native targets)"
    else
        warning "APT: no target configured, so no .deb is ever downloaded"
        hint "This is silent by design - nothing errors because nothing was asked for."
        hint "If Debian/Ubuntu clients should use this server, set:"
        hint "  MIRRORET_APT_TARGETS=\"ubuntu:jammy debian:bookworm\""
        hint "in /etc/mirroret/mirroret.conf, then: sudo ./install.sh --upgrade"
    fi

    # RPM
    if [[ "$n_rpm" -gt 0 ]]; then
        local repos
        repos="$(find "${base}/redhat/mirror" -name repomd.xml 2>/dev/null | wc -l | tr -d ' ')"
        if [[ "$repos" -gt 0 ]]; then
            pass "RPM: ${n_rpm} target(s), ${repos} repo(s) with published metadata"
        else
            warning "RPM: ${n_rpm} target(s) configured but no repo published yet"
            hint "Run the first sync: sudo ${base}/scripts/sync-rpm-repos.sh"
        fi
    elif [[ -f "${base}/scripts/sync-redhat-repos.sh" ]]; then
        note "RPM: using the legacy reposync path (no native targets)"
    else
        warning "RPM: no target configured"
        hint "Set MIRRORET_RPM_TARGETS=\"ol:9 rocky:9\" and re-run install.sh --upgrade"
    fi

    note "Full per-target detail: mirroretctl targets"
}

check_recent_sync_logs() {
    section_h "Recent sync logs"
    local base="${MIRRORET_BASE_DIR:-/srv/mirroret}"
    local logs="${base}/logs"
    if [[ ! -d "$logs" ]]; then
        note "No log directory (mirror not yet synced)."
        return
    fi
    local latest
    latest="$(find "$logs" -maxdepth 1 -name 'sync-*.log' -printf '%T@ %p\n' 2>/dev/null | sort -nr | head -5 | awk '{print $2}')"
    if [[ -z "$latest" ]]; then
        note "No sync-*.log entries yet."
        return
    fi
    printf "%s\n" "$latest" | while IFS= read -r f; do
        note "$(basename "$f") $(wc -l < "$f") lines last: $(tail -1 "$f" 2>/dev/null)"
    done
}

check_cron() {
    section_h "Cron"
    if ! command -v crontab >/dev/null 2>&1; then
        warning "crontab not installed."
        return
    fi
    local entries
    entries="$(crontab -l 2>/dev/null || true)"
    if [[ -z "$entries" ]]; then
        note "Root crontab is empty."
        return
    fi
    local managed
    managed="$(printf '%s\n' "$entries" | awk '/>>> mirroret managed/{f=1;next}/<<< mirroret managed/{f=0}f')"
    if [[ -n "$managed" ]]; then
        pass "mirroret cron block present"
        printf '%s\n' "$managed" | sed 's/^/ /'
    else
        warning "No mirroret cron block found in root crontab."
    fi
}

check_outbound_https() {
    [[ "$RUN_NET" -eq 1 ]] || { note "Network probes disabled (pass --net to enable)."; return; }
    section_h "Outbound HTTPS"
    if ! command -v curl >/dev/null 2>&1; then
        warning "curl missing - cannot probe."
        return
    fi
    # host|path|expected_codes - many upstreams legitimately return 401 or
    # 404 at /, so we treat ANY HTTP response (not just 2xx) as success.
    # 000 = TLS/network failure, which is what we actually want to flag.
    local targets=()
    [[ "${MIRRORET_ENABLE_PIP:-1}" == "1" ]] && targets+=("pypi.org|/" "files.pythonhosted.org|/")
    [[ "${MIRRORET_ENABLE_NPM:-1}" == "1" ]] && targets+=("registry.npmjs.org|/")
    # Docker Hub registry returns 401 at /v2/ and 404 at /. Both prove it's
    # reachable. Auth service returns 404 at / but 400 at /token (no args).
    [[ "${MIRRORET_ENABLE_DOCKER:-1}" == "1" ]] && targets+=("registry-1.docker.io|/v2/" "auth.docker.io|/token")

    local t host path code
    for t in "${targets[@]}"; do
        host="${t%%|*}"
        path="${t#*|}"
        code="$(curl --max-time 8 -sS -o /dev/null -w '%{http_code}' \
            "https://${host}${path}" 2>/dev/null)"
        if [[ -n "$code" && "$code" != "000" ]]; then
            pass "HTTPS reachable: ${host}${path} (HTTP ${code})"
        else
            failure "HTTPS unreachable: ${host}${path} (no response)"
            hint "Check proxy, DNS, and CA trust. docs/PROXY_AND_CA.md has per-tool config."
        fi
    done
}

check_docker_mode() {
    section_h "Docker registry mode"
    local conf=""
    for c in /etc/docker/registry/config.yml /etc/docker-distribution/registry/config.yml; do
        [[ -f "$c" ]] && conf="$c" && break
    done
    if [[ -z "$conf" ]]; then
        note "No registry config.yml found yet."
        return
    fi
    note "Config: $conf"
    if grep -q '^proxy:' "$conf"; then
        if grep -q 'remoteurl:' "$conf"; then
            pass "Registry mode: cache (proxy.remoteurl present)"
            if [[ -x "${MIRRORET_BASE_DIR:-/srv/mirroret}/scripts/sync-docker-images.sh" ]]; then
                failure "Active sync-docker-images.sh found in cache mode - it will fail (registry rejects pushes)"
                hint "Run install.sh with MIRRORET_DOCKER_MODE=hosted, OR move/remove sync-docker-images.sh."
            fi
        fi
    else
        pass "Registry mode: hosted (no proxy block)"
    fi
}

check_apt_signed_by() {
    section_h "APT client config"
    local cfg="${MIRRORET_BASE_DIR:-/srv/mirroret}/config/debian-client.list"
    [[ -f "$cfg" ]] || { note "No generated client list yet."; return; }
    if grep -q 'signed-by=' "$cfg" && grep -q '/mirroret.gpg' "$cfg"; then
        if [[ "${MIRRORET_APT_RESIGN:-0}" != "1" ]]; then
            failure "APT client points signed-by= at mirroret.gpg but MIRRORET_APT_RESIGN is not set."
            hint "Mirrored Release files are signed by the upstream, not by mirroret. apt update will fail."
            hint "Re-run install.sh with MIRRORET_APT_RESIGN=0 (default), OR re-sign manually."
        else
            pass "APT signed-by points at mirroret.gpg AND resign mode is on"
        fi
    else
        pass "APT signed-by configuration looks correct"
    fi
}

# -- Optional bundle output ----------------------------------------------------

write_bundle() {
    local out stage
    out="/tmp/mirroret-debug-bundle-$(date +%Y%m%d-%H%M%S).tar.gz"
    stage="$(mktemp -d /tmp/mirroret-debug-XXXXXX)"

    # nginx config (filenames only, redacted of secrets is just configs)
    cp /etc/nginx/nginx.conf "${stage}/nginx.conf" 2>/dev/null || true
    [[ -d /etc/nginx/conf.d ]] && cp -a /etc/nginx/conf.d "${stage}/conf.d" 2>/dev/null || true
    [[ -d /etc/nginx/sites-available ]] && cp -a /etc/nginx/sites-available "${stage}/sites-available" 2>/dev/null || true
    # systemd units
    for u in pypiserver verdaccio mirroret-registry docker-distribution docker-registry; do
        systemctl cat "${u}.service" 2>/dev/null > "${stage}/${u}.service.unit" || true
        journalctl -u "$u" -n 200 --no-pager 2>/dev/null > "${stage}/${u}.journal" || true
    done
    # Recent sync logs
    if [[ -d "${MIRRORET_BASE_DIR:-/srv/mirroret}/logs" ]]; then
        find "${MIRRORET_BASE_DIR:-/srv/mirroret}/logs" -maxdepth 1 -name 'sync-*.log' -printf '%T@ %p\n' \
            2>/dev/null | sort -nr | head -10 | awk '{print $2}' | xargs -r -I{} cp {} "${stage}/" 2>/dev/null || true
    fi
    # System inventory
    cp /etc/os-release "${stage}/os-release" 2>/dev/null || true
    df -h > "${stage}/df.txt" 2>/dev/null || true
    crontab -l 2>/dev/null > "${stage}/root-crontab.txt" || true
    if command -v ss >/dev/null 2>&1; then
        ss -lntp 2>/dev/null > "${stage}/listening-ports.txt" || true
    fi
    if command -v selinux_mode >/dev/null 2>&1; then
        echo "selinux: $(selinux_mode)" > "${stage}/selinux.txt"
    fi

    tar -czf "$out" -C "$(dirname "$stage")" "$(basename "$stage")" 2>/dev/null
    rm -rf "$stage"
    note "Bundle written: $out"
}

# -- Main ----------------------------------------------------------------------

main() {
    printf "${C_INFO}mirroret-debug.sh - read-only diagnostic snapshot${C_OFF}\n"
    printf "Date: %s\n" "$(date '+%Y-%m-%d %H:%M:%S')"
    printf "Host: %s\n" "$(hostname 2>/dev/null || echo unknown)"
    printf "User: %s (uid=%s)\n" "$(id -un)" "$(id -u)"
    printf "Repo: %s\n" "${REPO_DIR}"

    check_user
    check_distro
    check_systemd
    check_selinux
    check_disk
    check_proxy_env
    check_ca_trust
    check_dns
    check_ports
    check_services
    check_nginx_config
    check_repo_files
    check_targets
    check_docker_mode
    check_apt_signed_by
    check_cron
    check_recent_sync_logs
    check_outbound_https

    section_h "Summary"
    printf "${C_PASS}PASS:${C_OFF} %d ${C_WARN}WARN:${C_OFF} %d ${C_FAIL}FAIL:${C_OFF} %d\n" \
        "$PASS_COUNT" "$WARN_COUNT" "$FAIL_COUNT"

    if [[ ${#ROOT_CAUSE_HINTS[@]} -gt 0 ]]; then
        printf "\nLikely root causes / actions:\n"
        local i=1
        for h in "${ROOT_CAUSE_HINTS[@]}"; do
            printf " %d. %s\n" "$i" "$h"
            i=$(( i + 1 ))
        done
    fi

    [[ "$DO_BUNDLE" -eq 1 ]] && write_bundle

    exit "$FAIL_COUNT"
}

main "$@"

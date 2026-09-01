#!/usr/bin/env bash
# mirroret-collect.sh - exhaustive read-only evidence collector.
#
# Writes ONE plain-text report describing the entire state of a mirroret
# host: OS, SELinux, firewall, disk, config, generated scripts, systemd
# units, nginx, ports, cron, repo contents, approval staging, retention,
# locks, proxy, CA trust, DNS, outbound reachability, client-facing HTTP
# self-tests, tool versions and log tails. The report opens with an
# auto-computed FINDINGS section so the important lines are at the top.
#
# This script is READ ONLY. It never installs, writes, deletes, restarts,
# pulls or pushes anything. The only file it creates is the report.
#
# It is deliberately standalone: it sources nothing from lib/, so it can be
# copied to a host on its own and still run when the install is broken.
#
# Usage:
#   sudo ./scripts/mirroret-collect.sh
#   sudo ./scripts/mirroret-collect.sh -o /tmp/report.txt
#   sudo ./scripts/mirroret-collect.sh --no-net      # skip outbound tests
#   sudo ./scripts/mirroret-collect.sh --deep        # add slow inventory
#
# Run with sudo for a complete report. Without root it still works but
# systemd unit contents, journal output and some config files are skipped;
# every skip is recorded explicitly so nothing looks clean by omission.
#
# Secrets are redacted: any password/token/secret/key/auth assignment and
# any user:pass@host proxy URL is masked before being written. Private key
# files are never read, only fingerprinted.

# NOTE: no 'set -e', no 'pipefail', no ERR trap. A collector must survive
# every failing probe. A missing binary or unreadable file has to become a
# recorded line, not an aborted report. 'pipefail' would also turn ordinary
# 'cmd | head' SIGPIPE into a spurious failure.
set -u

COLLECT_VERSION="1.1"

# Many probes cannot succeed without root: reading root's crontab, reading
# 0600 nginx configs, listing another user's containers. Findings that depend
# on them must not be reported as FAIL when the cause is simply privilege.
IS_ROOT=0
[[ "$(id -u)" -eq 0 ]] && IS_ROOT=1

# -- Defaults ------------------------------------------------------------------

CONF_FILE="${MIRRORET_CONFIG_FILE:-/etc/mirroret/mirroret.conf}"
OUT_FILE=""
DO_NET=1
DO_DEEP=0
MAX_CAPTURE_BYTES=200000
LOG_TAIL_LINES=80
# Wall-clock ceiling per probe. Without this, one blocked call (a hung NFS
# mount under the base dir, a dead container daemon, reverse DNS on every
# socket) stalls the whole run and the operator gets no report at all.
CAP_TIMEOUT="${MIRRORET_COLLECT_TIMEOUT:-25}"

# -- Argument parsing ----------------------------------------------------------

while [[ $# -gt 0 ]]; do
    case "$1" in
        -o|--output) shift; OUT_FILE="${1:-}" ;;
        --no-net)    DO_NET=0 ;;
        --timeout)   shift; CAP_TIMEOUT="${1:-25}" ;;
        --deep)      DO_DEEP=1 ;;
        --conf)      shift; CONF_FILE="${1:-}" ;;
        -h|--help)
            grep '^#' "$0" | sed 's/^# \{0,1\}//' | head -32
            exit 0 ;;
        *)
            echo "Unknown option: $1 (try --help)" >&2
            exit 2 ;;
    esac
    shift
done

TIMEOUT_BIN=""
for t in timeout gtimeout; do
    if command -v "$t" >/dev/null 2>&1; then TIMEOUT_BIN="$t"; break; fi
done

HOSTNAME_SHORT="$(hostname -s 2>/dev/null || echo unknown)"
STAMP="$(date +%Y%m%d-%H%M%S 2>/dev/null || echo nodate)"
if [[ -z "${OUT_FILE}" ]]; then
    OUT_FILE="/tmp/mirroret-report-${HOSTNAME_SHORT}-${STAMP}.txt"
fi

BODY="$(mktemp "${TMPDIR:-/tmp}/mirroret-collect-body.XXXXXX")" || {
    echo "Cannot create temp file." >&2; exit 1; }
FINDINGS_FILE="$(mktemp "${TMPDIR:-/tmp}/mirroret-collect-find.XXXXXX")" || {
    echo "Cannot create temp file." >&2; exit 1; }
# shellcheck disable=SC2329  # invoked by the EXIT trap below
cleanup() { rm -f "${BODY}" "${FINDINGS_FILE}"; }
trap cleanup EXIT

# -- Redaction -----------------------------------------------------------------

# Masks credential-shaped text on stdin. Applied to every captured block,
# because the resulting report is intended to be shared off the host.
redact() {
    # Strip control bytes first. Captured output can contain binary (a log
    # tail, a package name, a daemon dump); left in, it makes the finished
    # report unusable with grep, sed and awk.
    tr -d '\000-\010\013\014\016-\037' \
    | LC_ALL=C sed -E \
        -e 's/((password|passwd|secret|token|api[_-]?key|auth[a-z_]*)[[:space:]]*[:=][[:space:]]*)[^[:space:]]+/\1***REDACTED***/Ig' \
        -e 's#((https?|ftp)://)[^:/@[:space:]]+:[^@[:space:]]+@#\1***REDACTED***@#g' \
        -e 's/(-----BEGIN [A-Z ]*PRIVATE KEY-----).*/\1 ***CONTENT WITHHELD***/' \
        -e 's/(Authorization:[[:space:]]*)[^[:space:]]+/\1***REDACTED***/Ig'
}

# -- Report primitives ---------------------------------------------------------

SECTION_NUM=0

out() { printf '%s\n' "$*" >>"${BODY}"; }

sec() {
    SECTION_NUM=$((SECTION_NUM + 1))
    {
        printf '\n\n'
        printf '===============================================================================\n'
        printf '== [%02d] %s\n' "${SECTION_NUM}" "$*"
        printf '===============================================================================\n'
    } >>"${BODY}"
    printf '  [%02d] %s\n' "${SECTION_NUM}" "$*" >&2
}

sub() { printf '\n--- %s ---\n' "$*" >>"${BODY}"; }

# cap <label> <command> [args...]
# Records the command line, its output (redacted, size-capped) and exit code.
# A missing binary is recorded rather than executed.
cap() {
    local label="$1"; shift
    sub "${label}"
    printf '$ %s\n' "$*" >>"${BODY}"
    if ! command -v "$1" >/dev/null 2>&1; then
        out "[binary not available: $1]"
        return 0
    fi
    local out_text rc
    if [[ -n "${TIMEOUT_BIN}" ]]; then
        out_text="$("${TIMEOUT_BIN}" -k 5 "${CAP_TIMEOUT}" "$@" 2>&1)"; rc=$?
    else
        out_text="$("$@" 2>&1)"; rc=$?
    fi
    printf '%s\n' "${out_text}" | redact | head -c "${MAX_CAPTURE_BYTES}" >>"${BODY}"
    note_timeout "${rc}" "${label}"
    out "[exit ${rc}]"
    return 0
}

# caps <label> <shell snippet>
# For pipelines, globs and redirections. Same recording contract as cap.
caps() {
    local label="$1"; shift
    sub "${label}"
    printf '$ %s\n' "$*" >>"${BODY}"
    local out_text rc
    if [[ -n "${TIMEOUT_BIN}" ]]; then
        out_text="$("${TIMEOUT_BIN}" -k 5 "${CAP_TIMEOUT}" bash -c "$*" 2>&1)"; rc=$?
    else
        out_text="$(bash -c "$*" 2>&1)"; rc=$?
    fi
    printf '%s\n' "${out_text}" | redact | head -c "${MAX_CAPTURE_BYTES}" >>"${BODY}"
    note_timeout "${rc}" "${label}"
    out "[exit ${rc}]"
    return 0
}

# _mtime <path> - epoch seconds, GNU stat then BSD stat.
_mtime() {
    stat -c '%Y' "$1" 2>/dev/null || stat -f '%m' "$1" 2>/dev/null || echo 0
}

# _newest_rpm_mtime <dir> - epoch seconds of the newest .rpm beneath dir.
_newest_rpm_mtime() {
    local d="$1" t
    t="$(find "$d" -name '*.rpm' -printf '%T@\n' 2>/dev/null \
         | sort -rn | head -1 | cut -d. -f1)"
    if [[ -n "${t}" ]]; then printf '%s' "${t}"; return 0; fi
    # No -printf (BSD find): compare one at a time, capped so a huge tree
    # cannot make the collector crawl.
    local f best=0 m n=0
    while read -r f; do
        m="$(_mtime "$f")"
        [[ "${m}" -gt "${best}" ]] && best="${m}"
        n=$(( n + 1 )); [[ "${n}" -ge 2000 ]] && break
    done < <(find "$d" -name '*.rpm' 2>/dev/null)
    printf '%s' "${best}"
}

# note_timeout <rc> <label>
# 124 is timeout's own exit code; 137 is SIGKILL after -k. Either means the
# probe was cut off, which is a finding in its own right.
note_timeout() {
    local rc="$1" label="$2"
    if [[ "${rc}" -eq 124 || "${rc}" -eq 137 ]]; then
        out "[TIMED OUT after ${CAP_TIMEOUT}s and was killed]"
        TIMED_OUT_PROBES="${TIMED_OUT_PROBES:-}${TIMED_OUT_PROBES:+, }${label}"
    fi
}

# catfile <path> [max_lines]
# Dumps a file with redaction, or records exactly why it could not be read.
catfile() {
    local f="$1" maxl="${2:-500}"
    sub "file: ${f}"
    if [[ ! -e "$f" ]]; then out "[missing]"; return 0; fi
    if [[ -d "$f" ]]; then out "[is a directory]"; return 0; fi
    if [[ ! -r "$f" ]]; then
        out "[not readable by uid $(id -u); re-run with sudo]"
        caps "stat ${f}" "stat -c '%A %U:%G %s bytes %y' '$f'"
        return 0
    fi
    caps "stat ${f}" "stat -c '%A %U:%G %s bytes mtime=%y' '$f'"
    out "-- contents (first ${maxl} lines) --"
    head -n "${maxl}" "$f" 2>/dev/null | redact >>"${BODY}"
    local total
    total="$(wc -l <"$f" 2>/dev/null || echo 0)"
    if [[ "${total}" -gt "${maxl}" ]]; then
        out "[truncated: ${total} lines total]"
    fi
    return 0
}

# finding <SEVERITY> <text>
# SEVERITY is FAIL, WARN or INFO. Collected and printed at the top.
finding() {
    printf '%-4s %s\n' "$1" "$2" >>"${FINDINGS_FILE}"
}

have() { command -v "$1" >/dev/null 2>&1; }

# -- Load config (in a subshell probe, never into this shell) -------------------
#
# The conf file is shell syntax. Sourcing it here would let a stray line
# clobber this script's own variables, so values are extracted one at a
# time from a sandboxed subshell instead.
# conf_get <key> [default] - resolve a setting the way the running install does.
#
# Precedence: the config file (which is what install.sh honours), then this
# process's environment, then the built-in default. The environment fallback
# matters: this collector is what you run when the install is broken, and on a
# host with no config file yet an operator who exported MIRRORET_BASE_DIR
# would otherwise get a report about /srv/mirroret while their data sits
# somewhere else entirely.
conf_get() {
    local key="$1" def="${2:-}"
    if [[ -r "${CONF_FILE}" ]]; then
        local v
        v="$(bash -c "set +u; source '${CONF_FILE}' >/dev/null 2>&1; printf '%s' \"\${${key}:-}\"" 2>/dev/null)"
        if [[ -n "${v}" ]]; then printf '%s' "${v}"; return 0; fi
    fi
    local env_v="${!key:-}"
    if [[ -n "${env_v}" ]]; then printf '%s' "${env_v}"; return 0; fi
    printf '%s' "${def}"
}

BASE_DIR="$(conf_get MIRRORET_BASE_DIR /srv/mirroret)"
WEB_PORT="$(conf_get MIRRORET_WEB_PORT 8080)"
PIP_PORT="$(conf_get MIRRORET_PIP_PORT 8081)"
NPM_PORT="$(conf_get MIRRORET_NPM_PORT 4873)"
REG_PORT="$(conf_get MIRRORET_DOCKER_REGISTRY_PORT 5000)"
DOCKER_MODE="$(conf_get MIRRORET_DOCKER_MODE cache)"
RPM_ARCH="$(conf_get MIRRORET_RPM_ARCH x86_64)"
RPM_REPOS="$(conf_get MIRRORET_RPM_REPOS "")"
APPROVAL="$(conf_get MIRRORET_APPROVAL_ENABLED 0)"
RHEL_VER="$(conf_get MIRRORET_RHEL_VERSION "")"
LOGS_DIR="${BASE_DIR}/logs"
SCRIPTS_DIR="${BASE_DIR}/scripts"

echo "mirroret-collect ${COLLECT_VERSION}: writing ${OUT_FILE}" >&2
echo "Sections:" >&2

# =============================================================================
# 01  Collection metadata
# =============================================================================
sec "COLLECTION METADATA"
out "collector version : ${COLLECT_VERSION}"
out "generated         : $(date -Is 2>/dev/null || date)"
out "host              : $(hostname -f 2>/dev/null || hostname 2>/dev/null || echo unknown)"
out "invoked as uid    : $(id -u) ($(id -un 2>/dev/null || echo '?'))"
out "root privileges   : $([[ "$(id -u)" -eq 0 ]] && echo yes || echo 'NO - report is incomplete')"
out "outbound tests    : $([[ "${DO_NET}" -eq 1 ]] && echo enabled || echo 'disabled (--no-net)')"
out "deep inventory    : $([[ "${DO_DEEP}" -eq 1 ]] && echo enabled || echo 'disabled (pass --deep)')"
out "config file       : ${CONF_FILE}"
out "base dir          : ${BASE_DIR}"
out ""
out "Resolved settings used by this report:"
out "  MIRRORET_WEB_PORT=${WEB_PORT}  PIP=${PIP_PORT}  NPM=${NPM_PORT}  REGISTRY=${REG_PORT}"
out "  MIRRORET_DOCKER_MODE=${DOCKER_MODE}"
out "  MIRRORET_RPM_ARCH=${RPM_ARCH}"
out "  MIRRORET_RPM_REPOS=${RPM_REPOS:-<default for distro>}"
out "  MIRRORET_APPROVAL_ENABLED=${APPROVAL}"
out "  MIRRORET_RHEL_VERSION=${RHEL_VER:-<autodetect>}"

if [[ "$(id -u)" -ne 0 ]]; then
    finding WARN "Collected without root. systemd unit bodies, journal output and some config files were skipped. Re-run with sudo for a complete report."
fi

# =============================================================================
# 02  Host and OS
# =============================================================================
sec "HOST AND OPERATING SYSTEM"
catfile /etc/os-release
catfile /etc/redhat-release 5
catfile /etc/debian_version 5
cap "uname" uname -a
cap "uptime" uptime
cap "cpu and memory" free -h
caps "cpu count" "nproc 2>/dev/null || grep -c ^processor /proc/cpuinfo"
cap "virtualisation" systemd-detect-virt
caps "timezone and clock" "timedatectl 2>/dev/null || date"

OS_ID="$(bash -c "set +u; source /etc/os-release 2>/dev/null; printf '%s' \"\${ID:-unknown}\"")"
OS_VER="$(bash -c "set +u; source /etc/os-release 2>/dev/null; printf '%s' \"\${VERSION_ID:-unknown}\"")"
MACHINE_ARCH="$(uname -m 2>/dev/null || echo unknown)"
out ""
out "parsed: OS_ID=${OS_ID} VERSION_ID=${OS_VER} arch=${MACHINE_ARCH}"

case "${OS_ID}" in
    rhel|centos|rocky|almalinux|ol|oracle|fedora) DISTRO_FAMILY=rhel ;;
    debian|ubuntu|linuxmint|pop)                  DISTRO_FAMILY=debian ;;
    *)                                            DISTRO_FAMILY=unknown ;;
esac
out "distro family: ${DISTRO_FAMILY}"
if [[ "${DISTRO_FAMILY}" == "unknown" ]]; then
    finding WARN "Unrecognised distro ID '${OS_ID}'. mirroret picks APT vs RPM paths from this value, so mirroring may be misconfigured."
fi

# =============================================================================
# 03  init system
# =============================================================================
sec "INIT SYSTEM"
caps "pid 1" "ps -p 1 -o comm= 2>/dev/null"
cap "systemd version" systemctl --version
if ! have systemctl; then
    finding FAIL "No systemctl on this host. mirroret generates systemd units for pypiserver, Verdaccio and the registry; none of them can run here."
fi
caps "failed units (whole system)" "systemctl --failed --no-legend --no-pager 2>/dev/null"

# =============================================================================
# 04  SELinux and AppArmor
# =============================================================================
sec "SELINUX AND APPARMOR"
cap "getenforce" getenforce
cap "sestatus" sestatus
catfile /etc/selinux/config 30
SEL_MODE="$(getenforce 2>/dev/null || echo none)"
out ""
out "SELinux mode: ${SEL_MODE}"
if [[ "${SEL_MODE}" == "Enforcing" ]]; then
    cap "httpd booleans" getsebool -a
    caps "relevant booleans" "getsebool httpd_can_network_connect httpd_can_network_relay 2>/dev/null"
    caps "context of nginx conf" "ls -Z /etc/nginx/nginx.conf /etc/nginx/conf.d/*.conf 2>/dev/null"
    caps "context of repo tree"  "ls -Zd '${BASE_DIR}' '${BASE_DIR}'/* 2>/dev/null"
    caps "recent SELinux denials" "ausearch -m AVC,USER_AVC -ts today 2>/dev/null | tail -n 60 || journalctl -t setroubleshoot --since today --no-pager 2>/dev/null | tail -n 40"

    if have getsebool; then
        if ! getsebool httpd_can_network_connect 2>/dev/null | grep -q ' on$'; then
            finding WARN "SELinux enforcing and httpd_can_network_connect is off. nginx cannot proxy to pypiserver/Verdaccio/registry on localhost ports; those endpoints will return 502."
        fi
    fi
    if have ls; then
        if [[ "$(stat -c '%C' /etc/nginx/conf.d/mirroret.conf 2>/dev/null)" == *":etc_t:"* ]]; then
            finding FAIL "SELinux enforcing and /etc/nginx/conf.d/mirroret.conf is labelled etc_t instead of httpd_config_t. nginx will fail to read it (Permission denied 13). Fix: restorecon -v /etc/nginx/conf.d/mirroret.conf"
        fi
    fi
fi
cap "apparmor status" aa-status

# =============================================================================
# 05  Firewall
# =============================================================================
sec "FIREWALL"
cap "firewalld state" firewall-cmd --state
caps "firewalld active zones" "firewall-cmd --list-all 2>/dev/null"
cap "ufw status" ufw status verbose
caps "nftables ruleset" "nft list ruleset 2>/dev/null | head -n 120"
caps "iptables filter table" "iptables -S 2>/dev/null | head -n 80"

for p in "${WEB_PORT}" "${PIP_PORT}" "${NPM_PORT}" "${REG_PORT}"; do
    if have firewall-cmd && firewall-cmd --state >/dev/null 2>&1; then
        if ! firewall-cmd --list-ports 2>/dev/null | tr ' ' '\n' | grep -q "^${p}/tcp$"; then
            finding WARN "Port ${p}/tcp is not open in the active firewalld zone. Clients on other hosts cannot reach it."
        fi
    fi
done

# =============================================================================
# 06  Disk and inodes
# =============================================================================
sec "DISK AND INODES"
cap "filesystems" df -hT
cap "inodes" df -i
caps "mount of base dir" "df -hT '${BASE_DIR}' 2>/dev/null; findmnt -T '${BASE_DIR}' 2>/dev/null"
caps "size of base dir subtrees" "du -sh '${BASE_DIR}'/* 2>/dev/null | sort -h"

AVAIL_GB=0
if [[ -d "${BASE_DIR}" ]]; then
    # POSIX -Pk, not --output=avail/-BG: those are GNU-only and silently
    # produce an empty value elsewhere, which would read as "0 GB free".
    AVAIL_KB="$(df -Pk "${BASE_DIR}" 2>/dev/null | awk 'NR==2 {print $4}' | tr -dc '0-9')"
    if [[ -n "${AVAIL_KB}" ]]; then
        AVAIL_GB=$(( AVAIL_KB / 1024 / 1024 ))
    else
        AVAIL_GB=""
    fi
    out ""
    out "available on base dir filesystem: ${AVAIL_GB:-unknown} GB"
    if [[ -z "${AVAIL_GB}" ]]; then
        finding INFO "Could not determine free space on ${BASE_DIR}; df output was not parseable."
    elif [[ "${AVAIL_GB}" -lt 20 ]]; then
        finding FAIL "Only ${AVAIL_GB} GB free on the filesystem holding ${BASE_DIR}. RPM sync aborts below its disk floor and repo metadata can be left half written."
    elif [[ "${AVAIL_GB}" -lt 100 ]]; then
        finding WARN "${AVAIL_GB} GB free on ${BASE_DIR}. A full baseos+appstream+EPEL mirror needs well over 100 GB; add i686 and it grows further."
    fi
fi
INODE_USE="$(df -Pi "${BASE_DIR}" 2>/dev/null | awk 'NR==2 {print $5}' | tr -dc '0-9')"
if [[ -n "${INODE_USE}" && "${INODE_USE}" -gt 85 ]]; then
    finding WARN "Inode usage on ${BASE_DIR} is ${INODE_USE} percent. Package mirrors create very many small files and can exhaust inodes long before bytes."
fi

# =============================================================================
# 07  Install tree inventory
# =============================================================================
sec "INSTALL TREE INVENTORY"
caps "base dir listing" "ls -la '${BASE_DIR}' 2>/dev/null"
caps "tree (2 levels)" "find '${BASE_DIR}' -maxdepth 2 -type d 2>/dev/null | sort | head -n 200"
caps "ownership and modes" "find '${BASE_DIR}' -maxdepth 2 2>/dev/null -printf '%M %u:%g %p\n' | sort -k3 | head -n 200"
caps "installed helper binaries" "ls -la /usr/local/bin/mirroret* /usr/bin/mirroret* 2>/dev/null"

if [[ ! -d "${BASE_DIR}" ]]; then
    finding FAIL "Base dir ${BASE_DIR} does not exist. mirroret is not installed, or MIRRORET_BASE_DIR in ${CONF_FILE} points somewhere else."
fi

# =============================================================================
# 08  Configuration
# =============================================================================
sec "CONFIGURATION"
catfile "${CONF_FILE}" 400
caps "config dir listing" "ls -la \"$(dirname "${CONF_FILE}")\" 2>/dev/null"
catfile /etc/mirroret/pip-packages.txt 100
catfile /etc/mirroret/npm-packages.txt 100
catfile /etc/mirroret/docker-images.txt 100

if [[ ! -e "${CONF_FILE}" ]]; then
    finding WARN "No config file at ${CONF_FILE}. Every setting is falling back to a built-in default, including MIRRORET_RPM_ARCH=x86_64."
fi

# The i686 question, answered from config rather than guessed.
case " ${RPM_ARCH} " in
    *" i686 "*) out ""; out "MIRRORET_RPM_ARCH includes i686." ;;
    *)
        finding WARN "MIRRORET_RPM_ARCH is '${RPM_ARCH}' with no i686. Clients running 'dnf install glibc.i686' or any 32-bit multilib package will fail with 'No match for argument'. Set MIRRORET_RPM_ARCH=\"${RPM_ARCH} i686\" and re-sync."
        ;;
esac

# =============================================================================
# 09  Generated scripts
# =============================================================================
sec "GENERATED SCRIPTS"
caps "scripts dir" "ls -la '${SCRIPTS_DIR}' 2>/dev/null"

MANAGED_MARKER="MIRRORET-MANAGED"
for s in sync-all.sh sync-apt-repos.sh sync-rpm-repos.sh sync-redhat-repos.sh \
         sync-apt-debmirror.sh sync-pip-packages.sh sync-npm-packages.sh \
         sync-docker-images.sh cleanup-all.sh cleanup-old-versions.sh; do
    f="${SCRIPTS_DIR}/${s}"
    sub "script: ${s}"
    if [[ ! -e "$f" ]]; then
        out "[missing]"
        continue
    fi
    caps "stat" "stat -c '%A %U:%G %s bytes mtime=%y' '$f'"
    caps "sha256" "sha256sum '$f' 2>/dev/null | awk '{print \$1}'"
    if grep -q "${MANAGED_MARKER}" "$f" 2>/dev/null; then
        out "managed marker: PRESENT (install.sh --upgrade will regenerate this file)"
    else
        out "managed marker: MISSING"
        finding FAIL "${f} has no ${MANAGED_MARKER} marker, so --upgrade refuses to touch it and preserves it as a user customisation. If you did not hand-edit it, this is a stale pre-upgrade copy missing current fixes (flock locking, proxy preamble, arch pinning). Fix: rm -f '${f}' then re-run install.sh --upgrade."
    fi
    if bash -n "$f" 2>/dev/null; then
        out "bash -n: OK"
    else
        out "bash -n: SYNTAX ERROR"
        caps "syntax error detail" "bash -n '$f' 2>&1 | head -n 20"
        finding FAIL "${f} does not parse. Cron will run it and it will die immediately."
    fi
    caps "flock present" "grep -c 'flock' '$f' 2>/dev/null"
    caps "proxy preamble present" "grep -c 'http_proxy\|HTTP_PROXY' '$f' 2>/dev/null"
    caps "arch flags" "grep -n 'ARCH=\|--arch' '$f' 2>/dev/null | head -n 10"
    out "-- head 60 lines --"
    head -n 60 "$f" 2>/dev/null | redact >>"${BODY}"
done

# Backticks inside expanding heredocs execute at generation time. This was a
# real install-blocking bug (exit 127), so the report checks for it.
if [[ -d "${SCRIPTS_DIR}" ]]; then
    caps "command-not-found evidence in logs" \
        "grep -rl 'command not found' '${LOGS_DIR}' 2>/dev/null | head -n 10"
fi

# =============================================================================
# 10  systemd units
# =============================================================================
sec "SYSTEMD UNITS"
# Enumerate what actually exists rather than only probing assumed names: a
# service can be installed under verdaccio.service instead of
# mirroret-verdaccio.service, and then a hardcoded list reports "not found"
# for a unit that is running fine under another name.
caps "all units matching mirroret/verdaccio/pypiserver/registry/distribution" \
    "systemctl list-unit-files --no-legend --no-pager 2>/dev/null | grep -iE 'mirroret|verdaccio|pypiserver|registry|distribution'"
DISCOVERED_UNITS="$(systemctl list-unit-files --no-legend --no-pager 2>/dev/null \
    | awk '{print $1}' | grep -iE 'mirroret|verdaccio|pypiserver|registry|distribution' \
    | sed 's/\.service$//' | sort -u | tr '\n' ' ')"
out "discovered: ${DISCOVERED_UNITS:-<none>}"
for u in nginx verdaccio pypiserver mirroret-registry docker-distribution \
         mirroret-pypiserver mirroret-verdaccio docker podman ${DISCOVERED_UNITS}; do
    # Skip duplicates from the discovery list.
    case " ${_SEEN_UNITS:-} " in *" ${u} "*) continue ;; esac
    _SEEN_UNITS="${_SEEN_UNITS:-} ${u}"
    sub "unit: ${u}"
    caps "is-enabled / is-active" \
        "systemctl is-enabled ${u} 2>&1; systemctl is-active ${u} 2>&1"
    caps "status" "systemctl status ${u} --no-pager -l 2>&1 | head -n 30"
    caps "unit file path" "systemctl show -p FragmentPath --value ${u} 2>/dev/null"
    UPATH="$(systemctl show -p FragmentPath --value "${u}" 2>/dev/null)"
    if [[ -n "${UPATH}" && -r "${UPATH}" ]]; then
        out "-- unit file --"
        redact <"${UPATH}" >>"${BODY}"
    fi
    caps "drop-ins" "systemctl show -p DropInPaths --value ${u} 2>/dev/null | tr ' ' '\n'"
    for d in /etc/systemd/system/"${u}".service.d/*.conf; do
        [[ -r "$d" ]] || continue
        out "-- drop-in: ${d} --"
        redact <"$d" >>"${BODY}"
    done
    caps "exit status and result" \
        "systemctl show -p ExecMainStatus -p Result -p NRestarts ${u} 2>/dev/null"
    caps "journal (last ${LOG_TAIL_LINES})" \
        "journalctl -u ${u} -n ${LOG_TAIL_LINES} --no-pager 2>&1 | tail -n ${LOG_TAIL_LINES}"

    # 203/EXEC means the ExecStart binary path does not exist. This bit the
    # Verdaccio unit for real, so name it explicitly rather than leaving the
    # reader to decode the number.
    EMS="$(systemctl show -p ExecMainStatus --value "${u}" 2>/dev/null)"
    if [[ "${EMS}" == "203" ]]; then
        EXECSTART="$(systemctl show -p ExecStart --value "${u}" 2>/dev/null)"
        finding FAIL "${u} failed with status=203/EXEC: the ExecStart binary does not exist or is not executable. ExecStart resolved to: ${EXECSTART}"
    fi
    if systemctl is-enabled "${u}" >/dev/null 2>&1 && \
       ! systemctl is-active "${u}" >/dev/null 2>&1; then
        # A socket-activated or oneshot unit sitting inactive is normal, not
        # a fault: podman.service is TriggeredBy podman.socket and exits 0
        # after each use.
        _trig="$(systemctl show -p TriggeredBy --value "${u}" 2>/dev/null)"
        _type="$(systemctl show -p Type --value "${u}" 2>/dev/null)"
        _res="$(systemctl show -p Result --value "${u}" 2>/dev/null)"
        if [[ -n "${_trig}" ]]; then
            out "[inactive but socket-activated by ${_trig}: normal]"
        elif [[ "${_type}" == "oneshot" && "${_res}" == "success" ]]; then
            out "[inactive oneshot that last succeeded: normal]"
        else
            finding FAIL "${u} is enabled but not active, and it is neither socket-activated nor a successful oneshot. It is supposed to be running and is not."
        fi
    fi
done

# =============================================================================
# 11  nginx
# =============================================================================
sec "NGINX"
cap "nginx version and build" nginx -V
cap "config test" nginx -t
caps "conf.d listing" "ls -la /etc/nginx/conf.d/ /etc/nginx/sites-available/ /etc/nginx/sites-enabled/ 2>/dev/null"
catfile /etc/nginx/nginx.conf 120
for c in /etc/nginx/conf.d/mirroret*.conf /etc/nginx/sites-available/mirroret*; do
    [[ -e "$c" ]] || continue
    catfile "$c" 250
done
caps "dangling symlinks in sites-enabled" \
    "find /etc/nginx/sites-enabled/ -xtype l 2>/dev/null"
caps "nginx error log tail" "tail -n ${LOG_TAIL_LINES} /var/log/nginx/error.log 2>/dev/null"
caps "nginx access log tail" "tail -n 30 /var/log/nginx/access.log 2>/dev/null"

if have nginx; then
    _ngt=""; _ngrc=0
    _ngt="$(nginx -t 2>&1)" || _ngrc=$?
    if [[ "${_ngrc}" -ne 0 ]]; then
        if [[ "${IS_ROOT}" -eq 0 && "${_ngt}" == *"Permission denied"* ]]; then
            # nginx configs are commonly mode 0600 root-only, and the error
            # log is unwritable by a normal user. As a non-root caller this
            # says nothing about whether the config is valid.
            finding INFO "nginx -t could not run as a non-root user (Permission denied reading the config or error log). This is expected and is NOT a config problem. Re-run with sudo to actually validate it."
        else
            finding FAIL "nginx -t fails. nginx is serving the last good config or is down entirely; any config change since the last successful reload has not taken effect. Error: $(printf '%s' "${_ngt}" | grep -m1 -iE 'emerg|error' || printf 'see section 11')"
        fi
    fi
fi

# Verify every alias/root target in the mirroret config actually exists. A
# root pointing at a missing directory yields 404 for every client.
sub "alias and root targets referenced by mirroret nginx config"
for c in /etc/nginx/conf.d/mirroret*.conf /etc/nginx/sites-available/mirroret*; do
    [[ -r "$c" ]] || continue
    while read -r target; do
        [[ -n "${target}" ]] || continue
        if [[ -d "${target}" ]]; then
            n=$(( $(find "${target}" -maxdepth 1 2>/dev/null | wc -l) ))
            out "OK      ${target} (entries: ${n})"
        else
            out "MISSING ${target}"
            finding FAIL "nginx config references '${target}' which does not exist. Every client request routed there returns 404."
        fi
    done < <(grep -hoE '^[[:space:]]*(alias|root)[[:space:]]+[^;]+' "$c" 2>/dev/null \
             | awk '{print $2}' | sed 's#/$##' | sort -u)
done

# =============================================================================
# 12  Listening ports
# =============================================================================
sec "LISTENING PORTS"
# -n on both is essential: without it netstat reverse-resolves every socket
# and can take a minute on a busy host.
caps "all listeners" "ss -tulpnH 2>/dev/null || netstat -an 2>/dev/null | head -n 80"
for p in "${WEB_PORT}" "${PIP_PORT}" "${NPM_PORT}" "${REG_PORT}"; do
    sub "port ${p}"
    caps "listener" "ss -tlpnH \"sport = :${p}\" 2>/dev/null || netstat -an 2>/dev/null | grep \"\\.${p} \""
    if have ss && ! ss -tlnH "sport = :${p}" 2>/dev/null | grep -q .; then
        out "[nothing listening on ${p}]"
    fi
done

for pair in "${WEB_PORT}:nginx" "${PIP_PORT}:pypiserver" "${NPM_PORT}:verdaccio" "${REG_PORT}:registry"; do
    p="${pair%%:*}"; svc="${pair##*:}"
    if ! have ss; then continue; fi
    _lst="$(ss -tlnH "sport = :${p}" 2>/dev/null)"
    if [[ -z "${_lst}" ]]; then
        finding WARN "Nothing is listening on port ${p} (expected ${svc}). If that component is intentionally disabled this is fine; otherwise clients get connection refused."
        continue
    fi

    # A service bound only to loopback serves this host and nothing else.
    # Every client host gets connection refused. Checked per address family:
    # 127.0.0.1 and [::1] are both loopback, 0.0.0.0 and [::] are not.
    _routable=0
    while read -r _addr; do
        [[ -n "${_addr}" ]] || continue
        case "${_addr}" in
            127.*|'[::1]'*|::1*|localhost*) ;;
            *) _routable=1 ;;
        esac
    done < <(printf '%s\n' "${_lst}" | awk '{print $4}' | sed 's/:[0-9]*$//')
    if [[ "${_routable}" -eq 0 ]]; then
        finding FAIL "Port ${p} (${svc}) is bound to LOOPBACK ONLY: $(printf '%s' "${_lst}" | awk '{print $4}' | tr '\n' ' '). It works on this host but every client host gets connection refused. Bind it to 0.0.0.0 (or the LAN address) instead."
    fi

    # Listening with no systemd unit means it dies at the next reboot.
    if have systemctl; then
        _managed=0
        for _u in ${DISCOVERED_UNITS:-} nginx verdaccio pypiserver \
                  mirroret-pypiserver mirroret-verdaccio mirroret-registry \
                  docker-distribution docker-registry; do
            systemctl is-active "${_u}" >/dev/null 2>&1 && _managed=1
        done
        if [[ "${_managed}" -eq 0 ]]; then
            if [[ "${IS_ROOT}" -eq 0 ]]; then
                finding INFO "Port ${p} (${svc}) is listening; could not confirm a managing systemd unit as a non-root user. Re-run with sudo."
            else
                finding FAIL "Port ${p} (${svc}) is listening but no matching systemd unit is active, so nothing will restart it. It will not survive a reboot. Run install.sh --upgrade to write the unit."
            fi
        fi
    fi
done

# =============================================================================
# 13  Cron and timers
# =============================================================================
sec "CRON AND TIMERS"
caps "root crontab" "crontab -l 2>&1"
caps "mirroret managed block" "crontab -l 2>/dev/null | sed -n '/>>> mirroret managed/,/<<< mirroret managed/p'"
caps "cron.d entries" "ls -la /etc/cron.d/ 2>/dev/null; grep -rl mirroret /etc/cron.d/ 2>/dev/null"
for f in /etc/cron.d/*mirroret*; do
    [[ -e "$f" ]] || continue
    catfile "$f" 40
done
caps "systemd timers" "systemctl list-timers --all --no-pager 2>/dev/null | head -n 30"
caps "cron service state" "systemctl is-active crond 2>&1; systemctl is-active cron 2>&1"
caps "cron log tail" \
    "journalctl -u crond -u cron -n 60 --no-pager 2>/dev/null | tail -n 60"

CRON_COUNT=$(( $(crontab -l 2>/dev/null | grep -c 'mirroret') ))
out ""
out "mirroret cron lines: ${CRON_COUNT}"
if [[ "${CRON_COUNT}" -eq 0 ]]; then
    if [[ "${IS_ROOT}" -eq 0 ]]; then
        # "crontab -l" reads the INVOKING user's crontab. mirroret installs
        # its schedule under root, so a non-root run always sees nothing.
        finding INFO "No mirroret cron entries in this user's crontab, but 'crontab -l' as a non-root user cannot see root's crontab, which is where mirroret installs its schedule. Re-run with sudo to check. Lock file timestamps in section 22 show when syncs last ran."
    else
        finding WARN "No mirroret cron entries for root. Nothing will sync automatically; mirrors go stale until someone runs the sync scripts by hand."
    fi
fi
if ! systemctl is-active crond >/dev/null 2>&1 && ! systemctl is-active cron >/dev/null 2>&1; then
    finding WARN "Neither crond nor cron is active. Scheduled syncs cannot fire even though crontab entries exist."
fi

# =============================================================================
# 14  logrotate
# =============================================================================
sec "LOGROTATE"
catfile /etc/logrotate.d/mirroret 60
caps "logrotate dry run" "logrotate -d /etc/logrotate.d/mirroret 2>&1 | head -n 60"
caps "log dir size and count" \
    "du -sh '${LOGS_DIR}' 2>/dev/null; find '${LOGS_DIR}' -type f 2>/dev/null | wc -l"

LOGN=$(( $(find "${LOGS_DIR}" -type f 2>/dev/null | wc -l) ))
if [[ "${LOGN}" -gt 2000 ]]; then
    finding WARN "${LOGN} files in ${LOGS_DIR}. logrotate is probably not covering them; unbounded log growth eventually fills the volume."
fi

# =============================================================================
# 14b  Mirror targets (which distributions this server serves)
# =============================================================================
sec "MIRROR TARGETS"
TARGETS_DIR="${MIRRORET_TARGETS_DIR:-/etc/mirroret/targets}"
caps "targets dir" "ls -la '${TARGETS_DIR}' 2>/dev/null"
caps "engines dir" "ls -la '${BASE_DIR}/engines' 2>/dev/null"
caps "python3" "python3 -V 2>&1"

_TGT_APT=0
_TGT_RPM=0
if [[ -d "${TARGETS_DIR}" ]]; then
    for f in "${TARGETS_DIR}"/*.json; do
        [[ -f "$f" ]] || continue
        sub "target: $(basename "$f")"
        # Print the spec verbatim: it is small, and it is the single source of
        # truth for what this server mirrors.
        out "$(cat "$f" 2>/dev/null)"
        case "$(basename "$f")" in
            apt-*) _TGT_APT=$(( _TGT_APT + 1 )) ;;
            rpm-*) _TGT_RPM=$(( _TGT_RPM + 1 )) ;;
        esac
    done
fi
out ""
out "APT targets: ${_TGT_APT}"
out "RPM targets: ${_TGT_RPM}"

# The failure this exists to catch: APT enabled, no APT target, so nothing
# is ever downloaded and nothing complains.
if [[ "${_TGT_APT}" -eq 0 ]] && [[ -d "${BASE_DIR}" ]]; then
    if [[ ! -f "${SCRIPTS_DIR}/sync-apt-debmirror.sh" ]] && \
       [[ ! -f /etc/apt/mirror.list ]]; then
        finding WARN "No APT mirror target is configured, so no .deb is ever downloaded and no error is reported. If Debian/Ubuntu clients should use this server, set MIRRORET_APT_TARGETS (e.g. \"ubuntu:jammy debian:bookworm\") in /etc/mirroret/mirroret.conf and run: sudo ./install.sh --upgrade"
    fi
fi
if [[ "${_TGT_RPM}" -eq 0 ]] && [[ -d "${BASE_DIR}" ]] && \
   [[ ! -f "${SCRIPTS_DIR}/sync-redhat-repos.sh" ]]; then
    finding WARN "No RPM mirror target is configured. If RHEL-family clients should use this server, set MIRRORET_RPM_TARGETS (e.g. \"ol:9 rocky:9\") and run: sudo ./install.sh --upgrade"
fi

# =============================================================================
# 14c  APT mirror contents
# =============================================================================
sec "APT MIRROR CONTENTS"
APT_ROOT="${BASE_DIR}/apt"
caps "apt root listing" "ls -la '${APT_ROOT}' 2>/dev/null"

if [[ -d "${APT_ROOT}" ]]; then
    sub "published suites (a suite is published when its Release file exists)"
    _APT_SUITES=0
    # Iterate dists/<suite>/ directories directly. Globbing for any
    # Release/InRelease anywhere under dists/ also matches the per-component
    # <comp>/binary-<arch>/Release files, which counts one real suite three
    # times and prints a nonsense row for each component.
    for flav in "${APT_ROOT}"/*; do
        [[ -d "${flav}/dists" ]] || continue
        for suite_dir in "${flav}/dists"/*; do
            [[ -d "${suite_dir}" ]] || continue
            if [[ ! -f "${suite_dir}/Release" ]] && [[ ! -f "${suite_dir}/InRelease" ]]; then
                printf '%-58s %s\n' \
                    "$(basename "$flav")/$(basename "$suite_dir")" \
                    "NOT PUBLISHED (no Release)" >>"${BODY}"
                continue
            fi
            _APT_SUITES=$(( _APT_SUITES + 1 ))
            n_pkg=0
            for idx in "${suite_dir}"/*/binary-*/Packages*; do
                [[ -f "$idx" ]] || continue
                case "$idx" in
                    *.gz) n=$(gzip -dc "$idx" 2>/dev/null | grep -c '^Filename:' || true) ;;
                    *.xz) n=$(xz -dc "$idx" 2>/dev/null | grep -c '^Filename:' || true) ;;
                    *)    n=$(grep -c '^Filename:' "$idx" 2>/dev/null || true) ;;
                esac
                n_pkg=$(( n_pkg + ${n:-0} ))
            done
            printf '%-58s %8s packages listed\n' \
                "$(basename "$flav")/$(basename "$suite_dir")" "${n_pkg}" >>"${BODY}"
        done
    done
    out ""
    out "published suites: ${_APT_SUITES}"

    sub "pool contents"
    caps "deb count" "find '${APT_ROOT}' -name '*.deb' 2>/dev/null | wc -l"
    caps "pool size" "du -sh '${APT_ROOT}' 2>/dev/null"

    # A tree with a dists/ but no pool means indices were published without
    # packages, which gives clients 404s on every install.
    for flav in "${APT_ROOT}"/*; do
        [[ -d "$flav" ]] || continue
        if [[ -d "${flav}/dists" ]] && [[ ! -d "${flav}/pool" ]]; then
            finding FAIL "$(basename "$flav"): dists/ exists but pool/ does not. Clients will resolve packages and then get 404 on download. Re-run the APT sync: sudo ${SCRIPTS_DIR}/sync-apt-repos.sh"
        fi
    done
    if [[ "${_APT_SUITES}" -eq 0 ]] && [[ "${_TGT_APT}" -gt 0 ]]; then
        finding WARN "${_TGT_APT} APT target(s) configured but no suite has been published yet. Run: sudo ${SCRIPTS_DIR}/sync-apt-repos.sh"
    fi
fi

# =============================================================================
# 15  RPM mirror contents
# =============================================================================
sec "RPM MIRROR CONTENTS"
RPM_ROOT="${BASE_DIR}/redhat/mirror"
caps "rpm root listing" "ls -la '${RPM_ROOT}' 2>/dev/null"
caps "repo directories" "find '${RPM_ROOT}' -maxdepth 3 -type d 2>/dev/null | sort | head -n 60"

if [[ -d "${RPM_ROOT}" ]]; then
    sub "per-repo package counts and sizes"
    printf '%-40s %8s %8s %8s %8s %8s  %s\n' \
        "REPO (relative to mirror root)" "TOTAL" "x86_64" "noarch" "i686" "SIZE" \
        "PKG SUBDIR" >>"${BODY}"
    # Leaf dirs only: those that directly hold at least one .rpm. Deriving
    # the list from the files themselves avoids counting a package once per
    # ancestor directory.
    # Directories that directly hold .rpm files.
    PKG_DIRS="$(find "${RPM_ROOT}" -type f -name '*.rpm' 2>/dev/null \
                | sed 's#/[^/]*$##' | sort -u)"

    # Map a package dir to its REPO ROOT: the nearest ancestor (or itself)
    # holding repodata/repomd.xml. Layouts differ by vendor. Oracle serves
    # <repo>/getPackage/*.rpm with <repo>/repodata/ one level up; Fedora and
    # EPEL nest deeper as Packages/a/, Packages/b/. Assuming repodata sits
    # beside the packages reports every Oracle repo as broken.
    _repo_root_for() {
        local d="$1" cur="$1" hops=0
        # Bounded walk: 5 levels is deeper than any real vendor layout.
        while [[ "${hops}" -lt 5 ]]; do
            hops=$(( hops + 1 ))
            if [[ -f "${cur}/repodata/repomd.xml" ]]; then
                printf '%s' "${cur}"; return 0
            fi
            # Never walk above the mirror root.
            [[ "${cur}" == "${RPM_ROOT}" ]] && break
            cur="$(dirname "${cur}")"
            [[ "${cur}" == "/" ]] && break
        done
        # No metadata anywhere above: report the package dir itself.
        printf '%s' "$d"
        return 1
    }

    # Aggregate counts per repo root, not per package dir.
    REPO_ROOTS=""
    NO_META_DIRS=""
    while read -r d; do
        [[ -n "$d" ]] || continue
        if root="$(_repo_root_for "$d")"; then
            REPO_ROOTS="${REPO_ROOTS}${root}
"
        else
            NO_META_DIRS="${NO_META_DIRS}${d}
"
        fi
    done <<<"${PKG_DIRS}"
    REPO_ROOTS="$(printf '%s' "${REPO_ROOTS}" | sort -u)"
    # Include metadata-less dirs in the table too: their packages are real
    # even though clients cannot see them yet.
    INVENTORY_DIRS="$(printf '%s\n%s' "${REPO_ROOTS}" "${NO_META_DIRS}" \
                      | grep -v '^$' | sort -u)"

    # Count source RPMs across the whole tree, independent of the repo-root
    # mapping: a .src.rpm in a metadata-less dir is still eating the disk.
    SRC_TOTAL=$(( $(find "${RPM_ROOT}" -name '*.src.rpm' 2>/dev/null | wc -l) ))
    while read -r d; do
        [[ -n "$d" ]] || continue
        # Recursive here on purpose: packages may live in getPackage/ or
        # Packages/<letter>/ beneath the repo root.
        tot=$(find "$d" -name '*.rpm' 2>/dev/null | wc -l)
        [[ "${tot}" -eq 0 ]] && continue
        x86=$(find "$d" -name '*.x86_64.rpm' 2>/dev/null | wc -l)
        noa=$(find "$d" -name '*.noarch.rpm' 2>/dev/null | wc -l)
        i68=$(find "$d" -name '*.i686.rpm' 2>/dev/null | wc -l)
        sz="$(du -sh "$d" 2>/dev/null | awk '{print $1}')"
        rel="${d#"${RPM_ROOT}"/}"
        # Pure parameter expansion: "$#" inside a double-quoted sed script
        # expands as the shell's argument count and corrupts the expression.
        pkgsub=""
        while read -r _f; do
            _rp="${_f#"$d"/}"
            if [[ "${_rp}" == */* ]]; then _sd="${_rp%/*}"; else _sd="<flat>"; fi
            case ",${pkgsub}," in
                *",${_sd},"*) ;;
                *) pkgsub="${pkgsub:+${pkgsub},}${_sd}" ;;
            esac
        done < <(find "$d" -type f -name '*.rpm' 2>/dev/null | head -50)
        printf '%-40s %8d %8d %8d %8d %8s  %s\n' \
            "${rel}" "${tot}" "${x86}" "${noa}" "${i68}" "${sz:-?}" \
            "${pkgsub:-none}" >>"${BODY}"
        if [[ "${i68}" -eq 0 && "${x86}" -gt 0 ]]; then
            I686_EMPTY_REPOS="${I686_EMPTY_REPOS:-} ${rel}"
        fi
    done <<<"${INVENTORY_DIRS}"

    if [[ "${SRC_TOTAL}" -gt 0 ]]; then
        finding FAIL "${SRC_TOTAL} .src.rpm files in the mirror. Source RPMs are hundreds of MB each and are almost never wanted; an unpinned reposync can pull tens of thousands. Set MIRRORET_RPM_SOURCE=0, pin MIRRORET_RPM_ARCH, then delete them."
    fi

    sub "repodata freshness per repo"
    while read -r d; do
        [[ -n "$d" ]] || continue
        caps "${d#"${RPM_ROOT}"/}" \
            "stat -c 'repomd.xml mtime=%y size=%s' '${d}/repodata/repomd.xml' 2>/dev/null; ls -la '${d}/repodata' 2>/dev/null | head -n 12"
    done <<<"${REPO_ROOTS}"

    # Only a package dir with NO repodata at or above it is genuinely broken.
    while read -r d; do
        [[ -n "$d" ]] || continue
        finding FAIL "${d} holds RPMs but no repodata/repomd.xml exists there or in any parent up to ${RPM_ROOT}. dnf on clients fails with 'Failed to download metadata for repo'. Fix: run createrepo_c on the repo root, or re-run the sync with --download-metadata."
    done <<<"${NO_META_DIRS}"

    # Metadata that predates the newest package means the repo is stale even
    # though the files are present: dnf only sees what repomd.xml lists.
    while read -r d; do
        [[ -n "$d" ]] || continue
        md="${d}/repodata/repomd.xml"
        [[ -f "${md}" ]] || continue
        md_t=$(_mtime "${md}")
        newest_t=$(_newest_rpm_mtime "$d")
        [[ -n "${newest_t}" && "${newest_t}" -gt 0 ]] || continue
        if [[ "${newest_t}" -gt "${md_t}" ]]; then
            skew=$(( (newest_t - md_t) / 3600 ))
            finding FAIL "${d#"${RPM_ROOT}"/}: repodata is ${skew}h OLDER than the newest package in it. dnf only installs what repomd.xml lists, so those packages are invisible to clients. Fix: createrepo_c --update '${d}'"
        fi
    done <<<"${REPO_ROOTS}"

    if [[ -n "${I686_EMPTY_REPOS:-}" ]]; then
        finding WARN "Zero i686 packages in:${I686_EMPTY_REPOS}. Confirms 32-bit multilib installs (glibc.i686 and friends) will fail on clients until MIRRORET_RPM_ARCH includes i686 and a re-sync completes."
    fi
else
    out "[no RPM mirror tree at ${RPM_ROOT}]"
fi

cap "reposync version" reposync --version
cap "createrepo_c version" createrepo_c --version
cap "dnf version" dnf --version

# =============================================================================
# 16  APT mirror contents
# =============================================================================
sec "APT MIRROR CONTENTS"
caps "apt tree" "find '${BASE_DIR}/debian' -maxdepth 4 -type d 2>/dev/null | head -n 40"
caps "deb count and size" \
    "find '${BASE_DIR}/debian' -name '*.deb' 2>/dev/null | wc -l; du -sh '${BASE_DIR}/debian' 2>/dev/null"
caps "Release files" \
    "find '${BASE_DIR}/debian' -name 'Release' -o -name 'InRelease' 2>/dev/null | head -n 20"
catfile /etc/apt/mirror.list 60
caps "apt-mirror / debmirror present" \
    "command -v apt-mirror apt-mirror2 debmirror 2>/dev/null"

# =============================================================================
# 17  pip mirror
# =============================================================================
sec "PIP MIRROR"
caps "pip tree" "ls -la '${BASE_DIR}/pip' '${BASE_DIR}/pip/approved' 2>/dev/null"
caps "package count" \
    "find '${BASE_DIR}/pip' -type f \\( -name '*.whl' -o -name '*.tar.gz' \\) 2>/dev/null | wc -l"
caps "distinct project names" \
    "find '${BASE_DIR}/pip' -name '*.whl' -printf '%f\n' 2>/dev/null | sed 's/-[0-9].*//' | sort -u | head -n 60"
caps "pypiserver venv" "ls -la '${BASE_DIR}/pip/venv/bin' 2>/dev/null | head -n 20"
caps "pypiserver binary resolution" \
    "command -v pypi-server pypiserver 2>/dev/null; ls -la '${BASE_DIR}/pip/venv/bin/pypi-server' 2>/dev/null"

# =============================================================================
# 18  npm mirror
# =============================================================================
sec "NPM MIRROR"
caps "npm tree" "ls -la '${BASE_DIR}/npm' 2>/dev/null"
caps "verdaccio storage" \
    "ls -la '${BASE_DIR}/npm/storage' 2>/dev/null | head -n 30; find '${BASE_DIR}/npm/storage' -maxdepth 1 -type d 2>/dev/null | wc -l"
caps "tarball count" "find '${BASE_DIR}/npm' -name '*.tgz' 2>/dev/null | wc -l"
catfile "${BASE_DIR}/npm/config.yaml" 80
caps "verdaccio binary resolution" \
    "command -v verdaccio 2>/dev/null; npm root -g 2>/dev/null; npm prefix -g 2>/dev/null; ls -la \"\$(npm root -g 2>/dev/null)/verdaccio/bin/verdaccio\" 2>/dev/null"
cap "node version" node --version
cap "npm version" npm --version

# =============================================================================
# 19  Docker / OCI registry
# =============================================================================
sec "DOCKER AND OCI REGISTRY"
out "configured mode: ${DOCKER_MODE}"
caps "container runtime" "command -v docker podman 2>/dev/null"
cap "docker info" docker info
caps "running containers" "docker ps -a 2>/dev/null || podman ps -a 2>/dev/null"
catfile "${BASE_DIR}/docker/config.yml" 80
catfile "${BASE_DIR}/registry/config.yml" 80
caps "registry data size" \
    "du -sh '${BASE_DIR}/docker' '${BASE_DIR}/registry' 2>/dev/null"
catfile /etc/docker/daemon.json 40
caps "registry proxy drop-in" \
    "cat /etc/systemd/system/mirroret-registry.service.d/*.conf 2>/dev/null"

if [[ "${DOCKER_MODE}" == "cache" ]] && [[ -x "${SCRIPTS_DIR}/sync-docker-images.sh" ]]; then
    finding WARN "MIRRORET_DOCKER_MODE=cache but ${SCRIPTS_DIR}/sync-docker-images.sh is still executable. A pull-through cache registry rejects pushes, so every cron run of that script fails. It should have been renamed to .cache-mode-disabled."
fi

# =============================================================================
# 20  Approval and staging
# =============================================================================
sec "APPROVAL AND STAGING"
out "MIRRORET_APPROVAL_ENABLED=${APPROVAL}"
if [[ "${APPROVAL}" == "1" ]]; then
    out "Approval gate ON: clients are served from ${BASE_DIR}/approved/{pip,npm}"
else
    out "Approval gate OFF: everything synced is served immediately, no review step."
fi
caps "staging counts" \
    "echo -n 'staging/pip: '; find '${BASE_DIR}/staging/pip' -type f 2>/dev/null | wc -l; echo -n 'staging/npm: '; find '${BASE_DIR}/staging/npm' -type f 2>/dev/null | wc -l"
caps "approved counts" \
    "echo -n 'approved/pip: '; find '${BASE_DIR}/approved/pip' -type f 2>/dev/null | wc -l; echo -n 'approved/npm: '; find '${BASE_DIR}/approved/npm' -type f 2>/dev/null | wc -l"
caps "staging listings" \
    "ls -la '${BASE_DIR}/staging/pip' '${BASE_DIR}/staging/npm' 2>/dev/null | head -n 40"

if [[ "${APPROVAL}" == "1" ]]; then
    SP=$(( $(find "${BASE_DIR}/staging/pip" "${BASE_DIR}/staging/npm" -type f 2>/dev/null | wc -l) ))
    AP=$(( $(find "${BASE_DIR}/approved/pip" "${BASE_DIR}/approved/npm" -type f 2>/dev/null | wc -l) ))
    if [[ "${SP}" -gt 0 && "${AP}" -eq 0 ]]; then
        finding WARN "Approval mode is on with ${SP} packages waiting in staging and nothing approved yet. Clients see an empty pip/npm index until you promote them (install.sh --list-staging, then --approve-all-pip / --approve-all-npm)."
    fi
fi

# =============================================================================
# 21  Retention
# =============================================================================
sec "RETENTION AND CLEANUP"
caps "retention settings" \
    "grep -n 'RETENTION\|KEEP\|MIRRORET_.*_KEEP' '${CONF_FILE}' 2>/dev/null"
catfile "${SCRIPTS_DIR}/cleanup-old-versions.sh" 60
caps "last cleanup log" \
    "ls -t '${LOGS_DIR}'/*clean* 2>/dev/null | head -n 3"
caps "cleanup log tail" \
    "tail -n 40 \"\$(ls -t '${LOGS_DIR}'/*clean* 2>/dev/null | head -n 1)\" 2>/dev/null"
cap "repomanage present" command -v repomanage

# =============================================================================
# 22  Locks and running syncs
# =============================================================================
sec "LOCKS AND RUNNING SYNCS"
caps "lock files" "ls -la /var/lock/mirroret-* 2>/dev/null"
for lk in redhat pip npm docker apt; do
    lf="/var/lock/mirroret-sync-${lk}.lock"
    if [[ -e "${lf}" ]]; then
        if flock -n "${lf}" true 2>/dev/null; then
            out "${lk}: lock file present, NOT held (idle)"
        else
            out "${lk}: lock HELD (a sync is running)"
        fi
    else
        out "${lk}: no lock file"
    fi
done
caps "sync-like processes" \
    "ps -eo pid,etime,rss,cmd 2>/dev/null | grep -E 'reposync|debmirror|apt-mirror|sync-(all|redhat|pip|npm|docker)|createrepo' | grep -v grep"

# A reposync that has been running for days is usually the source-RPM runaway.
caps "long-running reposync" \
    "ps -eo etimes,cmd 2>/dev/null | awk '/reposync/ && !/awk/ && \$1 > 86400 {print}'"

# =============================================================================
# 23  Proxy configuration in all three contexts
# =============================================================================
sec "PROXY CONFIGURATION"
out "Proxy settings must exist in three separate places. A shell that works"
out "proves nothing about cron or systemd: cron gets a minimal environment and"
out "systemd services read neither /etc/environment nor any shell rc file."
out ""
sub "1. interactive shell environment"
caps "env" "env 2>/dev/null | grep -iE '_proxy|no_proxy' | sort"
catfile /etc/environment 30
caps "profile.d proxy files" \
    "grep -rlis 'proxy' /etc/profile /etc/profile.d/ 2>/dev/null"
sub "2. generated sync scripts (what cron will actually see)"
caps "proxy lines in sync scripts" \
    "grep -n 'proxy\|PROXY' '${SCRIPTS_DIR}'/*.sh 2>/dev/null | head -n 30"
sub "3. systemd service environment"
for u in mirroret-registry mirroret-pypiserver mirroret-verdaccio docker; do
    caps "${u} Environment" \
        "systemctl show -p Environment --value ${u} 2>/dev/null"
done
sub "package manager proxy config"
caps "dnf/yum proxy" "grep -n 'proxy' /etc/dnf/dnf.conf /etc/yum.conf 2>/dev/null"
caps "apt proxy" "grep -rn 'Proxy' /etc/apt/apt.conf /etc/apt/apt.conf.d/ 2>/dev/null"
caps "pip proxy" "grep -n 'proxy' /etc/pip.conf ~/.pip/pip.conf ~/.config/pip/pip.conf 2>/dev/null"
caps "npm proxy" "npm config get proxy 2>/dev/null; npm config get https-proxy 2>/dev/null; npm config get registry 2>/dev/null"

SHELL_PROXY=$(( $(env 2>/dev/null | grep -ic '_proxy') ))
SCRIPT_PROXY=$(( $(grep -l 'http_proxy\|HTTP_PROXY' "${SCRIPTS_DIR}"/*.sh 2>/dev/null | wc -l) ))
if [[ "${SHELL_PROXY}" -gt 0 && "${SCRIPT_PROXY}" -eq 0 ]]; then
    finding FAIL "A proxy is set in this shell but no generated sync script exports one. Cron runs with a minimal environment, so every scheduled sync will hang or fail with a connection timeout while manual runs appear to work."
fi

# =============================================================================
# 24  CA trust
# =============================================================================
sec "CA TRUST"
caps "system trust store" \
    "ls -la /etc/pki/ca-trust/source/anchors/ /usr/local/share/ca-certificates/ 2>/dev/null"
caps "trust store size" \
    "wc -l /etc/pki/tls/certs/ca-bundle.crt /etc/ssl/certs/ca-certificates.crt 2>/dev/null"
caps "custom anchors (fingerprints only)" \
    "for f in /etc/pki/ca-trust/source/anchors/*.crt /usr/local/share/ca-certificates/*.crt; do [ -r \"\$f\" ] || continue; echo \"== \$f\"; openssl x509 -in \"\$f\" -noout -subject -issuer -dates -fingerprint 2>/dev/null; done"
caps "any private keys left in the tree (names only)" \
    "find /etc/pki /etc/ssl '${BASE_DIR}' -name '*.key' -o -name '*key.pem' 2>/dev/null | head -n 20"
caps "python cert env" "env | grep -iE 'REQUESTS_CA|SSL_CERT|CURL_CA|NODE_EXTRA_CA' 2>/dev/null"

# =============================================================================
# 25  DNS
# =============================================================================
sec "DNS RESOLUTION"
catfile /etc/resolv.conf 30
caps "hosts file mirroret entries" "grep -i 'mirroret\|mirror' /etc/hosts 2>/dev/null"
for h in registry-1.docker.io pypi.org files.pythonhosted.org registry.npmjs.org \
         yum.oracle.com dl.rockylinux.org repo.almalinux.org cdn.redhat.com \
         archive.ubuntu.com deb.debian.org; do
    caps "resolve ${h}" "getent hosts ${h} 2>&1 | head -n 3"
done

# =============================================================================
# 26  Outbound reachability
# =============================================================================
sec "OUTBOUND REACHABILITY"
if [[ "${DO_NET}" -eq 0 ]]; then
    out "[skipped: --no-net]"
else
    out "Reports the HTTP status code actually returned. Note that a 401 or"
    out "404 still proves reachability: registry-1.docker.io answers 404 at /"
    out "and 401 at /v2/. Only code 000 means no HTTP response at all."
    out ""
    printf '%-6s %-8s %s\n' "CODE" "TIME" "URL" >>"${BODY}"
    for url in \
        https://registry-1.docker.io/v2/ \
        https://auth.docker.io/token \
        https://pypi.org/simple/ \
        https://files.pythonhosted.org/ \
        https://registry.npmjs.org/ \
        https://yum.oracle.com/ \
        https://dl.rockylinux.org/pub/rocky/ \
        https://repo.almalinux.org/almalinux/ \
        https://archive.ubuntu.com/ubuntu/ \
        https://deb.debian.org/debian/ \
        https://download.fedoraproject.org/pub/epel/ ; do
        if have curl; then
            res="$(curl -sS -o /dev/null -m 20 \
                   -w '%{http_code} %{time_total}' "${url}" 2>&1)"
            code="$(printf '%s' "${res}" | awk '{print $1}')"
            tm="$(printf '%s' "${res}" | awk '{print $2}')"
            printf '%-6s %-8s %s\n' "${code:-ERR}" "${tm:-.}" "${url}" >>"${BODY}"
            if [[ "${code}" == "000" ]]; then
                printf '%-6s %-8s %s\n' "" "" \
                    "  detail: $(printf '%s' "${res}" | redact | tail -n1)" >>"${BODY}"
                NET_FAILS="${NET_FAILS:-0}"
                NET_FAILS=$((NET_FAILS + 1))
                NET_FAIL_URLS="${NET_FAIL_URLS:-} ${url}"
            elif [[ "${code}" == "403" ]]; then
                PROXY_403="${PROXY_403:-} ${url}"
            fi
        fi
    done

    sub "TLS chain actually presented (is traffic being re-signed?)"
    caps "pypi.org chain issuers" \
        "echo | timeout 20 openssl s_client -connect pypi.org:443 -servername pypi.org 2>/dev/null | grep -E '^ *[0-9]+ s:|^ *i:' | head -n 10"
    caps "registry-1.docker.io chain issuers" \
        "echo | timeout 20 openssl s_client -connect registry-1.docker.io:443 -servername registry-1.docker.io 2>/dev/null | grep -E '^ *[0-9]+ s:|^ *i:' | head -n 10"

    if [[ -n "${NET_FAIL_URLS:-}" ]]; then
        finding FAIL "No HTTP response at all (code 000) from:${NET_FAIL_URLS}. This is a network, DNS or proxy-CONNECT problem, not a certificate problem."
    fi
    if [[ -n "${PROXY_403:-}" ]]; then
        finding FAIL "HTTP 403 from:${PROXY_403}. A 403 arriving before any TLS handshake means the proxy refused CONNECT to that host. Ask the proxy team to allow-list it. This is NOT a CA/TLS-inspection issue and installing a certificate will not fix it."
    fi
fi

# =============================================================================
# 27  Client-facing self-test over loopback
# =============================================================================
sec "CLIENT-FACING HTTP SELF-TEST"
out "Requests the same URLs a client would, over loopback. A failure here"
out "means the problem is server side, independent of any client config."
out ""
if have curl; then
    printf '%-6s %s\n' "CODE" "URL" >>"${BODY}"
    URLS=("http://127.0.0.1:${WEB_PORT}/")
    [[ -d "${BASE_DIR}/redhat" ]] && URLS+=("http://127.0.0.1:${WEB_PORT}/redhat/")
    [[ -d "${BASE_DIR}/debian" ]] && URLS+=("http://127.0.0.1:${WEB_PORT}/ubuntu/" "http://127.0.0.1:${WEB_PORT}/debian/")
    URLS+=("http://127.0.0.1:${WEB_PORT}/simple/"
           "http://127.0.0.1:${PIP_PORT}/simple/"
           "http://127.0.0.1:${NPM_PORT}/"
           "http://127.0.0.1:${REG_PORT}/v2/"
           "http://127.0.0.1:${WEB_PORT}/logs/"
           "http://127.0.0.1:${WEB_PORT}/scripts/")
    for u in "${URLS[@]}"; do
        code="$(curl -sS -o /dev/null -m 10 -w '%{http_code}' "$u" 2>/dev/null)"
        printf '%-6s %s\n' "${code:-ERR}" "$u" >>"${BODY}"
        case "$u" in
            */logs/|*/scripts/)
                if [[ "${code}" == "200" ]]; then
                    finding WARN "nginx serves ${u} with 200. Internal logs and scripts should not be reachable by clients; the deny rule for logs|scripts|staging is missing from the nginx config."
                fi ;;
            *)
                if [[ "${code}" == "000" ]]; then
                    finding FAIL "No response from ${u} over loopback. The listening service is down or bound to the wrong interface."
                elif [[ "${code}" =~ ^5 ]]; then
                    finding FAIL "${u} returns HTTP ${code} over loopback. With SELinux enforcing this is usually httpd_can_network_connect being off; otherwise the upstream service is dead."
                fi ;;
        esac
    done

    # Prove repodata is actually fetchable through nginx, not merely on disk.
    sub "repodata reachable through nginx"
    while read -r rd; do
        [[ -n "${rd}" ]] || continue
        rel="${rd#"${BASE_DIR}"/redhat/mirror/}"
        u="http://127.0.0.1:${WEB_PORT}/redhat/${rel}/repomd.xml"
        code="$(curl -sS -o /dev/null -m 10 -w '%{http_code}' "$u" 2>/dev/null)"
        printf '%-6s %s\n' "${code:-ERR}" "$u" >>"${BODY}"
    done < <(find "${BASE_DIR}/redhat/mirror" -maxdepth 4 -type d -name repodata 2>/dev/null | head -n 10)
fi

# =============================================================================
# 28  Client configuration templates the server hands out
# =============================================================================
sec "CLIENT CONFIGURATION TEMPLATES"
caps "config dir" "ls -la '${BASE_DIR}/config' 2>/dev/null"
# Include dotfiles: .npmrc is a client config and a plain * glob misses it.
for f in "${BASE_DIR}/config"/* "${BASE_DIR}/config"/.[!.]*; do
    [[ -f "$f" ]] || continue
    case "$f" in
        # Key material is pages of base64 that tell us nothing. Fingerprint it.
        *.asc|*.gpg|*.pem|*.crt|*.key)
            sub "file: ${f} (key material, summarized)"
            caps "stat" "stat -c '%A %U:%G %s bytes mtime=%y' '$f' 2>/dev/null"
            caps "identity" "gpg --show-keys --with-fingerprint '$f' 2>/dev/null | head -n 6 || openssl x509 -in '$f' -noout -subject -dates -fingerprint 2>/dev/null"
            ;;
        *) catfile "$f" 80 ;;
    esac
done
caps "server IP as detected" \
    "hostname -I 2>/dev/null; ip -4 -o addr show scope global 2>/dev/null | awk '{print \$2, \$4}'"

# A client .repo pointing at 127.0.0.1 is useless to every other host.
# Only real client config text. A GPG key whose UID is
# "mirroret@localhost" is not a misconfigured template, and binary keyrings
# match on bytes that mean nothing here.
_LOOPBACK_HITS=""
for _cf in "${BASE_DIR}/config"/*.repo "${BASE_DIR}/config"/*.conf \
           "${BASE_DIR}/config"/*.list "${BASE_DIR}/config"/*.json \
           "${BASE_DIR}/config"/.npmrc "${BASE_DIR}/config"/*.npmrc; do
    [[ -f "${_cf}" ]] || continue
    if grep -qE '127\.0\.0\.1|localhost' "${_cf}" 2>/dev/null; then
        _LOOPBACK_HITS="${_LOOPBACK_HITS} $(basename "${_cf}")"
    fi
done
caps "loopback or localhost in client config text" \
    "grep -nE '127\.0\.0\.1|localhost' '${BASE_DIR}/config'/*.repo '${BASE_DIR}/config'/*.conf '${BASE_DIR}/config'/*.list '${BASE_DIR}/config'/*.json '${BASE_DIR}/config'/.npmrc 2>/dev/null | head -n 20"
if [[ -n "${_LOOPBACK_HITS}" ]]; then
    finding WARN "Client config templates reference 127.0.0.1 or localhost:${_LOOPBACK_HITS}. Copied to a client, they point that client at itself. MIRRORET_SERVER_IP was probably not detected correctly."
fi

# =============================================================================
# 29  Sync history and errors
# =============================================================================
sec "SYNC HISTORY AND ERRORS"
caps "log dir listing (newest 40)" "ls -lt '${LOGS_DIR}' 2>/dev/null | head -n 40"
sub "tail of the 5 newest logs"
while read -r lf; do
    [[ -n "${lf}" ]] || continue
    out ""
    out "=== ${lf} ==="
    caps "mtime and size" "stat -c '%s bytes mtime=%y' '${lf}'"
    tail -n "${LOG_TAIL_LINES}" "${lf}" 2>/dev/null | redact >>"${BODY}"
done < <(find "${LOGS_DIR}" -maxdepth 1 -name '*.log' -printf '%T@ %p\n' 2>/dev/null \
         | sort -rn | head -n 5 | cut -d' ' -f2-)

sub "error and failure lines across all logs"
caps "grep" \
    "grep -rhniE 'error|failed|fatal|cannot|denied|refused|timed out|command not found|no space' '${LOGS_DIR}' 2>/dev/null | sort | uniq -c | sort -rn | head -n 60"

# Stale mirror detection: newest RPM file mtime vs now.
if [[ -d "${RPM_ROOT}" ]]; then
    NEWEST="$(_newest_rpm_mtime "${RPM_ROOT}")"
    if [[ -n "${NEWEST}" && "${NEWEST}" -gt 0 ]]; then
        NOW="$(date +%s)"
        AGE_D=$(( (NOW - NEWEST) / 86400 ))
        out ""
        out "newest RPM in mirror is ${AGE_D} days old"
        if [[ "${AGE_D}" -gt 14 ]]; then
            finding WARN "Newest package in the RPM mirror is ${AGE_D} days old. Either sync is failing silently or cron is not running it. Clients are receiving stale security updates."
        fi
    fi
fi
caps "command not found in logs (heredoc backtick bug)" \
    "grep -rn 'command not found' '${LOGS_DIR}' 2>/dev/null | head -n 20"
if grep -rq 'command not found' "${LOGS_DIR}" 2>/dev/null; then
    finding FAIL "'command not found' appears in the logs. If the missing name is a word from a comment (for example 'registry'), this is the expanding-heredoc backtick bug: a generated script ran a backticked comment. Update to a build that quotes those comments."
fi

# =============================================================================
# 30  Tool inventory
# =============================================================================
sec "TOOL INVENTORY"
for t in bash curl openssl nginx systemctl flock reposync createrepo_c repomanage \
         dnf yum apt-get apt-mirror apt-mirror2 debmirror gpg python3 pip3 node npm \
         docker podman skopeo jq rsync ss getenforce restorecon firewall-cmd; do
    if have "$t"; then
        v="$("$t" --version 2>&1 | head -1)"
        printf '%-14s %-38s %s\n' "OK" "$(command -v "$t")" "${v:0:70}" >>"${BODY}"
    else
        printf '%-14s %s\n' "MISSING" "$t" >>"${BODY}"
    fi
done
out ""
cap "bash version" bash --version

for req in bash curl nginx systemctl flock; do
    have "${req}" || finding FAIL "Required tool '${req}' is not installed. mirroret cannot function without it."
done
if [[ "${DISTRO_FAMILY}" == "rhel" ]] && ! have reposync; then
    finding FAIL "reposync is missing on an RPM host. No RPM mirroring is possible. Install dnf-utils (or yum-utils)."
fi
if [[ "${DISTRO_FAMILY}" == "rhel" ]] && ! have createrepo_c; then
    finding FAIL "createrepo_c is missing. Repo metadata cannot be generated, so clients cannot use the mirror."
fi

# =============================================================================
# 31  Subscription / upstream repo state (RPM hosts)
# =============================================================================
sec "UPSTREAM REPO STATE"
caps "enabled repos" "dnf repolist --enabled 2>&1 | head -n 40"
caps "all repos" "dnf repolist --all 2>&1 | head -n 60"
caps "repo files" "ls -la /etc/yum.repos.d/ 2>/dev/null"
for f in /etc/yum.repos.d/*.repo; do
    [[ -r "$f" ]] || continue
    catfile "$f" 60
done
cap "subscription status" subscription-manager status
caps "apt sources" "ls -la /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null"
catfile /etc/apt/sources.list 40

# =============================================================================
# 32  Repo copy under test
# =============================================================================
sec "MIRRORET SOURCE TREE ON THIS HOST"
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)"
out "source tree: ${SRC_DIR}"
caps "listing" "ls -la '${SRC_DIR}' 2>/dev/null | head -n 40"
caps "git revision" "git -C '${SRC_DIR}' log --oneline -3 2>&1; git -C '${SRC_DIR}' status --short 2>&1 | head -n 20"
caps "version file" "cat '${SRC_DIR}/VERSION' 2>/dev/null"
caps "syntax check of every shipped script" \
    "for f in '${SRC_DIR}'/*.sh '${SRC_DIR}'/lib/*.sh '${SRC_DIR}'/scripts/*.sh '${SRC_DIR}'/mirroretctl; do [ -r \"\$f\" ] || continue; bash -n \"\$f\" 2>&1 && echo \"OK   \$f\" || echo \"FAIL \$f\"; done"
caps "checksums of lib modules" \
    "sha256sum '${SRC_DIR}'/lib/*.sh '${SRC_DIR}'/install.sh '${SRC_DIR}'/mirroretctl 2>/dev/null"

# =============================================================================
# 33  Kernel messages
# =============================================================================
sec "KERNEL AND SYSTEM MESSAGES"
caps "OOM kills" "dmesg 2>/dev/null | grep -iE 'oom|killed process' | tail -n 20"
caps "io errors" "dmesg 2>/dev/null | grep -iE 'i/o error|ext4|xfs.*error' | tail -n 20"
caps "journal errors today" \
    "journalctl -p err --since today --no-pager 2>/dev/null | tail -n 60"

if dmesg 2>/dev/null | grep -qi 'killed process'; then
    finding WARN "The kernel OOM killer has terminated processes on this host. A sync killed mid-write leaves partial packages and broken repodata."
fi

# =============================================================================
# Deep inventory (optional)
# =============================================================================
if [[ "${DO_DEEP}" -eq 1 ]]; then
    sec "DEEP INVENTORY (slow)"
    caps "full package list per repo" \
        "find '${RPM_ROOT}' -name '*.rpm' -printf '%f\n' 2>/dev/null | sort | head -n 4000"
    caps "duplicate versions per package name" \
        "find '${RPM_ROOT}' -name '*.rpm' -printf '%f\n' 2>/dev/null | sed -E 's/-[0-9][^-]*-[^-]*\\.[a-z0-9_]+\\.rpm$//' | sort | uniq -c | sort -rn | head -n 60"
    caps "largest 40 files in base dir" \
        "find '${BASE_DIR}' -type f -printf '%s %p\n' 2>/dev/null | sort -rn | head -n 40"
    caps "zero-length files (interrupted downloads)" \
        "find '${BASE_DIR}' -type f -size 0 2>/dev/null | head -n 60"

    ZERO=$(( $(find "${BASE_DIR}" -type f -size 0 2>/dev/null | wc -l) ))
    if [[ "${ZERO}" -gt 0 ]]; then
        finding WARN "${ZERO} zero-length files under ${BASE_DIR}. These are interrupted downloads; dnf and pip will fail on them. Delete them and re-sync."
    fi
fi

# =============================================================================
# Assemble the final report: findings first, evidence after
# =============================================================================
if [[ -n "${TIMED_OUT_PROBES:-}" ]]; then
    finding WARN "These probes exceeded ${CAP_TIMEOUT}s and were killed: ${TIMED_OUT_PROBES}. A blocking probe usually means a hung mount, an unreachable daemon or DNS that does not answer. Their sections are incomplete."
fi

# grep -c prints 0 AND exits 1 when nothing matches, so `|| echo 0` yielded
# "0\n0" inside $(( )) - a fatal arithmetic error on any clean host.
FAIL_N=$(grep -c '^FAIL' "${FINDINGS_FILE}" 2>/dev/null || true); FAIL_N=${FAIL_N:-0}
WARN_N=$(grep -c '^WARN' "${FINDINGS_FILE}" 2>/dev/null || true); WARN_N=${WARN_N:-0}

{
    printf '===============================================================================\n'
    printf 'MIRRORET DIAGNOSTIC REPORT\n'
    printf '===============================================================================\n'
    printf 'host       : %s\n' "$(hostname -f 2>/dev/null || hostname 2>/dev/null || echo unknown)"
    printf 'generated  : %s\n' "$(date -Is 2>/dev/null || date)"
    printf 'collector  : mirroret-collect.sh %s\n' "${COLLECT_VERSION}"
    printf 'os         : %s %s (%s)\n' "${OS_ID}" "${OS_VER}" "${MACHINE_ARCH}"
    printf 'base dir   : %s\n' "${BASE_DIR}"
    printf 'privileges : %s\n' "$([[ "$(id -u)" -eq 0 ]] && echo root || echo "non-root (partial report)")"
    printf 'sections   : %s\n' "${SECTION_NUM}"
    printf 'probe limit: %ss%s\n' "${CAP_TIMEOUT}" \
        "$([[ -n "${TIMEOUT_BIN}" ]] || echo ' (NOT ENFORCED: no timeout binary found)')"
    printf 'findings   : %s FAIL, %s WARN\n' "${FAIL_N}" "${WARN_N}"
    printf '\n'
    printf 'Secrets are redacted. Passwords, tokens, keys and proxy credentials\n'
    printf 'are masked; private key files were fingerprinted, never read.\n'
    printf '\n'
    printf '===============================================================================\n'
    printf '== FINDINGS (auto-detected, most important first)\n'
    printf '===============================================================================\n'
    printf '\n'
    if [[ -s "${FINDINGS_FILE}" ]]; then
        grep '^FAIL' "${FINDINGS_FILE}" 2>/dev/null
        grep '^WARN' "${FINDINGS_FILE}" 2>/dev/null
        grep '^INFO' "${FINDINGS_FILE}" 2>/dev/null
    else
        printf 'No problems auto-detected. Evidence sections below are still worth reading.\n'
    fi
    printf '\n'
    printf 'Findings are heuristics computed from the evidence below. Read the\n'
    printf 'matching section before acting on any of them.\n'
} >"${OUT_FILE}" 2>/dev/null

cat "${BODY}" >>"${OUT_FILE}" 2>/dev/null

{
    printf '\n\n'
    printf '===============================================================================\n'
    printf '== END OF REPORT\n'
    printf '===============================================================================\n'
} >>"${OUT_FILE}"

chmod 600 "${OUT_FILE}" 2>/dev/null

echo "" >&2
echo "Report written: ${OUT_FILE}" >&2
echo "Size: $(du -h "${OUT_FILE}" 2>/dev/null | awk '{print $1}')  Sections: ${SECTION_NUM}" >&2
echo "Findings: ${FAIL_N} FAIL, ${WARN_N} WARN" >&2
echo "" >&2
if [[ -s "${FINDINGS_FILE}" ]]; then
    echo "Top findings:" >&2
    head -n 12 "${FINDINGS_FILE}" >&2
    echo "" >&2
fi
echo "Mode 600. Review before sharing, then send the file." >&2

exit 0

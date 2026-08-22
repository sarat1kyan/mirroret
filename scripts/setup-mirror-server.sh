#!/usr/bin/env bash
# One-shot mirror server bring-up.
#
# Runs the whole sequence a human would otherwise type: preflight, config,
# install, firewall, first sync, and the verification that proves a client
# can actually install from the result.
#
# Design rules, because this runs unattended on someone's server:
#
#   * Every phase ends in a GATE. A failed gate stops the script and prints
#     the specific fix. It never carries on hoping the next phase repairs it,
#     because a mirror that half-works is worse than one that visibly failed.
#   * Idempotent. Re-running is safe and is the normal way to resume.
#   * --dry-run changes nothing at all.
#   * Everything is logged to a transcript you can send on.
#
# Usage:
#   sudo ./scripts/setup-mirror-server.sh \
#       --apt-targets "ubuntu:jammy ubuntu:noble debian:bookworm" \
#       --rpm-targets "ol:9" \
#       --proxy http://192.168.30.243:3128 \
#       --yes
#
#   sudo ./scripts/setup-mirror-server.sh --help

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TREE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# -- Options -------------------------------------------------------------------

APT_TARGETS=""
RPM_TARGETS=""
APT_COMPONENTS="main restricted"
PROXY=""
NO_PROXY_LIST="localhost,127.0.0.1,::1,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16"
CA_BUNDLE=""
SERVER_IP=""
FIREWALL_SOURCE=""
MIN_FREE_GB="15"
MIN_DISK_GB=""
ASSUME_YES=0
DRY_RUN=0
SKIP_SYNC=0
SKIP_FIREWALL=0
START_PHASE=1
APT_SCHEME=""
EXTRA_INSTALL_ARGS=()

CONF="/etc/mirroret/mirroret.conf"
LOG=""

usage() {
    # Print the header comment block: every line after the shebang that is
    # still a comment. A hardcoded line range silently leaks code into the
    # help text the first time the header grows.
    awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' \
        "${BASH_SOURCE[0]}"
    cat <<'USAGE'

Options:
  --apt-targets "<f:rel ...>"  distros for APT clients, e.g.
                               "ubuntu:jammy ubuntu:noble debian:bookworm"
                               flavors: ubuntu ubuntu-ports debian
  --rpm-targets "<f:maj ...>"  distros for RPM clients, e.g. "ol:9 rocky:9"
                               flavors: ol rocky almalinux centos rhel fedora epel
  --components "<c ...>"       APT components (default: "main restricted").
                               Adding universe/multiverse multiplies the
                               mirror size roughly tenfold.
  --proxy URL                  outbound HTTP(S) proxy
  --no-proxy LIST              comma-separated no_proxy list
  --ca-bundle PATH             corporate CA, ADDED to the system trust store
  --apt-scheme http|https      use https if the proxy allows CONNECT 443 only
  --server-ip IP               IP written into client configs (default: autodetect)
  --firewall-source CIDR       restrict the repo ports to this subnet
  --min-free-gb N              abort a SYNC below this much free space (default 15)
  --min-disk-gb N              install-time free-space floor. install.sh
                               refuses to install below 50 GB by default;
                               lower it here for a small pilot, or 0 to skip
  --skip-sync                  configure and verify, but do not download
  --skip-firewall              leave firewall rules alone
  --start-at N                 resume from phase N (1-6)
  --install-arg ARG            extra flag passed to install.sh (repeatable),
                               e.g. --install-arg --no-docker
  -y, --yes                    non-interactive; never prompt
  --dry-run                    show what would happen, change nothing
  -h, --help                   this text

Phases: 1 preflight  2 config  3 install  4 firewall  5 sync  6 verify
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --apt-targets)     shift; APT_TARGETS="${1:-}" ;;
        --rpm-targets)     shift; RPM_TARGETS="${1:-}" ;;
        --components)      shift; APT_COMPONENTS="${1:-}" ;;
        --proxy)           shift; PROXY="${1:-}" ;;
        --no-proxy)        shift; NO_PROXY_LIST="${1:-}" ;;
        --ca-bundle)       shift; CA_BUNDLE="${1:-}" ;;
        --apt-scheme)      shift; APT_SCHEME="${1:-}" ;;
        --server-ip)       shift; SERVER_IP="${1:-}" ;;
        --firewall-source) shift; FIREWALL_SOURCE="${1:-}" ;;
        --min-free-gb)     shift; MIN_FREE_GB="${1:-}" ;;
        --min-disk-gb)     shift; MIN_DISK_GB="${1:-}" ;;
        --install-arg)     shift; EXTRA_INSTALL_ARGS+=("${1:-}") ;;
        --start-at)        shift; START_PHASE="${1:-1}" ;;
        --skip-sync)       SKIP_SYNC=1 ;;
        --skip-firewall)   SKIP_FIREWALL=1 ;;
        -y|--yes)          ASSUME_YES=1 ;;
        --dry-run)         DRY_RUN=1 ;;
        -h|--help)         usage; exit 0 ;;
        *) printf 'Unknown option: %s\nRun with --help.\n' "$1" >&2; exit 2 ;;
    esac
    shift
done

# -- Output --------------------------------------------------------------------

if [[ -t 1 ]]; then
    C_OK=$'\033[32m'; C_ERR=$'\033[31m'; C_WARN=$'\033[33m'
    C_HEAD=$'\033[1;36m'; C_OFF=$'\033[0m'
else
    C_OK=""; C_ERR=""; C_WARN=""; C_HEAD=""; C_OFF=""
fi

_log()  { [[ -n "$LOG" ]] && printf '%s\n' "$*" >> "$LOG"; }
say()   { printf '%s\n' "$*"; _log "$*"; }
phase() { printf '\n%s=== PHASE %s: %s ===%s\n' "$C_HEAD" "$1" "$2" "$C_OFF"; _log "=== PHASE $1: $2 ==="; }
ok()    { printf '%s  ok%s    %s\n' "$C_OK" "$C_OFF" "$*"; _log "ok    $*"; }
warn()  { printf '%s  warn%s  %s\n' "$C_WARN" "$C_OFF" "$*"; _log "warn  $*"; }
info()  { printf '        %s\n' "$*"; _log "      $*"; }

# GATE failure: say exactly what to do, then stop. Never continue.
gate_fail() {
    printf '\n%s  STOP%s  %s\n' "$C_ERR" "$C_OFF" "$1"; _log "STOP  $1"
    shift
    local line
    for line in "$@"; do printf '        %s\n' "$line"; _log "      $line"; done
    printf '\n        Nothing further was attempted. Fix the above, then re-run:\n'
    printf '          sudo %s --start-at %s ...\n\n' "${BASH_SOURCE[0]}" "${CURRENT_PHASE:-1}"
    exit 1
}

run() {
    if [[ "$DRY_RUN" == "1" ]]; then
        printf '        [dry-run] %s\n' "$*"; _log "[dry-run] $*"
        return 0
    fi
    _log "+ $*"
    "$@"
}

confirm() {
    [[ "$ASSUME_YES" == "1" ]] && return 0
    [[ ! -t 0 ]] && return 0
    local reply
    read -r -p "        $1 [Y/n] " reply
    [[ -z "$reply" || "$reply" =~ ^[Yy] ]]
}

ask() {
    # ask <prompt> <varname>. Non-interactive with no value is a hard stop:
    # guessing what to mirror is exactly the mistake this rewrite removed.
    local prompt="$1" var="$2"
    [[ -n "${!var}" ]] && return 0
    if [[ "$ASSUME_YES" == "1" || ! -t 0 ]]; then
        return 1
    fi
    local reply
    read -r -p "        ${prompt}: " reply
    printf -v "$var" '%s' "$reply" 2>/dev/null || eval "${var}=\$reply"
    [[ -n "${!var}" ]]
}

# -- Phase 1: preflight --------------------------------------------------------

# Upstream hosts each configured flavor actually needs. Probing only the ones
# in use keeps a Debian-only mirror from being told Oracle is unreachable.
upstream_hosts_for() {
    local t flavor host_list=""
    for t in ${APT_TARGETS}; do
        flavor="${t%%:*}"
        case "$flavor" in
            ubuntu)       host_list+=" archive.ubuntu.com security.ubuntu.com" ;;
            ubuntu-ports) host_list+=" ports.ubuntu.com" ;;
            debian)       host_list+=" deb.debian.org" ;;
        esac
    done
    for t in ${RPM_TARGETS}; do
        flavor="${t%%:*}"
        case "$flavor" in
            ol)               host_list+=" yum.oracle.com" ;;
            rocky)            host_list+=" dl.rockylinux.org" ;;
            almalinux)        host_list+=" repo.almalinux.org" ;;
            centos)           host_list+=" mirror.stream.centos.org" ;;
            fedora|epel)      host_list+=" dl.fedoraproject.org" ;;
            rhel)             host_list+=" cdn.redhat.com" ;;
        esac
    done
    printf '%s\n' ${host_list} | sort -u
}

phase_preflight() {
    CURRENT_PHASE=1
    phase 1 "Preflight"

    [[ "$(id -u)" -eq 0 ]] || gate_fail "Not running as root." \
        "Re-run with sudo."

    if [[ ! -f "${TREE_DIR}/install.sh" ]] || [[ ! -d "${TREE_DIR}/engines" ]]; then
        gate_fail "This does not look like a complete mirroret tree." \
            "Expected install.sh and engines/ in ${TREE_DIR}." \
            "If you unpacked a zip, it may have extracted partially." \
            "Re-fetch, then: chmod +x install.sh mirroretctl scripts/*.sh engines/*.py"
    fi
    ok "mirroret tree: ${TREE_DIR}"

    local n_eng
    n_eng="$(find "${TREE_DIR}/engines" -name '*.py' | wc -l | tr -d ' ')"
    [[ "$n_eng" -ge 3 ]] || gate_fail "engines/ has only ${n_eng} file(s), expected 3." \
        "The download is incomplete. Re-fetch the repository."
    ok "mirroring engines present (${n_eng} files)"

    if ! command -v python3 >/dev/null 2>&1; then
        gate_fail "python3 is not installed." \
            "Both mirroring engines need it. Install it:" \
            "  dnf install -y python3     # RHEL family" \
            "  apt-get install -y python3 # Debian family"
    fi
    ok "python3: $(python3 -V 2>&1)"

    # Targets. Refusing to guess is the point: guessing from the server's own
    # OS is what silently mirrored zero Ubuntu packages on a RHEL host.
    if [[ -z "$APT_TARGETS" && -z "$RPM_TARGETS" ]]; then
        say ""
        info "Which distributions do your CLIENTS run? This has nothing to do"
        info "with what this server runs."
        info "APT examples: ubuntu:jammy ubuntu:noble debian:bookworm"
        info "RPM examples: ol:9 rocky:9 almalinux:9 epel:9"
        ask "APT targets (blank for none)" APT_TARGETS || true
        ask "RPM targets (blank for none)" RPM_TARGETS || true
    fi
    if [[ -z "$APT_TARGETS" && -z "$RPM_TARGETS" ]]; then
        gate_fail "No mirror targets given." \
            "Nothing would be downloaded, and nothing would report an error." \
            "Re-run with, for example:" \
            "  --apt-targets \"ubuntu:jammy debian:bookworm\" --rpm-targets \"ol:9\""
    fi
    [[ -n "$APT_TARGETS" ]] && ok "APT targets: ${APT_TARGETS}"
    [[ -n "$RPM_TARGETS" ]] && ok "RPM targets: ${RPM_TARGETS}"

    # Validate the flavors now, not after a 40-minute install.
    local t flavor bad=""
    for t in ${APT_TARGETS}; do
        flavor="${t%%:*}"
        case "$flavor" in ubuntu|ubuntu-ports|debian) ;; *) bad+=" ${t}" ;; esac
        [[ "$t" == *:* ]] || bad+=" ${t}(no release)"
    done
    for t in ${RPM_TARGETS}; do
        flavor="${t%%:*}"
        case "$flavor" in ol|rocky|almalinux|centos|rhel|fedora|epel) ;; *) bad+=" ${t}" ;; esac
        [[ "$t" == *:* ]] || bad+=" ${t}(no release)"
    done
    [[ -z "$bad" ]] || gate_fail "Unrecognised target(s):${bad}" \
        "Syntax is flavor:release, e.g. ubuntu:jammy or ol:9" \
        "APT flavors: ubuntu ubuntu-ports debian" \
        "RPM flavors: ol rocky almalinux centos rhel fedora epel"
    ok "target syntax valid"

    # Disk.
    local base="/srv/mirroret" probe avail
    probe="$base"; while [[ ! -d "$probe" && "$probe" != "/" ]]; do probe="$(dirname "$probe")"; done
    avail="$(df -BG --output=avail "$probe" 2>/dev/null | tail -1 | tr -dc '0-9')"
    if [[ -n "$avail" ]]; then
        local n_apt
        n_apt="$(printf '%s\n' ${APT_TARGETS} | sed 's/:.*//' | sort -u | grep -c . || true)"
        ok "free space on ${probe}: ${avail} GB"
        if [[ "$n_apt" -gt 0 ]] && [[ "$APT_COMPONENTS" == *universe* ]] \
           && [[ "$avail" -lt $(( n_apt * 400 )) ]]; then
            warn "APT components include universe: budget ~400-600 GB per flavor."
            info "You have ${avail} GB for ${n_apt} flavor(s)."
            info "Consider --components \"main restricted\" (roughly a tenth)."
            confirm "Continue anyway?" || exit 1
        fi
    fi

    # Upstream reachability. This is the gate that actually predicts success.
    local hosts
    hosts="$(upstream_hosts_for)"
    if [[ -n "$hosts" ]] && command -v curl >/dev/null 2>&1; then
        say ""
        info "Probing the upstreams your targets need:"
        local h code blocked=""
        for h in $hosts; do
            # `|| true`, never `|| echo 000`: the latter APPENDS to the value
            # curl already printed via -w, giving "000\n000" - which is not
            # equal to "000", so a blocked host would pass this gate. That is
            # the one gate whose whole purpose is to catch a blocked host.
            code="$(env ${PROXY:+https_proxy=$PROXY} curl -sS -o /dev/null \
                    -w '%{http_code}' --max-time 12 "https://${h}/" 2>/dev/null || true)"
            if [[ -z "$code" || "$code" == "000" ]]; then
                printf '        %-30s %sBLOCKED%s\n' "$h" "$C_ERR" "$C_OFF"
                blocked+=" ${h}"
            else
                printf '        %-30s %s%s%s\n' "$h" "$C_OK" "$code" "$C_OFF"
            fi
            _log "upstream ${h} = ${code}"
        done
        if [[ -n "$blocked" ]]; then
            gate_fail "The proxy is blocking upstream host(s):${blocked}" \
                "No sync of those ecosystems can succeed until this is opened." \
                "Ask the proxy team to permit CONNECT on 443 to them." \
                "" \
                "Note: security.ubuntu.com is separate from archive.ubuntu.com." \
                "Allowing only the archive gives a mirror with NO security updates." \
                "" \
                "If the proxy allows CONNECT on 443 only, plain-HTTP APT is blocked:" \
                "  re-run with --apt-scheme https" \
                "" \
                "To proceed with only the reachable ecosystems, drop the blocked" \
                "targets from --apt-targets / --rpm-targets and re-run."
        fi
        ok "every required upstream is reachable"
    fi
}

# -- Phase 2: config -----------------------------------------------------------

MANAGED_BEGIN="# >>> mirroret setup-mirror-server.sh (managed block) >>>"
MANAGED_END="# <<< mirroret setup-mirror-server.sh <<<"

phase_config() {
    CURRENT_PHASE=2
    phase 2 "Configuration"

    run mkdir -p /etc/mirroret
    if [[ ! -f "$CONF" ]] && [[ -f "${TREE_DIR}/config/mirroret.conf.example" ]]; then
        run install -m 0644 "${TREE_DIR}/config/mirroret.conf.example" "$CONF"
        ok "seeded ${CONF} from the shipped example"
    fi

    local block
    block="$(
        printf '%s\n' "$MANAGED_BEGIN"
        printf '# Written by setup-mirror-server.sh on %s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
        printf '# Edit freely; re-running the script replaces only this block.\n'
        [[ -n "$APT_TARGETS" ]] && printf 'MIRRORET_APT_TARGETS="%s"\n' "$APT_TARGETS"
        [[ -n "$RPM_TARGETS" ]] && printf 'MIRRORET_RPM_TARGETS="%s"\n' "$RPM_TARGETS"
        [[ -n "$APT_COMPONENTS" ]] && printf 'MIRRORET_APT_COMPONENTS="%s"\n' "$APT_COMPONENTS"
        [[ -n "$APT_SCHEME" ]] && printf 'MIRRORET_APT_SCHEME=%s\n' "$APT_SCHEME"
        printf 'MIRRORET_RPM_NEWEST_ONLY=1\n'
        printf 'MIRRORET_RPM_SOURCE=0\n'
        printf 'MIRRORET_RPM_DELETE=1\n'
        printf 'MIRRORET_APT_DELETE=1\n'
        printf 'MIRRORET_SYNC_MIN_FREE_GB=%s\n' "$MIN_FREE_GB"
        [[ -n "$MIN_DISK_GB" ]] && printf 'MIRRORET_MIN_DISK_GB=%s\n' "$MIN_DISK_GB"
        [[ -n "$SERVER_IP" ]] && printf 'MIRRORET_SERVER_IP=%s\n' "$SERVER_IP"
        [[ -n "$FIREWALL_SOURCE" ]] && printf 'MIRRORET_FIREWALL_SOURCE=%s\n' "$FIREWALL_SOURCE"
        if [[ -n "$PROXY" ]]; then
            printf '# cron and systemd read neither /etc/environment nor shell rc\n'
            printf 'http_proxy=%s\nhttps_proxy=%s\nno_proxy=%s\n' \
                "$PROXY" "$PROXY" "$NO_PROXY_LIST"
        fi
        [[ -n "$CA_BUNDLE" ]] && printf 'MIRRORET_CA_BUNDLE=%s\n' "$CA_BUNDLE"
        printf 'MIRRORET_INSTALL_DIR=%s\n' "$TREE_DIR"
        printf '%s\n' "$MANAGED_END"
    )"

    if [[ "$DRY_RUN" == "1" ]]; then
        say ""
        info "[dry-run] would write this block into ${CONF}:"
        printf '%s\n' "$block" | sed 's/^/          /'
        return 0
    fi

    # Replace only our own block, so operator edits elsewhere survive.
    local kept=""
    if [[ -f "$CONF" ]]; then
        cp -a "$CONF" "${CONF}.bak.$(date +%Y%m%d-%H%M%S)"
        kept="$(awk -v b="$MANAGED_BEGIN" -v e="$MANAGED_END" '
            $0 == b { skip = 1; next } $0 == e { skip = 0; next } !skip' "$CONF")"
    fi
    { printf '%s\n' "$kept"; printf '\n%s\n' "$block"; } > "${CONF}.new"
    mv "${CONF}.new" "$CONF"
    chmod 0644 "$CONF"
    ok "wrote managed block into ${CONF}"

    if [[ -n "$CA_BUNDLE" ]] && [[ ! -f "$CA_BUNDLE" ]]; then
        gate_fail "CA bundle not found: ${CA_BUNDLE}" \
            "Put the certificate there, or drop --ca-bundle."
    fi

    # Prove the file parses. A stray quote here breaks every later phase with
    # a confusing error, so catch it now.
    if ! bash -n "$CONF" 2>/dev/null; then
        gate_fail "${CONF} is not valid shell syntax." \
            "A previous manual edit is likely unbalanced." \
            "A timestamped backup is beside it."
    fi
    ok "${CONF} parses cleanly"
}

# -- Phase 3: install ----------------------------------------------------------

phase_install() {
    CURRENT_PHASE=3
    phase 3 "Install / upgrade"

    local -a args=()
    [[ -d /srv/mirroret ]] && args+=(--upgrade)
    args+=(--non-interactive)
    [[ ${#EXTRA_INSTALL_ARGS[@]} -gt 0 ]] && args+=("${EXTRA_INSTALL_ARGS[@]}")
    [[ "$SKIP_FIREWALL" == "1" ]] && args+=(--no-firewall)

    if [[ "${args[0]:-}" == "--upgrade" ]]; then
        info "existing install detected: using --upgrade (mirror data untouched)"
    else
        info "no existing install: doing a full install"
    fi

    # Preview first, always. It costs seconds and catches a config that is
    # not being read at all.
    #
    # The preview is handed the settings via the environment. In a real run
    # phase 2 has already written them to the conf file, but under --dry-run
    # it has not - and a preview that cannot see the operator's own settings
    # predicts a different run than the real one, which defeats the point.
    local -a penv=()
    [[ -n "$APT_TARGETS" ]]    && penv+=("MIRRORET_APT_TARGETS=${APT_TARGETS}")
    [[ -n "$RPM_TARGETS" ]]    && penv+=("MIRRORET_RPM_TARGETS=${RPM_TARGETS}")
    [[ -n "$APT_COMPONENTS" ]] && penv+=("MIRRORET_APT_COMPONENTS=${APT_COMPONENTS}")
    [[ -n "$MIN_DISK_GB" ]]    && penv+=("MIRRORET_MIN_DISK_GB=${MIN_DISK_GB}")
    [[ -n "$MIN_FREE_GB" ]]    && penv+=("MIRRORET_SYNC_MIN_FREE_GB=${MIN_FREE_GB}")
    [[ -n "$SERVER_IP" ]]      && penv+=("MIRRORET_SERVER_IP=${SERVER_IP}")
    [[ -n "$APT_SCHEME" ]]     && penv+=("MIRRORET_APT_SCHEME=${APT_SCHEME}")

    say ""
    info "Previewing (changes nothing)..."
    local preview
    if ! preview="$(cd "$TREE_DIR" && env "${penv[@]}" ./install.sh "${args[@]}" --dry-run 2>&1)"; then
        if printf '%s' "$preview" | grep -q 'insufficient disk space'; then
            local have floor
            have="$(printf '%s' "$preview" | grep -oE 'space \([0-9]+ GB\)' \
                    | grep -oE '[0-9]+' | head -1)"
            floor="$(printf '%s' "$preview" | grep -oE 'minimum \([0-9]+ GB\)' \
                     | grep -oE '[0-9]+' | head -1)"
            gate_fail "install.sh refuses to install: not enough free disk." \
                "It sees ${have:-?} GB free and wants at least ${floor:-50} GB." \
                "" \
                "That floor is a blanket default, not a calculation from your" \
                "targets. Decide deliberately:" \
                "" \
                "  * Genuinely short of space? Reduce what you mirror:" \
                "      --components \"main restricted\"   (roughly a tenth)" \
                "      fewer entries in --apt-targets / --rpm-targets" \
                "  * Running a small pilot on purpose? Lower the floor:" \
                "      --min-disk-gb ${have:-20}" \
                "  * Mirror data lives elsewhere? Point the base dir at it:" \
                "      MIRRORET_BASE_DIR=/data/mirroret in /etc/mirroret/mirroret.conf" \
                "" \
                "A full Ubuntu flavor is 300-600 GB with all components."
        fi
        printf '%s\n' "$preview" | tail -25 | sed 's/^/        /'
        gate_fail "install.sh --dry-run failed." \
            "The output above is the reason. Nothing was changed."
    fi
    _log "$preview"

    local shown_apt shown_rpm
    shown_apt="$(printf '%s\n' "$preview" | grep -m1 '^APT targets:' || true)"
    shown_rpm="$(printf '%s\n' "$preview" | grep -m1 '^RPM targets:' || true)"
    [[ -n "$shown_apt" ]] && info "$shown_apt"
    [[ -n "$shown_rpm" ]] && info "$shown_rpm"

    if [[ -n "$APT_TARGETS" ]] && [[ "$shown_apt" == *NONE* ]]; then
        gate_fail "APT targets were requested but install.sh resolved NONE." \
            "The config is not being read. Check ${CONF} for" \
            "MIRRORET_APT_TARGETS, and that nothing later in the file" \
            "overrides it."
    fi
    if [[ -n "$RPM_TARGETS" ]] && [[ "$shown_rpm" == *NONE* ]]; then
        gate_fail "RPM targets were requested but install.sh resolved NONE." \
            "Check MIRRORET_RPM_TARGETS in ${CONF}."
    fi
    ok "preview resolved the expected targets"

    if [[ "$DRY_RUN" == "1" ]]; then
        info "[dry-run] would now run: ./install.sh ${args[*]}"
        return 0
    fi

    confirm "Apply this configuration now?" || { say "Aborted at your request."; exit 1; }

    say ""
    info "Running install.sh (output in ${LOG})..."
    if ! (cd "$TREE_DIR" && ./install.sh "${args[@]}") >>"$LOG" 2>&1; then
        tail -30 "$LOG" | sed 's/^/        /'
        gate_fail "install.sh failed." \
            "The tail of its output is above; the full log is ${LOG}."
    fi
    ok "install.sh completed"

    # GATE: what is on disk must match what was asked for.
    local diff_out
    if ! diff_out="$(cd "$TREE_DIR" && ./mirroretctl config diff 2>&1)"; then
        printf '%s\n' "$diff_out" | sed 's/^/        /'
        gate_fail "Configuration and generated state disagree." \
            "The report above names what is missing."
    fi
    ok "config matches the generated specs"

    if ! (cd "$TREE_DIR" && ./mirroretctl targets) >>"$LOG" 2>&1; then
        warn "mirroretctl targets returned non-zero; see ${LOG}"
    fi
    (cd "$TREE_DIR" && ./mirroretctl targets 2>&1) | sed 's/^/        /'
}

# -- Phase 4: firewall ---------------------------------------------------------

phase_firewall() {
    CURRENT_PHASE=4
    phase 4 "Firewall"

    if [[ "$SKIP_FIREWALL" == "1" ]]; then
        info "--skip-firewall given; leaving rules alone"
        return 0
    fi

    local ports=(8080 8081 4873 5000)
    if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
        local p
        for p in "${ports[@]}"; do
            if [[ -n "$FIREWALL_SOURCE" ]]; then
                run firewall-cmd --permanent \
                    --add-rich-rule="rule family=ipv4 source address=${FIREWALL_SOURCE} port port=${p} protocol=tcp accept" >/dev/null
            else
                run firewall-cmd --permanent --add-port="${p}/tcp" >/dev/null
            fi
        done
        run firewall-cmd --reload >/dev/null
        ok "firewalld: opened ${ports[*]}${FIREWALL_SOURCE:+ for ${FIREWALL_SOURCE}}"
    elif command -v ufw >/dev/null 2>&1 && ufw status >/dev/null 2>&1; then
        local p
        for p in "${ports[@]}"; do
            if [[ -n "$FIREWALL_SOURCE" ]]; then
                run ufw allow from "$FIREWALL_SOURCE" to any port "$p" proto tcp >/dev/null
            else
                run ufw allow "${p}/tcp" >/dev/null
            fi
        done
        ok "ufw: opened ${ports[*]}${FIREWALL_SOURCE:+ from ${FIREWALL_SOURCE}}"
    else
        warn "no firewalld or ufw detected; open these TCP ports yourself:"
        info "8080 nginx (APT/RPM)  8081 pip  4873 npm  5000 docker"
    fi
}

# -- Phase 5: sync -------------------------------------------------------------

phase_sync() {
    CURRENT_PHASE=5
    phase 5 "First sync"

    if [[ "$SKIP_SYNC" == "1" ]]; then
        info "--skip-sync given. Run these when ready:"
        info "  sudo mirroretctl sync rpm"
        info "  sudo mirroretctl sync apt"
        return 0
    fi
    if [[ "$DRY_RUN" == "1" ]]; then
        info "[dry-run] would sync: rpm, apt, pip, npm"
        return 0
    fi

    say ""
    info "This downloads real package data and can take hours."
    info "Progress: tail -f ${LOG}   or   mirroretctl logs tail"
    confirm "Start the first sync now?" || {
        say ""
        info "Skipped. When ready: sudo mirroretctl sync rpm && sudo mirroretctl sync apt"
        SKIP_SYNC=1
        return 0
    }

    # RPM first: usually the bulk of the data.
    local what failed=0
    for what in rpm apt pip npm; do
        case "$what" in
            rpm) [[ -n "$RPM_TARGETS" ]] || continue ;;
            apt) [[ -n "$APT_TARGETS" ]] || continue ;;
        esac
        say ""
        info "--- syncing ${what} ..."
        if (cd "$TREE_DIR" && ./mirroretctl sync "$what") >>"$LOG" 2>&1; then
            ok "${what} sync completed"
        else
            local rc=$?
            warn "${what} sync exited ${rc}"
            grep -E 'ABORT|ERROR|FAIL' "$LOG" | tail -8 | sed 's/^/        /' || true
            failed=$(( failed + 1 ))
        fi
    done

    if [[ "$failed" -gt 0 ]]; then
        warn "${failed} sync step(s) did not finish cleanly."
        info "Phase 6 will show exactly what that means for clients."
        info "Details: mirroretctl logs errors"
    fi
}

# -- Phase 6: verify -----------------------------------------------------------

phase_verify() {
    CURRENT_PHASE=6
    phase 6 "Verification (does a client actually work?)"

    if [[ "$DRY_RUN" == "1" ]]; then
        info "[dry-run] would run: targets, serve, client verify, client simulate"
        return 0
    fi

    local hard=0

    say ""
    info "--- what this server serves"
    (cd "$TREE_DIR" && ./mirroretctl targets 2>&1) | tee -a "$LOG" | sed 's/^/        /'

    say ""
    info "--- HTTP endpoints"
    if (cd "$TREE_DIR" && ./mirroretctl serve) >>"$LOG" 2>&1; then
        ok "every endpoint answered"
    else
        warn "at least one endpoint did not answer as expected"
        (cd "$TREE_DIR" && ./mirroretctl serve 2>&1) | sed 's/^/        /'
        hard=1
    fi

    say ""
    info "--- client configs vs what is really published"
    if (cd "$TREE_DIR" && ./mirroretctl client verify) >>"$LOG" 2>&1; then
        ok "client configs are consistent with the published mirror"
    else
        warn "client configs advertise something that is not published"
        (cd "$TREE_DIR" && ./mirroretctl client verify 2>&1) | sed 's/^/        /'
        hard=1
    fi

    if [[ "$SKIP_SYNC" != "1" ]] && [[ -n "$RPM_TARGETS" ]] && command -v dnf >/dev/null 2>&1; then
        say ""
        info "--- acting as a client: resolve AND download"
        if (cd "$TREE_DIR" && ./mirroretctl client simulate) >>"$LOG" 2>&1; then
            ok "a client can resolve and download from this mirror"
        else
            warn "client simulation failed"
            (cd "$TREE_DIR" && ./mirroretctl client simulate 2>&1) | tail -20 | sed 's/^/        /'
            hard=1
        fi
    fi

    if [[ "$hard" != "0" ]]; then
        say ""
        warn "The server is configured but NOT yet proven good for clients."
        info "Do not roll clients out until the warnings above are resolved."
        info "Most common cause: a sync has not completed. Re-run:"
        info "  sudo mirroretctl sync apt   /   sudo mirroretctl sync rpm"
        info "Then: mirroretctl client verify"
        return 1
    fi
    ok "verification passed"
    return 0
}

# -- Summary -------------------------------------------------------------------

print_summary() {
    local ip
    ip="$(cd "$TREE_DIR" && ./mirroretctl client list 2>/dev/null \
          | grep -m1 -oE 'http://[^/]+' | sed 's|http://||')"
    ip="${ip:-<server-ip>:8080}"

    printf '\n%s=== NEXT: POINT THE CLIENTS AT IT ===%s\n\n' "$C_HEAD" "$C_OFF"
    say "On each client, run:"
    say ""
    say "  curl -fsSL -o /tmp/setup-mirror-client.sh \\"
    say "      http://${ip}/config/setup-mirror-client.sh"
    say "  sudo bash /tmp/setup-mirror-client.sh --server ${ip}"
    say ""
    say "That script detects the client's distro, installs the matching config,"
    say "disables the upstream repos (reversibly) and verifies the result."
    say ""
    say "Server housekeeping:"
    say "  mirroretctl                 interactive menu"
    say "  mirroretctl targets         what this box serves, and whether it synced"
    say "  mirroretctl logs errors     what failed recently"
    say "  mirroretctl report          one shareable txt file describing everything"
    say ""
    say "Transcript of this run: ${LOG}"
}

# -- Main ----------------------------------------------------------------------

main() {
    if [[ "$DRY_RUN" == "1" ]]; then
        LOG="$(mktemp /tmp/mirroret-setup-dryrun.XXXXXX.log)"
    else
        [[ "$(id -u)" -eq 0 ]] || { printf 'Run as root (sudo).\n' >&2; exit 1; }
        mkdir -p /var/log
        LOG="/var/log/mirroret-setup-$(date +%Y%m%d-%H%M%S).log"
        : > "$LOG"
    fi

    printf '%smirroret server setup%s\n' "$C_HEAD" "$C_OFF"
    printf 'tree : %s\n' "$TREE_DIR"
    printf 'host : %s\n' "$(hostname 2>/dev/null || echo unknown)"
    printf 'log  : %s\n' "$LOG"
    [[ "$DRY_RUN" == "1" ]] && printf '%sDRY RUN - nothing will be changed%s\n' "$C_WARN" "$C_OFF"

    local rc=0
    [[ "$START_PHASE" -le 1 ]] && phase_preflight
    # Later phases need the targets even when resuming past phase 1.
    if [[ "$START_PHASE" -gt 1 ]] && [[ -z "$APT_TARGETS$RPM_TARGETS" ]] && [[ -f "$CONF" ]]; then
        # shellcheck disable=SC1090
        APT_TARGETS="$(bash -c ". '$CONF' >/dev/null 2>&1; printf '%s' \"\${MIRRORET_APT_TARGETS:-}\"")"
        RPM_TARGETS="$(bash -c ". '$CONF' >/dev/null 2>&1; printf '%s' \"\${MIRRORET_RPM_TARGETS:-}\"")"
        info "resumed targets from ${CONF}"
    fi
    [[ "$START_PHASE" -le 2 ]] && phase_config
    [[ "$START_PHASE" -le 3 ]] && phase_install
    [[ "$START_PHASE" -le 4 ]] && phase_firewall
    [[ "$START_PHASE" -le 5 ]] && phase_sync
    if [[ "$START_PHASE" -le 6 ]]; then
        phase_verify || rc=1
    fi

    print_summary
    if [[ "$rc" -ne 0 ]]; then
        printf '\n%sFinished WITH WARNINGS - see phase 6 above.%s\n' "$C_WARN" "$C_OFF"
    else
        printf '\n%sFinished. The mirror is ready for clients.%s\n' "$C_OK" "$C_OFF"
    fi
    return "$rc"
}

main "$@"

#!/usr/bin/env bash
# Point THIS machine at a mirroret server.
#
# Detects the distribution, installs the matching client config, disables the
# upstream repositories and verifies that packages really come from the
# mirror.
#
# This changes how the machine gets software, so:
#
#   * Everything it disables is backed up first, and --rollback puts it all
#     back. The backup is a directory of the original files, not a diff.
#   * It refuses to guess. If the server does not publish a config for this
#     exact release it lists what IS available and stops, rather than pointing
#     you at the wrong one.
#   * It verifies at the end by resolving AND installing a package. "apt-get
#     update succeeded" is not proof the mirror is usable.
#   * --dry-run changes nothing.
#
# Usage:
#   sudo ./setup-mirror-client.sh --server 192.168.30.110
#   sudo ./setup-mirror-client.sh --server 192.168.30.110:8080 --yes
#   sudo ./setup-mirror-client.sh --rollback
#   sudo ./setup-mirror-client.sh --help

set -Eeuo pipefail

SERVER=""
WEB_PORT="8080"
NPM_PORT="4873"
DO_PIP=1
DO_NPM=1
DO_DOCKER=0
ASSUME_YES=0
DRY_RUN=0
ROLLBACK=0
KEEP_UPSTREAM=0
RELEASE_OVERRIDE=""
CONFIG_OVERRIDE=""
BACKUP_ROOT="/var/backups/mirroret-client"

usage() {
    awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' \
        "${BASH_SOURCE[0]}"
    cat <<'USAGE'

Options:
  --server HOST[:PORT]   mirror server (required unless --rollback)
  --release NAME         override the detected release (e.g. jammy, 9).
                         Use when this machine's codename differs from the
                         mirrored one you want to consume.
  --config NAME          use this exact published config, e.g.
                         debian-bookworm.list or rocky9.repo. Overrides all
                         detection - use it when the flavor differs too, not
                         just the release.
  --keep-upstream        install the mirror config but leave the upstream
                         repos enabled. Useful for a cautious first pass;
                         note the machine may still reach the internet.
  --no-pip               skip /etc/pip.conf
  --no-npm               skip ~/.npmrc
  --docker               also configure the Docker registry mirror
  --rollback             restore the most recent backup and remove the
                         mirror config
  -y, --yes              non-interactive
  --dry-run              show what would change, change nothing
  -h, --help             this text
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --server)        shift; SERVER="${1:-}" ;;
        --release)       shift; RELEASE_OVERRIDE="${1:-}" ;;
        --config)        shift; CONFIG_OVERRIDE="${1:-}" ;;
        --keep-upstream) KEEP_UPSTREAM=1 ;;
        --no-pip)        DO_PIP=0 ;;
        --no-npm)        DO_NPM=0 ;;
        --docker)        DO_DOCKER=1 ;;
        --rollback)      ROLLBACK=1 ;;
        -y|--yes)        ASSUME_YES=1 ;;
        --dry-run)       DRY_RUN=1 ;;
        -h|--help)       usage; exit 0 ;;
        *) printf 'Unknown option: %s\nRun with --help.\n' "$1" >&2; exit 2 ;;
    esac
    shift
done

if [[ -t 1 ]]; then
    C_OK=$'\033[32m'; C_ERR=$'\033[31m'; C_WARN=$'\033[33m'
    C_HEAD=$'\033[1;36m'; C_OFF=$'\033[0m'
else
    C_OK=""; C_ERR=""; C_WARN=""; C_HEAD=""; C_OFF=""
fi

step()  { printf '\n%s== %s%s\n' "$C_HEAD" "$*" "$C_OFF"; }
ok()    { printf '%s  ok%s    %s\n' "$C_OK" "$C_OFF" "$*"; }
warn()  { printf '%s  warn%s  %s\n' "$C_WARN" "$C_OFF" "$*"; }
info()  { printf '        %s\n' "$*"; }
die()   {
    printf '\n%s  STOP%s  %s\n' "$C_ERR" "$C_OFF" "$1"
    shift
    # Indent EVERY line, including embedded newlines from a list we built
    # up elsewhere - otherwise a multi-line argument comes out ragged.
    local l
    for l in "$@"; do printf '%s\n' "$l" | sed 's/^/        /'; done
    printf '\n'
    exit 1
}

run() {
    if [[ "$DRY_RUN" == "1" ]]; then printf '        [dry-run] %s\n' "$*"; return 0; fi
    "$@"
}

confirm() {
    [[ "$ASSUME_YES" == "1" ]] && return 0
    [[ ! -t 0 ]] && return 0
    local r; read -r -p "        $1 [Y/n] " r
    [[ -z "$r" || "$r" =~ ^[Yy] ]]
}

[[ "$(id -u)" -eq 0 ]] || die "Not running as root." "Re-run with sudo."

# -- Distro detection ----------------------------------------------------------

FAMILY=""       # debian | rhel
OS_ID=""
CODENAME=""
MAJOR=""

detect() {
    [[ -f /etc/os-release ]] || die "/etc/os-release is missing." \
        "Cannot identify this machine."
    # shellcheck disable=SC1091
    . /etc/os-release
    OS_ID="${ID:-unknown}"
    CODENAME="${VERSION_CODENAME:-}"
    MAJOR="${VERSION_ID%%.*}"

    case "$OS_ID" in
        ubuntu|debian|linuxmint|pop) FAMILY="debian" ;;
        rhel|ol|rocky|almalinux|centos|fedora) FAMILY="rhel" ;;
        *) die "Unsupported distribution: ${OS_ID}" \
               "This script handles Debian/Ubuntu and the RHEL family." ;;
    esac

    # Mint and Pop track an Ubuntu release, not their own codename.
    case "$OS_ID" in
        linuxmint|pop)
            CODENAME="${UBUNTU_CODENAME:-$CODENAME}"
            info "note: ${OS_ID} tracks Ubuntu ${CODENAME}"
            ;;
    esac

    if [[ -n "$RELEASE_OVERRIDE" ]]; then
        CODENAME="$RELEASE_OVERRIDE"
        MAJOR="$RELEASE_OVERRIDE"
        info "release overridden: ${RELEASE_OVERRIDE}"
    fi
    ok "detected: ${OS_ID} ${VERSION_ID:-?} (${FAMILY} family)"
}

# -- Backup / rollback ---------------------------------------------------------

BACKUP_DIR=""

new_backup() {
    BACKUP_DIR="${BACKUP_ROOT}/$(date +%Y%m%d-%H%M%S)"
    run mkdir -p "$BACKUP_DIR"
    [[ "$DRY_RUN" == "1" ]] || printf '%s\n' "$BACKUP_DIR" > "${BACKUP_ROOT}/latest"
}

# save <path> - copy a file or dir into the backup, preserving its full path.
save() {
    local src="$1"
    [[ -e "$src" ]] || return 0
    local dst="${BACKUP_DIR}${src}"
    run mkdir -p "$(dirname "$dst")"
    run cp -a "$src" "$dst"
    info "backed up ${src}"
}

do_rollback() {
    step "Rollback"
    local latest="${BACKUP_ROOT}/latest"
    [[ -f "$latest" ]] || die "No backup found in ${BACKUP_ROOT}." \
        "Nothing to roll back."
    local dir
    dir="$(cat "$latest")"
    [[ -d "$dir" ]] || die "Backup directory is missing: ${dir}"
    info "restoring from ${dir}"

    # Remove what we added.
    local f
    for f in /etc/apt/sources.list.d/mirroret.list \
             /etc/apt/sources.list.d/mirroret.sources \
             /etc/yum.repos.d/mirroret.repo; do
        [[ -e "$f" ]] && { run rm -f "$f"; info "removed ${f}"; }
    done
    # And the renamed originals. The real files come back from the backup
    # below; leaving these behind means a later rename recreates duplicate
    # sources for the same suite.
    while IFS= read -r -d '' f; do
        run rm -f "$f"
        info "removed leftover $(basename "$f")"
    done < <(find /etc/apt /etc/apt/sources.list.d -maxdepth 1 \
                  -name '*.disabled-by-mirroret' -print0 2>/dev/null)

    # Restore everything captured, at its original path.
    while IFS= read -r -d '' src; do
        local target="${src#"$dir"}"
        run mkdir -p "$(dirname "$target")"
        run cp -a "$src" "$target"
        info "restored ${target}"
    done < <(find "$dir" -mindepth 1 \( -type f -o -type l \) -print0)

    # Re-enable RHEL repos we disabled by name.
    if [[ -f "${dir}/.disabled-repos" ]] && command -v dnf >/dev/null 2>&1; then
        local ids
        ids="$(tr '\n' ' ' < "${dir}/.disabled-repos")"
        if [[ -n "${ids// /}" ]]; then
            # shellcheck disable=SC2086
            run dnf config-manager --set-enabled ${ids} 2>/dev/null || true
            info "re-enabled: ${ids}"
        fi
        run dnf config-manager --set-disabled 'mirroret-*' 2>/dev/null || true
    fi

    if command -v apt-get >/dev/null 2>&1; then
        run apt-get update -qq 2>/dev/null || true
    elif command -v dnf >/dev/null 2>&1; then
        run dnf clean all >/dev/null 2>&1 || true
    fi
    ok "rollback complete"
    printf '\n        This machine is back on its original repositories.\n\n'
    exit 0
}

[[ "$ROLLBACK" == "1" ]] && { detect; do_rollback; }

# -- Server reachability -------------------------------------------------------

BASE_URL=""

check_server() {
    [[ -n "$SERVER" ]] || die "--server is required." \
        "Example: sudo $0 --server 192.168.30.110"
    # Accept host or host:port.
    if [[ "$SERVER" == *:* ]]; then
        WEB_PORT="${SERVER##*:}"
        SERVER="${SERVER%%:*}"
    fi
    BASE_URL="http://${SERVER}:${WEB_PORT}"

    command -v curl >/dev/null 2>&1 || die "curl is not installed." \
        "Install it first: dnf install -y curl / apt-get install -y curl"

    # Treat empty and 000 alike: curl prints 000 when it never connected, and
    # prints nothing at all if it dies before -w is evaluated.
    local code
    code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 \
            "${BASE_URL}/config/" 2>/dev/null || true)"
    if [[ -z "$code" || "$code" == "000" ]]; then
        die "Cannot reach ${BASE_URL}/config/" \
            "Checks, in order:" \
            "  1. Is the mirror server up?      ping ${SERVER}" \
            "  2. Is port ${WEB_PORT} open on it?     nc -vz ${SERVER} ${WEB_PORT}" \
            "  3. On the SERVER: mirroretctl serve" \
            "  4. Is a proxy env var hijacking this? Try:" \
            "       no_proxy=${SERVER} sudo -E $0 --server ${SERVER}"
    fi
    ok "mirror reachable: ${BASE_URL} (HTTP ${code})"
}

# list what the server actually publishes
available_configs() {
    curl -sS --max-time 15 "${BASE_URL}/config/" 2>/dev/null \
        | grep -oE '[A-Za-z0-9._-]+\.(list|sources|repo|conf)' \
        | sort -u
}

fetch_or_die() {
    local name="$1" dest="$2"
    local code
    code="$(curl -sS -o "$dest.tmp" -w '%{http_code}' --max-time 30 \
            "${BASE_URL}/config/${name}" 2>/dev/null || true)"
    if [[ "${code:-000}" != "200" ]]; then
        rm -f "$dest.tmp"
        return 1
    fi
    # The config must point at the SERVER:PORT we were given - checking only
    # the host lets a stale MIRRORET_SERVER_IP through, and the client then
    # fails later with a bare "connection refused" that looks like a network
    # fault rather than a server misconfiguration.
    local advertised
    advertised="$(grep -oE 'https?://[^ /]+' "$dest.tmp" | sort -u | head -3 | tr '\n' ' ')"
    if ! grep -qE "https?://${SERVER}:${WEB_PORT}([/ ]|$)" "$dest.tmp"; then
        rm -f "$dest.tmp"
        die "${name} does not point at ${SERVER}:${WEB_PORT}." \
            "It points at: ${advertised:-(nothing recognisable)}" \
            "" \
            "The mirror server is generating client configs for the wrong" \
            "address. Clients would fail with 'connection refused'." \
            "" \
            "Fix on the SERVER:" \
            "  echo 'MIRRORET_SERVER_IP=${SERVER}' >> /etc/mirroret/mirroret.conf" \
            "  sudo mirroretctl upgrade" \
            "  mirroretctl client show ${name}   # confirm the address" \
            "" \
            "Or, if that address is correct and this one is not, re-run me" \
            "with --server pointing at it."
    fi
    mv "$dest.tmp" "$dest"
    return 0
}

# -- APT ----------------------------------------------------------------------

setup_apt() {
    step "APT configuration"

    local want="${OS_ID}-${CODENAME}.list"
    # Mint/Pop consume the Ubuntu tree.
    case "$OS_ID" in linuxmint|pop) want="ubuntu-${CODENAME}.list" ;; esac
    [[ -n "$CONFIG_OVERRIDE" ]] && want="$CONFIG_OVERRIDE"

    local avail
    # Exclude the legacy alias copies: they duplicate a real target and
    # offering them as a choice just invites picking the wrong one.
    avail="$(available_configs | grep -E '\.list$' \
             | grep -vE '^(debian|redhat)-client\.' || true)"
    if [[ -z "$avail" ]]; then
        die "The server publishes no APT client configs at all." \
            "It has no APT target configured, so it mirrors no .deb." \
            "On the SERVER:" \
            "  mirroretctl targets" \
            "  # then set MIRRORET_APT_TARGETS=\"${OS_ID}:${CODENAME}\" and:" \
            "  sudo mirroretctl upgrade && sudo mirroretctl sync apt"
    fi

    if ! printf '%s\n' "$avail" | grep -qx "$want"; then
        die "The server does not publish a config for ${OS_ID} ${CODENAME}." \
            "It publishes:" \
            "$(printf '%s\n' "$avail" | sed 's/^/  /')" \
            "" \
            "Either add this release on the SERVER:" \
            "  MIRRORET_APT_TARGETS=\"...existing... ${OS_ID}:${CODENAME}\"" \
            "  sudo mirroretctl upgrade && sudo mirroretctl sync apt" \
            "or, if you deliberately want one of the above, name it:" \
            "  --config <one-of-the-names-above>"
    fi
    ok "server publishes ${want}"

    local tmp="/tmp/mirroret-client.list.$$"
    fetch_or_die "$want" "$tmp" || die "Could not download ${want}."

    new_backup
    save /etc/apt/sources.list
    local f
    for f in /etc/apt/sources.list.d/*; do
        [[ -e "$f" ]] && save "$f"
    done

    run install -m 0644 "$tmp" /etc/apt/sources.list.d/mirroret.list
    rm -f "$tmp"
    ok "installed /etc/apt/sources.list.d/mirroret.list"

    if [[ "$KEEP_UPSTREAM" == "1" ]]; then
        warn "--keep-upstream: leaving the upstream repos enabled"
        info "This machine may still fetch packages from the internet."
    else
        # Disabling upstream is the step that makes the mirror authoritative.
        if [[ -f /etc/apt/sources.list ]] && grep -qE '^\s*deb ' /etc/apt/sources.list; then
            run mv /etc/apt/sources.list /etc/apt/sources.list.disabled-by-mirroret
            ok "disabled /etc/apt/sources.list"
        fi
        # deb822 hosts (Ubuntu 24.04+, Debian 12+) keep them here instead.
        for f in /etc/apt/sources.list.d/ubuntu.sources \
                 /etc/apt/sources.list.d/debian.sources; do
            if [[ -f "$f" ]]; then
                run mv "$f" "${f}.disabled-by-mirroret"
                ok "disabled $(basename "$f")"
            fi
        done
    fi

    if [[ "$DRY_RUN" == "1" ]]; then
        info "[dry-run] would run: apt-get update"
        return 0
    fi

    step "APT verification"
    if ! apt-get update 2>&1 | tee /tmp/mirroret-aptupdate.$$ | tail -5; then
        warn "apt-get update reported errors"
    fi
    if grep -qE 'Could not connect|Unable to connect|Connection refused|Temporary failure' \
            /tmp/mirroret-aptupdate.$$; then
        local detail
        detail="$(grep -m2 -E 'Could not connect|Unable to connect' \
                  /tmp/mirroret-aptupdate.$$ || true)"
        rm -f /tmp/mirroret-aptupdate.$$
        die "apt cannot REACH the address in the config." \
            "${detail}" \
            "" \
            "This is a network or address problem, not a missing package:" \
            "  1. Is that the right address?  mirroretctl client show on the server" \
            "  2. Is the port open?           nc -vz ${SERVER} ${WEB_PORT}" \
            "  3. Is nginx up?                on the server: mirroretctl serve" \
            "  4. Proxy hijacking it?         add ${SERVER} to no_proxy" \
            "" \
            "To undo the change on this machine now:" \
            "  sudo $0 --rollback"
    fi
    if grep -qE '^(E|W): .*(404|File not found)' /tmp/mirroret-aptupdate.$$; then
        rm -f /tmp/mirroret-aptupdate.$$
        die "apt reached the mirror but some indices are missing (404)." \
            "The server advertises a suite it has not published yet." \
            "On the SERVER, run:" \
            "  mirroretctl client verify     # names the unpublished suites" \
            "  sudo mirroretctl sync apt" \
            "" \
            "To undo the change on this machine now:" \
            "  sudo $0 --rollback"
    fi
    if grep -qE '^E: ' /tmp/mirroret-aptupdate.$$; then
        grep -E '^E: ' /tmp/mirroret-aptupdate.$$ | head -5 | sed 's/^/        /'
        rm -f /tmp/mirroret-aptupdate.$$
        die "apt-get update failed. The errors are above." \
            "To undo the change on this machine now:  sudo $0 --rollback"
    fi
    rm -f /tmp/mirroret-aptupdate.$$

    # Is the mirror in apt's list of sources at all?
    if apt-cache policy 2>/dev/null | grep -q "$SERVER"; then
        ok "apt lists ${SERVER} as a package source"
    else
        warn "apt-cache policy does not mention ${SERVER} at all"
        apt-cache policy 2>/dev/null | head -12 | sed 's/^/        /'
        die "The mirror is not among apt's sources." \
            "Check /etc/apt/sources.list.d/mirroret.list and re-run apt-get update." \
            "To undo:  sudo $0 --rollback"
    fi

    # Download a package the MIRROR actually provides.
    #
    # Testing with a fixed name like "bash" is worthless: if the mirror does
    # not carry it, apt satisfies the request from the installed version and
    # the test reports success while nothing came from the mirror at all. So
    # read a package name out of the mirror's OWN index.
    #
    # Two details that are easy to get wrong: apt keeps the dots in a
    # numeric host (127.0.0.1:19099_...), and it stores indices compressed
    # (.lz4 by default on modern apt), so the file needs decompressing
    # before it is greppable. apt-helper cat-file handles every compression
    # apt itself uses.
    local idx pkg="" content
    idx="$(find /var/lib/apt/lists -maxdepth 1 -type f \
           -name "*${SERVER}:${WEB_PORT}*_Packages*" 2>/dev/null | head -1 || true)"

    if [[ -n "$idx" ]]; then
        if [[ -x /usr/lib/apt/apt-helper ]]; then
            content="$(/usr/lib/apt/apt-helper cat-file "$idx" 2>/dev/null || true)"
        fi
        if [[ -z "${content:-}" ]]; then
            case "$idx" in
                *.gz)  content="$(zcat "$idx" 2>/dev/null || true)" ;;
                *.xz)  content="$(xzcat "$idx" 2>/dev/null || true)" ;;
                *.lz4) content="$(lz4cat "$idx" 2>/dev/null || true)" ;;
                *)     content="$(cat "$idx" 2>/dev/null || true)" ;;
            esac
        fi
        # Take the package AND its version from the same stanza. Downloading
        # by bare name fetches apt's *candidate*, which on a machine with any
        # other source is often not the mirror's copy - so the test would
        # pass or fail for reasons unrelated to the mirror.
        pkg="$(printf '%s\n' "${content:-}" | awk '
            /^Package: / { p = $2 }
            /^Version: / { if (p != "") { print p "=" $2; exit } }')"
    fi

    if [[ -z "$pkg" ]]; then
        warn "could not read a package name out of the mirror's index"
        [[ -n "$idx" ]] && info "index: ${idx}"
        info "apt has the mirror configured, but its index looks empty."
        info "On the SERVER:  mirroretctl targets   (has the sync completed?)"
        return 0
    fi

    info "test package, pinned to the mirror's own version: ${pkg}"
    local dl="/tmp/mirroret-dltest.$$"
    rm -rf "$dl"; mkdir -p "$dl"
    if (cd "$dl" && apt-get download "$pkg" >/dev/null 2>&1); then
        local deb
        deb="$(find "$dl" -name '*.deb' | head -1)"
        if [[ -n "$deb" ]]; then
            ok "downloaded ${pkg} from the mirror ($(stat -c%s "$deb") bytes)"
        else
            warn "apt-get download reported success but produced no .deb"
        fi
    else
        warn "could not download ${pkg} from the mirror"
        info "Its index lists that exact version but the .deb is not fetchable."
        info "On the SERVER:"
        info "  mirroretctl client verify"
        info "  sudo mirroretctl sync apt"
    fi
    rm -rf "$dl"
}

# -- RPM ----------------------------------------------------------------------

setup_rpm() {
    step "RPM configuration"

    local avail want=""
    avail="$(available_configs | grep -E '\.repo$' | grep -v '^redhat-client' || true)"
    if [[ -z "$avail" ]]; then
        die "The server publishes no RPM client configs at all." \
            "It has no RPM target configured, so it mirrors no .rpm." \
            "On the SERVER:" \
            "  mirroretctl targets" \
            "  # then set MIRRORET_RPM_TARGETS=\"${OS_ID}:${MAJOR}\" and:" \
            "  sudo mirroretctl upgrade && sudo mirroretctl sync rpm"
    fi

    # Prefer this machine's own flavor; fall back to a compatible one only
    # with the operator's explicit agreement.
    if [[ -n "$CONFIG_OVERRIDE" ]]; then
        if ! printf '%s\n' "$avail" | grep -qx "$CONFIG_OVERRIDE"; then
            die "The server does not publish ${CONFIG_OVERRIDE}." \
                "It publishes:" \
                "$(printf '%s\n' "$avail" | sed 's/^/  /')"
        fi
        want="$CONFIG_OVERRIDE"
        ok "using ${want} (named explicitly)"
    elif printf '%s\n' "$avail" | grep -qx "${OS_ID}${MAJOR}.repo"; then
        want="${OS_ID}${MAJOR}.repo"
        ok "server publishes ${want} (exact match)"
    else
        warn "no exact match for ${OS_ID} ${MAJOR}. The server publishes:"
        printf '%s\n' "$avail" | sed 's/^/          /'
        # Same-major RHEL-family repos are generally interchangeable, but
        # that is the operator's call, not ours.
        local cand
        cand="$(printf '%s\n' "$avail" | grep -E "^(rocky|almalinux|ol|centos|rhel)${MAJOR}\.repo$" | head -1 || true)"
        if [[ -z "$cand" ]]; then
            die "Nothing published for major version ${MAJOR}." \
                "Add it on the SERVER:" \
                "  MIRRORET_RPM_TARGETS=\"...existing... ${OS_ID}:${MAJOR}\"" \
                "  sudo mirroretctl upgrade && sudo mirroretctl sync rpm" \
                "" \
                "Or name one of the published configs explicitly:" \
                "  --config <name>"
        fi
        info "closest same-major candidate: ${cand}"
        info "RHEL-family repos of the same major are usually compatible,"
        info "but this is a deliberate choice - packages will come from"
        info "${cand%%.repo} rather than ${OS_ID}${MAJOR}."
        confirm "Use ${cand}?" || die "Declined." \
            "Add ${OS_ID}:${MAJOR} on the server, or name a config with --config."
        want="$cand"
    fi

    local tmp="/tmp/mirroret-client.repo.$$"
    fetch_or_die "$want" "$tmp" || die "Could not download ${want}."

    new_backup
    local f
    for f in /etc/yum.repos.d/*.repo; do
        [[ -e "$f" ]] && save "$f"
    done

    run install -m 0644 "$tmp" /etc/yum.repos.d/mirroret.repo
    rm -f "$tmp"
    ok "installed /etc/yum.repos.d/mirroret.repo"

    if [[ "$KEEP_UPSTREAM" == "1" ]]; then
        warn "--keep-upstream: leaving the upstream repos enabled"
        info "dnf may still prefer the internet for some packages."
    else
        # Record what we disable so rollback can put it back precisely.
        local enabled=""
        if command -v dnf >/dev/null 2>&1; then
            enabled="$(dnf repolist --enabled 2>/dev/null \
                       | awk 'NR>1 {print $1}' | grep -v '^mirroret-' || true)"
        fi
        if [[ "$DRY_RUN" != "1" ]] && [[ -n "$enabled" ]]; then
            printf '%s\n' "$enabled" > "${BACKUP_DIR}/.disabled-repos"
        fi
        if command -v dnf >/dev/null 2>&1; then
            run dnf config-manager --set-disabled '*' >/dev/null 2>&1 || \
                warn "could not disable all repos; check dnf config-manager"
            run dnf config-manager --set-enabled 'mirroret-*' >/dev/null 2>&1 || \
                warn "could not enable mirroret-*"
            ok "disabled upstream repos, enabled mirroret-*"
        else
            warn "dnf not found; disable the upstream .repo files by hand"
        fi
    fi

    if [[ "$DRY_RUN" == "1" ]]; then
        info "[dry-run] would run: dnf clean all && dnf makecache"
        return 0
    fi

    step "RPM verification"
    run dnf clean all >/dev/null 2>&1 || true
    if ! dnf makecache 2>&1 | tail -4; then
        die "dnf could not load metadata from the mirror." \
            "Most likely that repo has not been synced yet." \
            "On the SERVER:" \
            "  mirroretctl client verify     # names repos with no metadata" \
            "  sudo mirroretctl sync rpm" \
            "" \
            "To undo the change on this machine now:" \
            "  sudo $0 --rollback"
    fi

    local repos
    repos="$(dnf repolist --enabled 2>/dev/null | awk 'NR>1 {print $1}' | tr '\n' ' ')"
    info "enabled repos: ${repos}"
    if [[ "$KEEP_UPSTREAM" != "1" ]] && printf '%s' "$repos" | grep -qvE '^(mirroret-[^ ]+ )*$'; then
        : # informational only; the list is printed above
    fi

    if dnf -y reinstall bash >/dev/null 2>&1 || dnf -y install bash >/dev/null 2>&1; then
        ok "installed a package through the mirror"
    else
        warn "test install failed; try: dnf -y reinstall bash"
    fi
}

# -- pip / npm / docker --------------------------------------------------------

setup_pip() {
    [[ "$DO_PIP" == "1" ]] || return 0
    local code
    code="$(curl -sS -o /tmp/mirroret-pip.$$ -w '%{http_code}' --max-time 15 \
            "${BASE_URL}/config/pip.conf" 2>/dev/null || true)"
    if [[ "${code:-000}" != "200" ]]; then
        rm -f /tmp/mirroret-pip.$$
        info "pip: server publishes no pip.conf (pip mirroring disabled there)"
        return 0
    fi
    step "pip configuration"
    save /etc/pip.conf
    run install -m 0644 /tmp/mirroret-pip.$$ /etc/pip.conf
    rm -f /tmp/mirroret-pip.$$
    ok "installed /etc/pip.conf"
    if [[ "$DRY_RUN" != "1" ]] && command -v pip3 >/dev/null 2>&1; then
        if pip3 download --no-deps --no-cache-dir -d /tmp/mirroret-piptest.$$ \
               requests >/dev/null 2>&1; then
            ok "pip downloaded a package through the mirror"
        else
            warn "pip test download failed"
            info "The server may not have synced that package yet:"
            info "  sudo mirroretctl sync pip"
        fi
        rm -rf /tmp/mirroret-piptest.$$
    fi
}

setup_npm() {
    [[ "$DO_NPM" == "1" ]] || return 0
    local code
    code="$(curl -sS -o /tmp/mirroret-npmrc.$$ -w '%{http_code}' --max-time 15 \
            "${BASE_URL}/config/.npmrc" 2>/dev/null || true)"
    if [[ "${code:-000}" != "200" ]]; then
        rm -f /tmp/mirroret-npmrc.$$
        info "npm: server publishes no .npmrc (npm mirroring disabled there)"
        return 0
    fi
    step "npm configuration"
    # System-wide, so every user gets it rather than only root.
    save /etc/npmrc
    run install -m 0644 /tmp/mirroret-npmrc.$$ /etc/npmrc
    rm -f /tmp/mirroret-npmrc.$$
    ok "installed /etc/npmrc (system-wide)"
    if [[ "$DRY_RUN" != "1" ]] && command -v npm >/dev/null 2>&1; then
        if npm view express version >/dev/null 2>&1; then
            ok "npm resolved a package through the mirror"
        else
            warn "npm test failed; check the registry is reachable:"
            info "  curl -sS http://${SERVER}:${NPM_PORT}/"
        fi
    fi
}

setup_docker() {
    [[ "$DO_DOCKER" == "1" ]] || return 0
    local code
    code="$(curl -sS -o /tmp/mirroret-docker.$$ -w '%{http_code}' --max-time 15 \
            "${BASE_URL}/config/docker-daemon.json" 2>/dev/null || true)"
    if [[ "${code:-000}" != "200" ]]; then
        rm -f /tmp/mirroret-docker.$$
        info "docker: server publishes no docker-daemon.json"
        return 0
    fi
    step "Docker configuration"
    save /etc/docker/daemon.json
    run mkdir -p /etc/docker
    # Replacing daemon.json wholesale would drop unrelated settings, so say so.
    if [[ -f /etc/docker/daemon.json ]]; then
        warn "/etc/docker/daemon.json already exists and will be REPLACED"
        info "the original is in the backup; merge by hand if it had other keys"
        confirm "Replace it?" || { rm -f /tmp/mirroret-docker.$$; return 0; }
    fi
    run install -m 0644 /tmp/mirroret-docker.$$ /etc/docker/daemon.json
    rm -f /tmp/mirroret-docker.$$
    ok "installed /etc/docker/daemon.json"
    if [[ "$DRY_RUN" != "1" ]] && systemctl is-active --quiet docker 2>/dev/null; then
        run systemctl restart docker || warn "docker restart failed"
    fi
}

# -- Main ---------------------------------------------------------------------

main() {
    printf '%smirroret client setup%s\n' "$C_HEAD" "$C_OFF"
    printf 'host : %s\n' "$(hostname 2>/dev/null || echo unknown)"
    [[ "$DRY_RUN" == "1" ]] && printf '%sDRY RUN - nothing will be changed%s\n' "$C_WARN" "$C_OFF"

    step "Detection"
    detect
    check_server

    case "$FAMILY" in
        debian) setup_apt ;;
        rhel)   setup_rpm ;;
    esac
    setup_pip
    setup_npm
    setup_docker

    printf '\n%s== Done%s\n' "$C_OK" "$C_OFF"
    if [[ "$DRY_RUN" == "1" ]]; then
        info "Dry run: nothing was changed."
    else
        info "This machine now installs packages from ${SERVER}."
        [[ -n "$BACKUP_DIR" ]] && info "Originals backed up in ${BACKUP_DIR}"
        info "To undo everything:  sudo $0 --rollback"
    fi
    printf '\n'
}

main "$@"

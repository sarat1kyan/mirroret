#!/usr/bin/env bash
# Enrol THIS machine on a third-party APT mirror served by mirroret.
#
# Downloads the vendor's signing key and the sources.list entry from the
# mirror server itself, installs them, and proves the result by actually
# fetching a package from the mirror.
#
# Backs up anything it disables and provides --rollback.
#
# Usage:
#   sudo ./enroll-apt-extra.sh --server 192.168.30.110 --name grafana
#   sudo ./enroll-apt-extra.sh --server 192.168.30.110 --name grafana --rollback
#   sudo ./enroll-apt-extra.sh --help

set -Eeuo pipefail

SERVER=""
WEB_PORT="8080"
NAME=""
DISABLE_UPSTREAM=1
ASSUME_YES=0
DRY_RUN=0
ROLLBACK=0
BACKUP_ROOT="/var/backups/mirroret-client-extra"

usage() {
    awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' \
        "${BASH_SOURCE[0]}"
    cat <<'USAGE'

Options:
  --server HOST[:PORT]   the mirroret server (required)
  --name NAME            the mirror name on the server, e.g. grafana
                         (same string used with mirror-apt-extra.sh --name)
  --keep-upstream        do NOT disable this vendor's existing .list; useful
                         while you are still testing the mirror
  --rollback             restore the pre-enrolment state
  -y, --yes              non-interactive
  --dry-run              show what would change, change nothing
  -h, --help             this text
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --server)         shift; SERVER="${1:-}" ;;
        --name)           shift; NAME="${1:-}" ;;
        --keep-upstream)  DISABLE_UPSTREAM=0 ;;
        --rollback)       ROLLBACK=1 ;;
        -y|--yes)         ASSUME_YES=1 ;;
        --dry-run)        DRY_RUN=1 ;;
        -h|--help)        usage; exit 0 ;;
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
step() { printf '\n%s== %s%s\n' "$C_HEAD" "$*" "$C_OFF"; }
ok()   { printf '%s  ok%s    %s\n' "$C_OK" "$C_OFF" "$*"; }
warn() { printf '%s  warn%s  %s\n' "$C_WARN" "$C_OFF" "$*"; }
info() { printf '        %s\n' "$*"; }
die()  {
    printf '\n%s  STOP%s  %s\n' "$C_ERR" "$C_OFF" "$1"
    shift; local l; for l in "$@"; do printf '%s\n' "$l" | sed 's/^/        /'; done
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
[[ -n "$NAME" ]] || die "--name is required." \
    "That is the same name the server admin gave to mirror-apt-extra.sh."

# Debian/Ubuntu client check. Nothing here works elsewhere.
if [[ ! -d /etc/apt/sources.list.d ]]; then
    die "This is not a Debian-family host." \
        "The RPM equivalent is a topic for another script."
fi

# Server format host or host:port.
if [[ -n "${SERVER}" && "${SERVER}" == *:* ]]; then
    WEB_PORT="${SERVER##*:}"
    SERVER="${SERVER%%:*}"
fi

BACKUP_DIR=""
new_backup() {
    BACKUP_DIR="${BACKUP_ROOT}/${NAME}/$(date +%Y%m%d-%H%M%S)"
    run mkdir -p "$BACKUP_DIR"
    [[ "$DRY_RUN" == "1" ]] || {
        mkdir -p "${BACKUP_ROOT}/${NAME}"
        printf '%s\n' "$BACKUP_DIR" > "${BACKUP_ROOT}/${NAME}/latest"
    }
}
save() {
    local src="$1"
    [[ -e "$src" ]] || return 0
    local dst="${BACKUP_DIR}${src}"
    run mkdir -p "$(dirname "$dst")"
    run cp -a "$src" "$dst"
    info "backed up ${src}"
}

# -- Rollback ------------------------------------------------------------------

do_rollback() {
    step "Rollback"
    local latest="${BACKUP_ROOT}/${NAME}/latest"
    [[ -f "$latest" ]] || die "No backup found for ${NAME} in ${BACKUP_ROOT}."
    local dir
    dir="$(cat "$latest")"
    [[ -d "$dir" ]] || die "Backup directory is missing: ${dir}"
    info "restoring from ${dir}"

    # Undo our writes.
    run rm -f "/etc/apt/sources.list.d/mirroret-${NAME}.list"
    run rm -f "/usr/share/keyrings/mirroret-${NAME}.gpg"
    info "removed mirroret-${NAME}.list and its keyring"

    # Put back whatever we renamed.
    while IFS= read -r -d '' src; do
        local target="${src#"$dir"}"
        run mkdir -p "$(dirname "$target")"
        run cp -a "$src" "$target"
        info "restored ${target}"
    done < <(find "$dir" -mindepth 1 \( -type f -o -type l \) -print0)

    # And the files we suffixed. The backup restore above has normally put
    # the original back, in which case the renamed copy is a leftover that
    # a later re-enrol would suffix a second time - remove it. If the
    # original is NOT back (older backup), the rename is the restore.
    local renamed
    while IFS= read -r renamed; do
        [[ -z "$renamed" ]] && continue
        local orig="${renamed%.disabled-by-mirroret-extra-${NAME}}"
        if [[ -e "$orig" ]]; then
            run rm -f "$renamed"
            info "removed leftover $(basename "$renamed")"
        else
            run mv "$renamed" "$orig"
            info "renamed back $(basename "$orig")"
        fi
    done < <(find /etc/apt/sources.list.d -maxdepth 1 \
                  -name "*.disabled-by-mirroret-extra-${NAME}" 2>/dev/null)

    if [[ "$DRY_RUN" != "1" ]]; then
        apt-get update -qq 2>/dev/null || true
    fi
    ok "rollback complete"
    exit 0
}
[[ "$ROLLBACK" == "1" ]] && { [[ -n "$SERVER" ]] || true; do_rollback; }

# -- Server check --------------------------------------------------------------

[[ -n "$SERVER" ]] || die "--server is required." \
    "Example: sudo $0 --server 192.168.30.110 --name ${NAME:-<name>}"

command -v curl >/dev/null 2>&1 || die "curl is not installed."
BASE_URL="http://${SERVER}:${WEB_PORT}"

step "Reaching the mirror"
# --noproxy: a corporate http_proxy in the environment must not be asked to
# reach a LAN mirror it has never heard of.
code="$(curl -sS -o /dev/null -w '%{http_code}' --noproxy "$SERVER" --max-time 10 \
        "${BASE_URL}/config/extra-${NAME}.list" 2>/dev/null || true)"
if [[ -z "$code" || "$code" == "000" ]]; then
    die "Cannot reach ${BASE_URL}/config/extra-${NAME}.list" \
        "Checks in order:" \
        "  1. ping ${SERVER}" \
        "  2. nc -vz ${SERVER} ${WEB_PORT}" \
        "  3. On the SERVER: mirroretctl serve"
fi
if [[ "$code" != "200" ]]; then
    die "The server does not publish a config for '${NAME}' (HTTP ${code})." \
        "On the SERVER, list what IS published:" \
        "  ls /srv/mirroret/config/extra-*.list" \
        "" \
        "If '${NAME}' is missing, add it there:" \
        "  sudo mirror-apt-extra.sh --name ${NAME} --url ... --key-url ..."
fi
ok "config extra-${NAME}.list is published at ${BASE_URL}"

code="$(curl -sS -o /dev/null -w '%{http_code}' --noproxy "$SERVER" --max-time 10 \
        "${BASE_URL}/config/extra-${NAME}.gpg" 2>/dev/null || true)"
[[ "${code:-000}" == "200" ]] || die \
    "The server does not publish the signing key for '${NAME}' (HTTP ${code:-000})." \
    "On the SERVER: mirror-apt-extra.sh should have written" \
    "  /srv/mirroret/config/extra-${NAME}.gpg" \
    "Re-run it there."

# -- Install -------------------------------------------------------------------

step "Installing the mirror on this client"
new_backup

# Key first, so signed-by can verify from the moment the .list lands.
key_tmp="$(mktemp)"
curl -fsSL --noproxy "$SERVER" --max-time 30 -o "$key_tmp" "${BASE_URL}/config/extra-${NAME}.gpg" \
    || die "Could not download the signing key."
# Prove it is a real keyring before installing it.
if ! gpg --show-keys --with-colons "$key_tmp" 2>/dev/null | grep -q '^pub:'; then
    rm -f "$key_tmp"
    die "The file at ${BASE_URL}/config/extra-${NAME}.gpg is not a keyring." \
        "Ask the server admin: was it ASCII-armored before dearmor?"
fi
save "/usr/share/keyrings/mirroret-${NAME}.gpg"
run install -m 0644 "$key_tmp" "/usr/share/keyrings/mirroret-${NAME}.gpg"
rm -f "$key_tmp"
ok "installed /usr/share/keyrings/mirroret-${NAME}.gpg"

# .list. Download to a temp file first, then move: half-written .list files
# make apt-get update fail hard mid-edit.
list_tmp="$(mktemp)"
curl -fsSL --noproxy "$SERVER" --max-time 30 -o "$list_tmp" "${BASE_URL}/config/extra-${NAME}.list" \
    || die "Could not download the sources.list."
save "/etc/apt/sources.list.d/mirroret-${NAME}.list"
run install -m 0644 "$list_tmp" "/etc/apt/sources.list.d/mirroret-${NAME}.list"
rm -f "$list_tmp"
ok "installed /etc/apt/sources.list.d/mirroret-${NAME}.list"

# Disable the upstream vendor .list, if this machine has one and the operator
# did not ask us to leave it alone.
if [[ "$DISABLE_UPSTREAM" == "1" ]]; then
    # Match the common conventions vendors use.
    for pat in "${NAME}" "${NAME}-stable" "${NAME}.list" "${NAME}.sources"; do
        for f in /etc/apt/sources.list.d/${pat}*; do
            [[ -e "$f" ]] || continue
            # Never disable our own file we just wrote.
            [[ "$f" == "/etc/apt/sources.list.d/mirroret-${NAME}.list" ]] && continue
            # Nor a file a previous run already disabled: a second suffix
            # makes rollback unable to find it.
            [[ "$f" == *.disabled-by-mirroret-extra-* ]] && continue
            # Only disable if it actually references the upstream vendor.
            if grep -q 'https\?://[^ ]' "$f" 2>/dev/null && \
               ! grep -q "${SERVER}" "$f" 2>/dev/null; then
                save "$f"
                run mv "$f" "${f}.disabled-by-mirroret-extra-${NAME}"
                ok "disabled $(basename "$f")"
            fi
        done
    done
else
    warn "--keep-upstream: leaving the vendor's own .list files in place"
    info "This machine may still fetch from the internet for ${NAME}."
fi

if [[ "$DRY_RUN" == "1" ]]; then
    printf '\n%s== Dry run: nothing changed%s\n' "$C_OK" "$C_OFF"
    exit 0
fi

# -- Verify --------------------------------------------------------------------

step "Verifying"
if ! apt-get update 2>&1 | tee /tmp/mirroret-extra-update.$$ | tail -6; then
    warn "apt-get update reported errors"
fi
if grep -qE '(NO_PUBKEY|EXPKEYSIG|BADSIG|not signed)' /tmp/mirroret-extra-update.$$; then
    rm -f /tmp/mirroret-extra-update.$$
    die "apt cannot verify the mirror's Release." \
        "This is almost always the wrong signing key on the server. Ask" \
        "the admin to re-run mirror-apt-extra.sh with the CORRECT --key-url."
fi
if grep -qE 'Failed to fetch.*http' /tmp/mirroret-extra-update.$$; then
    grep -E 'Failed to fetch' /tmp/mirroret-extra-update.$$ | head -3 | sed 's/^/        /'
    rm -f /tmp/mirroret-extra-update.$$
    die "apt could not fetch some indices from the mirror." \
        "That means the server has advertised what it has not published:" \
        "on the SERVER, run:" \
        "  ls /srv/mirroret/apt/${NAME}/dists/    # published suites" \
        "  mirroretctl logs errors" \
        "  sudo mirror-apt-extra.sh --name ${NAME} ...    # re-sync"
fi
rm -f /tmp/mirroret-extra-update.$$

# Prove the mirror is where the packages come from.
policy="$(apt-cache policy 2>/dev/null | grep -F "${SERVER}" | head -3 || true)"
if [[ -z "$policy" ]]; then
    warn "apt policy does not mention ${SERVER}"
    apt-cache policy 2>/dev/null | head -10 | sed 's/^/        /'
    die "The mirror was installed but apt is not using it." \
        "Rare. Check /etc/apt/sources.list.d/mirroret-${NAME}.list contents."
fi
ok "apt lists ${SERVER} as a source"

# Prove a REAL download from the mirror. Read a package name AND version
# from the mirror's own index so the test cannot be satisfied elsewhere.
idx="$(find /var/lib/apt/lists -maxdepth 1 -type f \
       -name "*${SERVER}:${WEB_PORT}*${NAME}*_Packages*" 2>/dev/null | head -1 || true)"
# Never `[[ -z "$idx" ]] && ...` in a `set -e` script: when idx IS set the
# test fails, the compound returns 1, and set -e kills the script - which is
# exactly what silently ended the download-verification step on a live run.
if [[ -z "$idx" ]]; then
    idx="$(grep -rlF "${BASE_URL}/apt/${NAME}" /var/lib/apt/lists \
           --include='*_Packages*' 2>/dev/null | head -1 || true)"
fi

pkg=""
if [[ -n "$idx" ]]; then
    if [[ -x /usr/lib/apt/apt-helper ]]; then
        content="$(/usr/lib/apt/apt-helper cat-file "$idx" 2>/dev/null || true)"
    fi
    if [[ -z "${content:-}" ]]; then
        case "$idx" in
            *.gz)  content="$(zcat  "$idx" 2>/dev/null || true)" ;;
            *.xz)  content="$(xzcat "$idx" 2>/dev/null || true)" ;;
            *.lz4) content="$(lz4cat "$idx" 2>/dev/null || true)" ;;
            *)     content="$(cat "$idx" 2>/dev/null || true)" ;;
        esac
    fi
    # awk exits after the first (Package, Version) pair; printf keeps
    # feeding and gets SIGPIPE, and under `set -eo pipefail` that would kill
    # the whole script. On a big index (Grafana: 2478 records) it fires
    # every run - reported live before this guard was added.
    pkg="$(printf '%s\n' "${content:-}" | awk '
        /^Package: / { p = $2 }
        /^Version: / { if (p != "") { print p "=" $2; exit } }' || true)"
fi

if [[ -z "$pkg" ]]; then
    warn "could not identify a package from the mirror's own index"
    info "apt sees the mirror, its index just looks empty. On the SERVER:"
    info "  find /srv/mirroret/apt/${NAME}/pool -name '*.deb' | wc -l"
else
    info "test package, pinned to the mirror's own version: ${pkg}"
    dl="/tmp/mirroret-extra-dltest.$$"
    rm -rf "$dl" && mkdir -p "$dl"
    if (cd "$dl" && apt-get download "$pkg" >/dev/null 2>&1); then
        deb="$(find "$dl" -name '*.deb' | head -1 || true)"
        if [[ -n "$deb" ]]; then
            ok "downloaded ${pkg} from the mirror ($(stat -c%s "$deb") bytes)"
        fi
    else
        warn "could not download ${pkg}"
        info "The index lists that version but the .deb is not fetchable."
        info "On the SERVER: sudo mirror-apt-extra.sh --name ${NAME} ..."
    fi
    rm -rf "$dl"
fi

printf '\n%s== Done%s\n' "$C_OK" "$C_OFF"
info "This machine now gets ${NAME} updates from ${SERVER}."
[[ -n "$BACKUP_DIR" ]] && info "Originals backed up in ${BACKUP_DIR}"
info "To undo:  sudo $0 --server ${SERVER} --name ${NAME} --rollback"

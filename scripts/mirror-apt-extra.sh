#!/usr/bin/env bash
# Mirror a third-party APT repository on the mirror server.
#
# Everything mirroret's main flavors (ubuntu/debian) do, applied to an
# arbitrary signed APT source. Grafana, Docker CE, Kubernetes, HashiCorp,
# NodeSource, PGDG: same shape, same script.
#
# What it does:
#   1. Downloads the vendor's signing key and dearmors it (apt clients need
#      a binary keyring; almost every vendor serves ASCII-armored keys).
#   2. Runs the APT engine against the upstream, verifying the Release
#      signature with the key you just imported.
#   3. Publishes an nginx location for the mirrored tree.
#   4. Writes a client .list that clients point apt at.
#
# Idempotent. Re-running is the resync path.
#
# Usage:
#   sudo ./mirror-apt-extra.sh --name grafana \
#       --url https://apt.grafana.com \
#       --suite stable --component main \
#       --key-url https://apt.grafana.com/gpg.key \
#       --yes
#
#   sudo ./mirror-apt-extra.sh --help

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="${MIRRORET_BASE_DIR:-/srv/mirroret}"

# -- Options -------------------------------------------------------------------

NAME=""
URL=""
SUITES=()
COMPONENTS=("main")
ARCHES=()
KEY_URL=""
KEY_PATH=""              # override where the keyring is stored
PROXY="${https_proxy:-${HTTPS_PROXY:-}}"
MIN_FREE_GB="15"
ASSUME_YES=0
DRY_RUN=0
SKIP_SYNC=0

usage() {
    awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' \
        "${BASH_SOURCE[0]}"
    cat <<'USAGE'

Options:
  --name NAME            short name for the mirror (e.g. grafana, docker)
                         Used in paths and client filenames.
  --url URL              upstream repository root (the parent of dists/)
  --suite NAME           suite to mirror (repeatable; default: the first
                         one on --url or "stable")
  --component NAME       component to mirror (repeatable; default: main)
  --arch NAME            architecture to mirror (repeatable; default: amd64)
  --key-url URL          URL of the vendor's signing key. ASCII-armor is
                         auto-detected and converted for you.
  --key-path PATH        path to an already-installed keyring (skip the
                         download and use this)
  --proxy URL            outbound HTTP(S) proxy (default: from env)
  --min-free-gb N        abort a sync below this much free disk (default 15)
  --skip-sync            configure and publish, but do not download
  -y, --yes              non-interactive
  --dry-run              show the plan, change nothing
  -h, --help             this text
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --name)         shift; NAME="${1:-}" ;;
        --url)          shift; URL="${1:-}" ;;
        --suite)        shift; SUITES+=("${1:-}") ;;
        --component)    shift; COMPONENTS=("${1:-}") ;;
        --components)   shift; read -r -a COMPONENTS <<< "${1:-}" ;;
        --arch)         shift; ARCHES+=("${1:-}") ;;
        --key-url)      shift; KEY_URL="${1:-}" ;;
        --key-path)     shift; KEY_PATH="${1:-}" ;;
        --proxy)        shift; PROXY="${1:-}" ;;
        --min-free-gb)  shift; MIN_FREE_GB="${1:-}" ;;
        --skip-sync)    SKIP_SYNC=1 ;;
        -y|--yes)       ASSUME_YES=1 ;;
        --dry-run)      DRY_RUN=1 ;;
        -h|--help)      usage; exit 0 ;;
        *) printf 'Unknown option: %s\nRun with --help.\n' "$1" >&2; exit 2 ;;
    esac
    shift
done

[[ ${#SUITES[@]} -eq 0 ]] && SUITES=(stable)
[[ ${#ARCHES[@]} -eq 0 ]] && ARCHES=(amd64)

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
    shift
    local l; for l in "$@"; do printf '        %s\n' "$l" | sed 's/^/        /'; done
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
[[ -n "$NAME" ]] || die "--name is required."
[[ "$NAME" =~ ^[a-z0-9][a-z0-9._-]*$ ]] || die "--name must be lowercase [a-z0-9._-]."
[[ -n "$URL" ]] || die "--url is required."
[[ -n "$KEY_URL$KEY_PATH" ]] || die "Give --key-url or --key-path." \
    "The engine refuses to publish an unverified archive without" \
    "--require-signature=0, which this wrapper does not expose."

ENGINE="${BASE_DIR}/engines/mirroret_apt.py"
if [[ ! -f "$ENGINE" ]]; then
    ENGINE="${SCRIPT_DIR}/../engines/mirroret_apt.py"
fi
[[ -f "$ENGINE" ]] || die "APT engine not found." \
    "Expected at ${BASE_DIR}/engines/ or ${SCRIPT_DIR}/../engines/." \
    "Run install.sh --upgrade first."

command -v python3 >/dev/null 2>&1 || die "python3 is required."
command -v curl    >/dev/null 2>&1 || die "curl is required."

DEST="${BASE_DIR}/apt/${NAME}"
KEY_DIR="/etc/mirroret/keys"
[[ -z "$KEY_PATH" ]] && KEY_PATH="${KEY_DIR}/${NAME}.gpg"
CLIENT_LIST="${BASE_DIR}/config/extra-${NAME}.list"
NGINX_SNIPPET="/etc/nginx/conf.d/mirroret-extra-${NAME}.conf"
LOG_DIR="${BASE_DIR}/logs"
LOCK_FILE="/var/lock/mirroret-extra-${NAME}.lock"
LOG_FILE="${LOG_DIR}/sync-extra-${NAME}-$(date +%Y%m%d-%H%M%S).log"

printf '%smirroret third-party APT mirror: %s%s\n' "$C_HEAD" "$NAME" "$C_OFF"
info "upstream : ${URL}"
info "suites   : ${SUITES[*]}"
info "arches   : ${ARCHES[*]}"
info "dest     : ${DEST}"

# -- Key -----------------------------------------------------------------------

step "Signing key"

if [[ -n "${KEY_URL}" ]] && [[ ! -f "${KEY_PATH}" || -n "${MIRRORET_EXTRA_FORCE_KEY:-}" ]]; then
    # Fetch and dearmor if needed. Almost every vendor publishes ASCII-armor
    # under a plain URL; the engine and apt both want the binary form.
    local_tmp="$(mktemp)"
    if [[ "$DRY_RUN" == "1" ]]; then
        info "[dry-run] would download ${KEY_URL} -> ${KEY_PATH}"
        rm -f "${local_tmp}"
    else
        run mkdir -p "${KEY_DIR}"
        if ! curl -fsSL --max-time 60 -o "${local_tmp}" "${KEY_URL}"; then
            rm -f "${local_tmp}"
            die "Could not download ${KEY_URL}." \
                "Check the URL and the proxy."
        fi
        if head -c 40 "${local_tmp}" | grep -q 'BEGIN PGP'; then
            # ASCII-armored. Convert to the binary form apt and gpgv need.
            if ! gpg --dearmor < "${local_tmp}" > "${KEY_PATH}.new" 2>/dev/null; then
                rm -f "${local_tmp}" "${KEY_PATH}.new"
                die "gpg --dearmor failed on the downloaded key." \
                    "The URL served text that is not a PGP key."
            fi
            mv "${KEY_PATH}.new" "${KEY_PATH}"
            ok "downloaded and dearmored key -> ${KEY_PATH}"
        else
            # Already binary.
            mv "${local_tmp}" "${KEY_PATH}"
            ok "downloaded key -> ${KEY_PATH}"
        fi
        chmod 0644 "${KEY_PATH}"
        rm -f "${local_tmp}"
    fi
elif [[ -f "${KEY_PATH}" ]]; then
    ok "using existing key at ${KEY_PATH}"
else
    die "No --key-url and no key at ${KEY_PATH}."
fi

# Prove the key actually verifies a Release from this upstream BEFORE writing
# the client config. Verifying against a wrong key is the classic mistake.
step "Signature check against upstream"
if [[ "$DRY_RUN" == "1" ]]; then
    info "[dry-run] would fetch InRelease and verify with ${KEY_PATH}"
elif command -v gpgv >/dev/null 2>&1; then
    tmp_ir="$(mktemp)"
    if env https_proxy="${PROXY}" http_proxy="${PROXY}" curl -fsSL --max-time 30 \
           -o "$tmp_ir" "${URL%/}/dists/${SUITES[0]}/InRelease" 2>/dev/null; then
        if gpgv --keyring "${KEY_PATH}" "$tmp_ir" >/dev/null 2>&1; then
            ok "InRelease signature verifies with the imported key"
        else
            gpgv --keyring "${KEY_PATH}" "$tmp_ir" 2>&1 | sed 's/^/        /'
            rm -f "$tmp_ir"
            die "The key does NOT verify this upstream's Release." \
                "Two common causes:" \
                "  1. Wrong --key-url for this vendor." \
                "  2. The vendor rotated their signing key. Re-fetch with:" \
                "     sudo MIRRORET_EXTRA_FORCE_KEY=1 $0 ..."
        fi
    else
        warn "could not fetch ${URL%/}/dists/${SUITES[0]}/InRelease for a preflight check"
        info "The engine will do the real check when it syncs."
    fi
    rm -f "$tmp_ir"
else
    warn "gpgv not installed; skipping the preflight signature check"
fi

# -- Sync ----------------------------------------------------------------------

step "Sync"
run mkdir -p "${DEST}" "${LOG_DIR}"

# Single-instance lock so a cron run cannot collide with a manual one.
if [[ "$DRY_RUN" != "1" ]]; then
    exec 9>"${LOCK_FILE}"
    if ! flock -n 9; then
        die "Another sync of ${NAME} is already running (${LOCK_FILE})." \
            "Watch it: tail -f ${LOG_DIR}/sync-extra-${NAME}-*.log"
    fi
fi

if [[ "$SKIP_SYNC" == "1" ]]; then
    info "--skip-sync given; run this later:"
    info "  sudo $0 --name ${NAME} --url ${URL} \\"
    info "      --key-path ${KEY_PATH} --yes"
else
    args=(--dest "${DEST}" --url "${URL}" --min-free-gb "${MIN_FREE_GB}"
          --keyring "${KEY_PATH}" --require-signature
          --id "extra-${NAME}" --flavor "${NAME}" --delete)
    for s in "${SUITES[@]}";     do args+=(--suite     "$s"); done
    for c in "${COMPONENTS[@]}"; do args+=(--component "$c"); done
    for a in "${ARCHES[@]}";     do args+=(--arch      "$a"); done
    # Set the proxy for the engine via the environment, not as extra args.
    # The engine's ProxyHandler picks up http_proxy/https_proxy from the
    # environment automatically; passing them positionally would make
    # argparse reject them as "unrecognized arguments" - which happened
    # live and produced a very confusing failure right after the signature
    # check passed.
    if [[ -n "$PROXY" ]]; then
        export https_proxy="$PROXY" http_proxy="$PROXY"
    fi
    [[ "$DRY_RUN" == "1" ]] && args+=(--dry-run)

    # Show the estimated size first: a third-party repo that keeps every
    # historical version can be several hundred GB (Grafana today: ~177 GB).
    info "Estimating download size (dry run first)..."
    if [[ "$DRY_RUN" != "1" ]]; then
        # `tail -15` closes the pipe early; without `|| true` the tee gets
        # SIGPIPE and pipefail + set -e kill the script silently.
        est_out="$(python3 "$ENGINE" "${args[@]}" --dry-run 2>&1 \
                   | tee -a "$LOG_FILE" | tail -15 || true)"
        # The grep+sed pipeline exits 1 when nothing matched - which under
        # `set -eo pipefail` returned the operator to a bare shell with no
        # explanation. `|| true` keeps us in control regardless. Same trap
        # a user reported live: "just went back to prompt after Estimating".
        printf '%s\n' "$est_out" | grep -E 'packages:|ABORT' \
                                  | sed 's/^/        /' || true
        if printf '%s' "$est_out" | grep -q '^ABORT'; then
            die "Disk floor would be breached by this sync." \
                "Free space or lower --min-free-gb, then re-run." \
                "Full estimate log: ${LOG_FILE}"
        fi
        confirm "Start the real sync now?" || {
            warn "Sync skipped at your request."
            info "The mirror is CONFIGURED but empty. Run later:"
            info "  sudo $0 --name ${NAME} --url ${URL} --key-path ${KEY_PATH} --yes"
            SKIP_SYNC=1
        }
    fi

    if [[ "$SKIP_SYNC" != "1" ]]; then
        if ! python3 "$ENGINE" "${args[@]}" >>"$LOG_FILE" 2>&1; then
            tail -20 "$LOG_FILE" | sed 's/^/        /'
            die "Sync failed. Full log: ${LOG_FILE}"
        fi
        # Show the RESULT line the engine printed at the end.
        tail -4 "$LOG_FILE" | grep -E 'RESULT|published' | sed 's/^/        /' || true
        ok "sync complete"
    fi
fi

# -- Publish -------------------------------------------------------------------

step "Publishing"

# nginx location. mirroret's main nginx template does not know about extras,
# so drop in a tiny snippet that adds one alias per extra mirror.
if [[ "$DRY_RUN" == "1" ]]; then
    info "[dry-run] would write ${NGINX_SNIPPET}"
    info "[dry-run] would write ${CLIENT_LIST}"
else
    # A conf.d snippet is loaded INSIDE mirroret's server{} block via
    # nginx's own conf.d include - except our unified vhost lives in
    # sites-enabled or has its own conf.d file, so we cannot just drop a
    # `location` directive here (that requires a server context). Use a
    # sourceable stub the operator can add manually if wanted, and rely on
    # /apt/ being a browsable index that already covers this tree.
    run mkdir -p "${BASE_DIR}/config" "$(dirname "${NGINX_SNIPPET}")"

    # Reference doc, not a live nginx include - see above.
    cat > "${NGINX_SNIPPET}.example" <<NGINX
# Reference: to expose this mirror at http://server:8080/${NAME}/, add the
# location below INSIDE mirroret's unified server{} block, then reload nginx:
#     sudo nginx -t && sudo systemctl reload nginx
#
# mirroret already exposes it via the browsable /apt/ index, which is enough
# for clients using the generated .list. Add a dedicated location only if a
# short URL matters to you.
#
#     location /${NAME}/ {
#         alias ${DEST}/;
#         autoindex on;
#     }
NGINX
    ok "wrote ${NGINX_SNIPPET}.example (reference only)"

    # Client .list. The keyring path on the CLIENT is where the client's own
    # enrolment script installs it; we tell them where to expect it.
    server_ip="${MIRRORET_SERVER_IP:-$(hostname -I 2>/dev/null | awk '{print $1}')}"
    url="http://${server_ip}:${MIRRORET_WEB_PORT:-8080}/apt/${NAME}"
    {
        printf '# mirroret third-party APT client config - %s\n' "$NAME"
        printf '# Install as /etc/apt/sources.list.d/mirroret-%s.list on the CLIENT.\n' "$NAME"
        printf '# The client also needs the signing key at\n'
        printf '#   /usr/share/keyrings/mirroret-%s.gpg\n' "$NAME"
        printf '# which the enrolment script downloads from\n'
        printf '#   %s/config/extra-%s.gpg\n' "${url%/apt/*}" "$NAME"
        printf '\n'
        # Pin arch= so a client with add-architecture i386/arm64 does not
        # ask this mirror for arches we never published.
        arch_csv="$(IFS=,; printf '%s' "${ARCHES[*]}")"
        for s in "${SUITES[@]}"; do
            printf 'deb [signed-by=/usr/share/keyrings/mirroret-%s.gpg arch=%s] %s %s %s\n' \
                "$NAME" "$arch_csv" "$url" "$s" "${COMPONENTS[*]}"
        done
    } > "${CLIENT_LIST}"
    chmod 0644 "${CLIENT_LIST}"
    ok "wrote ${CLIENT_LIST}"

    # Also publish the key at /config/ so the client can fetch it over HTTP
    # from the mirror server itself - no separate distribution needed.
    if [[ -f "${KEY_PATH}" ]]; then
        install -m 0644 "${KEY_PATH}" "${BASE_DIR}/config/extra-${NAME}.gpg"
        ok "wrote ${BASE_DIR}/config/extra-${NAME}.gpg"
    fi

    # And the enrolment script itself, so the client instructions this
    # script prints are actually satisfiable. install.sh --upgrade does
    # the same, but this catches an operator who runs mirror-apt-extra.sh
    # on a tree that has not been upgraded yet.
    enrol="${SCRIPT_DIR}/enroll-apt-extra.sh"
    if [[ -f "${enrol}" ]] && [[ ! -f "${BASE_DIR}/config/enroll-apt-extra.sh" ]]; then
        install -m 0755 "${enrol}" "${BASE_DIR}/config/enroll-apt-extra.sh"
        ok "wrote ${BASE_DIR}/config/enroll-apt-extra.sh"
    fi
fi

# -- Done ----------------------------------------------------------------------

printf '\n%s== Done%s\n' "$C_OK" "$C_OFF"
info "The mirror is at http://<server-ip>:${MIRRORET_WEB_PORT:-8080}/apt/${NAME}/"
info "On each client, run:"
info "  curl -fsSL -o /tmp/e.sh \\"
info "      http://<server-ip>:${MIRRORET_WEB_PORT:-8080}/config/enroll-apt-extra.sh"
info "  sudo bash /tmp/e.sh --server <server-ip> --name ${NAME}"
info ""
info "Re-sync later:"
info "  sudo $0 --name ${NAME} --url ${URL} --key-path ${KEY_PATH} --yes"

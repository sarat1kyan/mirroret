#!/usr/bin/env bash
# lib/cache.sh - wiring for the on-demand pull-through cache.
#
# Three mirroring modes, chosen per install with MIRRORET_APT_MODE:
#
#   mirror  Download every package the archive publishes, ahead of time.
#           Fully offline once synced. Costs ~850 GB for Ubuntu
#           noble+jammy with two architectures.
#
#   hybrid  Mirror the whole signed index tree (a couple of GB) but no
#           packages; serve the pool on demand and keep what was asked
#           for. `apt-get update` is instant and works offline; the first
#           install of a given package pays one upstream fetch and every
#           later client gets it at LAN speed. This is the right default
#           for almost everyone.
#
#   cache   Nothing is mirrored ahead of time; indices and packages are
#           both fetched on demand and cached. Smallest footprint, but a
#           cold `apt-get update` needs upstream to be reachable.
#
# In hybrid and cache modes nginx serves whatever is already on disk and
# hands only misses to the daemon, so a warm cache costs nothing.

MIRRORET_APT_MODE="${MIRRORET_APT_MODE:-mirror}"
MIRRORET_CACHE_PORT="${MIRRORET_CACHE_PORT:-8082}"
MIRRORET_CACHE_CONFIG="${MIRRORET_CACHE_CONFIG:-/etc/mirroret/cache.json}"
MIRRORET_CACHE_MAX_SIZE_GB="${MIRRORET_CACHE_MAX_SIZE_GB:-0}"
MIRRORET_CACHE_METADATA_TTL="${MIRRORET_CACHE_METADATA_TTL:-300}"
# Overridable so the test suite can generate and inspect a unit without
# writing into the host's systemd directory.
MIRRORET_CACHE_UNIT="${MIRRORET_CACHE_UNIT:-/etc/systemd/system/mirroret-cache.service}"

# cache_mode_enabled - true when the configured mode needs the daemon.
cache_mode_enabled() {
    case "${MIRRORET_APT_MODE:-mirror}" in
        hybrid|cache) return 0 ;;
        *)            return 1 ;;
    esac
}

# cache_mode_is_metadata_only - true when the sync should publish indices
# but skip packages.
cache_mode_is_metadata_only() {
    [[ "${MIRRORET_APT_MODE:-mirror}" == "hybrid" ]]
}

# validate_cache_mode - reject a typo now rather than silently mirroring.
validate_cache_mode() {
    case "${MIRRORET_APT_MODE:-mirror}" in
        mirror|hybrid|cache) return 0 ;;
        *)
            die "MIRRORET_APT_MODE must be one of: mirror, hybrid, cache" \
                "  got: '${MIRRORET_APT_MODE}'"
            ;;
    esac
}

# -- route table ---------------------------------------------------------------

# generate_cache_config - write /etc/mirroret/cache.json from the APT targets.
#
# One route per flavor directory, because that is exactly the URL prefix
# nginx serves and the directory the mirror engine writes into. The upstream
# list is built from the same apt_suites() table the mirror uses, so the
# cache and the mirror can never disagree about where a suite comes from.
generate_cache_config() {
    local conf="${1:-${MIRRORET_CACHE_CONFIG}}"

    if [[ "${DRY_RUN:-0}" == "1" ]]; then
        info "[DRY-RUN] would write cache route table: ${conf}"
        return 0
    fi

    # The same resolution the mirror uses (explicit MIRRORET_APT_TARGETS, or
    # the host's own distro when unset). Reading the raw variable meant an
    # Ubuntu host with no explicit targets got a mirror spec but a daemon
    # with no routes - which crash-looped and 502'd every pool miss.
    local -a targets=()
    local _t
    while read -r _t; do
        [[ -n "${_t}" ]] && targets+=("${_t}")
    done < <(resolved_apt_targets)
    if [[ ${#targets[@]} -eq 0 ]]; then
        warn "No APT targets, so the cache has nothing to route."
        warn "Set MIRRORET_APT_TARGETS and re-run with --upgrade."
        return 1
    fi

    mkdir -p "$(dirname "$conf")"

    # flavor dir -> newline-separated upstream bases, de-duplicated in order.
    local tmp
    tmp="$(mktemp_file)"

    local target flavor release dir codename _suite url
    for target in "${targets[@]}"; do
        [[ -z "${target}" ]] && continue
        flavor="${target%%:*}"
        release="${target#*:}"
        release="${release%%:*}"
        [[ -z "${release}" || "${release}" == "${flavor}" ]] && continue
        dir="$(apt_flavor_dir "${flavor}")"
        codename="$(apt_codename_for "${flavor}" "${release}")" || continue

        # The suite name is not needed here - a route is keyed on the
        # flavor directory, and every suite of a flavor shares its upstreams.
        while IFS='|' read -r _suite url; do
            [[ -z "${url}" ]] && continue
            printf '%s\t%s\n' "${dir}" "${url}" >> "$tmp"
        done < <(apt_suites "${flavor}" "${codename}" || true)
    done

    if [[ ! -s "$tmp" ]]; then
        warn "Could not derive any cache routes from the APT targets."
        rm -f "$tmp"
        return 1
    fi

    # Build the JSON with python so quoting and escaping are not our problem.
    python3 - "$tmp" "$conf" <<'PY'
import json
import sys

src, dest = sys.argv[1], sys.argv[2]

routes = {}
with open(src) as fh:
    for line in fh:
        line = line.rstrip("\n")
        if not line:
            continue
        directory, _, upstream = line.partition("\t")
        if not directory or not upstream:
            continue
        # Ordered de-duplication: the first upstream seen for a flavor is the
        # main archive, and any distinct one after it (a separately hosted
        # security archive) becomes a fallback candidate.
        bucket = routes.setdefault(directory, [])
        if upstream not in bucket:
            bucket.append(upstream)

doc = {
    "_comment": (
        "Generated by mirroret. Each key is the URL prefix clients use and "
        "the directory the mirror writes into; upstreams are tried in order "
        "so a suite hosted on a separate security archive still resolves."
    ),
    "routes": {
        name: {"upstreams": ups, "kind": "apt"}
        for name, ups in sorted(routes.items())
    },
}
with open(dest, "w") as fh:
    json.dump(doc, fh, indent=2)
    fh.write("\n")
print("%d route(s): %s" % (len(routes), ", ".join(sorted(routes))))
PY

    rm -f "$tmp"
    chmod 0644 "$conf"
    success "Cache route table written: ${conf}"
}

# -- systemd -------------------------------------------------------------------

install_cache_service() {
    local base_dir="${MIRRORET_BASE_DIR}"
    local unit="${MIRRORET_CACHE_UNIT}"
    local launcher="${base_dir}/scripts/run-cache.sh"

    if [[ "${DRY_RUN:-0}" == "1" ]]; then
        info "[DRY-RUN] would install ${launcher} and ${unit}"
        return 0
    fi

    local extra=""
    [[ "${MIRRORET_CACHE_MAX_SIZE_GB}" != "0" ]] && \
        extra="--max-size-gb ${MIRRORET_CACHE_MAX_SIZE_GB}"

    # A launcher rather than systemd Environment= lines: the daemon has to
    # reach upstream exactly the way the sync scripts do, and that logic
    # (config sourcing, lower/upper-case proxy mirroring, CA bundle) already
    # lives in one place. Duplicating it into unit-file syntax is how the two
    # paths drift until the cache works and the nightly sync does not.
    mkdir -p "${base_dir}/scripts"
    cat > "${launcher}" <<LAUNCHER
#!/usr/bin/env bash
# Generated by mirroret - do not edit manually.
# ${MIRRORET_MANAGED_MARKER:-mirroret-managed}
set -eo pipefail

$(mirroret_script_preamble)

exec python3 "${base_dir}/engines/mirroret_cache.py" \\
    --config "${MIRRORET_CACHE_CONFIG}" \\
    --cache-dir "${base_dir}/apt" \\
    --listen "127.0.0.1:${MIRRORET_CACHE_PORT}" \\
    --metadata-ttl "${MIRRORET_CACHE_METADATA_TTL}" ${extra}
LAUNCHER
    chmod 0755 "${launcher}"

    # Runs as root because the sync scripts already write this tree as root;
    # a non-root daemon could serve hits but not store a miss. The exposure
    # is bounded: it binds loopback only and nginx is the sole client, and
    # the sandboxing below limits it to writing inside the mirror.
    mkdir -p "$(dirname "$unit")"
    cat > "$unit" <<UNIT
# Generated by mirroret - do not edit manually.
[Unit]
Description=mirroret on-demand package cache
Documentation=https://github.com/sarat1kyan/mirroret
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${launcher}
Restart=on-failure
RestartSec=5

NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true
ReadWritePaths=${base_dir}
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX

[Install]
WantedBy=multi-user.target
UNIT
    chmod 0644 "$unit"
    systemctl daemon-reload 2>/dev/null || true
    success "Cache service installed: ${unit}"
}

# configure_cache - the single entry point install.sh calls.
configure_cache() {
    validate_cache_mode
    if ! cache_mode_enabled; then
        debug "MIRRORET_APT_MODE=mirror: no cache daemon needed."
        # Switching back to full-mirror mode must also stop the daemon that
        # an earlier hybrid/cache install left enabled.
        if [[ "${DRY_RUN:-0}" != "1" ]] && [[ -f "${MIRRORET_CACHE_UNIT}" ]]; then
            systemctl disable --now mirroret-cache 2>/dev/null || true
            info "mirroret-cache disabled (MIRRORET_APT_MODE=mirror)."
        fi
        return 0
    fi

    section "Configuring On-Demand Cache (mode: ${MIRRORET_APT_MODE})"
    if ! generate_cache_config "${MIRRORET_CACHE_CONFIG}"; then
        # No routes means the daemon would die on start-up and restart
        # every 5 s forever while nginx 502s every pool miss. Better to
        # leave it uninstalled and say so.
        warn "Cache daemon not installed: no routes could be generated."
        return 0
    fi
    install_cache_service

    if [[ "${DRY_RUN:-0}" == "1" ]]; then
        info "[DRY-RUN] would enable and start mirroret-cache"
        return 0
    fi

    if systemctl enable --now mirroret-cache 2>/dev/null; then
        success "mirroret-cache is running on 127.0.0.1:${MIRRORET_CACHE_PORT}"
    else
        warn "Could not start mirroret-cache. Check: systemctl status mirroret-cache"
    fi
}

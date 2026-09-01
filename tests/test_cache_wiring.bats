#!/usr/bin/env bats
# Tests for lib/cache.sh - how the cache daemon is wired into the install.
#
# The daemon itself is covered by test_cache.bats. What matters here is that
# the generated configuration is internally consistent: the route table has
# to name the same upstreams the mirror engine would use, nginx has to hand
# misses to the port the daemon actually binds, and the sync script has to
# stop downloading packages in the modes where the cache supplies them.
# A mismatch in any of those produces a mirror that looks configured and
# 404s every client.

load 'test_helpers'

setup() {
    load_lib
    # cache.sh derives its routes from the same upstream catalog the mirror
    # uses, so targets.sh has to be in scope alongside it.
    # shellcheck source=/dev/null
    source "${SCRIPT_DIR}/lib/targets.sh"
    # shellcheck source=/dev/null
    source "${SCRIPT_DIR}/lib/cache.sh"
    TMPDIR_TEST="$(mktemp -d)"
    export MIRRORET_BASE_DIR="${TMPDIR_TEST}/srv"
    mkdir -p "${MIRRORET_BASE_DIR}"
    # These tests assert on files the wiring actually writes, so the shared
    # harness's dry-run default has to be off. The unit goes to a temp path
    # rather than the host's systemd directory.
    export DRY_RUN=0
    export MIRRORET_CACHE_UNIT="${TMPDIR_TEST}/mirroret-cache.service"
}

teardown() {
    [[ -n "${TMPDIR_TEST:-}" ]] && rm -rf "${TMPDIR_TEST}"
}

# -- mode selection -----------------------------------------------------------

@test "cache mode: only mirror, hybrid and cache are accepted" {
    MIRRORET_APT_MODE=mirror  && validate_cache_mode
    MIRRORET_APT_MODE=hybrid  && validate_cache_mode
    MIRRORET_APT_MODE=cache   && validate_cache_mode

    # A typo must stop the install rather than silently mirroring 800 GB.
    run bash -c "
        source '${SCRIPT_DIR}/lib/logging.sh'
        source '${SCRIPT_DIR}/lib/common.sh'
        source '${SCRIPT_DIR}/lib/cache.sh'
        MIRRORET_APT_MODE=cahce validate_cache_mode"
    [ "$status" -ne 0 ]
    [[ "$output" == *"mirror, hybrid, cache"* ]]
}

@test "cache mode: the daemon runs for hybrid and cache, not for mirror" {
    MIRRORET_APT_MODE=mirror; ! cache_mode_enabled
    MIRRORET_APT_MODE=hybrid; cache_mode_enabled
    MIRRORET_APT_MODE=cache;  cache_mode_enabled
}

@test "cache mode: only hybrid mirrors indices without packages" {
    # In 'cache' mode nothing is pre-mirrored at all, so a metadata-only sync
    # would be pointless work; in 'mirror' mode packages are the whole job.
    MIRRORET_APT_MODE=hybrid; cache_mode_is_metadata_only
    MIRRORET_APT_MODE=mirror; ! cache_mode_is_metadata_only
    MIRRORET_APT_MODE=cache;  ! cache_mode_is_metadata_only
}

# -- route table --------------------------------------------------------------

@test "cache routes: security archives become ordered fallbacks" {
    # Ubuntu serves noble-security from security.ubuntu.com while clients see
    # one /ubuntu/ prefix, and Debian's security archive is a different path
    # on the same host. Both must appear after the main archive, not instead
    # of it.
    MIRRORET_APT_TARGETS="ubuntu:noble debian:bookworm" \
        generate_cache_config "${TMPDIR_TEST}/cache.json"

    run python3 - "${TMPDIR_TEST}/cache.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))["routes"]
assert sorted(d) == ["debian", "ubuntu"], sorted(d)
ub = d["ubuntu"]["upstreams"]
assert "archive.ubuntu.com" in ub[0], ub
assert any("security.ubuntu.com" in u for u in ub[1:]), ub
deb = d["debian"]["upstreams"]
assert deb[0].endswith("/debian"), deb
assert any(u.endswith("/debian-security") for u in deb[1:]), deb
print("ok")
PY
    [ "$status" -eq 0 ]
}

@test "cache routes: the generated table is what the engine accepts" {
    # The route table and the daemon's parser are written in different
    # languages in different files; this is the test that keeps them honest.
    MIRRORET_APT_TARGETS="ubuntu:noble" \
        generate_cache_config "${TMPDIR_TEST}/cache.json"

    run python3 "$(cache_engine)" --check \
        --config "${TMPDIR_TEST}/cache.json" --cache-dir "${TMPDIR_TEST}"
    [ "$status" -eq 0 ]
    [[ "$output" == *"archive.ubuntu.com"* ]]
}

@test "cache routes: MIRRORET_APT_SCHEME=https reaches the route table" {
    # A CONNECT-only corporate proxy refuses plain HTTP to the archives, so
    # the cache has to inherit the same scheme override the mirror uses -
    # otherwise the mirror syncs and the cache 502s on every miss.
    MIRRORET_APT_SCHEME=https MIRRORET_APT_TARGETS="ubuntu:noble" \
        generate_cache_config "${TMPDIR_TEST}/cache.json"
    run grep -c 'https://' "${TMPDIR_TEST}/cache.json"
    [ "$status" -eq 0 ]
    ! grep -q '"http://' "${TMPDIR_TEST}/cache.json"
}

@test "cache routes: one route per flavor, not one per release" {
    # noble and jammy share /ubuntu/ and the same archive root; emitting the
    # flavor twice would give the daemon duplicate work and a confusing
    # status output.
    MIRRORET_APT_TARGETS="ubuntu:noble ubuntu:jammy" \
        generate_cache_config "${TMPDIR_TEST}/cache.json"
    run python3 -c "
import json,sys
d = json.load(open('${TMPDIR_TEST}/cache.json'))['routes']
assert list(d) == ['ubuntu'], list(d)
# Duplicate upstreams must be collapsed too.
ups = d['ubuntu']['upstreams']
assert len(ups) == len(set(ups)), ups
print('ok')"
    [ "$status" -eq 0 ]
}

@test "cache routes: no APT targets is a warning, not a broken config file" {
    run bash -c "
        source '${SCRIPT_DIR}/lib/logging.sh'
        source '${SCRIPT_DIR}/lib/common.sh'
        source '${SCRIPT_DIR}/lib/distro.sh'
        source '${SCRIPT_DIR}/lib/targets.sh'
        source '${SCRIPT_DIR}/lib/cache.sh'
        MIRRORET_APT_TARGETS='' OS_ID=rhel generate_cache_config '${TMPDIR_TEST}/none.json'"
    # Non-zero on purpose: configure_cache uses it to NOT install a daemon
    # that would crash-loop with no routes.
    [ "$status" -ne 0 ]
    [[ "$output" == *"nothing to route"* ]]
    [ ! -f "${TMPDIR_TEST}/none.json" ]
}

# -- nginx --------------------------------------------------------------------

@test "nginx: cache mode routes misses to the port the daemon binds" {
    # try_files serves hits from disk; @mirroret_cache must point at the same
    # port install_cache_service tells the daemon to listen on.
    run bash -c "
        source '${SCRIPT_DIR}/lib/logging.sh'
        source '${SCRIPT_DIR}/lib/common.sh'
        source '${SCRIPT_DIR}/lib/distro.sh'
        source '${SCRIPT_DIR}/lib/targets.sh'
        source '${SCRIPT_DIR}/lib/cache.sh'
        source '${SCRIPT_DIR}/lib/nginx.sh'
        export MIRRORET_APT_MODE=hybrid
        export MIRRORET_TARGETS_DIR='${TMPDIR_TEST}/targets'
        export MIRRORET_APT_TARGETS='ubuntu:noble'
        mkdir -p \"\$MIRRORET_TARGETS_DIR\"
        generate_target_specs >/dev/null 2>&1
        _nginx_apt_locations /srv/mirroret /legacy"
    [ "$status" -eq 0 ]
    [[ "$output" == *"try_files \$uri @mirroret_cache"* ]]
    [[ "$output" == *"proxy_pass http://127.0.0.1:8082"* ]]
    # root, not alias: try_files resolves against the location root, and with
    # alias nginx appends the URI to the alias path a second time.
    [[ "$output" == *"root /srv/mirroret/apt/"* ]]
}

@test "nginx: mirror mode keeps the plain alias and adds no proxy" {
    run bash -c "
        source '${SCRIPT_DIR}/lib/logging.sh'
        source '${SCRIPT_DIR}/lib/common.sh'
        source '${SCRIPT_DIR}/lib/distro.sh'
        source '${SCRIPT_DIR}/lib/targets.sh'
        source '${SCRIPT_DIR}/lib/cache.sh'
        source '${SCRIPT_DIR}/lib/nginx.sh'
        export MIRRORET_APT_MODE=mirror
        export MIRRORET_TARGETS_DIR='${TMPDIR_TEST}/targets'
        export MIRRORET_APT_TARGETS='ubuntu:noble'
        mkdir -p \"\$MIRRORET_TARGETS_DIR\"
        generate_target_specs >/dev/null 2>&1
        _nginx_apt_locations /srv/mirroret /legacy"
    [ "$status" -eq 0 ]
    [[ "$output" == *"alias /srv/mirroret/apt/ubuntu/"* ]]
    [[ "$output" != *"@mirroret_cache"* ]]
}

@test "nginx: a cold package must not hit a proxy read timeout" {
    # The default proxy_read_timeout is 60s. A few hundred MB through a slow
    # corporate proxy takes longer, and the client is already waiting.
    run bash -c "
        source '${SCRIPT_DIR}/lib/logging.sh'
        source '${SCRIPT_DIR}/lib/common.sh'
        source '${SCRIPT_DIR}/lib/distro.sh'
        source '${SCRIPT_DIR}/lib/targets.sh'
        source '${SCRIPT_DIR}/lib/cache.sh'
        source '${SCRIPT_DIR}/lib/nginx.sh'
        export MIRRORET_APT_MODE=cache
        export MIRRORET_TARGETS_DIR='${TMPDIR_TEST}/targets'
        export MIRRORET_APT_TARGETS='ubuntu:noble'
        mkdir -p \"\$MIRRORET_TARGETS_DIR\"
        generate_target_specs >/dev/null 2>&1
        _nginx_apt_locations /srv/mirroret /legacy"
    [[ "$output" == *"proxy_read_timeout 1800s"* ]]
    # Buffering off so bytes reach the client as they arrive rather than
    # after nginx has spooled the whole package.
    [[ "$output" == *"proxy_buffering off"* ]]
}

# -- sync script --------------------------------------------------------------

@test "sync script: hybrid and cache modes pass --metadata-only" {
    # Without this the sync would download the full pool anyway and the whole
    # point of the mode is lost.
    # Decided at GENERATION time via cache_mode_enabled and baked into the
    # script - not read from the environment at run time, which cron never
    # has.
    grep -q 'cache_mode_enabled' "${SCRIPT_DIR}/lib/apt.sh"
    grep -q 'mode_args=" --metadata-only"' "${SCRIPT_DIR}/lib/apt.sh"
    grep -q '${spec_args}${mode_args}' "${SCRIPT_DIR}/lib/apt.sh"
}

# -- systemd ------------------------------------------------------------------

@test "cache service: the launcher carries the proxy environment" {
    # cron and systemd both start with a minimal environment. The daemon
    # reaches upstream exactly like the sync scripts do, so it must reuse the
    # same preamble rather than a hand-copied set of Environment= lines that
    # can drift.
    MIRRORET_APT_MODE=hybrid install_cache_service
    local launcher="${MIRRORET_BASE_DIR}/scripts/run-cache.sh"
    [ -x "$launcher" ]
    grep -q '/etc/mirroret/mirroret.conf' "$launcher"
    grep -q 'https_proxy' "$launcher"
    grep -q 'MIRRORET_CA_BUNDLE' "$launcher"
    run bash -n "$launcher"
    [ "$status" -eq 0 ]
}

@test "cache service: unit runs the launcher and is confined to the mirror" {
    MIRRORET_APT_MODE=hybrid install_cache_service
    local unit="${MIRRORET_CACHE_UNIT}"
    [ -f "$unit" ]
    grep -q "ExecStart=${MIRRORET_BASE_DIR}/scripts/run-cache.sh" "$unit"
    grep -q "ReadWritePaths=${MIRRORET_BASE_DIR}" "$unit"
    grep -q 'ProtectSystem=full' "$unit"
}

@test "cache service: a size cap reaches the daemon's command line" {
    MIRRORET_APT_MODE=hybrid MIRRORET_CACHE_MAX_SIZE_GB=120 install_cache_service
    grep -q -- '--max-size-gb 120' "${MIRRORET_BASE_DIR}/scripts/run-cache.sh"

    # And no cap means the flag is absent entirely, not "--max-size-gb 0".
    MIRRORET_APT_MODE=hybrid MIRRORET_CACHE_MAX_SIZE_GB=0 install_cache_service
    ! grep -q -- '--max-size-gb' "${MIRRORET_BASE_DIR}/scripts/run-cache.sh"
}

# -- CLI ----------------------------------------------------------------------

@test "mirroretctl: cache subcommand is dispatched and documents its verbs" {
    grep -q 'cmd_cache' "${SCRIPT_DIR}/mirroretctl"
    grep -qE 'cache\)  *cmd_cache' "${SCRIPT_DIR}/mirroretctl"
    run bash -c "MIRRORET_CONF=/dev/null '${SCRIPT_DIR}/mirroretctl' cache bogus"
    [ "$status" -ne 0 ]
    [[ "$output" == *"status|routes|size|gc"* ]]
}

@test "mirroretctl: cache status explains mirror mode instead of erroring" {
    # In mirror mode there is no daemon, and reporting that as a failure
    # would send an operator hunting a service that should not exist.
    run bash -c "MIRRORET_CONF=/dev/null MIRRORET_APT_MODE=mirror \
        '${SCRIPT_DIR}/mirroretctl' cache status"
    [ "$status" -eq 0 ]
    [[ "$output" == *"not used"* ]]
}

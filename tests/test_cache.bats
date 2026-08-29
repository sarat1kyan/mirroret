#!/usr/bin/env bats
# Tests for engines/mirroret_cache.py - the on-demand pull-through cache.
#
# These run against a real HTTP upstream and a real daemon over a real
# socket, because every bug this file guards against was a concurrency or
# framing bug that a mocked transport would have hidden:
#
#   - a response body that contained a second HTTP response, because a lost
#     race made the handler send headers twice
#   - waiters reporting 404 for a download that was about to succeed
#   - a truncated body under a promised Content-Length, which hangs a
#     keep-alive client forever instead of failing it
#
# Byte-for-byte equality with upstream is asserted everywhere: a package
# cache that returns *almost* the right bytes is worse than one that fails.

load 'test_helpers'

setup() {
    load_lib
    TMPDIR_TEST="$(mktemp -d)"
    no_proxy_env
    UP="${TMPDIR_TEST}/up"
    CACHE="${TMPDIR_TEST}/cache"
    mkdir -p "${UP}/dists/noble" "${UP}/pool/main/c" "${CACHE}"
    echo "Suite: noble" > "${UP}/dists/noble/InRelease"
    head -c 300000 /dev/urandom > "${UP}/pool/main/c/pkg_1.0_amd64.deb"
}

teardown() {
    stop_fixture
    [[ -n "${TMPDIR_TEST:-}" ]] && rm -rf "${TMPDIR_TEST}"
}

_write_config() {
    # $1 = config path, remaining args = upstream URLs (in candidate order)
    local conf="$1"; shift
    local list="" u
    for u in "$@"; do
        [[ -n "$list" ]] && list="${list}, "
        list="${list}\"${u}\""
    done
    cat > "$conf" <<EOF
{"routes": {"ubuntu": {"upstreams": [${list}], "kind": "apt"}}}
EOF
}

_get() { curl -fsS --noproxy '*' --max-time 30 "$@"; }
_code() {
    curl -s -o /dev/null -w '%{http_code}' --noproxy '*' --max-time 30 "$1"
}

# -- basic pull-through -------------------------------------------------------

@test "cache: a miss fetches upstream, stores it, and returns exact bytes" {
    local up base
    up="$(serve_fixture "${UP}")"
    _write_config "${TMPDIR_TEST}/c.json" "$up"
    base="$(start_cache "${TMPDIR_TEST}/c.json" "${CACHE}")"

    _get -o "${TMPDIR_TEST}/got" "${base}/ubuntu/pool/main/c/pkg_1.0_amd64.deb"

    # What the client received, and what we stored, must both equal upstream.
    run bash -c "sha256sum '${UP}/pool/main/c/pkg_1.0_amd64.deb' \
        '${TMPDIR_TEST}/got' \
        '${CACHE}/ubuntu/pool/main/c/pkg_1.0_amd64.deb' \
        | awk '{print \$1}' | sort -u | wc -l"
    [ "$output" = "1" ]
}

@test "cache: the second request is a HIT and never touches upstream" {
    local up base log="${TMPDIR_TEST}/access.log"
    up="$(serve_fixture "${UP}" "$log")"
    _write_config "${TMPDIR_TEST}/c.json" "$up"
    base="$(start_cache "${TMPDIR_TEST}/c.json" "${CACHE}")"

    _get -o /dev/null "${base}/ubuntu/pool/main/c/pkg_1.0_amd64.deb"
    _get -o /dev/null "${base}/ubuntu/pool/main/c/pkg_1.0_amd64.deb"
    _get -o /dev/null "${base}/ubuntu/pool/main/c/pkg_1.0_amd64.deb"

    # Three client requests, exactly one upstream fetch.
    run bash -c "grep -c 'pkg_1.0_amd64.deb' '$log'"
    [ "$output" = "1" ]
    [ "$(cache_stat "$base" hits)" = "2" ]
}

@test "cache: response never contains a second HTTP response" {
    # A lost race between the writer renaming the partial file and a waiter
    # opening it used to make the handler emit a whole second response - so
    # the body of a small metadata file began with a literal
    # "HTTP/1.1 200 OK". Small files hit that race almost every time.
    local up base i
    up="$(serve_fixture "${UP}")"
    _write_config "${TMPDIR_TEST}/c.json" "$up"
    base="$(start_cache "${TMPDIR_TEST}/c.json" "${CACHE}")"

    for i in $(seq 1 15); do
        rm -rf "${CACHE:?}"/*
        run _get "${base}/ubuntu/dists/noble/InRelease"
        [ "$status" -eq 0 ]
        [ "$output" = "Suite: noble" ]
    done
}

# -- request coalescing -------------------------------------------------------

@test "cache: concurrent clients cause exactly ONE upstream fetch" {
    # The scenario this exists for: a fleet whose nightly upgrade window is
    # the same cron minute on every machine. Without single-flight that is N
    # identical downloads through one corporate proxy.
    local up base log="${TMPDIR_TEST}/access.log"
    head -c 4000000 /dev/urandom > "${UP}/pool/main/c/big_1.0_amd64.deb"
    up="$(serve_fixture "${UP}" "$log")"
    _write_config "${TMPDIR_TEST}/c.json" "$up"
    base="$(start_cache "${TMPDIR_TEST}/c.json" "${CACHE}")"

    local pids="" i p failed=0
    for i in $(seq 1 12); do
        curl -fsS --noproxy '*' --max-time 60 \
            -o "${TMPDIR_TEST}/out.$i" \
            "${base}/ubuntu/pool/main/c/big_1.0_amd64.deb" &
        pids="$pids $!"
    done
    for p in $pids; do wait "$p" || failed=$((failed + 1)); done
    [ "$failed" -eq 0 ]

    # Every client got the identical, complete file...
    run bash -c "sha256sum '${UP}/pool/main/c/big_1.0_amd64.deb' \
        ${TMPDIR_TEST}/out.* | awk '{print \$1}' | sort -u | wc -l"
    [ "$output" = "1" ]
    # ...from a single upstream request.
    run bash -c "grep -c 'big_1.0_amd64.deb' '$log'"
    [ "$output" = "1" ]
}

# -- routing and safety -------------------------------------------------------

@test "cache: an unconfigured route is 404, not a proxy to anywhere" {
    local up base
    up="$(serve_fixture "${UP}")"
    _write_config "${TMPDIR_TEST}/c.json" "$up"
    base="$(start_cache "${TMPDIR_TEST}/c.json" "${CACHE}")"
    [ "$(_code "${base}/not-a-route/x")" = "404" ]
}

@test "cache: path traversal cannot escape the cache directory" {
    # The daemon may be reachable from the LAN. A route prefix must not be a
    # way to read arbitrary files off the mirror server.
    local up base
    up="$(serve_fixture "${UP}")"
    _write_config "${TMPDIR_TEST}/c.json" "$up"
    base="$(start_cache "${TMPDIR_TEST}/c.json" "${CACHE}")"

    [ "$(_code "${base}/ubuntu/../../../etc/passwd")" = "404" ]
    [ "$(_code "${base}/ubuntu/%2e%2e/%2e%2e/etc/passwd")" = "404" ]
    [ "$(_code "${base}/ubuntu/a/../../../../etc/passwd")" = "404" ]
}

@test "cache: a file upstream does not have is 404, and is not cached" {
    local up base
    up="$(serve_fixture "${UP}")"
    _write_config "${TMPDIR_TEST}/c.json" "$up"
    base="$(start_cache "${TMPDIR_TEST}/c.json" "${CACHE}")"

    [ "$(_code "${base}/ubuntu/pool/main/c/nope_9.9_amd64.deb")" = "404" ]
    [ ! -e "${CACHE}/ubuntu/pool/main/c/nope_9.9_amd64.deb" ]
    # A failed fetch must not leave a partial behind for the next request to
    # mistake for a complete file.
    run bash -c "find '${CACHE}' -name '*.mirroret-part' | wc -l"
    [ "$output" = "0" ]
}

# -- split archives -----------------------------------------------------------

@test "cache: falls back to the next upstream on 404 (split security archive)" {
    # Debian serves bookworm from /debian but bookworm-security from
    # /debian-security, while clients see one /debian/ prefix. Candidates are
    # tried in order, so each suite resolves to the archive that has it.
    local main="${TMPDIR_TEST}/main" sec="${TMPDIR_TEST}/sec"
    mkdir -p "${main}/dists/bookworm" "${sec}/dists/bookworm-security"
    echo "from-main" > "${main}/dists/bookworm/InRelease"
    echo "from-security" > "${sec}/dists/bookworm-security/InRelease"

    local u1 u2 base
    u1="$(serve_fixture "${main}")"
    u2="$(serve_fixture "${sec}")"
    _write_config "${TMPDIR_TEST}/c.json" "$u1" "$u2"
    base="$(start_cache "${TMPDIR_TEST}/c.json" "${CACHE}")"

    run _get "${base}/ubuntu/dists/bookworm/InRelease"
    [ "$output" = "from-main" ]
    run _get "${base}/ubuntu/dists/bookworm-security/InRelease"
    [ "$output" = "from-security" ]
    # And again warm, from disk.
    run _get "${base}/ubuntu/dists/bookworm-security/InRelease"
    [ "$output" = "from-security" ]
}

# -- resilience ---------------------------------------------------------------

@test "cache: serves stale metadata when upstream is unreachable" {
    # A flaky corporate proxy must not take every client's package manager
    # down with it. A stale index is strictly better than a hard failure.
    local up base
    up="$(serve_fixture "${UP}")"
    _write_config "${TMPDIR_TEST}/c.json" "$up"
    base="$(start_cache "${TMPDIR_TEST}/c.json" "${CACHE}" --metadata-ttl 1)"

    run _get "${base}/ubuntu/dists/noble/InRelease"
    [ "$output" = "Suite: noble" ]

    stop_upstreams        # the archive is now gone; the mirror stays up
    sleep 2               # and the metadata TTL has expired

    run _get "${base}/ubuntu/dists/noble/InRelease"
    [ "$status" -eq 0 ]
    [ "$output" = "Suite: noble" ]
    [ "$(cache_stat "$base" stale_served)" -ge 1 ]
}

@test "cache: --offline serves what is cached and 404s the rest" {
    local up base
    up="$(serve_fixture "${UP}")"
    _write_config "${TMPDIR_TEST}/c.json" "$up"

    # Warm one file with a normal daemon, then restart offline.
    base="$(start_cache "${TMPDIR_TEST}/c.json" "${CACHE}")"
    _get -o /dev/null "${base}/ubuntu/pool/main/c/pkg_1.0_amd64.deb"
    stop_fixture

    base="$(start_cache "${TMPDIR_TEST}/c.json" "${CACHE}" --offline)"
    [ "$(_code "${base}/ubuntu/pool/main/c/pkg_1.0_amd64.deb")" = "200" ]
    [ "$(_code "${base}/ubuntu/dists/noble/InRelease")" = "404" ]
}

# -- classification (unit) ----------------------------------------------------

@test "cache: package files are immutable, metadata is not" {
    # Getting this backwards is a security bug in one direction (caching an
    # index forever hides security updates) and a performance bug in the
    # other (re-fetching every .deb on a TTL).
    run python3 - <<'PY'
import sys
sys.path.insert(0, "engines")
from mirroret_cache import is_immutable

immutable = [
    "pool/main/c/curl_8.5.0_amd64.deb",
    "pool/universe/n/nginx_1.24_amd64.deb",
    "getPackage/bash-5.1-1.el9.x86_64.rpm",
    "some/path/thing-1.0.tar.gz",
]
mutable = [
    "dists/noble/InRelease",
    "dists/noble/Release",
    "dists/noble/main/binary-amd64/Packages.xz",
    "dists/noble/main/dep11/Components-amd64.yml.gz",
    "dists/noble/main/cnf/Commands-amd64.xz",
    "repodata/repomd.xml",
    "repodata/primary.xml.gz",
]
bad = []
for p in immutable:
    if not is_immutable(p):
        bad.append("should be immutable: %s" % p)
for p in mutable:
    if is_immutable(p):
        bad.append("should be mutable: %s" % p)
if bad:
    print("\n".join(bad))
    sys.exit(1)
print("ok")
PY
    [ "$status" -eq 0 ]
    [[ "$output" == *"ok"* ]]
}

# -- config validation --------------------------------------------------------

@test "cache: --check validates the route table without binding a port" {
    _write_config "${TMPDIR_TEST}/c.json" "https://archive.ubuntu.com/ubuntu"
    run python3 "$(cache_engine)" --check \
        --config "${TMPDIR_TEST}/c.json" --cache-dir "${CACHE}"
    [ "$status" -eq 0 ]
    [[ "$output" == *"archive.ubuntu.com"* ]]
}

@test "cache: a missing or malformed config fails with an actionable message" {
    run python3 "$(cache_engine)" --check \
        --config "${TMPDIR_TEST}/absent.json" --cache-dir "${CACHE}"
    [ "$status" -ne 0 ]
    [[ "$output" == *"mirroretctl upgrade"* ]]

    echo '{"routes": {}}' > "${TMPDIR_TEST}/empty.json"
    run python3 "$(cache_engine)" --check \
        --config "${TMPDIR_TEST}/empty.json" --cache-dir "${CACHE}"
    [ "$status" -ne 0 ]
    [[ "$output" == *"no 'routes'"* ]]

    echo '{"routes": {"x": {"upstream": "ftp://nope/"}}}' > "${TMPDIR_TEST}/bad.json"
    run python3 "$(cache_engine)" --check \
        --config "${TMPDIR_TEST}/bad.json" --cache-dir "${CACHE}"
    [ "$status" -ne 0 ]
    [[ "$output" == *"http(s) URL"* ]]
}

# -- metadata-only mirroring (the hybrid half) --------------------------------

@test "apt engine: --metadata-only publishes indices and downloads no packages" {
    python3 "${SCRIPT_DIR}/tests/fixtures/make_apt_repo.py" \
        "${TMPDIR_TEST}/repo" --packages 4 >/dev/null
    local url
    url="$(serve_fixture "${TMPDIR_TEST}/repo")"

    run python3 "$(apt_engine)" --dest "${TMPDIR_TEST}/m" --url "${url}" \
        --suite testsuite --component main --arch amd64 --min-free-gb 0 \
        --metadata-only
    [ "$status" -eq 0 ]

    # The signed index tree is fully published...
    [ -f "${TMPDIR_TEST}/m/dists/testsuite/Release" ]
    [ -f "${TMPDIR_TEST}/m/dists/testsuite/main/binary-amd64/Packages.gz" ]
    # ...and not one package was downloaded.
    run bash -c "find '${TMPDIR_TEST}/m/pool' -type f 2>/dev/null | wc -l"
    [ "$output" = "0" ]
}

@test "apt engine: --metadata-only must NOT prune an existing pool" {
    # metadata-only deliberately empties the wanted-set. Pruning against an
    # empty set would delete every package the cache has accumulated - which
    # is the entire working set of the mirror.
    python3 "${SCRIPT_DIR}/tests/fixtures/make_apt_repo.py" \
        "${TMPDIR_TEST}/repo" --packages 3 >/dev/null
    local url
    url="$(serve_fixture "${TMPDIR_TEST}/repo")"

    # Full sync first, so the pool has real content.
    python3 "$(apt_engine)" --dest "${TMPDIR_TEST}/m" --url "${url}" \
        --suite testsuite --component main --arch amd64 --min-free-gb 0 \
        --delete >/dev/null
    local before
    before="$(find "${TMPDIR_TEST}/m/pool" -type f | wc -l)"
    [ "$before" -gt 0 ]

    # Now a metadata-only refresh with --delete still requested.
    run python3 "$(apt_engine)" --dest "${TMPDIR_TEST}/m" --url "${url}" \
        --suite testsuite --component main --arch amd64 --min-free-gb 0 \
        --metadata-only --delete
    [ "$status" -eq 0 ]
    [[ "$output" == *"prune skipped"* ]]

    run bash -c "find '${TMPDIR_TEST}/m/pool' -type f | wc -l"
    [ "$output" = "$before" ]
}

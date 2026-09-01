#!/usr/bin/env bats
# Regression tests for the defects found in the full-codebase audit.
#
# Each test names the failure it prevents. Several of these were data-loss
# bugs (an arch typo pruning an entire mirror), one was a proxy setting the
# wizard recorded but nothing read, and one was the integrity checker
# failing every healthy sync. None of them is allowed back.

load 'test_helpers'

setup() {
    load_lib
    # shellcheck source=/dev/null
    source "${SCRIPT_DIR}/lib/targets.sh"
    # shellcheck source=/dev/null
    source "${SCRIPT_DIR}/lib/cache.sh"
    # shellcheck source=/dev/null
    source "${SCRIPT_DIR}/lib/apt.sh"
    TMPDIR_TEST="$(mktemp -d)"
    no_proxy_env
    export DRY_RUN=0
}

teardown() {
    stop_fixture
    [[ -n "${TMPDIR_TEST:-}" ]] && rm -rf "${TMPDIR_TEST}"
}

_mk_apt_fixture() { python3 "${SCRIPT_DIR}/tests/fixtures/make_apt_repo.py" "$@" >/dev/null; }
_mk_rpm_fixture() { python3 "${SCRIPT_DIR}/tests/fixtures/make_rpm_repo.py" "$@" >/dev/null; }

# -- engines: empty selection must never publish or prune -----------------------

@test "apt engine: an arch typo refuses to publish instead of pruning the pool" {
    # MIRRORET_APT_ARCH="x86_64" (rpm spelling) matched nothing. The suite
    # still counted as successful, Release was published with no usable
    # index, and --delete pruned every .deb against an empty wanted-set.
    _mk_apt_fixture "${TMPDIR_TEST}/up" --packages 3
    local url
    url="$(serve_fixture "${TMPDIR_TEST}/up")"

    # A good sync first, so there is a pool to lose.
    python3 "$(apt_engine)" --dest "${TMPDIR_TEST}/m" --url "${url}" \
        --suite testsuite --component main --arch amd64 --min-free-gb 0 --delete >/dev/null
    local before
    before="$(find "${TMPDIR_TEST}/m/pool" -type f | wc -l)"
    [ "$before" -eq 3 ]

    run python3 "$(apt_engine)" --dest "${TMPDIR_TEST}/m" --url "${url}" \
        --suite testsuite --component main --arch x86_64 --min-free-gb 0 --delete
    [ "$status" -ne 0 ]
    [[ "$output" == *"no Packages index matched"* ]]
    [[ "$output" == *"amd64, not x86_64"* ]]

    # Nothing was deleted, and the previously published Release is intact.
    [ "$(find "${TMPDIR_TEST}/m/pool" -type f | wc -l)" -eq "$before" ]
    [ -f "${TMPDIR_TEST}/m/dists/testsuite/Release" ]
}

@test "apt engine: prune() with an empty wanted-set is a no-op" {
    run python3 - <<'PY'
import os, sys, tempfile, argparse
sys.path.insert(0, "engines")
from mirroret_apt import AptMirror
d = tempfile.mkdtemp()
os.makedirs(os.path.join(d, "pool/main/x"))
open(os.path.join(d, "pool/main/x/x_1_amd64.deb"), "w").write("keep me")
m = AptMirror.__new__(AptMirror)
m.dest = d; m.wanted = {}
removed = m.prune()
assert removed == 0, removed
assert os.path.exists(os.path.join(d, "pool/main/x/x_1_amd64.deb"))
print("ok")
PY
    [ "$status" -eq 0 ]
    [[ "$output" == *"ok"* ]]
}

@test "rpm engine: an arch that matches nothing refuses to publish empty repodata" {
    _mk_rpm_fixture "${TMPDIR_TEST}/up"
    local url
    url="$(serve_fixture "${TMPDIR_TEST}/up")"

    python3 "$(rpm_engine)" --dest "${TMPDIR_TEST}/m" --repo "r=${url}" \
        --arch x86_64 --min-free-gb 0 >/dev/null
    local before
    before="$(find "${TMPDIR_TEST}/m" -name '*.rpm' | wc -l)"
    [ "$before" -gt 0 ]

    run python3 "$(rpm_engine)" --dest "${TMPDIR_TEST}/m" --repo "r=${url}" \
        --arch amd64 --min-free-gb 0
    [ "$status" -ne 0 ]
    [[ "$output" == *"no packages matched"* ]]
    [ "$(find "${TMPDIR_TEST}/m" -name '*.rpm' | wc -l)" -eq "$before" ]
    [ -f "${TMPDIR_TEST}/m/r/repodata/repomd.xml" ]
}

@test "rpm engine: an empty or traversing repo id is rejected" {
    run python3 "$(rpm_engine)" --dest "${TMPDIR_TEST}/m" --repo "=http://127.0.0.1:1/" --min-free-gb 0
    [ "$status" -ne 0 ]
    [[ "$output" == *"invalid repo id"* ]]
    run python3 "$(rpm_engine)" --dest "${TMPDIR_TEST}/m" --repo "../x=http://127.0.0.1:1/" --min-free-gb 0
    [ "$status" -ne 0 ]
    [[ "$output" == *"invalid repo id"* ]]
}

# -- engines: untrusted paths ----------------------------------------------------

@test "apt engine: a traversing Filename in Packages is ignored, never written" {
    # On an http:// upstream with no local keyring, Filename is attacker-
    # influenced and is joined onto dest as root.
    run python3 - <<'PY'
import sys
sys.path.insert(0, "engines")
from mirroret_apt import _safe_archive_relpath as ok
assert ok("pool/main/c/curl_1_amd64.deb")
assert not ok("../../etc/cron.d/x")
assert not ok("pool/../../x")
assert not ok("/etc/passwd")
assert not ok("pool/main//x.deb")
assert not ok("pool/main/./x.deb")
assert not ok("pool/a\x00b.deb")
print("ok")
PY
    [ "$status" -eq 0 ]
    [[ "$output" == *"ok"* ]]
}

@test "apt engine: a repo that publishes only InRelease is accepted" {
    # Many third-party repos (GitHub pages, aptly) ship InRelease and no
    # plain Release. apt accepts that; so must the mirror.
    _mk_apt_fixture "${TMPDIR_TEST}/up" --packages 1
    mv "${TMPDIR_TEST}/up/dists/testsuite/Release" "${TMPDIR_TEST}/up/dists/testsuite/InRelease"
    local url
    url="$(serve_fixture "${TMPDIR_TEST}/up")"
    run python3 "$(apt_engine)" --dest "${TMPDIR_TEST}/m" --url "${url}" \
        --suite testsuite --component main --arch amd64 --min-free-gb 0
    [ "$status" -eq 0 ]
    [ -f "${TMPDIR_TEST}/m/dists/testsuite/InRelease" ]
}

@test "apt engine: publishing writes a manifest of the mirrored index paths" {
    _mk_apt_fixture "${TMPDIR_TEST}/up" --packages 1
    local url
    url="$(serve_fixture "${TMPDIR_TEST}/up")"
    python3 "$(apt_engine)" --dest "${TMPDIR_TEST}/m" --url "${url}" \
        --suite testsuite --component main --arch amd64 --min-free-gb 0 >/dev/null
    local mf="${TMPDIR_TEST}/m/dists/testsuite/.mirroret-manifest.json"
    [ -f "$mf" ]
    run python3 -c "
import json; d=json.load(open('$mf'))
assert 'main/binary-amd64/Packages.gz' in d['entries'], d['entries']
assert d['arches']==['amd64']
print('ok')"
    [ "$status" -eq 0 ]
}

# -- fetch layer -----------------------------------------------------------------

@test "fetch layer: legacy checksum type 'sha' is SHA-1, not a crash" {
    run python3 - <<'PY'
import sys, hashlib
sys.path.insert(0, "engines")
from mirroret_fetch import normalize_algo, file_matches
import tempfile, os
assert normalize_algo("sha") == "sha1"
assert normalize_algo("SHA-256") == "sha256"
p = tempfile.mktemp(); open(p, "wb").write(b"abc")
assert file_matches(p, hashlib.sha1(b"abc").hexdigest(), "sha", 3)
# An algorithm hashlib does not know must be "does not match", not a traceback.
assert file_matches(p, "00", "nonsense-algo", 3) is False
print("ok")
PY
    [ "$status" -eq 0 ]
    [[ "$output" == *"ok"* ]]
}

@test "fetch layer: a mid-body reset is a retryable TransferError, not a raw OSError" {
    run python3 - <<'PY'
import sys
sys.path.insert(0, "engines")
import mirroret_fetch as mf
assert issubclass(mf.TransferError, mf.FetchError)
import http.client
assert http.client.IncompleteRead in mf._TRANSFER_ERRORS or any(
    issubclass(http.client.IncompleteRead, t) for t in mf._TRANSFER_ERRORS)
assert any(issubclass(ConnectionResetError, t) for t in mf._TRANSFER_ERRORS)
print("ok")
PY
    [ "$status" -eq 0 ]
}

# -- cache daemon ----------------------------------------------------------------

@test "cache: a directory path is 404, never fetched and cached as a file" {
    # GET /ubuntu/dists (no slash) used to store an HTML listing as a regular
    # file named 'dists', after which every dists/... request died with
    # NotADirectoryError until someone deleted it by hand.
    mkdir -p "${TMPDIR_TEST}/up/dists/noble" "${TMPDIR_TEST}/cache/ubuntu/dists"
    echo x > "${TMPDIR_TEST}/up/dists/noble/InRelease"
    local up base
    up="$(serve_fixture "${TMPDIR_TEST}/up")"
    printf '{"routes":{"ubuntu":{"upstreams":["%s"]}}}' "$up" > "${TMPDIR_TEST}/c.json"
    base="$(start_cache "${TMPDIR_TEST}/c.json" "${TMPDIR_TEST}/cache")"
    local code
    code="$(curl -s -o /dev/null -w '%{http_code}' --noproxy '*' "${base}/ubuntu/dists")"
    [ "$code" = "404" ]
    [ -d "${TMPDIR_TEST}/cache/ubuntu/dists" ]
    # And the subtree still works afterwards.
    run curl -fsS --noproxy '*' "${base}/ubuntu/dists/noble/InRelease"
    [ "$output" = "x" ]
}

@test "cache: concurrent revalidation of one stale index yields one intact file" {
    mkdir -p "${TMPDIR_TEST}/up/dists/noble"
    head -c 600000 /dev/urandom > "${TMPDIR_TEST}/up/dists/noble/Packages"
    local up base
    up="$(serve_fixture "${TMPDIR_TEST}/up")"
    printf '{"routes":{"ubuntu":{"upstreams":["%s"]}}}' "$up" > "${TMPDIR_TEST}/c.json"
    base="$(start_cache "${TMPDIR_TEST}/c.json" "${TMPDIR_TEST}/cache" --metadata-ttl 1)"
    curl -fsS --noproxy '*' -o /dev/null "${base}/ubuntu/dists/noble/Packages"
    sleep 2   # expire the TTL so every request below revalidates
    # Change upstream so revalidation actually re-downloads.
    head -c 700000 /dev/urandom > "${TMPDIR_TEST}/up/dists/noble/Packages"
    touch -d '+1 minute' "${TMPDIR_TEST}/up/dists/noble/Packages" 2>/dev/null || true
    local pids="" i p
    for i in $(seq 1 12); do
        curl -fsS --noproxy '*' -o "${TMPDIR_TEST}/o.$i" "${base}/ubuntu/dists/noble/Packages" &
        pids="$pids $!"
    done
    for p in $pids; do wait "$p"; done
    # No zero-filled holes: the cached file equals upstream byte for byte.
    run bash -c "sha256sum '${TMPDIR_TEST}/up/dists/noble/Packages' '${TMPDIR_TEST}/cache/ubuntu/dists/noble/Packages' | awk '{print \$1}' | sort -u | wc -l"
    [ "$output" = "1" ]
    # And no temp files were left behind.
    run bash -c "find '${TMPDIR_TEST}/cache' -name '.mirroret-reval-*' -o -name '*.mirroret-part' | wc -l"
    [ "$output" = "0" ]
}

# -- shared preamble -------------------------------------------------------------

@test "preamble: MIRRORET_PROXY is mapped onto http_proxy/https_proxy" {
    # The wizard recorded MIRRORET_PROXY and nothing read it. Every nightly
    # sync behind a corporate proxy failed while the conf looked correct.
    local pre
    pre="$(mirroret_script_preamble)"
    run bash -c "
        MIRRORET_PROXY=http://proxy.example:3128
        unset http_proxy https_proxy
        $(printf '%s\n' "$pre" | grep -v '^\. /etc/mirroret/mirroret.conf' | sed 's|/etc/mirroret/mirroret.conf|/nonexistent|')
        echo \"\$https_proxy|\$http_proxy|\$no_proxy\""
    [ "$status" -eq 0 ]
    [[ "$output" == "http://proxy.example:3128|http://proxy.example:3128|"*localhost* ]]
}

@test "preamble: loopback is excluded from the proxy" {
    local pre
    pre="$(mirroret_script_preamble)"
    run bash -c "
        http_proxy=http://proxy.example:3128
        $(printf '%s\n' "$pre" | sed 's|/etc/mirroret/mirroret.conf|/nonexistent|')
        echo \"\$no_proxy\""
    [[ "$output" == *"127.0.0.1"* ]]
    [[ "$output" == *"localhost"* ]]
}

# -- target specs ----------------------------------------------------------------

@test "targets: booleans accept yes/true/1 and numbers are validated" {
    run bash -c "source '${SCRIPT_DIR}/lib/logging.sh'; source '${SCRIPT_DIR}/lib/common.sh'
        source '${SCRIPT_DIR}/lib/distro.sh'; source '${SCRIPT_DIR}/lib/targets.sh'
        printf '%s %s %s %s ' \"\$(_json_bool yes)\" \"\$(_json_bool TRUE)\" \"\$(_json_bool 0)\" \"\$(_json_bool '')\"
        printf '%s %s' \"\$(_json_number 12 10)\" \"\$(_json_number 10G 10 2>/dev/null)\""
    [ "$output" = "true true false false 12 10" ]
}

@test "targets: a quote in an operator string still yields valid JSON" {
    export MIRRORET_TARGETS_DIR="${TMPDIR_TEST}/t"
    MIRRORET_APT_TARGETS="ubuntu:noble" MIRRORET_APT_REQUIRE_SIGNATURE=yes \
        MIRRORET_APT_KEYRING='/tmp/we"ird.gpg' generate_target_specs >/dev/null 2>&1 || true
    run python3 -c "import json,glob; [json.load(open(f)) for f in glob.glob('${TMPDIR_TEST}/t/*.json')]; print('ok')"
    [ "$status" -eq 0 ]
    run bash -c "grep -c '\"require_signature\": true' ${TMPDIR_TEST}/t/apt-ubuntu-noble.json"
    [ "$output" = "1" ]
}

@test "targets: hybrid mode is recorded in the spec as metadata_only" {
    export MIRRORET_TARGETS_DIR="${TMPDIR_TEST}/t"
    MIRRORET_APT_MODE=hybrid MIRRORET_APT_TARGETS="ubuntu:noble" generate_target_specs >/dev/null 2>&1
    grep -q '"metadata_only": true' "${TMPDIR_TEST}/t/apt-ubuntu-noble.json"
    MIRRORET_APT_MODE=mirror MIRRORET_APT_TARGETS="ubuntu:noble" generate_target_specs >/dev/null 2>&1
    grep -q '"metadata_only": false' "${TMPDIR_TEST}/t/apt-ubuntu-noble.json"
}

@test "targets: an RPM major with a minor is normalised (ol:9.4 -> 9)" {
    export MIRRORET_TARGETS_DIR="${TMPDIR_TEST}/t"
    MIRRORET_RPM_TARGETS="ol:9.4" MIRRORET_APT_TARGETS="" MIRRORET_ENABLE_APT=0 generate_target_specs >/dev/null 2>&1
    [ -f "${TMPDIR_TEST}/t/rpm-ol-9.json" ]
    ! grep -q 'OL9.4' "${TMPDIR_TEST}/t/rpm-ol-9.json"
}

@test "targets: unknown ol repo ids fall through in stripped form" {
    run bash -c "source '${SCRIPT_DIR}/lib/logging.sh'; source '${SCRIPT_DIR}/lib/common.sh'
        source '${SCRIPT_DIR}/lib/distro.sh'; source '${SCRIPT_DIR}/lib/targets.sh'
        rpm_repo_alias ol 9 ol9_Developer"
    [ "$output" = "developer" ]
}

@test "targets: ubuntu + arm64 warns to use ubuntu-ports" {
    export MIRRORET_TARGETS_DIR="${TMPDIR_TEST}/t"
    run bash -c "source '${SCRIPT_DIR}/lib/logging.sh'; source '${SCRIPT_DIR}/lib/common.sh'
        source '${SCRIPT_DIR}/lib/distro.sh'; source '${SCRIPT_DIR}/lib/targets.sh'
        MIRRORET_APT_TARGETS='ubuntu:noble:arm64' MIRRORET_ENABLE_RPM=0 generate_target_specs"
    [[ "$output" == *"ubuntu-ports"* ]]
}

# -- generated sync scripts ------------------------------------------------------

@test "sync-all: the conf is sourced BEFORE the disk floor is read" {
    # cron gives an empty environment; MIRRORET_SYNC_MIN_FREE_GB lives in
    # the conf. Reading the floor first silently used the 10 GB default.
    local pre floor
    pre="$(grep -n 'mirroret.conf' "${SCRIPT_DIR}/install.sh" | grep -m1 'mirroret_script_preamble\|\. /etc/mirroret' | cut -d: -f1)"
    run bash -c "awk '/^write_master_sync_script/,/^SYNC_EOF/' '${SCRIPT_DIR}/install.sh' | grep -n 'mirroret_script_preamble\|MIN_FREE_GB=' | head -2"
    # preamble line number must be smaller than the MIN_FREE_GB line number
    local l1 l2
    l1="$(echo "$output" | sed -n 1p | cut -d: -f1)"
    l2="$(echo "$output" | sed -n 2p | cut -d: -f1)"
    [[ "$(echo "$output" | sed -n 1p)" == *preamble* ]]
    [ "$l1" -lt "$l2" ]
}

@test "sync-all: pip and npm steps are gated on their ENABLE flags" {
    run bash -c "awk '/^write_master_sync_script/,/^SYNC_EOF/' '${SCRIPT_DIR}/install.sh'"
    [[ "$output" == *'_run_step "pip" "${pip_sync_cmd}"'* ]]
    [[ "$output" == *'_run_step "npm" "${npm_sync_cmd}"'* ]]
    [[ "$output" == *'MIRRORET_ENABLE_PIP}" == "1" ]] && pip_sync_cmd='* ]]
}

@test "sync-apt: --metadata-only is baked at generation time, not read from env at run time" {
    export MIRRORET_BASE_DIR="${TMPDIR_TEST}/srv" DRY_RUN=0
    export MIRRORET_TARGETS_DIR="${TMPDIR_TEST}/t"
    mkdir -p "${MIRRORET_BASE_DIR}/scripts"
    MIRRORET_APT_MODE=hybrid MIRRORET_APT_TARGETS="ubuntu:noble" generate_target_specs >/dev/null 2>&1
    MIRRORET_APT_MODE=hybrid _write_apt_native_sync_script "${MIRRORET_BASE_DIR}" "${MIRRORET_TARGETS_DIR}/apt-ubuntu-noble.json"
    grep -q -- '--metadata-only' "${MIRRORET_BASE_DIR}/scripts/sync-apt-repos.sh"
    ! grep -q 'case "${MIRRORET_APT_MODE' "${MIRRORET_BASE_DIR}/scripts/sync-apt-repos.sh"
    bash -n "${MIRRORET_BASE_DIR}/scripts/sync-apt-repos.sh"
}

@test "sync-apt: the spec path is %q-quoted" {
    grep -q "printf -v q '%q'" "${SCRIPT_DIR}/lib/apt.sh"
}

# -- nginx -----------------------------------------------------------------------

@test "nginx: pure cache mode sends dists/ through the daemon so indices refresh" {
    # With try_files alone, a cached InRelease was served off disk forever and
    # no security update ever reached a client.
    export MIRRORET_TARGETS_DIR="${TMPDIR_TEST}/t"
    run bash -c "source '${SCRIPT_DIR}/lib/logging.sh'; source '${SCRIPT_DIR}/lib/common.sh'
        source '${SCRIPT_DIR}/lib/distro.sh'; source '${SCRIPT_DIR}/lib/targets.sh'
        source '${SCRIPT_DIR}/lib/cache.sh'; source '${SCRIPT_DIR}/lib/nginx.sh'
        export MIRRORET_APT_MODE=cache MIRRORET_APT_TARGETS='ubuntu:noble'
        generate_target_specs >/dev/null 2>&1
        _nginx_apt_locations /srv/mirroret /legacy"
    [[ "$output" == *'location ~ ^/ubuntu/dists/ {'* ]]
    [[ "$output" == *'try_files $uri @mirroret_cache'* ]]
    # hybrid must NOT proxy dists (the nightly sync rewrites it)
    run bash -c "source '${SCRIPT_DIR}/lib/logging.sh'; source '${SCRIPT_DIR}/lib/common.sh'
        source '${SCRIPT_DIR}/lib/distro.sh'; source '${SCRIPT_DIR}/lib/targets.sh'
        source '${SCRIPT_DIR}/lib/cache.sh'; source '${SCRIPT_DIR}/lib/nginx.sh'
        export MIRRORET_APT_MODE=hybrid MIRRORET_APT_TARGETS='ubuntu:noble'
        generate_target_specs >/dev/null 2>&1
        _nginx_apt_locations /srv/mirroret /legacy"
    [[ "$output" != *'location ~ ^/ubuntu/dists/'* ]]
}

@test "nginx: legacy fallback honours the flavor prefix and hides engines/backups" {
    run bash -c "source '${SCRIPT_DIR}/lib/logging.sh'; source '${SCRIPT_DIR}/lib/common.sh'
        source '${SCRIPT_DIR}/lib/nginx.sh'
        MIRRORET_APT_SPECS=(); MIRRORET_APT_NGINX_PREFIX=/debian _nginx_apt_locations /srv/mirroret /legacy/path"
    [[ "$output" == *'location /debian/ {'* ]]
    grep -q 'logs|scripts|staging|engines|backups|targets' "${SCRIPT_DIR}/lib/nginx.sh"
}

# -- cache wiring ----------------------------------------------------------------

@test "cache wiring: routes come from the resolved targets, and no routes means no daemon" {
    grep -q 'resolved_apt_targets' "${SCRIPT_DIR}/lib/cache.sh"
    grep -q 'Cache daemon not installed: no routes' "${SCRIPT_DIR}/lib/cache.sh"
    # switching back to mirror mode disables a previously enabled unit
    grep -q 'systemctl disable --now mirroret-cache' "${SCRIPT_DIR}/lib/cache.sh"
}

# -- RPM engine selection --------------------------------------------------------

@test "rpm.sh: one empty target does not flip the whole install to reposync" {
    export MIRRORET_TARGETS_DIR="${TMPDIR_TEST}/t"
    run bash -c "source '${SCRIPT_DIR}/lib/logging.sh'; source '${SCRIPT_DIR}/lib/common.sh'
        source '${SCRIPT_DIR}/lib/distro.sh'; source '${SCRIPT_DIR}/lib/targets.sh'
        source '${SCRIPT_DIR}/lib/rpm.sh'
        export MIRRORET_ENABLE_APT=0 MIRRORET_RPM_TARGETS='ol:9 epel:9' MIRRORET_RPM_REPOS='baseos appstream'
        generate_target_specs >/dev/null 2>&1
        MIRRORET_RPM_ENGINE=auto _rpm_resolve_engine"
    [[ "$output" == *native* ]]
}

# -- installer -------------------------------------------------------------------

@test "install.sh: environment beats the auto-loaded conf" {
    grep -q '_env_snapshot' "${SCRIPT_DIR}/install.sh"
    grep -q "printf -v \"\${_name}\"" "${SCRIPT_DIR}/install.sh"
}

@test "install.sh: a value flag as the last argument is a usage error, not a crash" {
    run bash "${SCRIPT_DIR}/install.sh" --apt-targets
    [ "$status" -ne 0 ]
    [[ "$output" == *"requires a value"* ]]
    [[ "$output" != *"unbound variable"* ]]
}

@test "install.sh: the wizard runs before preflight and package installation" {
    local wiz pre pkg
    wiz="$(grep -n 'run_first_run_wizard$' "${SCRIPT_DIR}/install.sh" | head -1 | cut -d: -f1)"
    pre="$(grep -n '^    run_preflight$' "${SCRIPT_DIR}/install.sh" | head -1 | cut -d: -f1)"
    pkg="$(grep -n '^        install_system_packages$' "${SCRIPT_DIR}/install.sh" | head -1 | cut -d: -f1)"
    [ "$wiz" -lt "$pre" ]
    [ "$pre" -lt "$pkg" ]
}

@test "install.sh: --check captures each check's status instead of dying on the first" {
    grep -q 'rc=0; _check_commands || rc=$?' "${SCRIPT_DIR}/lib/validation.sh"
    grep -q 'run_validation || _rc=$?' "${SCRIPT_DIR}/install.sh"
}

@test "install.sh: dry-run never installs packages on RHEL" {
    run bash -c "awk '/^install_system_packages/,/^}/' '${SCRIPT_DIR}/install.sh'"
    # every raw dnf/yum install is inside a DRY_RUN guard now
    [[ "$output" == *'[DRY-RUN] would install: nodejs npm'* ]]
    [[ "$output" == *'[DRY-RUN] would install: docker-distribution'* ]]
}

@test "install.sh: mirroretctl is linked onto PATH" {
    grep -q 'ln -sfn "${target}" "${link}"' "${SCRIPT_DIR}/install.sh"
    grep -q '^    install_cli_symlink$' "${SCRIPT_DIR}/install.sh"
}

@test "firewall: a firewalld that is installed but stopped does not kill the install" {
    grep -q 'firewall-cmd --state' "${SCRIPT_DIR}/lib/firewall.sh"
    grep -q 'installed but not running' "${SCRIPT_DIR}/lib/firewall.sh"
}

@test "preflight: hybrid/cache mode lowers the disk floor and non-interactive warns instead of dying" {
    grep -q 'hybrid|cache) \[\[ "${min_gb}" -gt 10 \]\] && min_gb=10' "${SCRIPT_DIR}/lib/preflight.sh"
    grep -q 'Non-interactive: continuing' "${SCRIPT_DIR}/lib/preflight.sh"
}

@test "rollback: files that did not exist before the install are removed" {
    grep -q 'would remove (did not exist before install)' "${SCRIPT_DIR}/lib/backup.sh"
    grep -q 'systemctl daemon-reload' "${SCRIPT_DIR}/lib/backup.sh"
}

# -- wizard ----------------------------------------------------------------------

@test "wizard: the proxy answer is exported for the rest of the install" {
    grep -q 'export http_proxy="$proxy" https_proxy="$proxy"' "${SCRIPT_DIR}/lib/wizard.sh"
}

@test "wizard: comma-separated menu input works" {
    # shellcheck source=/dev/null
    source "${SCRIPT_DIR}/lib/wizard.sh"
    REPLY=""
    _wz_multichoice "q" "1" "a|A" "b|B" "c|C" <<< "1,3" 2>/dev/null
    [ "$REPLY" = "a c" ]
}

@test "wizard: the sync hour it writes is now asked for" {
    grep -q 'Nightly sync hour' "${SCRIPT_DIR}/lib/wizard.sh"
}

# -- verify-mirror ---------------------------------------------------------------

@test "verify-mirror: Release entries the config never mirrored are not failures" {
    # Ubuntu's Release lists i386, arm64, Contents-*, sources... A filtered
    # amd64 mirror republishes that Release verbatim, so 'every entry must
    # exist' failed every healthy nightly sync with exit 4.
    local base="${TMPDIR_TEST}/srv" suite="${TMPDIR_TEST}/srv/apt/ubuntu/dists/noble"
    mkdir -p "${suite}/main/binary-amd64"
    printf 'hello' > "${suite}/main/binary-amd64/Packages"
    local z; z="$(printf '%064d' 0)"
    {
        echo "Suite: noble"; echo "SHA256:"
        printf " %s 5 main/binary-amd64/Packages\n" "$z"
        printf " %s 5 main/binary-i386/Packages\n" "$z"
        printf " %s 999 Contents-amd64.gz\n" "$z"
        printf " %s 999 main/source/Sources.gz\n" "$z"
    } > "${suite}/Release"
    # Without a manifest: old behaviour, 3 missing.
    run "${SCRIPT_DIR}/scripts/verify-mirror.sh" --base-dir "$base"
    [ "$status" -eq 2 ]
    # With the engine's manifest: only the intended entry is checked.
    echo '{"entries": ["main/binary-amd64/Packages"]}' > "${suite}/.mirroret-manifest.json"
    run "${SCRIPT_DIR}/scripts/verify-mirror.sh" --base-dir "$base"
    [ "$status" -eq 0 ]
    [[ "$output" == *"3 not mirrored by config"* ]]
    # A manifest entry that IS missing still fails.
    echo '{"entries": ["main/binary-amd64/Packages", "main/binary-i386/Packages"]}' > "${suite}/.mirroret-manifest.json"
    run "${SCRIPT_DIR}/scripts/verify-mirror.sh" --base-dir "$base"
    [ "$status" -eq 2 ]
    [[ "$output" == *"missing: main/binary-i386/Packages"* ]]
    [[ "$output" == *"mirroretctl logs errors"* ]]
}

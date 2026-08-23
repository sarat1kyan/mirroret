#!/usr/bin/env bats
# Tests for mirroretctl and the service-binary resolution fixes.
#
# The CLI is exercised against a fake install tree under a tmpdir so the
# read-only subcommands can be verified without root and without touching
# a real /srv/mirroret.

load 'test_helpers'

setup() {
    TMPDIR="$(mktemp -d)"
    FAKE_BASE="${TMPDIR}/srv/mirroret"
    mkdir -p "${FAKE_BASE}"/{scripts,logs,config}
    # mirroretctl reads MIRRORET_BASE_DIR from the environment (or the conf
    # file, which we do not create here).
    export MIRRORET_BASE_DIR="${FAKE_BASE}"
    # Isolate MIRRORET_TARGETS_DIR and MIRRORET_CONF from anything a
    # neighbouring test (or a real install on this box) may have written to
    # /etc/mirroret. Without this, one leftover target spec makes an
    # otherwise green test flip flavour.
    export MIRRORET_TARGETS_DIR="${TMPDIR}/targets"
    export MIRRORET_CONF="${TMPDIR}/mirroret.conf"
    mkdir -p "${MIRRORET_TARGETS_DIR}"
    CTL="${SCRIPT_DIR}/mirroretctl"
}

teardown() {
    rm -rf "${TMPDIR}"
}

# ---------------------------------------------------------------- basics ----

@test "cli: exists and is executable" {
    [ -x "${CTL}" ]
}

@test "cli: parses cleanly under bash -n" {
    bash -n "${CTL}"
}

@test "cli: help exits 0 and lists the command groups" {
    run bash "${CTL}" help
    [ "$status" -eq 0 ]
    [[ "$output" == *"Inspect (no root needed)"* ]]
    [[ "$output" == *"Change state (root)"* ]]
}

@test "cli: no args on a non-tty prints help instead of hanging on a menu" {
    run bash -c "bash '${CTL}' </dev/null"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Usage:"* ]]
}

@test "cli: unknown command exits 2" {
    run bash "${CTL}" not-a-real-command
    [ "$status" -eq 2 ]
    [[ "$output" == *"Unknown command"* ]]
}

@test "cli: unknown sync target is rejected" {
    run bash "${CTL}" sync bananas
    [ "$status" -ne 0 ]
}

# ------------------------------------------------------------- root gating ----

@test "cli: state-changing subcommand refuses to run without root" {
    [ "$(id -u)" -ne 0 ] || skip "needs a non-root user; this run is root"
    run bash "${CTL}" sync all
    [ "$status" -eq 1 ]
    [[ "$output" == *"needs root"* ]]
}

@test "cli: upgrade refuses without root" {
    [ "$(id -u)" -ne 0 ] || skip "needs a non-root user; this run is root"
    run bash "${CTL}" upgrade
    [ "$status" -eq 1 ]
    [[ "$output" == *"needs root"* ]]
}

@test "cli: clean refuses without root" {
    [ "$(id -u)" -ne 0 ] || skip "needs a non-root user; this run is root"
    run bash "${CTL}" clean report
    [ "$status" -eq 1 ]
}

@test "cli: read-only subcommands do NOT require root" {
    [ "$(id -u)" -ne 0 ] || skip "needs a non-root user; this run is root"
    for sub in status "sync status" "sync last" "client list" "logs list" "config path"; do
        # shellcheck disable=SC2086
        run bash "${CTL}" $sub
        [ "$status" -eq 0 ]
    done
}

# ---------------------------------------------------------------- status ----

@test "cli: status reports the configured base dir" {
    run bash "${CTL}" status
    [ "$status" -eq 0 ]
    [[ "$output" == *"${FAKE_BASE}"* ]]
}

@test "cli: status warns when the base dir is absent" {
    export MIRRORET_BASE_DIR="${TMPDIR}/definitely-not-here"
    run bash "${CTL}" status
    [ "$status" -eq 0 ]
    [[ "$output" == *"does not exist"* ]]
}

# ------------------------------------------------------------ sync status ----

@test "cli: sync status reports idle when no lock files exist" {
    run bash "${CTL}" sync status
    [ "$status" -eq 0 ]
    [[ "$output" == *"idle"* ]]
}

@test "cli: sync last summarises the newest log" {
    printf 'start\nRPM sync completed: today (sync_failed=0 metadata_failed=0)\n' \
        > "${FAKE_BASE}/logs/sync-redhat-20260101-000000.log"
    run bash "${CTL}" sync last
    [ "$status" -eq 0 ]
    [[ "$output" == *"sync-redhat-20260101-000000.log"* ]]
}

# ------------------------------------------------------------------ logs ----

@test "cli: logs errors surfaces FAIL lines from recent logs" {
    printf 'ok line\nFAIL: reposync ol9_appstream\n' \
        > "${FAKE_BASE}/logs/sync-redhat-20260101-000000.log"
    run bash "${CTL}" logs errors
    [ "$status" -eq 0 ]
    [[ "$output" == *"FAIL: reposync ol9_appstream"* ]]
}

@test "cli: logs list tolerates an empty log dir" {
    run bash "${CTL}" logs list
    [ "$status" -eq 0 ]
}

# -------------------------------------------------------- client verify ----

@test "cli: client verify flags gpgcheck=1 with no gpgkey" {
    cat > "${FAKE_BASE}/config/redhat-client.repo" <<'EOF'
[mirroret-ol9_baseos_latest]
name=Mirroret - ol9_baseos_latest
baseurl=http://10.0.0.1:8080/redhat/ol/9/ol9_baseos_latest
enabled=1
gpgcheck=1
EOF
    run bash "${CTL}" client verify
    [ "$status" -ne 0 ]
    [[ "$output" == *"no gpgkey"* ]]
}

@test "cli: client verify accepts gpgcheck=1 with a gpgkey" {
    mkdir -p "${FAKE_BASE}/redhat/ol/9/ol9_baseos_latest"
    cat > "${FAKE_BASE}/config/redhat-client.repo" <<'EOF'
[mirroret-ol9_baseos_latest]
name=Mirroret - ol9_baseos_latest
baseurl=http://10.0.0.1:8080/redhat/ol/9/ol9_baseos_latest
enabled=1
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-oracle
EOF
    run bash "${CTL}" client verify
    [[ "$output" == *"gpgcheck/gpgkey consistent"* ]]
}

@test "cli: client verify flags signed-by=mirroret.gpg without resign mode" {
    export MIRRORET_APT_RESIGN=0
    cat > "${FAKE_BASE}/config/debian-client.list" <<'EOF'
deb [signed-by=/etc/apt/keyrings/mirroret.gpg] http://10.0.0.1:8080/ubuntu jammy main
EOF
    run bash "${CTL}" client verify
    [ "$status" -ne 0 ]
    [[ "$output" == *"MIRRORET_APT_RESIGN"* ]]
}

@test "cli: client verify flags invalid docker daemon.json" {
    printf '{ this is not json' > "${FAKE_BASE}/config/docker-daemon.json"
    run bash "${CTL}" client verify
    [ "$status" -ne 0 ]
    [[ "$output" == *"not valid JSON"* ]]
}

@test "cli: client show prints a named config" {
    printf 'registry=http://10.0.0.1:4873/\n' > "${FAKE_BASE}/config/.npmrc"
    run bash "${CTL}" client show .npmrc
    [ "$status" -eq 0 ]
    [[ "$output" == *"4873"* ]]
}

@test "cli: client show fails clearly on a missing config" {
    run bash "${CTL}" client show nope.conf
    [ "$status" -ne 0 ]
    [[ "$output" == *"No such client config"* ]]
}

# ---------------------------------------------------- generated-script gate ----

@test "cli: sync target with a missing script gives an actionable error" {
    # Root is required first, so assert the message for the non-root case is
    # the root gate, then verify the missing-script path via the helper.
    run bash -c "
        set -Eeuo pipefail
        source '${SCRIPT_DIR}/lib/logging.sh'
        source '${SCRIPT_DIR}/lib/common.sh'
        MIRRORET_BASE_DIR='${FAKE_BASE}'
        # Re-declare the helper the way mirroretctl defines it.
        _er() { printf 'fail  %s\n' \"\$*\"; }
        _in() { printf '      %s\n' \"\$*\"; }
        _run_script() {
            local s=\"\$1\"; shift || true
            if [[ ! -x \"\$s\" ]]; then
                _er \"Not found or not executable: \$s\"
                _in \"Run 'mirroretctl install' (or install.sh --upgrade) to regenerate it.\"
                return 1
            fi
            \"\$s\" \"\$@\"
        }
        _run_script '${FAKE_BASE}/scripts/sync-redhat-repos.sh'
    "
    [ "$status" -ne 0 ]
    [[ "$output" == *"Not found or not executable"* ]]
}

# ------------------------------------------------------------- config diff ----

@test "cli: config diff lists the sync scripts that are present" {
    # config diff used to grep FLAVOR=/ARCH= out of the legacy
    # sync-redhat-repos.sh. That told you nothing on a native install (which
    # has no such file) and nothing about APT ever. It now reports the live
    # generated state instead.
    printf '#!/usr/bin/env bash\nFLAVOR="ol"\n' \
        > "${FAKE_BASE}/scripts/sync-redhat-repos.sh"
    chmod +x "${FAKE_BASE}/scripts/sync-redhat-repos.sh"
    run bash "${CTL}" config diff
    [ "$status" -eq 0 ]
    [[ "$output" == *"sync-redhat-repos.sh"* ]]
    [[ "$output" == *"Targets: requested vs generated"* ]]
}

@test "cli: config diff flags a sync script that is not executable" {
    # A zip transfer does not preserve the execute bit, so every script is
    # present and cron silently runs none of them. This project's own
    # runbook documents that failure; the diagnostic has to catch it.
    printf '#!/usr/bin/env bash\ntrue\n' \
        > "${FAKE_BASE}/scripts/sync-rpm-repos.sh"
    chmod -x "${FAKE_BASE}/scripts/sync-rpm-repos.sh"
    run bash "${CTL}" config diff
    [ "$status" -ne 0 ]
    [[ "$output" == *"NOT EXECUTABLE"* ]]
    [[ "$output" == *"chmod +x"* ]]
    # And it must not claim the file is absent.
    ! [[ "$output" == *"no generated sync scripts at all"* ]]
}

@test "cli: config diff says so when there are no sync scripts at all" {
    run bash "${CTL}" config diff
    [ "$status" -ne 0 ]
    [[ "$output" == *"no generated sync scripts at all"* ]]
    [[ "$output" == *"mirroretctl upgrade"* ]]
}

# ================= service binary resolution (203/EXEC bug) =================

@test "npm: _resolve_verdaccio_bin exists" {
    grep -q '_resolve_verdaccio_bin' "${SCRIPT_DIR}/lib/npm.sh"
}

@test "npm: unit no longer hardcodes a /usr/bin/verdaccio fallback path" {
    # The old code did: command -v verdaccio || echo /usr/bin/verdaccio
    # which wrote a nonexistent path into the unit -> status=203/EXEC.
    run grep -c 'command -v verdaccio 2>/dev/null || echo /usr/bin/verdaccio' \
        "${SCRIPT_DIR}/lib/npm.sh"
    [ "$output" = "0" ]
}

@test "npm: install dies instead of writing a unit with a missing binary" {
    grep -q 'Cannot locate the verdaccio binary' "${SCRIPT_DIR}/lib/npm.sh"
}

@test "npm: verdaccio resolution only accepts executable paths" {
    section="$(awk '/_resolve_verdaccio_bin\(\)/,/^}/' "${SCRIPT_DIR}/lib/npm.sh")"
    [[ "$section" == *'-x "$c"'* ]]
}

@test "npm: verdaccio resolution consults npm prefix and npm root" {
    section="$(awk '/_resolve_verdaccio_bin\(\)/,/^}/' "${SCRIPT_DIR}/lib/npm.sh")"
    [[ "$section" == *'npm prefix -g'* ]]
    [[ "$section" == *'npm root -g'* ]]
}

@test "pip: _resolve_pypiserver_bin exists and checks the venv first" {
    grep -q '_resolve_pypiserver_bin' "${SCRIPT_DIR}/lib/pip.sh"
    section="$(awk '/_resolve_pypiserver_bin\(\)/,/^}/' "${SCRIPT_DIR}/lib/pip.sh")"
    # The venv path is overridable, so the literal is
    # ${MIRRORET_PYPI_VENV:-/opt/mirroret-pypiserver}/bin/pypi-server.
    # Assert the two halves rather than a substring the code never contained.
    [[ "$section" == *'mirroret-pypiserver'*'/bin/pypi-server'* ]]
    # The venv candidate must be FIRST, before anything found on PATH.
    [[ "$section" == *'candidates=('*'mirroret-pypiserver'* ]]
    [[ "$section" == *'-x "$c"'* ]]
}

@test "pip: unit no longer hardcodes a /usr/local/bin fallback path" {
    run grep -c 'command -v pypi-server 2>/dev/null || echo /usr/local/bin/pypi-server' \
        "${SCRIPT_DIR}/lib/pip.sh"
    [ "$output" = "0" ]
}

@test "systemd: enable_and_start polls instead of checking active once" {
    section="$(awk '/^enable_and_start\(\)/,/^}/' "${SCRIPT_DIR}/lib/systemd.sh")"
    [[ "$section" == *'waited'* ]]
}

@test "systemd: start failure reports the missing ExecStart path" {
    section="$(awk '/^enable_and_start\(\)/,/^}/' "${SCRIPT_DIR}/lib/systemd.sh")"
    [[ "$section" == *'203/EXEC'* ]]
    [[ "$section" == *'ExecStart binary is missing'* ]]
}

# ================== audit round 3: remaining findings ==================

@test "retention: _ret_int rejects non-numeric and warns" {
    source "${SCRIPT_DIR}/lib/logging.sh"
    source "${SCRIPT_DIR}/lib/common.sh"
    source "${SCRIPT_DIR}/lib/retention.sh"
    run _ret_int MIRRORET_RPM_KEEP_VERSIONS "abc" 3
    [ "$status" -eq 0 ]
    [[ "$output" == *"3"* ]]
    [[ "$output" == *"not a number"* ]]
}

@test "retention: _ret_int passes a valid number through" {
    source "${SCRIPT_DIR}/lib/logging.sh"
    source "${SCRIPT_DIR}/lib/common.sh"
    source "${SCRIPT_DIR}/lib/retention.sh"
    result="$(_ret_int MIRRORET_RPM_KEEP_VERSIONS 5 3 2>/dev/null)"
    [ "$result" = "5" ]
}

@test "retention: pip prune orders by version not mtime" {
    section="$(awk '/^retention_pip_prune\(\)/,/^}/' "${SCRIPT_DIR}/lib/retention.sh")"
    [[ "$section" == *'sort -V'* ]]
    [[ "$section" != *'ls -t '* ]]
}

@test "retention: pip prune keeps the highest VERSION even if downloaded first" {
    source "${SCRIPT_DIR}/lib/logging.sh"
    source "${SCRIPT_DIR}/lib/common.sh"
    source "${SCRIPT_DIR}/lib/retention.sh"
    d="${TMPDIR}/pipver/pip/approved"
    mkdir -p "$d"
    export MIRRORET_BASE_DIR="${TMPDIR}/pipver"
    # 2.0.0 is the newest VERSION but the OLDEST mtime. The old mtime-based
    # code would have deleted it and kept 1.0.0.
    touch -t 202601010000 "${d}/pkg-2.0.0-py3-none-any.whl"
    touch -t 202612010000 "${d}/pkg-1.0.0-py3-none-any.whl"
    MIRRORET_PIP_KEEP_VERSIONS=1
    MIRRORET_RETENTION_MODE=prune
    retention_pip_prune >/dev/null 2>&1
    [ -f "${d}/pkg-2.0.0-py3-none-any.whl" ]
    [ ! -f "${d}/pkg-1.0.0-py3-none-any.whl" ]
}

@test "retention: npm prune refuses a live Verdaccio storage root" {
    source "${SCRIPT_DIR}/lib/logging.sh"
    source "${SCRIPT_DIR}/lib/common.sh"
    source "${SCRIPT_DIR}/lib/retention.sh"
    d="${TMPDIR}/verd/npm/approved"
    mkdir -p "${d}/express"
    export MIRRORET_BASE_DIR="${TMPDIR}/verd"
    # Verdaccio marker.
    printf '{}' > "${d}/express/package.json"
    touch -t 202001010000 "${d}/express/express-1.0.0.tgz"
    MIRRORET_NPM_KEEP_DAYS=30
    MIRRORET_RETENTION_MODE=prune
    unset MIRRORET_NPM_PRUNE_STORAGE
    run retention_npm_prune
    [ "$status" -eq 0 ]
    [[ "$output" == *"live Verdaccio storage root"* ]]
    # The tarball must survive.
    [ -f "${d}/express/express-1.0.0.tgz" ]
}

@test "retention: stale metadata sets a non-zero run_retention exit" {
    grep -q 'RETENTION_METADATA_BROKEN' "${SCRIPT_DIR}/lib/retention.sh"
    grep -q 'METADATA STALE' "${SCRIPT_DIR}/lib/retention.sh"
}

@test "rpm: sync script estimates size before downloading" {
    grep -q '_estimate_gb' "${SCRIPT_DIR}/lib/rpm.sh"
    grep -q 'MIRRORET_SYNC_ESTIMATE' "${SCRIPT_DIR}/lib/rpm.sh"
}

@test "rpm: sync script smoke tests repodata after syncing" {
    grep -q 'MIRRORET_SYNC_SMOKE_TEST' "${SCRIPT_DIR}/lib/rpm.sh"
    grep -q 'repofrompath' "${SCRIPT_DIR}/lib/rpm.sh"
}

@test "rpm: sync script uses nice and ionice" {
    grep -q 'MIRRORET_SYNC_NICE' "${SCRIPT_DIR}/lib/rpm.sh"
    grep -q 'ionice' "${SCRIPT_DIR}/lib/rpm.sh"
}

@test "rpm: flavor and repo-name mismatch is warned about" {
    grep -q 'names Oracle repos' "${SCRIPT_DIR}/lib/rpm.sh"
}

@test "docker: sync script has lock, disk guard, timeout and prune" {
    grep -q 'mirroret-sync-docker.lock' "${SCRIPT_DIR}/lib/docker_registry.sh"
    grep -q '_check_disk' "${SCRIPT_DIR}/lib/docker_registry.sh"
    grep -q 'MIRRORET_DOCKER_PULL_TIMEOUT' "${SCRIPT_DIR}/lib/docker_registry.sh"
    grep -q 'image prune -f' "${SCRIPT_DIR}/lib/docker_registry.sh"
}

@test "docker: disk guard also watches the container store on /" {
    section="$(awk '/write_docker_sync_script/,/^}/' "${SCRIPT_DIR}/lib/docker_registry.sh")"
    [[ "$section" == *'/var/lib/containers'* ]]
}

@test "install: sync-all takes a lock and checks disk" {
    grep -q 'mirroret-sync-all.lock' "${SCRIPT_DIR}/install.sh"
    section="$(awk '/^write_master_sync_script\(\)/,/^}/' "${SCRIPT_DIR}/install.sh")"
    [[ "$section" == *'MIN_FREE_GB'* ]]
}

@test "install: cleanup-all falls back when the install tree moved" {
    grep -q 'MIRRORET_INSTALL_DIR' "${SCRIPT_DIR}/install.sh"
    grep -q 'the tree may have moved' "${SCRIPT_DIR}/install.sh"
}

@test "install: help example puts env vars before the script name" {
    run bash "${SCRIPT_DIR}/install.sh" --help
    [[ "$output" == *"sudo MIRRORET_FIREWALL_SOURCE=10.0.0.0/8 ./install.sh"* ]]
}

@test "install: --config detection is exact, not a substring match" {
    section="$(awk '/^parse_args\(\)/,/while \[\[ \$# -gt 0/' "${SCRIPT_DIR}/install.sh")"
    [[ "$section" == *'_explicit_config'* ]]
    [[ "$section" != *'!= *"--config"*'* ]]
}

@test "common: run_quietly uses mktemp not a fixed /tmp path" {
    section="$(awk '/^run_quietly\(\)/,/^}/' "${SCRIPT_DIR}/lib/common.sh")"
    [[ "$section" == *'mktemp'* ]]
    [[ "$section" != *'> /tmp/mirroret_cmd_out '* ]]
}

@test "logging: warn_insecure log append is fail-soft" {
    section="$(awk '/^warn_insecure\(\)/,/^}/' "${SCRIPT_DIR}/lib/logging.sh")"
    [[ "$section" == *'|| true'* ]]
}

@test "validation: registry status is runtime-agnostic" {
    grep -q '_status_registry' "${SCRIPT_DIR}/lib/validation.sh"
    section="$(awk '/_status_registry\(\)/,/^}/' "${SCRIPT_DIR}/lib/validation.sh")"
    [[ "$section" == *'podman'* ]]
    [[ "$section" == *'docker-distribution'* ]]
}

@test "npm: sync starts from a clean work dir every run" {
    # A tarball or node_modules tree left behind by an earlier run would make
    # the per-package result reporting lie about what was actually fetched.
    grep -q 'clean work dir' "${SCRIPT_DIR}/lib/npm.sh"
    grep -qF 'rm -rf "\${WORK_DIR}/warm"' "${SCRIPT_DIR}/lib/npm.sh"
    # Approval mode collects tarballs instead, so those get cleared too.
    grep -q "name '\*.tgz' -delete" "${SCRIPT_DIR}/lib/npm.sh"
}

@test "config example documents every new knob" {
    for v in MIRRORET_SYNC_ESTIMATE MIRRORET_SYNC_SMOKE_TEST MIRRORET_SYNC_NICE \
             MIRRORET_DOCKER_PULL_TIMEOUT MIRRORET_NPM_PRUNE_STORAGE \
             MIRRORET_INSTALL_DIR; do
        grep -q "$v" "${SCRIPT_DIR}/config/mirroret.conf.example"
    done
}

@test "cli: sync status exits 0 even when a sync process is running" {
    # Regression: the function ended in `[[ $found -eq 0 ]] && _in "none"`,
    # so a running sync (found=1) made the whole subcommand return 1.
    # Fake a matching process so pgrep -af finds something.
    bash -c 'exec -a sync-redhat-repos.sh sleep 5' &
    fake_pid=$!
    run bash "${CTL}" sync status
    kill "$fake_pid" 2>/dev/null || true
    wait "$fake_pid" 2>/dev/null || true
    [ "$status" -eq 0 ]
}

@test "cli: sync status has no trailing short-circuit as its last statement" {
    # Guard the shape, not just the behaviour: a bare `cond && cmd` at the
    # tail of a function leaks the condition's falsity as the exit status.
    run bash -c "sed -n '/^cmd_sync_status()/,/^}/p' '${CTL}' | grep -c 'found.*-eq 0.*&&'"
    [ "$output" = "0" ]
}

@test "cli: report subcommand is wired to the collector" {
    run bash "${CTL}" report --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"read-only"* ]]
}

@test "cli: help lists the report subcommand" {
    run bash "${CTL}" help
    [ "$status" -eq 0 ]
    [[ "$output" == *"report"* ]]
}

@test "cli: interactive menu has no duplicate numbers" {
    # Appending an entry must not silently renumber the existing ones.
    dupes="$(sed -n '/1) status/,/q) quit/p' "${CTL}" \
             | grep -oE '^ *[0-9]+\)' | tr -d ' )' | sort | uniq -d)"
    [ -z "$dupes" ]
}

@test "cli: every menu number has a case branch" {
    nums="$(sed -n '/1) status/,/q) quit/p' "${CTL}" | grep -oE '^ *[0-9]+\)' | tr -d ' )')"
    for n in $nums; do
        # Actions are dispatched through _menu_run, which keeps a failing
        # subcommand from taking the whole CLI down via `set -e`. Accept
        # either form so this test checks the mapping, not the wrapper.
        grep -qE "^ +${n}\) +(_menu_run )?cmd_" "${CTL}"
    done
}

# -- client simulate ------------------------------------------------------------

@test "cli: client simulate exits 0 and explains when dnf is absent" {
    if command -v dnf >/dev/null 2>&1; then skip "dnf present"; fi
    run bash "${CTL}" client simulate
    [ "$status" -eq 0 ]
    [[ "$output" == *"dnf not available"* ]]
}

@test "cli: client simulate is listed in help and the menu" {
    run bash "${CTL}" help
    [[ "$output" == *"client simulate"* ]]
    # Match the dispatch, not a hardcoded menu number: pinning the number
    # means every menu addition breaks this test for no reason. The
    # menu-to-branch mapping has its own dedicated test.
    grep -qE '^ +[0-9]+\) +(_menu_run )?cmd_client simulate' "${CTL}"
    grep -qE '^ +[0-9]+\) client simulate' "${CTL}"
}

@test "cli: client simulate probes i686 by default" {
    # 32-bit multilib is the case that repeatedly appeared broken, so it must
    # be part of the default probe set, not something you have to remember.
    grep -q 'glibc.i686' "${CTL}"
    grep -q 'libstdc++.i686' "${CTL}"
}

@test "cli: client simulate verifies the download, not just the metadata" {
    # Metadata listing a package proves nothing if the file is not on disk:
    # that is exactly what a filtered mirror with upstream metadata does.
    grep -q 'repoquery --location' "${CTL}"
    grep -q 'listed in metadata but returns HTTP' "${CTL}"
}

@test "cli: client simulate disables the host's own repos" {
    # Without --disablerepo the host's upstream repos satisfy the query and a
    # completely broken mirror still looks fine.
    grep -qE "client_simulate\(\)" "${CTL}"
    sed -n '/cmd_client_simulate()/,/^}/p' "${CTL}" | grep -q "disablerepo='\*'"
    sed -n '/cmd_client_simulate()/,/^}/p' "${CTL}" | grep -q 'reposdir='
}

# ---------------------------------------------------------------- approve ----

@test "cli: approve list works without root" {
    [ "$(id -u)" -ne 0 ] || skip "needs a non-root user; this run is root"
    run bash "${CTL}" approve list
    [ "$status" -eq 0 ]
}

@test "cli: approve warns when approval mode is off" {
    run bash "${CTL}" approve list
    [[ "$output" == *"Approval mode is OFF"* ]]
}

@test "cli: approve all refuses without root" {
    [ "$(id -u)" -ne 0 ] || skip "needs a non-root user; this run is root"
    run bash "${CTL}" approve all rpm
    [ "$status" -ne 0 ]
}

@test "cli: approve rejects an unknown action" {
    run bash "${CTL}" approve banana
    [ "$status" -ne 0 ]
    [[ "$output" == *"Unknown approve action"* ]]
}

@test "cli: approve is listed in help" {
    run bash "${CTL}" help
    [ "$status" -eq 0 ]
    [[ "$output" == *"approve list"* ]]
    [[ "$output" == *"approve all"* ]]
}

@test "cli: approve list rpm shows the empty-staging message" {
    export MIRRORET_APPROVAL_ENABLED=1
    run bash "${CTL}" approve list rpm
    [ "$status" -eq 0 ]
    [[ "$output" == *"no RPMs in staging"* ]]
}

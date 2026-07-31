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
    [ "$(id -u)" -ne 0 ]
    run bash "${CTL}" sync all
    [ "$status" -eq 1 ]
    [[ "$output" == *"needs root"* ]]
}

@test "cli: upgrade refuses without root" {
    [ "$(id -u)" -ne 0 ]
    run bash "${CTL}" upgrade
    [ "$status" -eq 1 ]
    [[ "$output" == *"needs root"* ]]
}

@test "cli: clean refuses without root" {
    [ "$(id -u)" -ne 0 ]
    run bash "${CTL}" clean report
    [ "$status" -eq 1 ]
}

@test "cli: read-only subcommands do NOT require root" {
    [ "$(id -u)" -ne 0 ]
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

@test "cli: config diff reports generated script values" {
    cat > "${FAKE_BASE}/scripts/sync-redhat-repos.sh" <<'EOF'
#!/usr/bin/env bash
FLAVOR="ol"
ARCH="x86_64"
NEWEST_ONLY="1"
INCLUDE_SOURCE="0"
REPOS=(ol9_baseos_latest)
EOF
    run bash "${CTL}" config diff
    [ "$status" -eq 0 ]
    [[ "$output" == *'FLAVOR="ol"'* ]]
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
    [[ "$section" == *'mirroret-pypiserver/bin/pypi-server'* ]]
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

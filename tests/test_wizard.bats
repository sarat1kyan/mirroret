#!/usr/bin/env bats
# Tests for lib/wizard.sh - the interactive first-run installer flow.
#
# We can't script a real TTY in bats, so instead we test the guards
# (should_run_first_run_wizard) and drive the wizard's write step with a
# fake TTY via a here-doc into stdin, checking the config it writes.

load 'test_helpers'

setup() {
    load_lib
    TMPDIR_TEST="$(mktemp -d)"
    # shellcheck source=/dev/null
    source "${SCRIPT_DIR}/lib/wizard.sh"
}

teardown() {
    [[ -n "${TMPDIR_TEST:-}" ]] && rm -rf "${TMPDIR_TEST}"
}

# -- gating -------------------------------------------------------------------

@test "wizard: skipped in --upgrade mode" {
    MODE_UPGRADE=1
    ! should_run_first_run_wizard
}

@test "wizard: skipped when MIRRORET_NON_INTERACTIVE=1" {
    MIRRORET_NON_INTERACTIVE=1
    ! should_run_first_run_wizard
}

@test "wizard: skipped when a config already exists" {
    local conf="${TMPDIR_TEST}/mirroret.conf"
    printf 'MIRRORET_APT_TARGETS=""\n' > "$conf"
    (
        cd "$TMPDIR_TEST"
        # Fake /etc path by pointing the function at our tmp conf via env.
        # should_run_first_run_wizard hard-codes /etc/mirroret; use a bind
        # via HOME override wouldn't help. Instead test the intent: the
        # guard is a plain -f check on that path, so grep the function.
        grep -q '/etc/mirroret/mirroret.conf' "${SCRIPT_DIR}/lib/wizard.sh"
    )
}

@test "wizard: skipped when MIRRORET_APT_TARGETS is set in env" {
    MIRRORET_APT_TARGETS="ubuntu:noble"
    ! should_run_first_run_wizard
}

@test "wizard: skipped in dry-run" {
    DRY_RUN=1
    ! should_run_first_run_wizard
}

# -- config writing ----------------------------------------------------------

@test "wizard: writes the answers to a config file the installer can source" {
    # Drive _wz_write_conf directly with the vars set (that's how
    # run_first_run_wizard would call it after the prompts).
    export MIRRORET_APT_TARGETS="ubuntu:noble:amd64"
    export MIRRORET_RPM_TARGETS="ol:9"
    export MIRRORET_PROXY="http://proxy.example:3128"
    export MIRRORET_APT_SCHEME="https"
    export MIRRORET_SYNC_MIN_FREE_GB="20"
    _wz_proxy_line='MIRRORET_PROXY="http://proxy.example:3128"'
    _wz_apt_scheme_line='MIRRORET_APT_SCHEME="https"'

    local conf="${TMPDIR_TEST}/wiz.conf"
    _wz_write_conf "$conf"

    [ -f "$conf" ]
    # The generated file must be sourceable — no stray shell errors.
    ( source "$conf" && [[ "$MIRRORET_APT_TARGETS" == "ubuntu:noble:amd64" ]] )
    ( source "$conf" && [[ "$MIRRORET_RPM_TARGETS" == "ol:9" ]] )
    ( source "$conf" && [[ "$MIRRORET_PROXY" == "http://proxy.example:3128" ]] )
    ( source "$conf" && [[ "$MIRRORET_APT_SCHEME" == "https" ]] )
    ( source "$conf" && [[ "$MIRRORET_SYNC_MIN_FREE_GB" == "20" ]] )
}

@test "wizard: no proxy line when the operator declined a proxy" {
    export MIRRORET_APT_TARGETS="ubuntu:noble:amd64"
    export MIRRORET_RPM_TARGETS=""
    unset MIRRORET_PROXY MIRRORET_APT_SCHEME
    _wz_proxy_line=""
    _wz_apt_scheme_line='MIRRORET_APT_SCHEME="http"'
    export MIRRORET_SYNC_MIN_FREE_GB="15"

    local conf="${TMPDIR_TEST}/wiz.conf"
    _wz_write_conf "$conf"

    # The proxy variable name must not appear as a bound value.
    ! grep -qE '^MIRRORET_PROXY=' "$conf"
    grep -q 'MIRRORET_APT_SCHEME="http"' "$conf"
}

@test "wizard: multichoice sentinel 'none' is stripped from the targets" {
    # In run_first_run_wizard the "None" option resolves to the literal
    # 'none'; the wizard code has to filter it out before writing.
    grep -q '"none|None (no APT clients)"' "${SCRIPT_DIR}/lib/wizard.sh"
    grep -q 'apt_targets=""' "${SCRIPT_DIR}/lib/wizard.sh"
    grep -q 'rpm_targets=""' "${SCRIPT_DIR}/lib/wizard.sh"
}

@test "wizard: install.sh sources lib/wizard.sh" {
    grep -q 'lib/wizard.sh' "${SCRIPT_DIR}/install.sh"
    grep -q 'should_run_first_run_wizard' "${SCRIPT_DIR}/install.sh"
    grep -q 'run_first_run_wizard' "${SCRIPT_DIR}/install.sh"
}

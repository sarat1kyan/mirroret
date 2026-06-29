#!/usr/bin/env bats
# Tests for lib/uninstall.sh and the uninstall.sh entry point.
#
# All tests run as a non-root user inside a tmp tree — they exercise the
# planner, the helper functions, and idempotency. They never actually
# touch system services, /etc, or /srv.

load 'test_helpers'

setup() {
    load_distro_lib
    TMPDIR="$(mktemp -d)"
    MIRRORET_BASE_DIR="${TMPDIR}/mirroret"
    MIRRORET_BACKUP_BASE="${TMPDIR}/backups"
    MIRRORET_TLS_DIR="${TMPDIR}/etc/mirroret/tls"
    MIRRORET_GPG_HOMEDIR="${TMPDIR}/etc/mirroret/gnupg"
    export MIRRORET_BASE_DIR MIRRORET_BACKUP_BASE MIRRORET_TLS_DIR MIRRORET_GPG_HOMEDIR
    DRY_RUN=1
    MIRRORET_NON_INTERACTIVE=1
    export DRY_RUN MIRRORET_NON_INTERACTIVE
    source "${SCRIPT_DIR}/lib/uninstall.sh"
}

teardown() {
    cleanup_mock
    rm -rf "$TMPDIR"
}

# ── plan + flag handling ──────────────────────────────────────────────────────

@test "uninstall: --list with no targets defaults to all" {
    # Default behaviour: no --apt / --docker / etc. → target everything.
    run bash -c "
        source '${SCRIPT_DIR}/lib/logging.sh'
        source '${SCRIPT_DIR}/lib/common.sh'
        source '${SCRIPT_DIR}/lib/distro.sh'
        source '${SCRIPT_DIR}/lib/uninstall.sh'
        uninstall_main --list
    "
    [ "$status" -eq 0 ]
    # All six steps should appear in the plan.
    [[ "$output" == *"remove pypiserver"* ]]
    [[ "$output" == *"remove Verdaccio"* ]]
    [[ "$output" == *"remove Docker registry"* ]]
    [[ "$output" == *"remove APT mirror"* ]]
    [[ "$output" == *"remove RPM mirror"* ]]
    [[ "$output" == *"remove nginx vhost"* ]]
}

@test "uninstall: --list --docker plans ONLY docker steps" {
    run bash -c "
        source '${SCRIPT_DIR}/lib/logging.sh'
        source '${SCRIPT_DIR}/lib/common.sh'
        source '${SCRIPT_DIR}/lib/distro.sh'
        source '${SCRIPT_DIR}/lib/uninstall.sh'
        uninstall_main --list --docker
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"remove Docker registry"* ]]
    [[ "$output" != *"remove pypiserver"* ]]
    [[ "$output" != *"remove Verdaccio"* ]]
    [[ "$output" != *"remove APT mirror"* ]]
    [[ "$output" != *"remove RPM mirror"* ]]
    [[ "$output" != *"remove nginx vhost"* ]]
}

@test "uninstall: --list --pip --npm plans both, nothing else" {
    run bash -c "
        source '${SCRIPT_DIR}/lib/logging.sh'
        source '${SCRIPT_DIR}/lib/common.sh'
        source '${SCRIPT_DIR}/lib/distro.sh'
        source '${SCRIPT_DIR}/lib/uninstall.sh'
        uninstall_main --list --pip --npm
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"remove pypiserver"* ]]
    [[ "$output" == *"remove Verdaccio"* ]]
    [[ "$output" != *"remove Docker registry"* ]]
    [[ "$output" != *"remove APT mirror"* ]]
    [[ "$output" != *"remove RPM mirror"* ]]
    [[ "$output" != *"remove nginx vhost"* ]]
}

@test "uninstall: --list does not require root" {
    [ "$(id -u)" -ne 0 ]
    run bash "${SCRIPT_DIR}/uninstall.sh" --list --docker
    [ "$status" -eq 0 ]
    [[ "$output" == *"remove Docker registry"* ]]
}

@test "uninstall: --dry-run does not require root" {
    [ "$(id -u)" -ne 0 ]
    run bash "${SCRIPT_DIR}/uninstall.sh" --dry-run --pip
    [ "$status" -eq 0 ]
    [[ "$output" == *"remove pypiserver"* ]]
}

@test "uninstall: --help exits 0 and shows usage" {
    run bash "${SCRIPT_DIR}/uninstall.sh" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"--purge"* ]]
    [[ "$output" == *"--docker"* ]]
    [[ "$output" == *"--keep-users"* ]]
}

@test "uninstall: unknown flag dies with clear message" {
    run bash -c "
        source '${SCRIPT_DIR}/lib/logging.sh'
        source '${SCRIPT_DIR}/lib/common.sh'
        source '${SCRIPT_DIR}/lib/distro.sh'
        source '${SCRIPT_DIR}/lib/uninstall.sh'
        uninstall_main --list --not-a-real-flag
    "
    [ "$status" -ne 0 ]
    [[ "$output" == *"Unknown uninstall flag"* ]]
}

# ── purge gating ──────────────────────────────────────────────────────────────

@test "uninstall: --list without --purge does NOT plan data deletion" {
    run bash -c "
        source '${SCRIPT_DIR}/lib/logging.sh'
        source '${SCRIPT_DIR}/lib/common.sh'
        source '${SCRIPT_DIR}/lib/distro.sh'
        source '${SCRIPT_DIR}/lib/uninstall.sh'
        uninstall_main --list --all
    "
    [ "$status" -eq 0 ]
    [[ "$output" != *"PURGE mirror data"* ]]
    [[ "$output" != *"PURGE GPG"* ]]
}

@test "uninstall: --list --purge plans data deletion explicitly" {
    run bash -c "
        source '${SCRIPT_DIR}/lib/logging.sh'
        source '${SCRIPT_DIR}/lib/common.sh'
        source '${SCRIPT_DIR}/lib/distro.sh'
        source '${SCRIPT_DIR}/lib/uninstall.sh'
        uninstall_main --list --all --purge
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"PURGE mirror data"* ]]
    [[ "$output" == *"PURGE GPG"* ]]
}

@test "uninstall: dry-run never touches an existing data dir" {
    mkdir -p "${MIRRORET_BASE_DIR}/redhat/mirror"
    touch    "${MIRRORET_BASE_DIR}/canary"
    run bash -c "
        source '${SCRIPT_DIR}/lib/logging.sh'
        source '${SCRIPT_DIR}/lib/common.sh'
        source '${SCRIPT_DIR}/lib/distro.sh'
        source '${SCRIPT_DIR}/lib/uninstall.sh'
        MIRRORET_BASE_DIR='${MIRRORET_BASE_DIR}'
        uninstall_main --dry-run --all --purge --yes
    "
    [ "$status" -eq 0 ]
    [ -f "${MIRRORET_BASE_DIR}/canary" ]
}

# ── idempotent removers (run on tmp filesystem) ──────────────────────────────

@test "uninstall: uninst_remove_file is a no-op for missing files" {
    DRY_RUN=0
    run uninst_remove_file "${TMPDIR}/does-not-exist"
    [ "$status" -eq 0 ]
}

@test "uninstall: uninst_remove_dir is a no-op for missing directories" {
    DRY_RUN=0
    run uninst_remove_dir "${TMPDIR}/no-such-dir"
    [ "$status" -eq 0 ]
}

@test "uninstall: uninst_remove_file actually deletes when present (live mode)" {
    DRY_RUN=0
    local f="${TMPDIR}/will-be-removed"
    touch "$f"
    [ -f "$f" ]
    uninst_remove_file "$f"
    [ ! -f "$f" ]
}

@test "uninstall: uninst_remove_dir actually deletes when present (live mode)" {
    DRY_RUN=0
    local d="${TMPDIR}/will-be-removed-dir"
    mkdir -p "${d}/sub"
    touch "${d}/sub/x"
    [ -d "$d" ]
    uninst_remove_dir "$d"
    [ ! -d "$d" ]
}

# ── cron managed-block awk strip ─────────────────────────────────────────────

@test "uninstall: cron strip removes only the managed block" {
    local existing="0 1 * * * /usr/local/bin/keep-me.sh
# >>> mirroret managed (do not edit between markers) >>>
0 2 * * * /srv/mirroret/scripts/sync-all.sh
# <<< mirroret managed <<<
*/15 * * * * /opt/foo/check.sh"

    BEGIN="# >>> mirroret managed (do not edit between markers) >>>"
    END="# <<< mirroret managed <<<"

    stripped="$(printf '%s\n' "$existing" | awk -v b="$BEGIN" -v e="$END" '
        $0 == b { skip = 1; next }
        $0 == e { skip = 0; next }
        !skip { print }
    ')"

    echo "$stripped" | grep -qF "/usr/local/bin/keep-me.sh"
    echo "$stripped" | grep -qF "/opt/foo/check.sh"
    echo "$stripped" | grep -qvF "/srv/mirroret/scripts/sync-all.sh"
}

# ── safety guards: do not delete users when --keep-users ─────────────────────

@test "uninstall: --keep-users prevents user removal" {
    UNINST_KEEP_USERS=1
    DRY_RUN=0
    # The function should short-circuit with "skip" before touching userdel.
    run uninst_remove_user "definitely-not-a-real-user-zzz"
    [ "$status" -eq 0 ]
}

# ── install.sh --uninstall integration ────────────────────────────────────────

@test "install.sh --uninstall --list defaults to all components" {
    run bash "${SCRIPT_DIR}/install.sh" --uninstall --list
    [ "$status" -eq 0 ]
    [[ "$output" == *"remove pypiserver"* ]]
    [[ "$output" == *"remove Docker registry"* ]]
}

@test "install.sh --uninstall --list --docker is selective" {
    run bash "${SCRIPT_DIR}/install.sh" --uninstall --list --docker
    [ "$status" -eq 0 ]
    [[ "$output" == *"remove Docker registry"* ]]
    [[ "$output" != *"remove pypiserver"* ]]
    [[ "$output" != *"remove Verdaccio"* ]]
}

# ── detection of components present on host ──────────────────────────────────

@test "uninstall: components_present reports nothing on a clean tmp tree" {
    run bash -c "
        source '${SCRIPT_DIR}/lib/logging.sh'
        source '${SCRIPT_DIR}/lib/common.sh'
        source '${SCRIPT_DIR}/lib/distro.sh'
        source '${SCRIPT_DIR}/lib/uninstall.sh'
        MIRRORET_BASE_DIR='${MIRRORET_BASE_DIR}'
        uninstall_components_present
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"not found"* ]]
}

# ── _has_unit returns false when systemctl absent ────────────────────────────

@test "uninstall: _has_unit returns false when systemctl absent (PATH stripped)" {
    PATH_OLD="$PATH"
    stub="$(mktemp -d)"
    PATH="${stub}"
    ! _has_unit pypiserver
    PATH="${PATH_OLD}"
    rm -rf "$stub"
}

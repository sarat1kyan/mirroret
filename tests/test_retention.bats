#!/usr/bin/env bats
# Tests for lib/retention.sh and the MIRRORET-MANAGED sentinel.

load 'test_helpers'

setup() {
    load_distro_lib
    TMPDIR="$(mktemp -d)"
    MIRRORET_BASE_DIR="${TMPDIR}/mirroret"
    export MIRRORET_BASE_DIR
    DRY_RUN=1
    MIRRORET_NON_INTERACTIVE=1
    export DRY_RUN MIRRORET_NON_INTERACTIVE
    source "${SCRIPT_DIR}/lib/retention.sh"
    mkdir -p "${MIRRORET_BASE_DIR}"
}

teardown() {
    cleanup_mock
    rm -rf "${TMPDIR}"
}

# -- Default state ------------------------------------------------------------

@test "retention: MIRRORET_RETENTION_ENABLE defaults to 0" {
    [[ "${MIRRORET_RETENTION_ENABLE}" == "0" ]]
}

@test "retention: MIRRORET_RETENTION_MODE defaults to report" {
    [[ "${MIRRORET_RETENTION_MODE}" == "report" ]]
}

@test "retention: MIRRORET_RPM_KEEP_VERSIONS defaults to 3" {
    [[ "${MIRRORET_RPM_KEEP_VERSIONS}" == "3" ]]
}

@test "retention: MIRRORET_NPM_KEEP_DAYS defaults to 180" {
    [[ "${MIRRORET_NPM_KEEP_DAYS}" == "180" ]]
}

@test "retention: MIRRORET_DOCKER_GC defaults to 0 (opt-in)" {
    [[ "${MIRRORET_DOCKER_GC}" == "0" ]]
}

# -- Mode gating --------------------------------------------------------------

@test "retention: run_retention is a no-op when disabled" {
    MIRRORET_RETENTION_ENABLE=0
    run run_retention
    [ "$status" -eq 0 ]
    [[ "$output" == *"Retention disabled"* ]]
}

@test "retention: _ret_mode collapses unknown to report" {
    MIRRORET_RETENTION_MODE=banana
    [ "$(_ret_mode)" = "report" ]
}

@test "retention: _ret_mode passes prune through" {
    MIRRORET_RETENTION_MODE=prune
    [ "$(_ret_mode)" = "prune" ]
}

# -- pip retention actually keeps N newest ------------------------------------

@test "retention: pip prune keeps N newest wheels per package (report mode)" {
    local dir="${MIRRORET_BASE_DIR}/pip/approved"
    mkdir -p "$dir"
    # Create 5 versions of one package with different mtimes.
    for v in 1.0.0 1.1.0 1.2.0 1.3.0 1.4.0; do
        touch "${dir}/mypkg-${v}-py3-none-any.whl"
    done
    # Make them chronological (older = older).
    touch -t 202601010000 "${dir}/mypkg-1.0.0-py3-none-any.whl"
    touch -t 202602010000 "${dir}/mypkg-1.1.0-py3-none-any.whl"
    touch -t 202603010000 "${dir}/mypkg-1.2.0-py3-none-any.whl"
    touch -t 202604010000 "${dir}/mypkg-1.3.0-py3-none-any.whl"
    touch -t 202605010000 "${dir}/mypkg-1.4.0-py3-none-any.whl"

    MIRRORET_PIP_KEEP_VERSIONS=2
    MIRRORET_RETENTION_MODE=report

    run retention_pip_prune
    [ "$status" -eq 0 ]
    # In report mode, all 5 files must still exist.
    [ "$(ls "$dir" | wc -l | tr -d ' ')" = "5" ]
    # And the log must mention pruning 3 (5 - keep=2).
    [[ "$output" == *"pruning 3"* ]]
}

@test "retention: pip prune actually deletes in prune mode" {
    local dir="${MIRRORET_BASE_DIR}/pip/approved"
    mkdir -p "$dir"
    for v in 1.0.0 1.1.0 1.2.0; do
        touch "${dir}/pkgA-${v}-py3-none-any.whl"
    done
    touch -t 202601010000 "${dir}/pkgA-1.0.0-py3-none-any.whl"
    touch -t 202602010000 "${dir}/pkgA-1.1.0-py3-none-any.whl"
    touch -t 202603010000 "${dir}/pkgA-1.2.0-py3-none-any.whl"

    MIRRORET_PIP_KEEP_VERSIONS=1
    MIRRORET_RETENTION_MODE=prune

    run retention_pip_prune
    [ "$status" -eq 0 ]
    # Only the newest should survive.
    [ -f "${dir}/pkgA-1.2.0-py3-none-any.whl" ]
    [ ! -f "${dir}/pkgA-1.0.0-py3-none-any.whl" ]
    [ ! -f "${dir}/pkgA-1.1.0-py3-none-any.whl" ]
}

@test "retention: pip prune leaves packages within keep-N untouched" {
    local dir="${MIRRORET_BASE_DIR}/pip/approved"
    mkdir -p "$dir"
    touch "${dir}/singleton-1.0.0-py3-none-any.whl"
    MIRRORET_PIP_KEEP_VERSIONS=3
    MIRRORET_RETENTION_MODE=prune
    retention_pip_prune
    [ -f "${dir}/singleton-1.0.0-py3-none-any.whl" ]
}

# -- npm retention drops old tarballs -----------------------------------------

@test "retention: npm prune drops tarballs older than N days" {
    local dir="${MIRRORET_BASE_DIR}/npm/approved"
    mkdir -p "$dir"
    touch -t 202001010000 "${dir}/express-1.0.0.tgz" # very old
    touch "${dir}/express-2.0.0.tgz" # today
    MIRRORET_NPM_KEEP_DAYS=30
    MIRRORET_RETENTION_MODE=prune
    retention_npm_prune
    [ ! -f "${dir}/express-1.0.0.tgz" ]
    [ -f "${dir}/express-2.0.0.tgz" ]
}

@test "retention: npm prune report mode leaves files intact" {
    local dir="${MIRRORET_BASE_DIR}/npm/approved"
    mkdir -p "$dir"
    touch -t 202001010000 "${dir}/express-1.0.0.tgz"
    MIRRORET_NPM_KEEP_DAYS=30
    MIRRORET_RETENTION_MODE=report
    run retention_npm_prune
    [ "$status" -eq 0 ]
    [ -f "${dir}/express-1.0.0.tgz" ]
    [[ "$output" == *"would remove"* ]]
}

# -- Docker GC is opt-in even if RETENTION_ENABLE=1 ---------------------------

@test "retention: Docker GC skipped when MIRRORET_DOCKER_GC=0" {
    MIRRORET_DOCKER_GC=0
    run retention_docker_gc
    [ "$status" -eq 0 ]
}

# -- MIRRORET-MANAGED sentinel ------------------------------------------------

@test "sentinel: is_managed_file returns true when file is absent" {
    source "${SCRIPT_DIR}/lib/common.sh"
    is_managed_file "${TMPDIR}/does-not-exist"
}

@test "sentinel: is_managed_file returns true when file has the marker" {
    source "${SCRIPT_DIR}/lib/common.sh"
    local f="${TMPDIR}/managed"
    printf '#!/bin/bash\n%s\n' "${MIRRORET_MANAGED_MARKER}" > "$f"
    is_managed_file "$f"
}

@test "sentinel: is_managed_file returns false when marker is missing" {
    source "${SCRIPT_DIR}/lib/common.sh"
    local f="${TMPDIR}/unmanaged"
    printf '#!/bin/bash\n# operator wrote this from scratch\n' > "$f"
    ! is_managed_file "$f"
}

@test "sentinel: preserve_user_customization returns 0 for absent file" {
    source "${SCRIPT_DIR}/lib/common.sh"
    run preserve_user_customization "${TMPDIR}/absent"
    [ "$status" -eq 0 ]
}

@test "sentinel: preserve_user_customization returns 0 for a managed file" {
    source "${SCRIPT_DIR}/lib/common.sh"
    local f="${TMPDIR}/managed"
    printf '#!/bin/bash\n%s\n' "${MIRRORET_MANAGED_MARKER}" > "$f"
    run preserve_user_customization "$f"
    [ "$status" -eq 0 ]
}

@test "sentinel: preserve_user_customization returns 1 for unmanaged file" {
    source "${SCRIPT_DIR}/lib/common.sh"
    local f="${TMPDIR}/customized"
    printf '#!/bin/bash\necho MY_OWN_SCRIPT\n' > "$f"
    run preserve_user_customization "$f"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Preserving your customized"* ]]
}

# -- Generated sync scripts must carry the sentinel ---------------------------

@test "sentinel: pip sync script generator inserts the marker" {
    grep -q 'MIRRORET_MANAGED_MARKER' "${SCRIPT_DIR}/lib/pip.sh"
}

@test "sentinel: npm sync script generator inserts the marker" {
    grep -q 'MIRRORET_MANAGED_MARKER' "${SCRIPT_DIR}/lib/npm.sh"
}

@test "sentinel: RPM sync script generator inserts the marker" {
    grep -q 'MIRRORET_MANAGED_MARKER' "${SCRIPT_DIR}/lib/rpm.sh"
}

@test "sentinel: docker sync script generator inserts the marker" {
    grep -q 'MIRRORET_MANAGED_MARKER' "${SCRIPT_DIR}/lib/docker_registry.sh"
}

@test "sentinel: master sync-all generator inserts the marker" {
    grep -q 'MIRRORET_MANAGED_MARKER' "${SCRIPT_DIR}/install.sh"
}

# -- install.sh --cleanup / --cleanup-report / --upgrade CLI flags ------------

@test "install.sh --help mentions --cleanup" {
    run bash "${SCRIPT_DIR}/install.sh" --help
    [[ "$output" == *"--cleanup"* ]]
}

@test "install.sh --help mentions --cleanup-report" {
    run bash "${SCRIPT_DIR}/install.sh" --help
    [[ "$output" == *"--cleanup-report"* ]]
}

@test "install.sh --help mentions --upgrade" {
    run bash "${SCRIPT_DIR}/install.sh" --help
    [[ "$output" == *"--upgrade"* ]]
}

# -- cleanup-all.sh generation -------------------------------------------------

@test "install.sh writes a cleanup-all.sh generator" {
    grep -q 'write_master_cleanup_script' "${SCRIPT_DIR}/install.sh"
    grep -q 'cleanup-all.sh' "${SCRIPT_DIR}/install.sh"
}

@test "install.sh setup_cron includes the weekly cleanup entry" {
    section="$(awk '/^setup_cron/,/^}/' "${SCRIPT_DIR}/install.sh")"
    [[ "$section" == *"cleanup_entry"* ]]
    [[ "$section" == *"MIRRORET_CLEANUP_DOW"* ]]
}

@test "retention: never prunes the APT tree" {
    # An apt archive is a closed set: every .deb in pool/ is referenced by a
    # Packages index hashed by a signed Release. Version-pruning the pool
    # leaves the index pointing at files that are gone, and every client
    # fails mid-download. Growth is controlled by the sync's --delete.
    MIRRORET_RETENTION_ENABLE=1
    MIRRORET_RETENTION_MODE=prune
    mkdir -p "${MIRRORET_BASE_DIR}/apt/ubuntu/pool/main/h/hello"
    local deb="${MIRRORET_BASE_DIR}/apt/ubuntu/pool/main/h/hello/hello_1.0_amd64.deb"
    local old="${MIRRORET_BASE_DIR}/apt/ubuntu/pool/main/h/hello/hello_0.9_amd64.deb"
    echo new > "$deb"
    echo old > "$old"

    run run_retention
    # Both must survive - including the "old version".
    [ -f "$deb" ]
    [ -f "$old" ]
    [[ "$output" == *"not pruned here"* ]]
}

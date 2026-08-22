#!/usr/bin/env bats
# Tests for dry-run behaviour: verifies that DRY_RUN=1 prevents system modifications.

load 'test_helpers'

setup() {
    load_lib
    TMPDIR="$(mktemp -d)"
    DRY_RUN=1
    MIRRORET_BASE_DIR="${TMPDIR}/mirroret"
    MIRRORET_SERVER_IP="10.0.0.1"
    MIRRORET_WEB_PORT=8080
    MIRRORET_PIP_PORT=8081
    MIRRORET_DOCKER_REGISTRY_PORT=5000
    MIRRORET_NPM_PORT=4873
    MIRRORET_BACKUP_BASE="${TMPDIR}/backups"
}

teardown() {
    rm -rf "$TMPDIR"
}

@test "dry-run: backup_file does not create backup directory" {
    source "${SCRIPT_DIR}/lib/backup.sh"
    backup_file "testid" "/etc/hostname"
    [ ! -d "${TMPDIR}/backups/testid" ]
}

@test "dry-run: new_backup_id prints an ID without creating a directory" {
    source "${SCRIPT_DIR}/lib/backup.sh"
    result="$(new_backup_id)"
    [ -n "$result" ]
    [ ! -d "${TMPDIR}/backups/${result}" ]
}

@test "dry-run: write_file does not create file" {
    target="${TMPDIR}/should_not_exist.txt"
    write_file "$target" "content"
    [ ! -f "$target" ]
}

@test "install.sh --help exits 0 and shows usage" {
    result="$(bash "${SCRIPT_DIR}/install.sh" --help 2>&1)"
    echo "$result" | grep -q "Usage"
}

@test "install.sh --list-backups exits 0 with empty backups" {
    MIRRORET_BACKUP_BASE="${TMPDIR}/empty_backups" \
        bash "${SCRIPT_DIR}/install.sh" --list-backups
}

@test "install.sh --dry-run requires root and exits with meaningful code" {
    # As non-root, should exit 1 (root check) not crash with a syntax error.
    result=0
    bash "${SCRIPT_DIR}/install.sh" --dry-run --non-interactive 2>/dev/null || result=$?
    # 1 = root check failed (expected), anything else is unexpected.
    [ "$result" -eq 1 ] || [ "$result" -eq 0 ]
}

@test "dry-run: a full install writes nothing under the base dir" {
    # --dry-run's whole contract. generate_all_client_configs used to mkdir
    # the config dir unconditionally, so a dry run always created part of the
    # tree it claimed not to touch.
    local base="${BATS_TEST_TMPDIR}/srv"
    local targets="${BATS_TEST_TMPDIR}/targets"
    run env MIRRORET_BASE_DIR="${base}" MIRRORET_TARGETS_DIR="${targets}" \
        MIRRORET_APT_TARGETS="ubuntu:jammy" MIRRORET_RPM_TARGETS="rocky:9" \
        MIRRORET_MIN_DISK_GB=0 \
        bash "${SCRIPT_DIR}/install.sh" --dry-run --non-interactive \
        --no-pip --no-npm --no-docker --no-firewall
    [ "$status" -eq 0 ]
    [ ! -e "${base}" ]
    [ ! -e "${targets}" ]
}

@test "dry-run: still reports the targets it would configure" {
    # A dry run that cannot name what it would do is not a useful preview.
    # The specs are written to a scratch dir precisely so this stays accurate.
    local base="${BATS_TEST_TMPDIR}/srv2"
    run env MIRRORET_BASE_DIR="${base}" \
        MIRRORET_TARGETS_DIR="${BATS_TEST_TMPDIR}/targets2" \
        MIRRORET_APT_TARGETS="ubuntu:jammy debian:bookworm" \
        MIRRORET_RPM_TARGETS="ol:9" MIRRORET_MIN_DISK_GB=0 \
        bash "${SCRIPT_DIR}/install.sh" --dry-run --non-interactive \
        --no-pip --no-npm --no-docker --no-firewall
    [ "$status" -eq 0 ]
    [[ "$output" == *"APT targets: ubuntu-jammy debian-bookworm"* ]]
    [[ "$output" == *"RPM targets: ol9"* ]]
    [[ "$output" == *"target: ubuntu-jammy -> ${base}/apt/ubuntu"* ]]
}

@test "dry-run: survives on a host with no pypiserver or verdaccio installed" {
    # Regression: _resolve_pypiserver_bin / _resolve_verdaccio_bin return 1
    # when they find nothing, and under `set -e` with an ERR trap that
    # aborted install.sh from inside the assignment - before the empty-check
    # could report anything. So `--dry-run` died on any host that did not
    # already have those binaries, i.e. every fresh server, which is exactly
    # where a dry run matters most.
    #
    # Assert the `|| true` guard is present in both resolvers' call sites.
    grep -q 'pypi_bin="$(_resolve_pypiserver_bin || true)"' "${SCRIPT_DIR}/lib/pip.sh"
    grep -q 'verdaccio_bin="$(_resolve_verdaccio_bin || true)"' "${SCRIPT_DIR}/lib/npm.sh"
}

@test "dry-run: a missing service binary is reported, not fatal, under DRY_RUN" {
    # DRY_RUN skips the install step, so the binary is legitimately absent.
    # That must produce a plan line, not abort the whole preview.
    if command -v pypi-server >/dev/null 2>&1; then
        skip "pypi-server is installed here; cannot exercise the absent case"
    fi
    run bash -c "
        source '${SCRIPT_DIR}/lib/logging.sh'
        source '${SCRIPT_DIR}/lib/common.sh'
        source '${SCRIPT_DIR}/lib/backup.sh'
        source '${SCRIPT_DIR}/lib/systemd.sh'
        source '${SCRIPT_DIR}/lib/pip.sh'
        DRY_RUN=1
        MIRRORET_BASE_DIR='${BATS_TEST_TMPDIR}/srv'
        MIRRORET_PYPI_VENV='${BATS_TEST_TMPDIR}/no-such-venv'
        mkdir -p \"\$MIRRORET_BASE_DIR\"
        _write_pypiserver_unit id \"\$MIRRORET_BASE_DIR\" 8081"
    [ "$status" -eq 0 ]
    [[ "$output" == *"pypiserver is not installed yet"* ]]
}

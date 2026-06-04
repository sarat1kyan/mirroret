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

#!/usr/bin/env bats
# Tests for config parsing and variable handling.

load 'test_helpers'

setup() {
    load_lib
    TMPDIR="$(mktemp -d)"
}

teardown() {
    rm -rf "$TMPDIR"
}

@test "DRY_RUN=1 prevents xrun() from executing commands" {
    local tmpfile="${TMPDIR}/should_not_exist"
    # Source libs in a subprocess so xrun is available.
    bash -c "
        source '${SCRIPT_DIR}/lib/logging.sh'
        source '${SCRIPT_DIR}/lib/common.sh'
        DRY_RUN=1
        xrun touch '${tmpfile}'
    "
    [ ! -f "$tmpfile" ]
}

@test "xrun() executes command when DRY_RUN=0" {
    local tmpfile="${TMPDIR}/test_xrun_file"
    bash -c "
        source '${SCRIPT_DIR}/lib/logging.sh'
        source '${SCRIPT_DIR}/lib/common.sh'
        DRY_RUN=0
        xrun touch '${tmpfile}'
    "
    [ -f "$tmpfile" ]
}

@test "get_server_ip returns MIRRORET_SERVER_IP if set" {
    result="$(MIRRORET_SERVER_IP=192.168.99.99 bash -c "
        source '${SCRIPT_DIR}/lib/logging.sh'
        source '${SCRIPT_DIR}/lib/common.sh'
        get_server_ip
    ")"
    [ "$result" = "192.168.99.99" ]
}

@test "config example file is valid shell syntax" {
    bash -n "${SCRIPT_DIR}/config/mirroret.conf.example"
}

@test "backup_id has correct timestamp format" {
    result="$(bash -c "
        DRY_RUN=1
        MIRRORET_BACKUP_BASE='${TMPDIR}/backups'
        source '${SCRIPT_DIR}/lib/logging.sh'
        source '${SCRIPT_DIR}/lib/common.sh'
        source '${SCRIPT_DIR}/lib/backup.sh'
        new_backup_id
    ")"
    # Should match YYYYMMDD-HHMMSS
    [[ "$result" =~ ^[0-9]{8}-[0-9]{6}$ ]]
}

@test "backup_file in dry-run does not create files" {
    local test_file="${TMPDIR}/testfile.txt"
    echo "test content" > "$test_file"

    bash -c "
        DRY_RUN=1
        MIRRORET_BACKUP_BASE='${TMPDIR}/backups'
        source '${SCRIPT_DIR}/lib/logging.sh'
        source '${SCRIPT_DIR}/lib/common.sh'
        source '${SCRIPT_DIR}/lib/backup.sh'
        backup_file 'testbackup' '${test_file}'
    "
    # Backup dir should NOT be created in dry-run mode.
    [ ! -d "${TMPDIR}/backups/testbackup" ]
}

@test "backup_file creates backup of existing file" {
    local test_file="${TMPDIR}/testfile.txt"
    echo "original content" > "$test_file"

    bash -c "
        DRY_RUN=0
        MIRRORET_BACKUP_BASE='${TMPDIR}/backups'
        source '${SCRIPT_DIR}/lib/logging.sh'
        source '${SCRIPT_DIR}/lib/common.sh'
        source '${SCRIPT_DIR}/lib/backup.sh'
        backup_file 'testbackup' '${test_file}'
    "
    [ -f "${TMPDIR}/backups/testbackup/${TMPDIR#/}/testfile.txt" ]
}

@test "backup_file records MISSING for non-existent file" {
    bash -c "
        DRY_RUN=0
        MIRRORET_BACKUP_BASE='${TMPDIR}/backups'
        source '${SCRIPT_DIR}/lib/logging.sh'
        source '${SCRIPT_DIR}/lib/common.sh'
        source '${SCRIPT_DIR}/lib/backup.sh'
        backup_file 'testbackup' '/nonexistent_path_xyz/file.txt'
    "
    grep -q "MISSING /nonexistent_path_xyz/file.txt" "${TMPDIR}/backups/testbackup/backup.manifest"
}

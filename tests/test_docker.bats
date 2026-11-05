#!/usr/bin/env bats
# Docker registry: secure bind, image-list validation, client config endpoint.
# No real Docker is used - these assert the generated config and scripts, the
# same way the rest of the suite does.

load 'test_helpers'

setup() {
    load_distro_lib
    source "${SCRIPT_DIR}/lib/backup.sh"
    source "${SCRIPT_DIR}/lib/systemd.sh"
    source "${SCRIPT_DIR}/lib/docker_registry.sh"
    TMPDIR_TEST="$(mktemp -d)"
    MIRRORET_BASE_DIR="${TMPDIR_TEST}/srv"
    MIRRORET_BACKUP_BASE="${TMPDIR_TEST}/bk"
    export MIRRORET_BACKUP_BASE
    mkdir -p "${MIRRORET_BASE_DIR}/scripts" "${MIRRORET_BACKUP_BASE}"
    DRY_RUN=0
    MIRRORET_SERVER_IP="10.0.0.1"
    MIRRORET_WEB_PORT=8080
    MIRRORET_DOCKER_REGISTRY_PORT=5000
    MIRRORET_DOCKER_MODE=hosted
    mock_os_release "ubuntu" "22.04" "jammy"; detect_distro_from_mock
}

teardown() {
    cleanup_mock
    rm -rf "${TMPDIR_TEST}"
}

@test "docker: an image list cannot inject shell into the generated sync script" {
    local imgs="${TMPDIR_TEST}/images.txt"
    printf 'ubuntu:22.04\n$(touch %s/pwn)\na;b\nnginx:stable\n' "${TMPDIR_TEST}" > "${imgs}"
    MIRRORET_DOCKER_IMAGES_FILE="${imgs}"
    write_docker_sync_script "${MIRRORET_BASE_DIR}/scripts/sync-docker-images.sh"
    local out="${MIRRORET_BASE_DIR}/scripts/sync-docker-images.sh"
    grep -q 'ubuntu:22.04' "${out}"
    grep -q 'nginx:stable' "${out}"
    ! grep -q 'touch' "${out}"
    ! grep -q ';b' "${out}"
}

@test "docker: registry binds loopback by default, all interfaces only on request" {
    run _docker_bind_addr
    [ "$output" = "127.0.0.1:5000" ]
    run _docker_bind_publish
    [ "$output" = "127.0.0.1:5000:5000" ]

    MIRRORET_DOCKER_BIND=all
    run _docker_bind_addr
    [ "$output" = ":5000" ]
    run _docker_bind_publish
    [ "$output" = "5000:5000" ]
}

@test "docker: emitted registry config addr is loopback by default" {
    _emit_registry_config "${TMPDIR_TEST}/registry.yml"
    grep -qE 'addr: 127\.0\.0\.1:5000' "${TMPDIR_TEST}/registry.yml"
    MIRRORET_DOCKER_BIND=all
    _emit_registry_config "${TMPDIR_TEST}/registry2.yml"
    grep -qE 'addr: :5000' "${TMPDIR_TEST}/registry2.yml"
}

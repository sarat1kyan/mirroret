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

@test "docker: firewall does not open the registry port in loopback bind mode" {
    source "${SCRIPT_DIR}/lib/firewall.sh"
    MIRRORET_ENABLE_DOCKER=1
    MIRRORET_DOCKER_BIND=loopback
    run list_required_ports
    [ "$status" -eq 0 ]
    [[ "$output" != *"Docker registry"* ]]
}

@test "docker: firewall opens the registry port with MIRRORET_DOCKER_BIND=all" {
    source "${SCRIPT_DIR}/lib/firewall.sh"
    MIRRORET_ENABLE_DOCKER=1
    MIRRORET_DOCKER_BIND=all
    run list_required_ports
    [ "$status" -eq 0 ]
    [[ "$output" == *"${MIRRORET_DOCKER_REGISTRY_PORT} Docker registry"* ]]
}

@test "docker client config: loopback bind points clients at the nginx web port, not the registry port" {
    MIRRORET_DOCKER_MODE=cache
    MIRRORET_DOCKER_BIND=loopback
    generate_docker_client_config "${TMPDIR_TEST}/daemon.json"
    grep -q "${MIRRORET_SERVER_IP}:${MIRRORET_WEB_PORT}" "${TMPDIR_TEST}/daemon.json"
    ! grep -q ":${MIRRORET_DOCKER_REGISTRY_PORT}" "${TMPDIR_TEST}/daemon.json"
}

@test "docker client config: MIRRORET_DOCKER_BIND=all keeps the raw registry port" {
    MIRRORET_DOCKER_MODE=cache
    MIRRORET_DOCKER_BIND=all
    generate_docker_client_config "${TMPDIR_TEST}/daemon.json"
    grep -q "${MIRRORET_SERVER_IP}:${MIRRORET_DOCKER_REGISTRY_PORT}" "${TMPDIR_TEST}/daemon.json"
}

@test "docker: container backend binds :port inside the container (host restricted via -p)" {
    # Binding 127.0.0.1 INSIDE a container breaks -p forwarding, so the
    # container registry must bind all interfaces internally; the loopback
    # restriction is the -p 127.0.0.1:port:port mapping.
    MIRRORET_DOCKER_BIND=loopback
    _emit_registry_config "${TMPDIR_TEST}/c.yml" container
    grep -qE 'addr: :5000' "${TMPDIR_TEST}/c.yml"
    ! grep -qE 'addr: 127\.0\.0\.1:5000' "${TMPDIR_TEST}/c.yml"
}

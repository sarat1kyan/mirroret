#!/usr/bin/env bats
# Tests for security-related behaviour: insecure mode warnings,
# default-secure defaults, and config generation.

load 'test_helpers'

setup() {
    load_distro_lib
    TMPDIR="$(mktemp -d)"
    DRY_RUN=0
    MIRRORET_BASE_DIR="${TMPDIR}/mirroret"
    MIRRORET_SERVER_IP="192.168.1.10"
    MIRRORET_WEB_PORT=8080
    MIRRORET_PIP_PORT=8081
    MIRRORET_DOCKER_REGISTRY_PORT=5000
    MIRRORET_NPM_PORT=4873
    mock_os_release "ubuntu" "22.04" "jammy"
    detect_distro_from_mock
    source "${SCRIPT_DIR}/lib/apt.sh"
    source "${SCRIPT_DIR}/lib/rpm.sh"
    source "${SCRIPT_DIR}/lib/pip.sh"
    source "${SCRIPT_DIR}/lib/npm.sh"
    source "${SCRIPT_DIR}/lib/docker_registry.sh"
    mkdir -p "${MIRRORET_BASE_DIR}/config"
}

teardown() {
    cleanup_mock
    rm -rf "$TMPDIR"
}

# -- APT -----------------------------------------------------------------------

@test "APT client config: default does NOT contain trusted=yes" {
    MIRRORET_APT_INSECURE=0
    unset MIRRORET_APT_KEYRING
    generate_apt_client_config "${TMPDIR}/test.list"
    run grep -c "trusted=yes" "${TMPDIR}/test.list"
    [ "$output" = "0" ]
}

@test "APT client config: insecure mode adds trusted=yes with warning" {
    MIRRORET_APT_INSECURE=1
    run bash -c "
        source '${SCRIPT_DIR}/lib/logging.sh'
        source '${SCRIPT_DIR}/lib/common.sh'
        source '${SCRIPT_DIR}/lib/distro.sh'
        source '${SCRIPT_DIR}/lib/apt.sh'
        DRY_RUN=0
        MIRRORET_APT_INSECURE=1
        MIRRORET_SERVER_IP=192.168.1.10
        MIRRORET_WEB_PORT=8080
        OS_CODENAME=jammy OS_VER=22.04 OS_ID=ubuntu DISTRO_TYPE=debian
        generate_apt_client_config '${TMPDIR}/insecure.list'
    "
    grep -q "trusted=yes" "${TMPDIR}/insecure.list"
}

@test "APT client config: insecure mode outputs security warning" {
    run bash -c "
        source '${SCRIPT_DIR}/lib/logging.sh'
        source '${SCRIPT_DIR}/lib/common.sh'
        source '${SCRIPT_DIR}/lib/distro.sh'
        source '${SCRIPT_DIR}/lib/apt.sh'
        DRY_RUN=0
        MIRRORET_APT_INSECURE=1
        MIRRORET_SERVER_IP=192.168.1.10
        MIRRORET_WEB_PORT=8080
        OS_CODENAME=jammy OS_VER=22.04 OS_ID=ubuntu DISTRO_TYPE=debian
        generate_apt_client_config '${TMPDIR}/insecure2.list' 2>&1
    "
    [[ "$output" == *"SECURITY WARNING"* ]]
}

@test "APT client config: resign+keyring mode uses signed-by" {
    # signed-by= is now only emitted when MIRRORET_APT_RESIGN=1 AND a
    # keyring path is set. Without resign, the upstream signature is
    # what the client validates, so signed-by is intentionally absent.
    MIRRORET_APT_INSECURE=0
    MIRRORET_APT_RESIGN=1
    MIRRORET_APT_KEYRING="/etc/apt/keyrings/test.gpg"
    generate_apt_client_config "${TMPDIR}/signed.list"
    grep -q "signed-by=/etc/apt/keyrings/test.gpg" "${TMPDIR}/signed.list"
    unset MIRRORET_APT_KEYRING MIRRORET_APT_RESIGN
}

@test "APT client config: default (no resign) does NOT emit signed-by=mirroret.gpg" {
    # Regression: mirroret used to emit signed-by pointing at its own key
    # for upstream-mirrored repos, which made apt update fail because the
    # Release file is signed by the upstream archive, not by mirroret.
    MIRRORET_APT_INSECURE=0
    MIRRORET_APT_RESIGN=0
    MIRRORET_APT_KEYRING="/etc/apt/keyrings/mirroret.gpg"
    generate_apt_client_config "${TMPDIR}/default.list"
    run grep -c "signed-by=/etc/apt/keyrings/mirroret.gpg" "${TMPDIR}/default.list"
    [ "$output" = "0" ]
    unset MIRRORET_APT_KEYRING MIRRORET_APT_RESIGN
}

# -- RPM -----------------------------------------------------------------------

@test "RPM client config: default has gpgcheck=1" {
    mock_os_release "rocky" "9.3"
    detect_distro_from_mock
    MIRRORET_RPM_INSECURE=0
    unset MIRRORET_RPM_GPGKEY_URL
    generate_rpm_client_config "${TMPDIR}/test.repo"
    grep -q "gpgcheck=1" "${TMPDIR}/test.repo"
}

@test "RPM client config: default does NOT have gpgcheck=0" {
    mock_os_release "rocky" "9.3"
    detect_distro_from_mock
    MIRRORET_RPM_INSECURE=0
    unset MIRRORET_RPM_GPGKEY_URL
    generate_rpm_client_config "${TMPDIR}/test2.repo"
    run grep -c "gpgcheck=0" "${TMPDIR}/test2.repo"
    [ "$output" = "0" ]
}

@test "RPM client config: insecure mode outputs security warning" {
    mock_os_release "rocky" "9.3"
    detect_distro_from_mock
    run bash -c "
        source '${SCRIPT_DIR}/lib/logging.sh'
        source '${SCRIPT_DIR}/lib/common.sh'
        source '${SCRIPT_DIR}/lib/distro.sh'
        source '${SCRIPT_DIR}/lib/rpm.sh'
        DRY_RUN=0
        MIRRORET_RPM_INSECURE=1
        MIRRORET_SERVER_IP=192.168.1.10
        MIRRORET_WEB_PORT=8080
        OS_VER=9.3 DISTRO_TYPE=rhel
        generate_rpm_client_config '${TMPDIR}/insecure.repo' 2>&1
    "
    [[ "$output" == *"SECURITY WARNING"* ]]
}

# -- Docker --------------------------------------------------------------------

@test "Docker client config: default is a plain-http mirror dockerd will accept" {
    # The registry speaks plain HTTP on its port. dockerd refuses an http
    # mirror unless it is also listed in insecure-registries, so with TLS not
    # configured the generated daemon.json MUST carry that entry - and must
    # never point at https:// on the http port (the old default did, and
    # Docker silently fell back to Docker Hub).
    MIRRORET_DOCKER_INSECURE=0 MIRRORET_TLS_ENABLED=0
    generate_docker_client_config "${TMPDIR}/daemon.json"
    run python3 -c "
import json; d=json.load(open('${TMPDIR}/daemon.json'))
m=d['registry-mirrors'][0]
assert m.startswith('http://'), m
assert 'insecure-registries' in d, d
assert '_comment' not in d, 'dockerd rejects unknown keys'
print('ok')"
    [ "$status" -eq 0 ]
}

@test "Docker client config: insecure mode adds insecure-registries" {
    MIRRORET_DOCKER_INSECURE=1
    run bash -c "
        source '${SCRIPT_DIR}/lib/logging.sh'
        source '${SCRIPT_DIR}/lib/common.sh'
        source '${SCRIPT_DIR}/lib/docker_registry.sh'
        DRY_RUN=0
        MIRRORET_DOCKER_INSECURE=1
        MIRRORET_SERVER_IP=192.168.1.10
        MIRRORET_DOCKER_REGISTRY_PORT=5000
        generate_docker_client_config '${TMPDIR}/insecure_daemon.json' 2>&1
    "
    grep -q "insecure-registries" "${TMPDIR}/insecure_daemon.json"
}

# -- pip -----------------------------------------------------------------------

@test "pip client config: an http index ALWAYS sets trusted-host" {
    # pip refuses to use a plain-HTTP index whose host is not trusted: it
    # prints "not a trusted or secure host and is being ignored" and then
    # finds no packages. Omitting trusted-host produced a pip.conf that
    # looked correct and broke every client, so it is now unconditional for
    # http:// indexes.
    DRY_RUN=0
    MIRRORET_PIP_INSECURE=0
    generate_pip_client_config "${TMPDIR}/pip.conf"
    grep -q '^index-url = http://' "${TMPDIR}/pip.conf"
    grep -q "^trusted-host = ${MIRRORET_SERVER_IP}$" "${TMPDIR}/pip.conf"
}

@test "pip client config: insecure mode adds trusted-host" {
    MIRRORET_PIP_INSECURE=1
    run bash -c "
        source '${SCRIPT_DIR}/lib/logging.sh'
        source '${SCRIPT_DIR}/lib/common.sh'
        source '${SCRIPT_DIR}/lib/pip.sh'
        DRY_RUN=0
        MIRRORET_PIP_INSECURE=1
        MIRRORET_SERVER_IP=192.168.1.10
        MIRRORET_PIP_PORT=8081
        generate_pip_client_config '${TMPDIR}/insecure_pip.conf' 2>&1
    "
    grep -q "trusted-host" "${TMPDIR}/insecure_pip.conf"
}

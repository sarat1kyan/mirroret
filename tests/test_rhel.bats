#!/usr/bin/env bats
# RHEL-specific tests for mirroret.
# Covers: distro detection, RPM config, SELinux stubs, Docker registry native backend.
# No real RHEL system required — uses mocks and dry-run mode throughout.

load 'test_helpers'

setup() {
    load_distro_lib
    source "${SCRIPT_DIR}/lib/rpm.sh"
    source "${SCRIPT_DIR}/lib/backup.sh"
    source "${SCRIPT_DIR}/lib/systemd.sh"
    source "${SCRIPT_DIR}/lib/docker_registry.sh"
    TMPDIR="$(mktemp -d)"
    DRY_RUN=1
    MIRRORET_BASE_DIR="${TMPDIR}/mirroret"
    MIRRORET_SERVER_IP="10.0.0.1"
    MIRRORET_WEB_PORT=8080
    MIRRORET_DOCKER_REGISTRY_PORT=5000
    mkdir -p "${MIRRORET_BASE_DIR}/scripts"
}

teardown() {
    cleanup_mock
    rm -rf "${TMPDIR}"
}

# ── Distribution detection ────────────────────────────────────────────────────

@test "detect_distro: almalinux sets DISTRO_TYPE=rhel" {
    mock_os_release "almalinux" "9.3"
    detect_distro_from_mock
    [ "$DISTRO_TYPE" = "rhel" ]
}

@test "detect_distro: fedora sets DISTRO_TYPE=rhel" {
    mock_os_release "fedora" "39"
    detect_distro_from_mock
    [ "$DISTRO_TYPE" = "rhel" ]
}

@test "detect_distro: ol (Oracle Linux) sets DISTRO_TYPE=rhel" {
    mock_os_release "ol" "8.9"
    detect_distro_from_mock
    [ "$DISTRO_TYPE" = "rhel" ]
}

@test "detect_distro: rocky sets PKG_MGR=dnf" {
    mock_os_release "rocky" "9.3"
    detect_distro_from_mock
    [ "$PKG_MGR" = "dnf" ]
}

@test "detect_distro: rocky PKG_MGR_INSTALL uses dnf install" {
    mock_os_release "rocky" "9.3"
    detect_distro_from_mock
    [[ "$PKG_MGR_INSTALL" == *"dnf install"* ]]
}

@test "detect_distro: rocky PKG_MGR_INSTALL does not contain force-confold" {
    mock_os_release "rocky" "9.3"
    detect_distro_from_mock
    [[ "$PKG_MGR_INSTALL" != *"force-confold"* ]]
}

@test "detect_distro: rhel_major_version strips minor for rocky 8.7" {
    mock_os_release "rocky" "8.7"
    detect_distro_from_mock
    result="$(rhel_major_version)"
    [ "$result" = "8" ]
}

@test "detect_distro: rhel_major_version strips minor for almalinux 9.2" {
    mock_os_release "almalinux" "9.2"
    detect_distro_from_mock
    result="$(rhel_major_version)"
    [ "$result" = "9" ]
}

# ── SELinux ───────────────────────────────────────────────────────────────────

@test "selinux: set_selinux_context is a no-op when not enforcing" {
    # On non-RHEL test machines SELinux is always not enforcing.
    # This asserts the function does not die even when semanage is absent.
    run set_selinux_context "/tmp"
    [ "$status" -eq 0 ]
}

@test "selinux: selinux_enforcing returns false on Ubuntu/CI" {
    ! selinux_enforcing
}

# ── RPM sync script generation ────────────────────────────────────────────────

@test "rpm: configure_createrepo dry-run does not create sync script" {
    mock_os_release "rocky" "9.3"
    detect_distro_from_mock
    MIRRORET_RHEL_VERSION=9
    run configure_createrepo "test-backup"
    [ "$status" -eq 0 ]
    [ ! -f "${MIRRORET_BASE_DIR}/scripts/sync-redhat-repos.sh" ]
}

@test "rpm: configure_createrepo dry-run outputs expected message" {
    mock_os_release "rocky" "9.3"
    detect_distro_from_mock
    MIRRORET_RHEL_VERSION=9
    run configure_createrepo "test-backup"
    [[ "$output" == *"DRY-RUN"* ]]
}

@test "rpm: configure_createrepo live mode writes sync script" {
    mock_os_release "rocky" "9.3"
    detect_distro_from_mock
    DRY_RUN=0
    MIRRORET_RHEL_VERSION=9
    configure_createrepo "test-backup"
    [ -f "${MIRRORET_BASE_DIR}/scripts/sync-redhat-repos.sh" ]
}

@test "rpm: sync script contains createrepo command" {
    mock_os_release "rocky" "9.3"
    detect_distro_from_mock
    DRY_RUN=0
    MIRRORET_RHEL_VERSION=9
    configure_createrepo "test-backup"
    grep -qE "createrepo_c|createrepo" "${MIRRORET_BASE_DIR}/scripts/sync-redhat-repos.sh"
}

@test "rpm: sync script checks for required tools" {
    mock_os_release "rocky" "9.3"
    detect_distro_from_mock
    DRY_RUN=0
    MIRRORET_RHEL_VERSION=9
    configure_createrepo "test-backup"
    grep -q "command -v" "${MIRRORET_BASE_DIR}/scripts/sync-redhat-repos.sh"
}

# ── RPM client config ─────────────────────────────────────────────────────────

@test "rpm: generate_rpm_client_config dry-run skips file write" {
    mock_os_release "rocky" "9.3"
    detect_distro_from_mock
    run generate_rpm_client_config "${TMPDIR}/test.repo"
    [ "$status" -eq 0 ]
    [ ! -f "${TMPDIR}/test.repo" ]
}

@test "rpm: generate_rpm_client_config live mode creates .repo file" {
    mock_os_release "rocky" "9.3"
    detect_distro_from_mock
    DRY_RUN=0
    MIRRORET_RPM_INSECURE=1
    generate_rpm_client_config "${TMPDIR}/test.repo"
    [ -f "${TMPDIR}/test.repo" ]
}

@test "rpm: client config contains mirroret-baseos section" {
    mock_os_release "rocky" "9.3"
    detect_distro_from_mock
    DRY_RUN=0
    MIRRORET_RPM_INSECURE=1
    generate_rpm_client_config "${TMPDIR}/test.repo"
    grep -q "\[mirroret-baseos\]" "${TMPDIR}/test.repo"
}

@test "rpm: client config contains mirroret-appstream section" {
    mock_os_release "rocky" "9.3"
    detect_distro_from_mock
    DRY_RUN=0
    MIRRORET_RPM_INSECURE=1
    generate_rpm_client_config "${TMPDIR}/test.repo"
    grep -q "\[mirroret-appstream\]" "${TMPDIR}/test.repo"
}

@test "rpm: client config contains server IP in baseurl" {
    mock_os_release "rocky" "9.3"
    detect_distro_from_mock
    DRY_RUN=0
    MIRRORET_RPM_INSECURE=1
    generate_rpm_client_config "${TMPDIR}/test.repo"
    grep -q "10.0.0.1" "${TMPDIR}/test.repo"
}

# ── Docker registry native backend ────────────────────────────────────────────

@test "docker_registry: MIRRORET_DOCKER_BACKEND defaults to auto" {
    [ "${MIRRORET_DOCKER_BACKEND}" = "auto" ]
}

@test "docker_registry: _native_registry_info sets docker-distribution for RHEL" {
    DISTRO_TYPE=rhel
    _native_registry_info
    [ "${NATIVE_PKG}" = "docker-distribution" ]
}

@test "docker_registry: _native_registry_info sets docker-registry for Debian" {
    DISTRO_TYPE=debian
    _native_registry_info
    [ "${NATIVE_PKG}" = "docker-registry" ]
}

@test "docker_registry: _native_registry_info sets correct service for RHEL" {
    DISTRO_TYPE=rhel
    _native_registry_info
    [ "${NATIVE_SERVICE}" = "docker-distribution" ]
}

@test "docker_registry: _native_registry_info sets correct config dir for RHEL" {
    DISTRO_TYPE=rhel
    _native_registry_info
    [ "${NATIVE_CONF_DIR}" = "/etc/docker-distribution/registry" ]
}

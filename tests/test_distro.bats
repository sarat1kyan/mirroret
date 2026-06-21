#!/usr/bin/env bats
# Tests for lib/distro.sh

load 'test_helpers'

setup() {
    load_distro_lib
}

teardown() {
    cleanup_mock
}

@test "detect_distro: ubuntu sets DISTRO_TYPE=debian" {
    mock_os_release "ubuntu" "22.04" "jammy"
    detect_distro_from_mock
    [ "$DISTRO_TYPE" = "debian" ]
}

@test "detect_distro: debian sets DISTRO_TYPE=debian" {
    mock_os_release "debian" "12"
    detect_distro_from_mock
    [ "$DISTRO_TYPE" = "debian" ]
}

@test "detect_distro: rocky sets DISTRO_TYPE=rhel" {
    mock_os_release "rocky" "9.3"
    detect_distro_from_mock
    [ "$DISTRO_TYPE" = "rhel" ]
}

@test "detect_distro: centos sets DISTRO_TYPE=rhel" {
    mock_os_release "centos" "8"
    detect_distro_from_mock
    [ "$DISTRO_TYPE" = "rhel" ]
}

@test "detect_distro: unknown distro returns error" {
    mock_os_release "archlinux" "rolling"
    # Run in a subprocess so the die() doesn't abort bats.
    result="$(detect_distro_from_mock 2>&1)" && status=0 || status=$?
    [ "$status" -ne 0 ]
}

@test "detect_distro: ubuntu sets PKG_MGR=apt-get" {
    mock_os_release "ubuntu" "22.04" "jammy"
    detect_distro_from_mock
    [ "$PKG_MGR" = "apt-get" ]
}

@test "detect_distro: rocky sets PKG_MGR=dnf" {
    mock_os_release "rocky" "9.3"
    detect_distro_from_mock
    [ "$PKG_MGR" = "dnf" ]
}

@test "ubuntu_codename: returns codename from MIRRORET_UBUNTU_CODENAME override" {
    # When MIRRORET_UBUNTU_CODENAME is set, return it regardless of OS_VER.
    result="$(MIRRORET_UBUNTU_CODENAME=noble bash -c "
        source '${SCRIPT_DIR}/lib/logging.sh'
        source '${SCRIPT_DIR}/lib/common.sh'
        source '${SCRIPT_DIR}/lib/distro.sh'
        ubuntu_codename
    ")"
    [ "$result" = "noble" ]
}

@test "ubuntu_codename: derives codename for 22.04" {
    mock_os_release "ubuntu" "22.04" "jammy"
    detect_distro_from_mock
    result="$(ubuntu_codename)"
    [ "$result" = "jammy" ]
}

@test "ubuntu_codename: honours explicit override over auto-detection" {
    mock_os_release "ubuntu" "22.04" "jammy"
    detect_distro_from_mock
    result="$(MIRRORET_UBUNTU_CODENAME=focal ubuntu_codename)"
    [ "$result" = "focal" ]
}

@test "rhel_major_version: strips minor version" {
    mock_os_release "rocky" "9.3"
    detect_distro_from_mock
    result="$(rhel_major_version)"
    [ "$result" = "9" ]
}

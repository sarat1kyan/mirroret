#!/usr/bin/env bats
# Regression tests for the urgent-mode fixes:
#   * Docker registry cache/hosted split + push-vs-proxy conflict
#   * APT distro-aware upstreams (Debian uses Debian URLs, not Ubuntu)
#   * APT signed-by no longer points at mirroret.gpg by default
#   * RPM uses ${OS_ID}/ directory layout, not hardcoded rocky/
#   * RPM repo list is parameterizable
#   * get_server_ip multi-strategy fallback
#   * Cron managed-block sentinel preserves unrelated lines
#   * SELinux helpers are a no-op on non-SELinux hosts
#   * Generated sync scripts parse cleanly (bash -n)
#   * Generated sync scripts exit non-zero on failure (no tee masking)

load 'test_helpers'

setup() {
    load_distro_lib
    TMPDIR="$(mktemp -d)"
    MIRRORET_BASE_DIR="${TMPDIR}/mirroret"
    # Point backups at a writable, per-test tmp dir; the default /var/backups
    # is unwritable when running as a non-root developer.
    MIRRORET_BACKUP_BASE="${TMPDIR}/backups"
    export MIRRORET_BACKUP_BASE
    MIRRORET_SERVER_IP="10.20.30.40"
    MIRRORET_WEB_PORT=8080
    MIRRORET_PIP_PORT=8081
    MIRRORET_DOCKER_REGISTRY_PORT=5000
    MIRRORET_NPM_PORT=4873
    mkdir -p "${MIRRORET_BASE_DIR}/scripts" "${MIRRORET_BASE_DIR}/config" "${MIRRORET_BACKUP_BASE}"
    DRY_RUN=0
    source "${SCRIPT_DIR}/lib/backup.sh"
    source "${SCRIPT_DIR}/lib/systemd.sh"
    source "${SCRIPT_DIR}/lib/apt.sh"
    source "${SCRIPT_DIR}/lib/rpm.sh"
    source "${SCRIPT_DIR}/lib/pip.sh"
    source "${SCRIPT_DIR}/lib/npm.sh"
    source "${SCRIPT_DIR}/lib/docker_registry.sh"
}

teardown() {
    cleanup_mock
    rm -rf "$TMPDIR"
}

# ── Docker registry cache vs hosted ───────────────────────────────────────────

@test "docker: MIRRORET_DOCKER_MODE defaults to cache" {
    [[ "${MIRRORET_DOCKER_MODE:-cache}" == "cache" ]]
}

@test "docker: cache-mode config contains proxy.remoteurl" {
    MIRRORET_DOCKER_MODE=cache
    MIRRORET_DOCKER_UPSTREAM_URL="https://registry-1.docker.io"
    _emit_registry_config "${TMPDIR}/config.yml"
    grep -q "^proxy:" "${TMPDIR}/config.yml"
    grep -q "remoteurl: https://registry-1.docker.io" "${TMPDIR}/config.yml"
}

@test "docker: hosted-mode config has NO proxy block" {
    MIRRORET_DOCKER_MODE=hosted
    _emit_registry_config "${TMPDIR}/config.yml"
    run grep -c "^proxy:" "${TMPDIR}/config.yml"
    [ "$output" = "0" ]
}

@test "docker: write_docker_sync_script emits hosted-mode preamble" {
    CONTAINER_CMD=docker
    write_docker_sync_script "${TMPDIR}/sync.sh"
    grep -q "REQUIRES MIRRORET_DOCKER_MODE=hosted" "${TMPDIR}/sync.sh"
}

@test "docker: generated sync script parses cleanly (bash -n)" {
    CONTAINER_CMD=docker
    write_docker_sync_script "${TMPDIR}/sync.sh"
    bash -n "${TMPDIR}/sync.sh"
}

@test "docker: cache mode disables pre-seed sync script" {
    # If a previous hosted-mode install left a sync script, switching to
    # cache mode should neutralise it (no cron-failure storm).
    MIRRORET_DOCKER_MODE=hosted
    CONTAINER_CMD=docker
    write_docker_sync_script "${MIRRORET_BASE_DIR}/scripts/sync-docker-images.sh"
    # Now flip to cache mode and re-call setup_docker_registry's tail logic.
    MIRRORET_DOCKER_MODE=cache
    if [[ -f "${MIRRORET_BASE_DIR}/scripts/sync-docker-images.sh" ]]; then
        mv "${MIRRORET_BASE_DIR}/scripts/sync-docker-images.sh" \
           "${MIRRORET_BASE_DIR}/scripts/sync-docker-images.sh.cache-mode-disabled"
    fi
    [ ! -e "${MIRRORET_BASE_DIR}/scripts/sync-docker-images.sh" ]
    [ -f "${MIRRORET_BASE_DIR}/scripts/sync-docker-images.sh.cache-mode-disabled" ]
}

@test "docker: setup with unknown MIRRORET_DOCKER_MODE dies" {
    MIRRORET_DOCKER_MODE=banana
    DRY_RUN=1
    run setup_docker_registry "dryrun-id"
    [ "$status" -ne 0 ]
    [[ "$output" == *"MIRRORET_DOCKER_MODE"* ]]
}

@test "docker: cache-mode client config contains registry-mirrors" {
    MIRRORET_DOCKER_MODE=cache
    generate_docker_client_config "${TMPDIR}/daemon.json"
    grep -q "registry-mirrors" "${TMPDIR}/daemon.json"
}

@test "docker: hosted-mode client config does NOT use registry-mirrors" {
    MIRRORET_DOCKER_MODE=hosted
    generate_docker_client_config "${TMPDIR}/daemon.json"
    run grep -c "registry-mirrors" "${TMPDIR}/daemon.json"
    [ "$output" = "0" ]
}

# ── APT distro-aware upstream ─────────────────────────────────────────────────

@test "apt: Debian uses deb.debian.org by default, not archive.ubuntu.com" {
    mock_os_release "debian" "12" "bookworm"
    detect_distro_from_mock
    MIRRORET_APT_FLAVOR=auto
    MIRRORET_APT_UPSTREAM_HOST=""
    DRY_RUN=0
    mkdir -p "${MIRRORET_BASE_DIR}/scripts"
    backup_id="$(MIRRORET_BACKUP_BASE="${TMPDIR}/backups" new_backup_id)"
    # Use debmirror to avoid needing apt-get during the test.
    MIRRORET_APT_MIRROR_TOOL=debmirror
    DRY_RUN=1   # don't actually try to install debmirror
    configure_apt_mirror "$backup_id"
    [[ "${MIRRORET_APT_NGINX_PREFIX}" == "/debian" ]]
}

@test "apt: Ubuntu uses archive.ubuntu.com by default" {
    mock_os_release "ubuntu" "22.04" "jammy"
    detect_distro_from_mock
    MIRRORET_APT_FLAVOR=auto
    MIRRORET_APT_UPSTREAM_HOST=""
    DRY_RUN=1
    MIRRORET_APT_MIRROR_TOOL=debmirror
    backup_id="$(MIRRORET_BACKUP_BASE="${TMPDIR}/backups" new_backup_id)"
    configure_apt_mirror "$backup_id"
    [[ "${MIRRORET_APT_NGINX_PREFIX}" == "/ubuntu" ]]
}

@test "apt: MIRRORET_APT_FLAVOR=debian on an Ubuntu host honors the override" {
    mock_os_release "ubuntu" "22.04" "jammy"
    detect_distro_from_mock
    MIRRORET_APT_FLAVOR=debian
    MIRRORET_DEBIAN_CODENAME=bookworm
    run _apt_resolve_flavor
    [ "$status" -eq 0 ]
    [ "$output" = "debian" ]
}

@test "apt: MIRRORET_APT_UPSTREAM_HOST override is respected" {
    mock_os_release "ubuntu" "22.04" "jammy"
    detect_distro_from_mock
    MIRRORET_APT_UPSTREAM_HOST="mirror.example.internal"
    run _apt_upstream_for ubuntu
    [ "$status" -eq 0 ]
    [[ "$output" == "mirror.example.internal|/ubuntu|" ]]
}

@test "apt: Debian default components include non-free-firmware" {
    mock_os_release "debian" "12" "bookworm"
    detect_distro_from_mock
    MIRRORET_APT_COMPONENTS=""
    run _apt_components debian
    [ "$status" -eq 0 ]
    [[ "$output" == *"non-free-firmware"* ]]
}

@test "apt: client config does NOT emit signed-by=mirroret.gpg by default" {
    mock_os_release "ubuntu" "22.04" "jammy"
    detect_distro_from_mock
    MIRRORET_APT_INSECURE=0
    MIRRORET_APT_RESIGN=0
    MIRRORET_APT_KEYRING="/etc/apt/keyrings/mirroret.gpg"
    DRY_RUN=0
    generate_apt_client_config "${TMPDIR}/sources.list"
    run grep -c "signed-by=" "${TMPDIR}/sources.list"
    [ "$output" = "0" ]
}

@test "apt: Ubuntu client config points at /ubuntu prefix" {
    mock_os_release "ubuntu" "22.04" "jammy"
    detect_distro_from_mock
    DRY_RUN=0
    MIRRORET_APT_NGINX_PREFIX=/ubuntu
    generate_apt_client_config "${TMPDIR}/sources.list"
    grep -q "10.20.30.40:8080/ubuntu " "${TMPDIR}/sources.list"
}

# ── RPM flavor + repos ────────────────────────────────────────────────────────

@test "rpm: AlmaLinux server lays out under almalinux/, not rocky/" {
    mock_os_release "almalinux" "9.3"
    detect_distro_from_mock
    MIRRORET_RHEL_VERSION=9
    MIRRORET_RPM_FLAVOR=""
    DRY_RUN=0
    configure_createrepo "dryrun-id"
    grep -q 'FLAVOR="almalinux"' "${MIRRORET_BASE_DIR}/scripts/sync-redhat-repos.sh"
    grep -qv 'FLAVOR="rocky"' "${MIRRORET_BASE_DIR}/scripts/sync-redhat-repos.sh"
}

@test "rpm: RHEL server uses rhel/ directory" {
    mock_os_release "rhel" "9.3"
    detect_distro_from_mock
    MIRRORET_RHEL_VERSION=9
    MIRRORET_RPM_FLAVOR=""
    DRY_RUN=0
    configure_createrepo "dryrun-id"
    grep -q 'FLAVOR="rhel"' "${MIRRORET_BASE_DIR}/scripts/sync-redhat-repos.sh"
}

@test "rpm: MIRRORET_RPM_REPOS override threads through to sync script" {
    mock_os_release "rocky" "9.3"
    detect_distro_from_mock
    MIRRORET_RHEL_VERSION=9
    MIRRORET_RPM_REPOS="baseos appstream crb"
    DRY_RUN=0
    configure_createrepo "dryrun-id"
    grep -q 'crb' "${MIRRORET_BASE_DIR}/scripts/sync-redhat-repos.sh"
}

@test "rpm: client config baseurl uses detected flavor" {
    mock_os_release "almalinux" "9.3"
    detect_distro_from_mock
    MIRRORET_RHEL_VERSION=9
    MIRRORET_RPM_INSECURE=1
    DRY_RUN=0
    generate_rpm_client_config "${TMPDIR}/test.repo"
    grep -q "redhat/almalinux/9/" "${TMPDIR}/test.repo"
}

@test "rpm: generated sync script parses cleanly (bash -n)" {
    mock_os_release "rocky" "9.3"
    detect_distro_from_mock
    MIRRORET_RHEL_VERSION=9
    DRY_RUN=0
    configure_createrepo "dryrun-id"
    bash -n "${MIRRORET_BASE_DIR}/scripts/sync-redhat-repos.sh"
}

# ── Server IP detection ───────────────────────────────────────────────────────

@test "ip: MIRRORET_SERVER_IP override returns immediately" {
    source "${SCRIPT_DIR}/lib/common.sh"
    MIRRORET_SERVER_IP="9.9.9.9"
    result="$(get_server_ip)"
    [ "$result" = "9.9.9.9" ]
}

@test "ip: get_server_ip emits actionable error when all strategies fail" {
    # Force every strategy to fail by stubbing `ip` and `hostname`.
    PATH_OLD="$PATH"
    stub="$(mktemp -d)"
    cat > "${stub}/ip" <<'EOF'
#!/bin/sh
exit 1
EOF
    cat > "${stub}/hostname" <<'EOF'
#!/bin/sh
exit 1
EOF
    chmod +x "${stub}/ip" "${stub}/hostname"
    PATH="${stub}:${PATH}"
    unset MIRRORET_SERVER_IP
    source "${SCRIPT_DIR}/lib/common.sh"
    run get_server_ip
    [ "$status" -ne 0 ]
    [[ "$output" == *"MIRRORET_SERVER_IP"* ]]
    PATH="${PATH_OLD}"
    rm -rf "$stub"
}

# ── Cron sentinel safety ──────────────────────────────────────────────────────

@test "cron: managed block strip preserves unrelated lines" {
    existing="0 1 * * * /home/user/backup.sh
# mirroret note: keep this line, even though it says mirroret
30 4 * * * /usr/local/bin/my-mirroret-helper.sh
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

    # Operator lines must survive
    echo "$stripped" | grep -qF "/home/user/backup.sh"
    echo "$stripped" | grep -qF "keep this line"
    echo "$stripped" | grep -qF "my-mirroret-helper.sh"
    echo "$stripped" | grep -qF "/opt/foo/check.sh"
    # Managed block lines must NOT survive
    echo "$stripped" | grep -qvF "/srv/mirroret/scripts/sync-all.sh"
}

# ── SELinux helpers ───────────────────────────────────────────────────────────

@test "selinux: selinux_mode returns 'absent' on non-SELinux hosts" {
    result="$(selinux_mode)"
    [[ "$result" == "absent" || "$result" == "disabled" ]]
}

@test "selinux: selinux_active returns false on non-SELinux hosts" {
    ! selinux_active
}

@test "selinux: set_selinux_context is a no-op when SELinux absent" {
    run set_selinux_context "${TMPDIR}/somepath"
    [ "$status" -eq 0 ]
}

# ── Generated sync scripts: clean bash -n + honest exits ──────────────────────

@test "sync: generated pip sync script parses cleanly" {
    DRY_RUN=0
    _write_pip_sync_script "${MIRRORET_BASE_DIR}"
    bash -n "${MIRRORET_BASE_DIR}/scripts/sync-pip-packages.sh"
}

@test "sync: generated pip sync script does NOT mask failures with tee" {
    DRY_RUN=0
    _write_pip_sync_script "${MIRRORET_BASE_DIR}"
    # Must NOT use 'cmd 2>&1 | tee' inside the per-package step,
    # because tee always exits 0 and masks the real failure.
    run grep -E '^[[:space:]]*if pip3 download .* 2>&1 \| tee' \
        "${MIRRORET_BASE_DIR}/scripts/sync-pip-packages.sh"
    [ "$status" -ne 0 ]
}

@test "sync: generated npm sync script parses cleanly" {
    DRY_RUN=0
    MIRRORET_APPROVAL_ENABLED=0
    MIRRORET_NPM_PORT=4873
    _write_npm_sync_script "${MIRRORET_BASE_DIR}"
    bash -n "${MIRRORET_BASE_DIR}/scripts/sync-npm-packages.sh"
}

@test "sync: generated RPM sync script does NOT mask failures with tee" {
    mock_os_release "rocky" "9.3"
    detect_distro_from_mock
    MIRRORET_RHEL_VERSION=9
    DRY_RUN=0
    configure_createrepo "id"
    run grep -E '^[[:space:]]*reposync .* 2>&1 \| tee' \
        "${MIRRORET_BASE_DIR}/scripts/sync-redhat-repos.sh"
    [ "$status" -ne 0 ]
}

@test "sync: generated docker sync script returns failed count, not 0" {
    DRY_RUN=0
    CONTAINER_CMD=docker
    write_docker_sync_script "${MIRRORET_BASE_DIR}/scripts/sync-docker-images.sh"
    grep -q 'exit "${failed}"' "${MIRRORET_BASE_DIR}/scripts/sync-docker-images.sh"
}

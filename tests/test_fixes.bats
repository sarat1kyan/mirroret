#!/usr/bin/env bats
# Regression tests for the urgent-mode fixes:
# * Docker registry cache/hosted split + push-vs-proxy conflict
# * APT distro-aware upstreams (Debian uses Debian URLs, not Ubuntu)
# * APT signed-by no longer points at mirroret.gpg by default
# * RPM uses ${OS_ID}/ directory layout, not hardcoded rocky/
# * RPM repo list is parameterizable
# * get_server_ip multi-strategy fallback
# * Cron managed-block sentinel preserves unrelated lines
# * SELinux helpers are a no-op on non-SELinux hosts
# * Generated sync scripts parse cleanly (bash -n)
# * Generated sync scripts exit non-zero on failure (no tee masking)

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

# -- Docker registry cache vs hosted -------------------------------------------

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

# -- APT distro-aware upstream -------------------------------------------------

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
    DRY_RUN=1 # don't actually try to install debmirror
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

# -- RPM flavor + repos --------------------------------------------------------

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

@test "install: auto-loads /etc/mirroret/mirroret.conf when --config absent" {
    # Regression: prior behavior required --config. Now install.sh
    # auto-sources /etc/mirroret/mirroret.conf if present.
    grep -q 'Auto-load' "${SCRIPT_DIR}/install.sh" || \
        grep -q 'Auto-load\|auto-load\|mirroret.conf (auto)' "${SCRIPT_DIR}/install.sh"
}

@test "rpm: OL9 defaults include UEKR8 and developer_EPEL" {
    mock_os_release "ol" "9.4"
    detect_distro_from_mock
    MIRRORET_RHEL_VERSION=9
    unset MIRRORET_RPM_REPOS
    result="$(_rpm_default_repos ol 9)"
    [[ "$result" == *"ol9_baseos_latest"* ]]
    [[ "$result" == *"ol9_appstream"* ]]
    [[ "$result" == *"ol9_UEKR8"* ]]
    [[ "$result" == *"ol9_developer_EPEL"* ]]
}

@test "rpm: OL8 defaults stay minimal (no UEK/EPEL auto-add)" {
    mock_os_release "ol" "8.9"
    detect_distro_from_mock
    unset MIRRORET_RPM_REPOS
    result="$(_rpm_default_repos ol 8)"
    [[ "$result" == *"ol8_baseos_latest"* ]]
    [[ "$result" == *"ol8_appstream"* ]]
    [[ "$result" != *"UEKR"* ]]
    [[ "$result" != *"EPEL"* ]]
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

# -- Server IP detection -------------------------------------------------------

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

# -- Cron sentinel safety ------------------------------------------------------

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

# -- SELinux helpers -----------------------------------------------------------

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

# -- Generated sync scripts: clean bash -n + honest exits ----------------------

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

@test "sync: generated docker sync script propagates failure via exit code" {
    DRY_RUN=0
    CONTAINER_CMD=docker
    write_docker_sync_script "${MIRRORET_BASE_DIR}/scripts/sync-docker-images.sh"
    # Exit codes wrap at 256, so we clamp rather than `exit $failed`.
    grep -q 'exit 1' "${MIRRORET_BASE_DIR}/scripts/sync-docker-images.sh"
    grep -q 'wrap at 256' "${MIRRORET_BASE_DIR}/scripts/sync-docker-images.sh"
}

# -- Outbound HTTPS probes: don't false-flag healthy upstreams -----------------

@test "preflight: outbound probe does NOT use curl -f (would 4xx-flag healthy upstreams)" {
    # registry-1.docker.io legitimately returns 404 at / and 401 at /v2/,
    # and auth.docker.io returns 404 at /. curl -f makes those look like
    # failures. The fix is to read the HTTP code and treat any non-000
    # response as reachable. Guard against future re-introduction of -f
    # in the outbound probe.
    source "${SCRIPT_DIR}/lib/preflight.sh"
    # The probe helper must not contain ' -f' or '--fail' on the curl line.
    run declare -f _pf_probe_https
    [ "$status" -eq 0 ]
    [[ "$output" != *' -f '* ]]
    [[ "$output" != *'--fail'* ]]
}

@test "preflight: outbound probe targets Docker /v2/, not /" {
    # If we ever probe registry-1.docker.io/ instead of /v2/, the probe
    # has to treat 404 as success - otherwise the bug we just fixed
    # comes back. Easier to just target /v2/.
    source "${SCRIPT_DIR}/lib/preflight.sh"
    run declare -f _pf_check_outbound_https
    [ "$status" -eq 0 ]
    [[ "$output" == *"registry-1.docker.io|/v2/"* ]]
}

@test "debug script: outbound probe accepts any HTTP code as reachable" {
    # mirroret-debug.sh check_outbound_https must do the same thing.
    run grep -E 'curl .* -fsS' "${SCRIPT_DIR}/scripts/mirroret-debug.sh"
    [ "$status" -ne 0 ]
    grep -q "registry-1.docker.io|/v2/" "${SCRIPT_DIR}/scripts/mirroret-debug.sh"
}

# -- Real-world fixes (from 2026-07-01 log review) ----------------------------

@test "docker: _docker_proxy_run_args emits -e HTTP_PROXY when set" {
    source "${SCRIPT_DIR}/lib/logging.sh"
    source "${SCRIPT_DIR}/lib/common.sh"
    source "${SCRIPT_DIR}/lib/docker_registry.sh"
    HTTP_PROXY="http://proxy.example:3128"
    HTTPS_PROXY="http://proxy.example:3128"
    NO_PROXY="localhost,127.0.0.1"
    result="$(_docker_proxy_run_args)"
    [[ "$result" == *"-e HTTP_PROXY=http://proxy.example:3128"* ]]
    [[ "$result" == *"-e HTTPS_PROXY=http://proxy.example:3128"* ]]
    [[ "$result" == *"-e NO_PROXY=localhost,127.0.0.1"* ]]
}

@test "docker: _docker_proxy_run_args emits nothing when no proxy env is set" {
    source "${SCRIPT_DIR}/lib/logging.sh"
    source "${SCRIPT_DIR}/lib/common.sh"
    source "${SCRIPT_DIR}/lib/docker_registry.sh"
    unset HTTP_PROXY HTTPS_PROXY NO_PROXY http_proxy https_proxy no_proxy
    result="$(_docker_proxy_run_args)"
    [ -z "${result// }" ]
}

@test "docker: _write_service_proxy_dropin writes proxy env file when proxy set" {
    source "${SCRIPT_DIR}/lib/logging.sh"
    source "${SCRIPT_DIR}/lib/common.sh"
    source "${SCRIPT_DIR}/lib/docker_registry.sh"
    HTTPS_PROXY="http://p.example:3128"
    DRY_RUN=1
    run _write_service_proxy_dropin "docker-distribution"
    [ "$status" -eq 0 ]
    [[ "$output" == *"would write /etc/systemd/system/docker-distribution.service.d/proxy.conf"* ]]
}

@test "docker: _write_service_proxy_dropin is a no-op with no proxy env" {
    source "${SCRIPT_DIR}/lib/logging.sh"
    source "${SCRIPT_DIR}/lib/common.sh"
    source "${SCRIPT_DIR}/lib/docker_registry.sh"
    unset HTTP_PROXY HTTPS_PROXY NO_PROXY http_proxy https_proxy no_proxy
    DRY_RUN=0 # even in live mode, we must not create the file.
    tmp="$(mktemp -d)"
    _write_service_proxy_dropin "docker-distribution" 2>/dev/null || true
    [ ! -d /etc/systemd/system/docker-distribution.service.d ] || \
        [ ! -f /etc/systemd/system/docker-distribution.service.d/proxy.conf ]
    rm -rf "$tmp"
}

@test "npm: Verdaccio pin logic uses verdaccio@^5 when node < 18" {
    # We can't easily run _install_verdaccio because it does real installs.
    # Assert the source contains the version-pin branch and the right
    # verdaccio spec.
    grep -q 'verdaccio@\^5' "${SCRIPT_DIR}/lib/npm.sh"
    grep -q 'node_major.*-lt.*18' "${SCRIPT_DIR}/lib/npm.sh"
}

@test "npm: MIRRORET_VERDACCIO_VERSION override is honored" {
    grep -q 'MIRRORET_VERDACCIO_VERSION' "${SCRIPT_DIR}/lib/npm.sh"
}

@test "preflight: subscription 'Simple Content Access' treated as OK" {
    grep -q 'Simple Content Access' "${SCRIPT_DIR}/lib/preflight.sh"
}

@test "preflight: subscription 'Registered' does NOT fire the dnf-will-fail warning" {
    # Regression: the old code warned "dnf install will likely fail" on
    # any status != Current, including the perfectly-normal SCA state.
    # Read the source and confirm the case-branch treats Registered as info-level.
    section="$(awk '/_pf_check_rhel_subscription/,/^}/' "${SCRIPT_DIR}/lib/preflight.sh")"
    [[ "$section" == *"Registered)"* ]]
    # And the alarming message must NOT be in the Registered branch.
    reg_branch="$(printf '%s\n' "$section" | awk '/^ Registered\)/,/;;/')"
    [[ "$reg_branch" != *"dnf install will likely fail"* ]]
}

@test "uninstall: failed labels are captured and printed in summary" {
    grep -q 'UNINST_FAILED_LABELS' "${SCRIPT_DIR}/lib/uninstall.sh"
    grep -q 'Some items failed:' "${SCRIPT_DIR}/lib/uninstall.sh"
}

@test "nginx: newly-written config is restorecon'd on SELinux hosts" {
    # Regression: on RHEL SELinux enforcing, a file created under
    # /etc/nginx/ by an unconfined process inherits etc_t which httpd_t
    # cannot read - nginx -t then fails with "Permission denied". The
    # fix is to call restorecon on the freshly-written config file.
    grep -q 'restorecon "\$conf_file"' "${SCRIPT_DIR}/lib/nginx.sh"
    # Also the TLS-append path must restorecon after appending.
    section="$(awk '/configure_nginx_unified/,/^}/' "${SCRIPT_DIR}/lib/nginx.sh")"
    [[ "$section" == *'restorecon'* ]]
}

@test "nginx: layout choice is keyed on DISTRO_TYPE, not directory existence" {
    # Regression: previously _write_nginx_config did `if [[ -d /etc/nginx/sites-available ]]`
    # to pick Debian vs RHEL style. A stale sites-available/ left over from
    # a partial install on RHEL made the code pick Debian style, then the
    # symlink step failed because sites-enabled/ didn't exist. Fix keys off
    # DISTRO_TYPE instead.
    section="$(awk '/^_write_nginx_config/,/^}/' "${SCRIPT_DIR}/lib/nginx.sh")"
    [[ "$section" == *'DISTRO_TYPE'* ]]
    # And it must NOT depend on `-d /etc/nginx/sites-available` for the choice.
    ! [[ "$section" == *'-d /etc/nginx/sites-available'*'conf_file='* ]]
}

@test "install: client-config gen is gated on DISTRO_TYPE (no cross-distro nonsense)" {
    # Regression: install.sh used to call generate_apt_client_config even
    # on RHEL, which then died in _apt_codename because OS_VER=9.8 has no
    # matching Ubuntu codename. Same in reverse for RPM on Debian.
    section="$(awk '/^generate_all_client_configs/,/^}/' "${SCRIPT_DIR}/install.sh")"
    # APT client config must be gated on DISTRO_TYPE == debian
    [[ "$section" == *'DISTRO_TYPE}" == "debian"'*'generate_apt_client_config'* ]] || \
        [[ "$section" == *'generate_apt_client_config'*'DISTRO_TYPE'* ]]
    # RPM client config must be gated on DISTRO_TYPE == rhel
    [[ "$section" == *'DISTRO_TYPE}" == "rhel"'*'generate_rpm_client_config'* ]] || \
        [[ "$section" == *'generate_rpm_client_config'*'DISTRO_TYPE'* ]]
}

# -- Sync safety guards (runaway-download incident, 2026-07-22) ----------------

@test "rpm: reposync pins arch (prevents src.rpm runaway)" {
    # A real sync pulled 44k .src.rpm files (400-600 MB each) because
    # reposync had no --arch pin. Assert the generated script pins arch.
    mock_os_release "ol" "9.4"
    detect_distro_from_mock
    MIRRORET_RHEL_VERSION=9
    DRY_RUN=0
    configure_createrepo "id"
    grep -q -- '--arch' "${MIRRORET_BASE_DIR}/scripts/sync-redhat-repos.sh"
    # One --arch per entry in ARCH, plus noarch, emitted by a loop.
    grep -q 'for _a in ${ARCH} noarch' "${MIRRORET_BASE_DIR}/scripts/sync-redhat-repos.sh"
}

@test "rpm: source RPMs default to OFF" {
    unset MIRRORET_RPM_SOURCE
    mock_os_release "ol" "9.4"
    detect_distro_from_mock
    MIRRORET_RHEL_VERSION=9
    DRY_RUN=0
    configure_createrepo "id"
    grep -q 'INCLUDE_SOURCE="0"' "${MIRRORET_BASE_DIR}/scripts/sync-redhat-repos.sh"
}

@test "rpm: newest-only defaults to ON" {
    unset MIRRORET_RPM_NEWEST_ONLY
    mock_os_release "ol" "9.4"
    detect_distro_from_mock
    MIRRORET_RHEL_VERSION=9
    DRY_RUN=0
    configure_createrepo "id"
    grep -q 'NEWEST_ONLY="1"' "${MIRRORET_BASE_DIR}/scripts/sync-redhat-repos.sh"
}

@test "rpm: sync script has a disk floor guard" {
    mock_os_release "ol" "9.4"
    detect_distro_from_mock
    MIRRORET_RHEL_VERSION=9
    DRY_RUN=0
    configure_createrepo "id"
    grep -q '_check_disk' "${MIRRORET_BASE_DIR}/scripts/sync-redhat-repos.sh"
    grep -q 'MIN_FREE_GB' "${MIRRORET_BASE_DIR}/scripts/sync-redhat-repos.sh"
}

@test "rpm: sync script takes a single-instance flock" {
    mock_os_release "ol" "9.4"
    detect_distro_from_mock
    MIRRORET_RHEL_VERSION=9
    DRY_RUN=0
    configure_createrepo "id"
    grep -q 'flock -n 9' "${MIRRORET_BASE_DIR}/scripts/sync-redhat-repos.sh"
}

@test "pip: sync script has disk guard and flock" {
    DRY_RUN=0
    _write_pip_sync_script "${MIRRORET_BASE_DIR}"
    grep -q '_check_disk' "${MIRRORET_BASE_DIR}/scripts/sync-pip-packages.sh"
    grep -q 'flock -n 9' "${MIRRORET_BASE_DIR}/scripts/sync-pip-packages.sh"
}

@test "pip: download has timeout and retry cap" {
    DRY_RUN=0
    _write_pip_sync_script "${MIRRORET_BASE_DIR}"
    grep -q -- '--timeout 60' "${MIRRORET_BASE_DIR}/scripts/sync-pip-packages.sh"
    grep -q -- '--retries 3' "${MIRRORET_BASE_DIR}/scripts/sync-pip-packages.sh"
}

@test "npm: sync script has disk guard, flock, and quiet loglevel" {
    DRY_RUN=0
    MIRRORET_APPROVAL_ENABLED=0
    MIRRORET_NPM_PORT=4873
    _write_npm_sync_script "${MIRRORET_BASE_DIR}"
    grep -q '_check_disk' "${MIRRORET_BASE_DIR}/scripts/sync-npm-packages.sh"
    grep -q 'flock -n 9' "${MIRRORET_BASE_DIR}/scripts/sync-npm-packages.sh"
    grep -q 'npm_config_loglevel=error' "${MIRRORET_BASE_DIR}/scripts/sync-npm-packages.sh"
}

@test "install: generates a logrotate config" {
    grep -q 'write_logrotate_config' "${SCRIPT_DIR}/install.sh"
    grep -q '/etc/logrotate.d/mirroret' "${SCRIPT_DIR}/install.sh"
}

@test "uninstall: removes logrotate config and stale sync locks" {
    grep -q '/etc/logrotate.d/mirroret' "${SCRIPT_DIR}/lib/uninstall.sh"
    grep -q 'mirroret-sync-redhat.lock' "${SCRIPT_DIR}/lib/uninstall.sh"
}

@test "config example documents the sync-safety knobs" {
    for v in MIRRORET_RPM_ARCH MIRRORET_RPM_NEWEST_ONLY MIRRORET_RPM_SOURCE \
             MIRRORET_RPM_DELETE MIRRORET_SYNC_MIN_FREE_GB; do
        grep -q "$v" "${SCRIPT_DIR}/config/mirroret.conf.example"
    done
}

# -- Audit round 2 (2026-07-22 full-repo audit) --------------------------------

@test "nginx: logs and scripts dirs are denied over HTTP" {
    grep -q 'logs|scripts|staging' "${SCRIPT_DIR}/lib/nginx.sh"
    grep -q 'deny all' "${SCRIPT_DIR}/lib/nginx.sh"
}

@test "nginx: alias locations use matching trailing slashes" {
    grep -q 'location /redhat/ {' "${SCRIPT_DIR}/lib/nginx.sh"
    grep -q 'location /ubuntu/ {' "${SCRIPT_DIR}/lib/nginx.sh"
}

@test "common: script preamble sources conf and exports proxy" {
    source "${SCRIPT_DIR}/lib/common.sh"
    out="$(mirroret_script_preamble)"
    [[ "$out" == *"/etc/mirroret/mirroret.conf"* ]]
    [[ "$out" == *"https_proxy"* ]]
    [[ "$out" == *"NODE_EXTRA_CA_CERTS"* ]]
    [[ "$out" == *"PIP_CERT"* ]]
}

@test "rpm: generated sync script carries the runtime preamble" {
    mock_os_release "ol" "9.4"; detect_distro_from_mock
    MIRRORET_RHEL_VERSION=9; DRY_RUN=0
    configure_createrepo "id"
    grep -q '/etc/mirroret/mirroret.conf' "${MIRRORET_BASE_DIR}/scripts/sync-redhat-repos.sh"
}

@test "rpm: reposync runs under a wall-clock timeout" {
    mock_os_release "ol" "9.4"; detect_distro_from_mock
    MIRRORET_RHEL_VERSION=9; DRY_RUN=0
    configure_createrepo "id"
    grep -q 'timeout -k 60' "${MIRRORET_BASE_DIR}/scripts/sync-redhat-repos.sh"
    grep -q 'setopt=timeout=60' "${MIRRORET_BASE_DIR}/scripts/sync-redhat-repos.sh"
}

@test "rpm: createrepo does not clobber upstream metadata on a FULL mirror" {
    # Original intent: rebuilding destroys repomd.xml.asc and breaks any
    # client using repo_gpgcheck=1. That still holds, but only for an
    # unfiltered mirror. With --newest-only or an --arch filter the upstream
    # metadata describes packages this mirror does not have, so it must be
    # rebuilt or clients get 404 and "no match".
    mock_os_release "ol" "9.4"; detect_distro_from_mock
    MIRRORET_RHEL_VERSION=9; DRY_RUN=0
    configure_createrepo "id"
    s="${MIRRORET_BASE_DIR}/scripts/sync-redhat-repos.sh"
    grep -q 'keeping upstream signed metadata' "$s"
    # The keep branch must be reachable, i.e. gated rather than removed.
    grep -q 'REBUILD_METADATA=0' "$s"
}

@test "rpm: OL client config points gpgkey at the Oracle vendor key" {
    mock_os_release "ol" "9.4"; detect_distro_from_mock
    MIRRORET_RHEL_VERSION=9
    MIRRORET_RPM_INSECURE=0
    unset MIRRORET_RPM_GPGKEY_URL
    DRY_RUN=0
    generate_rpm_client_config "${TMPDIR}/ol.repo"
    grep -q 'gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-oracle' "${TMPDIR}/ol.repo"
    run grep -c '^# gpgkey=' "${TMPDIR}/ol.repo"
    [ "$output" = "0" ]
}

@test "rpm: client config tells operators to disable upstream repos" {
    mock_os_release "ol" "9.4"; detect_distro_from_mock
    MIRRORET_RHEL_VERSION=9; MIRRORET_RPM_INSECURE=1; DRY_RUN=0
    generate_rpm_client_config "${TMPDIR}/ol.repo"
    grep -q 'config-manager --disable' "${TMPDIR}/ol.repo"
}

@test "pip: download uses --no-cache-dir (root fs is not the guarded volume)" {
    DRY_RUN=0
    _write_pip_sync_script "${MIRRORET_BASE_DIR}"
    grep -q -- '--no-cache-dir' "${MIRRORET_BASE_DIR}/scripts/sync-pip-packages.sh"
}

@test "npm: republish conflict is not counted as a failure" {
    DRY_RUN=0
    MIRRORET_APPROVAL_ENABLED=0
    MIRRORET_NPM_ALLOW_ANON_PUBLISH=1
    MIRRORET_NPM_PORT=4873
    _write_npm_sync_script "${MIRRORET_BASE_DIR}"
    grep -q 'ALREADY PRESENT' "${MIRRORET_BASE_DIR}/scripts/sync-npm-packages.sh"
    grep -q 'EPUBLISHCONFLICT' "${MIRRORET_BASE_DIR}/scripts/sync-npm-packages.sh"
}

@test "npm: verdaccio unit sets a writable HOME" {
    grep -q 'HOME=' "${SCRIPT_DIR}/lib/npm.sh"
    grep -q 'crash-loops' "${SCRIPT_DIR}/lib/npm.sh"
}

@test "docker: registry config enables delete (required for GC)" {
    MIRRORET_DOCKER_MODE=hosted
    _emit_registry_config "${TMPDIR}/config.yml"
    grep -q -A1 'delete:' "${TMPDIR}/config.yml"
    grep -q 'enabled: true' "${TMPDIR}/config.yml"
}

@test "docker: sync script clamps exit code (256 must not become 0)" {
    grep -q 'exit codes wrap at 256' "${SCRIPT_DIR}/lib/docker_registry.sh"
}

@test "install: cleanup-all takes the sync locks before pruning" {
    grep -q 'mirroret-sync-\\${_lk}.lock' "${SCRIPT_DIR}/install.sh" || \
        grep -q 'Cleanup deferred' "${SCRIPT_DIR}/install.sh"
}

@test "install: cleanup-all age-deletes old logs" {
    grep -q 'MIRRORET_LOG_KEEP_DAYS' "${SCRIPT_DIR}/install.sh"
}

@test "install: seeds /etc/mirroret/mirroret.conf on first install" {
    grep -q 'Seeded /etc/mirroret/mirroret.conf' "${SCRIPT_DIR}/install.sh"
}

@test "validation: RPM metadata check looks at redhat/mirror not approved" {
    section="$(awk '/_check_repo_metadata/,/^}/' "${SCRIPT_DIR}/lib/validation.sh")"
    [[ "$section" == *'redhat/mirror'* ]]
}

@test "config example documents proxy, CA bundle, timeout, log retention" {
    for v in MIRRORET_CA_BUNDLE MIRRORET_SYNC_TIMEOUT MIRRORET_LOG_KEEP_DAYS https_proxy; do
        grep -q "$v" "${SCRIPT_DIR}/config/mirroret.conf.example"
    done
}

# ============ heredoc command substitution + multi-arch ============

@test "no backticks inside expanding heredocs (bash would execute them)" {
    # A backtick in an unquoted heredoc is command substitution. A comment
    # reading `registry garbage-collect` made bash try to run `registry`,
    # producing "command not found" and exit 127 mid-install.
    run python3 - "${SCRIPT_DIR}" <<'PY'
import re, sys, os
root = sys.argv[1]
targets = ['install.sh','uninstall.sh','mirroretctl','scripts/mirroret-debug.sh']
targets += ['lib/'+f for f in os.listdir(os.path.join(root,'lib')) if f.endswith('.sh')]
bad = []
for rel in targets:
    p = os.path.join(root, rel)
    if not os.path.isfile(p):
        continue
    delim = None; quoted = False
    for i, ln in enumerate(open(p).read().split('\n'), 1):
        if delim is None:
            m = re.search(r'<<-?\s*(["\']?)([A-Za-z_][A-Za-z_0-9]*)\1\s*$', ln)
            if m:
                quoted = bool(m.group(1)); delim = m.group(2)
            continue
        if ln.strip() == delim:
            delim = None; continue
        if not quoted and '`' in ln and '\\`' not in ln:
            bad.append(f"{rel}:{i}")
print('\n'.join(bad))
sys.exit(1 if bad else 0)
PY
    [ "$status" -eq 0 ]
}

@test "rpm: MIRRORET_RPM_ARCH accepts a space-separated list" {
    mock_os_release "ol" "9.8"; detect_distro_from_mock
    MIRRORET_RHEL_VERSION=9
    MIRRORET_RPM_ARCH="x86_64 i686"
    DRY_RUN=0
    configure_createrepo "id"
    s="${MIRRORET_BASE_DIR}/scripts/sync-redhat-repos.sh"
    grep -q 'ARCH="x86_64 i686"' "$s"
    # One --arch per requested arch, plus noarch, built in a loop.
    grep -q 'for _a in ${ARCH} noarch' "$s"
    bash -n "$s"
}

@test "rpm: noarch is always added even with a single arch" {
    mock_os_release "ol" "9.8"; detect_distro_from_mock
    MIRRORET_RHEL_VERSION=9
    MIRRORET_RPM_ARCH="x86_64"
    DRY_RUN=0
    configure_createrepo "id"
    grep -q 'for _a in ${ARCH} noarch' "${MIRRORET_BASE_DIR}/scripts/sync-redhat-repos.sh"
}

@test "rpm: install notes that i686 is missing when only x86_64 requested" {
    mock_os_release "ol" "9.8"; detect_distro_from_mock
    MIRRORET_RHEL_VERSION=9
    MIRRORET_RPM_ARCH="x86_64"
    DRY_RUN=1
    run configure_createrepo "id"
    [[ "$output" == *"i686 is not mirrored"* ]]
}

@test "rpm: no multilib note when i686 already requested" {
    mock_os_release "ol" "9.8"; detect_distro_from_mock
    MIRRORET_RHEL_VERSION=9
    MIRRORET_RPM_ARCH="x86_64 i686"
    DRY_RUN=1
    run configure_createrepo "id"
    [[ "$output" != *"i686 is not mirrored"* ]]
}

@test "docker: registry config comment does not trigger command substitution" {
    MIRRORET_DOCKER_MODE=cache
    run _emit_registry_config "${TMPDIR}/reg.yml"
    [ "$status" -eq 0 ]
    [[ "$output" != *"command not found"* ]]
    grep -q "'registry garbage-collect'" "${TMPDIR}/reg.yml"
    grep -q 'enabled: true' "${TMPDIR}/reg.yml"
}

@test "backup: list_backups returns 0 when backups exist" {
    # Same trailing-&& bug class as cmd_sync_status: with found=1 the
    # `[[ $found == 0 ]]` test is false and the function returned 1.
    mkdir -p "${MIRRORET_BACKUP_BASE}/20260101-000000"
    printf '/etc/nginx/nginx.conf\n' > "${MIRRORET_BACKUP_BASE}/20260101-000000/backup.manifest"
    run list_backups
    [ "$status" -eq 0 ]
    [[ "$output" == *"20260101-000000"* ]]
}

@test "backup: list_backups returns 0 when no backups exist" {
    rm -rf "${MIRRORET_BACKUP_BASE}"
    mkdir -p "${MIRRORET_BACKUP_BASE}"
    run list_backups
    [ "$status" -eq 0 ]
}

@test "rpm: repoquery gets a comma-separated arch list, not spaces" {
    # reposync takes repeated --arch flags; dnf repoquery takes ONE comma
    # list. Passing "x86_64 i686,noarch" makes the argument invalid, so
    # repoquery returns nothing and the pre-sync size estimate reads 0,
    # which silently defeats the disk guard.
    mock_os_release "ol" "9.8"; detect_distro_from_mock
    MIRRORET_RHEL_VERSION=9
    MIRRORET_RPM_ARCH="x86_64 i686"
    DRY_RUN=0
    configure_createrepo "id"
    s="${MIRRORET_BASE_DIR}/scripts/sync-redhat-repos.sh"
    grep -q 'ARCH_CSV="${ARCH// /,}"' "$s"
    grep -q 'repoquery .*--arch="${ARCH_CSV},noarch"' "$s"
    # The space-separated form must not reach repoquery.
    ! grep -q 'repoquery .*--arch="${ARCH},noarch"' "$s"
}

@test "rpm: ARCH_CSV collapses a multi-arch list correctly" {
    ARCH="x86_64 i686"; ARCH_CSV="${ARCH// /,}"
    [ "$ARCH_CSV" = "x86_64,i686" ]
    ARCH="x86_64"; ARCH_CSV="${ARCH// /,}"
    [ "$ARCH_CSV" = "x86_64" ]
}

@test "rpm: generated script builds one --arch flag per architecture" {
    mock_os_release "ol" "9.8"; detect_distro_from_mock
    MIRRORET_RHEL_VERSION=9
    MIRRORET_RPM_ARCH="x86_64 i686"
    DRY_RUN=0
    configure_createrepo "id"
    s="${MIRRORET_BASE_DIR}/scripts/sync-redhat-repos.sh"
    # Execute the real arg-building block from the generated file.
    sed -n '/^ARCH=/p;/^REPOSYNC_ARGS=(/,/^done$/p' "$s" > "${TMPDIR}/block.sh"
    run bash -c "set -Eeuo pipefail; source '${TMPDIR}/block.sh'; printf '%s' \"\${REPOSYNC_ARGS[*]}\""
    [ "$status" -eq 0 ]
    [[ "$output" == *"--arch x86_64 --arch i686 --arch noarch"* ]]
}

# -- Metadata must match what is on disk ----------------------------------------

@test "rpm: filtered mirror rebuilds metadata instead of keeping upstream" {
    # Upstream metadata describes the whole upstream repo. With --newest-only
    # or an --arch filter the mirror holds a subset, so clients resolve
    # against packages that were never downloaded and get 404 or "no match".
    mock_os_release "ol" "9.8"; detect_distro_from_mock
    MIRRORET_RHEL_VERSION=9
    MIRRORET_RPM_ARCH="x86_64 i686"
    MIRRORET_RPM_NEWEST_ONLY=1
    DRY_RUN=0
    configure_createrepo "id"
    s="${MIRRORET_BASE_DIR}/scripts/sync-redhat-repos.sh"
    grep -q 'ARCH_FILTERED=1' "$s"
    grep -q 'REBUILD_METADATA=1' "$s"
    grep -q 'filtered mirror: metadata must match disk' "$s"
    bash -n "$s"
}

@test "rpm: full mirror keeps upstream signed metadata" {
    mock_os_release "ol" "9.8"; detect_distro_from_mock
    MIRRORET_RHEL_VERSION=9
    DRY_RUN=0
    configure_createrepo "id"
    s="${MIRRORET_BASE_DIR}/scripts/sync-redhat-repos.sh"
    # The keep-upstream branch must still exist for an unfiltered mirror,
    # since rebuilding would destroy repomd.xml.asc and break repo_gpgcheck=1.
    grep -q 'full mirror, keeping upstream signed metadata' "$s"
    grep -q 'MIRRORET_RPM_KEEP_UPSTREAM_METADATA' "$s"
}

@test "rpm: metadata rebuild decision evaluates correctly" {
    run bash -c 'NEWEST_ONLY=1; ARCH_FILTERED=1
        if [[ "$NEWEST_ONLY" == "1" ]] || [[ "$ARCH_FILTERED" == "1" ]]; then echo REBUILD; else echo KEEP; fi'
    [ "$output" = "REBUILD" ]
    run bash -c 'NEWEST_ONLY=0; ARCH_FILTERED=0
        if [[ "$NEWEST_ONLY" == "1" ]] || [[ "$ARCH_FILTERED" == "1" ]]; then echo REBUILD; else echo KEEP; fi'
    [ "$output" = "KEEP" ]
}

@test "rpm: createrepo uses --update when metadata already exists" {
    mock_os_release "ol" "9.8"; detect_distro_from_mock
    MIRRORET_RHEL_VERSION=9
    DRY_RUN=0
    configure_createrepo "id"
    # A full rebuild every night on a 27k-package repo is hours of CPU.
    grep -q 'CR_ARGS+=(--update)' "${MIRRORET_BASE_DIR}/scripts/sync-redhat-repos.sh"
}

# -- Verdaccio bind address -----------------------------------------------------

@test "npm: verdaccio listens on a routable address, not a bare port" {
    # "--listen 4873" binds localhost, which resolves to [::1] on a
    # dual-stack host: the registry answers on the server and refuses every
    # client host.
    grep -q -- '--listen ${npm_bind}:${npm_port}' "${SCRIPT_DIR}/lib/npm.sh"
    ! grep -q -- '--listen ${npm_port}$' "${SCRIPT_DIR}/lib/npm.sh"
}

@test "npm: bind address defaults to 0.0.0.0 and is overridable" {
    grep -q 'MIRRORET_NPM_BIND_ADDR="${MIRRORET_NPM_BIND_ADDR:-0.0.0.0}"' "${SCRIPT_DIR}/lib/npm.sh"
}

@test "npm: verdaccio config.yaml also carries an explicit listen host" {
    # A manual verdaccio run must behave the same as the unit.
    grep -qE '^listen: \$\{MIRRORET_NPM_BIND_ADDR:-0\.0\.0\.0\}:\$\{npm_port\}' "${SCRIPT_DIR}/lib/npm.sh"
}
@test "rpm: approval mode stages outside the served mirror tree" {
    mock_os_release "ol" "9.8"; detect_distro_from_mock
    MIRRORET_RHEL_VERSION=9
    MIRRORET_APPROVAL_ENABLED=1
    DRY_RUN=0
    configure_createrepo "id"
    s="${MIRRORET_BASE_DIR}/scripts/sync-redhat-repos.sh"
    grep -q 'REPO_BASE=.*/redhat/staging' "$s"
    grep -q 'APPROVAL_MODE="1"' "$s"
    bash -n "$s"
}

@test "rpm: non-approval mode still syncs straight into the mirror tree" {
    mock_os_release "ol" "9.8"; detect_distro_from_mock
    MIRRORET_RHEL_VERSION=9
    MIRRORET_APPROVAL_ENABLED=0
    DRY_RUN=0
    configure_createrepo "id"
    s="${MIRRORET_BASE_DIR}/scripts/sync-redhat-repos.sh"
    grep -q 'REPO_BASE=.*/redhat/mirror' "$s"
    grep -q 'APPROVAL_MODE="0"' "$s"
}

@test "rpm: approval-mode sync still reports reposync failure (no masked exit 0)" {
    mock_os_release "ol" "9.8"; detect_distro_from_mock
    MIRRORET_RHEL_VERSION=9
    MIRRORET_APPROVAL_ENABLED=1
    DRY_RUN=0
    configure_createrepo "id"
    s="${MIRRORET_BASE_DIR}/scripts/sync-redhat-repos.sh"
    # The early-exit branch must consult sync_failed/aborted before exiting.
    grep -q 'sync_failed + aborted' "$s"
}

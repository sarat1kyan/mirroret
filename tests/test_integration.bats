#!/usr/bin/env bats
# Integration tests for mirroret new features.
# No real server, no internet access required.
# Tests cover: config variables, new lib functions, install.sh CLI flags,
# mode selection, sync script generation, approval workflow, TLS/GPG stubs.

load 'test_helpers'

# ── Setup / Teardown ─────────────────────────────────────────────────────────

setup() {
    load_lib
    # Source the new libs.
    source "${SCRIPT_DIR}/lib/tls.sh"
    source "${SCRIPT_DIR}/lib/gpg.sh"
    source "${SCRIPT_DIR}/lib/approval.sh"
    source "${SCRIPT_DIR}/lib/apt.sh"
    source "${SCRIPT_DIR}/lib/nginx.sh"
    source "${SCRIPT_DIR}/lib/npm.sh"
    source "${SCRIPT_DIR}/lib/pip.sh"
    source "${SCRIPT_DIR}/lib/docker_registry.sh"

    TMPDIR="$(mktemp -d)"
    MIRRORET_BASE_DIR="${TMPDIR}/mirroret"
    export MIRRORET_BASE_DIR DRY_RUN=1 MIRRORET_SERVER_IP=127.0.0.1
    mkdir -p "${MIRRORET_BASE_DIR}"
}

teardown() {
    rm -rf "${TMPDIR:-/tmp/bats-integration-$$}"
}

# ── TLS default variables ─────────────────────────────────────────────────────

@test "tls: MIRRORET_TLS_ENABLED defaults to 0" {
    [[ "${MIRRORET_TLS_ENABLED:-0}" == "0" ]]
}

@test "tls: MIRRORET_TLS_PORT defaults to 8443" {
    [[ "${MIRRORET_TLS_PORT}" == "8443" ]]
}

@test "tls: MIRRORET_TLS_SELF_SIGNED defaults to 0" {
    [[ "${MIRRORET_TLS_SELF_SIGNED}" == "0" ]]
}

@test "tls: is_tls_ready returns false when TLS not configured" {
    MIRRORET_TLS_ENABLED=0
    ! is_tls_ready
}

@test "tls: is_tls_ready returns true when cert and key are set" {
    MIRRORET_TLS_ENABLED=1
    MIRRORET_TLS_CERT="/etc/ssl/certs/test.crt"
    MIRRORET_TLS_KEY="/etc/ssl/private/test.key"
    is_tls_ready
}

@test "tls: setup_tls with no config dies with clear message" {
    MIRRORET_TLS_SELF_SIGNED=0
    MIRRORET_TLS_CERT=""
    MIRRORET_TLS_KEY=""
    run setup_tls
    [[ "${status}" -ne 0 ]]
    [[ "${output}" =~ "no cert/key" || "${output}" =~ "MIRRORET_TLS_SELF_SIGNED" ]]
}

@test "tls: dry-run self-signed sets MIRRORET_TLS_CERT without writing files" {
    MIRRORET_TLS_SELF_SIGNED=1
    DRY_RUN=1
    run setup_tls
    [[ "${status}" -eq 0 ]]
    # No real file should be created.
    [[ ! -f "${MIRRORET_TLS_DIR:-/etc/mirroret/tls}/cert.pem" ]]
}

@test "tls: tls_nginx_server_block contains ssl_certificate directive" {
    MIRRORET_TLS_CERT="/etc/ssl/certs/test.crt"
    MIRRORET_TLS_KEY="/etc/ssl/private/test.key"
    run tls_nginx_server_block "" "mirroret-test"
    [[ "${status}" -eq 0 ]]
    [[ "${output}" =~ "ssl_certificate" ]]
}

@test "tls: tls_nginx_server_block uses MIRRORET_TLS_PORT" {
    MIRRORET_TLS_PORT=9443
    MIRRORET_TLS_CERT="/etc/ssl/certs/test.crt"
    MIRRORET_TLS_KEY="/etc/ssl/private/test.key"
    run tls_nginx_server_block "" "mirroret-test"
    [[ "${output}" =~ "9443" ]]
}

# ── GPG default variables ─────────────────────────────────────────────────────

@test "gpg: MIRRORET_GPG_AUTO defaults to 0" {
    [[ "${MIRRORET_GPG_AUTO}" == "0" ]]
}

@test "gpg: MIRRORET_GPG_HOMEDIR defaults to /etc/mirroret/gnupg" {
    [[ "${MIRRORET_GPG_HOMEDIR}" == "/etc/mirroret/gnupg" ]]
}

@test "gpg: write_gpg_client_instructions creates a script file" {
    DRY_RUN=0
    local out_file="${TMPDIR}/import-key.sh"
    write_gpg_client_instructions "${out_file}"
    [[ -f "${out_file}" ]]
    [[ -x "${out_file}" ]]
}

@test "gpg: client import script contains apt-get block" {
    DRY_RUN=0
    local out_file="${TMPDIR}/import-key.sh"
    write_gpg_client_instructions "${out_file}"
    grep -q "apt-get" "${out_file}"
}

@test "gpg: client import script contains rpm --import block" {
    DRY_RUN=0
    local out_file="${TMPDIR}/import-key.sh"
    write_gpg_client_instructions "${out_file}"
    grep -q "rpm --import" "${out_file}"
}

# ── Approval workflow ─────────────────────────────────────────────────────────

@test "approval: MIRRORET_APPROVAL_ENABLED defaults to 0" {
    [[ "${MIRRORET_APPROVAL_ENABLED:-0}" == "0" ]]
}

@test "approval: ensure_approval_dirs is a no-op when disabled" {
    MIRRORET_APPROVAL_ENABLED=0
    DRY_RUN=0
    ensure_approval_dirs
    [[ ! -d "${MIRRORET_BASE_DIR}/staging/pip" ]]
}

@test "approval: ensure_approval_dirs creates staging/pip when enabled" {
    MIRRORET_APPROVAL_ENABLED=1
    DRY_RUN=0
    ensure_approval_dirs
    [[ -d "${MIRRORET_BASE_DIR}/staging/pip" ]]
}

@test "approval: ensure_approval_dirs creates staging/npm when enabled" {
    MIRRORET_APPROVAL_ENABLED=1
    DRY_RUN=0
    ensure_approval_dirs
    [[ -d "${MIRRORET_BASE_DIR}/staging/npm" ]]
}

@test "approval: list_staging reports nothing when dirs are empty" {
    DRY_RUN=0
    mkdir -p "${MIRRORET_BASE_DIR}/staging/pip" "${MIRRORET_BASE_DIR}/staging/npm"
    run list_staging
    [[ "${status}" -eq 0 ]]
    [[ "${output}" =~ "no packages in staging" ]]
}

@test "approval: approve_all_pip moves whl from staging to approved" {
    DRY_RUN=0
    mkdir -p "${MIRRORET_BASE_DIR}/staging/pip" "${MIRRORET_BASE_DIR}/approved/pip"
    touch "${MIRRORET_BASE_DIR}/staging/pip/requests-2.31.0-py3-none-any.whl"
    approve_all_pip
    [[ -f "${MIRRORET_BASE_DIR}/approved/pip/requests-2.31.0-py3-none-any.whl" ]]
    [[ ! -f "${MIRRORET_BASE_DIR}/staging/pip/requests-2.31.0-py3-none-any.whl" ]]
}

@test "approval: approve_pip_package promotes matched package" {
    DRY_RUN=0
    mkdir -p "${MIRRORET_BASE_DIR}/staging/pip" "${MIRRORET_BASE_DIR}/approved/pip"
    touch "${MIRRORET_BASE_DIR}/staging/pip/flask-3.0.0-py3-none-any.whl"
    approve_pip_package "flask"
    [[ -f "${MIRRORET_BASE_DIR}/approved/pip/flask-3.0.0-py3-none-any.whl" ]]
}

@test "approval: exclude_pip_package removes staged package" {
    DRY_RUN=0
    mkdir -p "${MIRRORET_BASE_DIR}/staging/pip"
    touch "${MIRRORET_BASE_DIR}/staging/pip/badpkg-1.0-py3-none-any.whl"
    exclude_pip_package "badpkg"
    [[ ! -f "${MIRRORET_BASE_DIR}/staging/pip/badpkg-1.0-py3-none-any.whl" ]]
}

@test "approval: approve_all_npm moves tgz from staging to approved" {
    DRY_RUN=0
    mkdir -p "${MIRRORET_BASE_DIR}/staging/npm" "${MIRRORET_BASE_DIR}/approved/npm"
    touch "${MIRRORET_BASE_DIR}/staging/npm/express-4.18.2.tgz"
    approve_all_npm
    [[ -f "${MIRRORET_BASE_DIR}/approved/npm/express-4.18.2.tgz" ]]
}

@test "approval: exclude_npm_package removes staged tarball" {
    DRY_RUN=0
    mkdir -p "${MIRRORET_BASE_DIR}/staging/npm"
    touch "${MIRRORET_BASE_DIR}/staging/npm/badpkg-1.0.0.tgz"
    exclude_npm_package "badpkg"
    [[ ! -f "${MIRRORET_BASE_DIR}/staging/npm/badpkg-1.0.0.tgz" ]]
}

@test "approval: approve_all_pip dry-run does not move files" {
    DRY_RUN=1
    mkdir -p "${MIRRORET_BASE_DIR}/staging/pip"
    touch "${MIRRORET_BASE_DIR}/staging/pip/testpkg-1.0-py3-none-any.whl"
    approve_all_pip
    [[ -f "${MIRRORET_BASE_DIR}/staging/pip/testpkg-1.0-py3-none-any.whl" ]]
}

# ── APT mirror tool selection ──────────────────────────────────────────────────

@test "apt: MIRRORET_APT_MIRROR_TOOL defaults to auto" {
    [[ "${MIRRORET_APT_MIRROR_TOOL}" == "auto" ]]
}

@test "apt: _apt_resolve_tool debmirror returns debmirror" {
    run _apt_resolve_tool "debmirror"
    [[ "${status}" -eq 0 ]]
    [[ "${output}" == "debmirror" ]]
}

@test "apt: _apt_resolve_tool unknown value dies" {
    run _apt_resolve_tool "nonexistent-tool"
    [[ "${status}" -ne 0 ]]
}

# ── Docker backend ────────────────────────────────────────────────────────────

@test "docker: MIRRORET_DOCKER_BACKEND defaults to auto" {
    [[ "${MIRRORET_DOCKER_BACKEND}" == "auto" ]]
}

@test "docker: write_docker_sync_script dry-run does not create file" {
    DRY_RUN=1
    run write_docker_sync_script "${TMPDIR}/sync-docker.sh"
    [[ "${status}" -eq 0 ]]
    [[ ! -f "${TMPDIR}/sync-docker.sh" ]]
}

@test "docker: write_docker_sync_script creates executable script in non-dry-run" {
    DRY_RUN=0
    mkdir -p "${MIRRORET_BASE_DIR}/scripts"
    MIRRORET_DOCKER_REGISTRY_PORT=5000
    CONTAINER_CMD=docker
    write_docker_sync_script "${TMPDIR}/sync-docker.sh"
    [[ -f "${TMPDIR}/sync-docker.sh" ]]
    [[ -x "${TMPDIR}/sync-docker.sh" ]]
}

@test "docker: sync script contains default images when no file given" {
    DRY_RUN=0
    mkdir -p "${MIRRORET_BASE_DIR}/scripts"
    MIRRORET_DOCKER_REGISTRY_PORT=5000
    CONTAINER_CMD=docker
    MIRRORET_DOCKER_IMAGES_FILE=""
    write_docker_sync_script "${TMPDIR}/sync-docker.sh"
    grep -q "ubuntu:22.04" "${TMPDIR}/sync-docker.sh"
}

@test "docker: sync script uses custom image file when provided" {
    DRY_RUN=0
    mkdir -p "${MIRRORET_BASE_DIR}/scripts"
    MIRRORET_DOCKER_REGISTRY_PORT=5000
    CONTAINER_CMD=docker
    local img_file="${TMPDIR}/images.txt"
    printf "myorg/myimage:1.0\n# comment\n" > "${img_file}"
    MIRRORET_DOCKER_IMAGES_FILE="${img_file}"
    write_docker_sync_script "${TMPDIR}/sync-docker-custom.sh"
    grep -q "myorg/myimage:1.0" "${TMPDIR}/sync-docker-custom.sh"
}

# ── npm sync script ───────────────────────────────────────────────────────────

@test "npm: MIRRORET_NPM_ALLOW_ANON_PUBLISH defaults to 0" {
    [[ "${MIRRORET_NPM_ALLOW_ANON_PUBLISH}" == "0" ]]
}

@test "npm: sync script uses staging dir when approval enabled" {
    DRY_RUN=0
    MIRRORET_APPROVAL_ENABLED=1
    MIRRORET_NPM_PORT=4873
    mkdir -p "${MIRRORET_BASE_DIR}/scripts"
    _write_npm_sync_script "${MIRRORET_BASE_DIR}"
    grep -q "staging/npm" "${MIRRORET_BASE_DIR}/scripts/sync-npm-packages.sh"
}

@test "npm: sync script contains auto-publish block when anon publish enabled" {
    DRY_RUN=0
    MIRRORET_APPROVAL_ENABLED=0
    MIRRORET_NPM_ALLOW_ANON_PUBLISH=1
    MIRRORET_NPM_PORT=4873
    mkdir -p "${MIRRORET_BASE_DIR}/scripts"
    _write_npm_sync_script "${MIRRORET_BASE_DIR}"
    grep -q "npm publish" "${MIRRORET_BASE_DIR}/scripts/sync-npm-packages.sh"
}

# ── pip sync script ───────────────────────────────────────────────────────────

@test "pip: sync script targets staging when approval enabled" {
    DRY_RUN=0
    MIRRORET_APPROVAL_ENABLED=1
    MIRRORET_PIP_PORT=8081
    mkdir -p "${MIRRORET_BASE_DIR}/scripts"
    _write_pip_sync_script "${MIRRORET_BASE_DIR}"
    grep -q "staging/pip" "${MIRRORET_BASE_DIR}/scripts/sync-pip-packages.sh"
}

@test "pip: sync script targets approved directly when approval disabled" {
    DRY_RUN=0
    MIRRORET_APPROVAL_ENABLED=0
    MIRRORET_PIP_PORT=8081
    mkdir -p "${MIRRORET_BASE_DIR}/scripts"
    _write_pip_sync_script "${MIRRORET_BASE_DIR}"
    grep -q "pip/approved" "${MIRRORET_BASE_DIR}/scripts/sync-pip-packages.sh"
}

# ── install.sh new CLI flags ──────────────────────────────────────────────────

@test "install.sh --tls-self-signed is accepted without error" {
    run bash "${SCRIPT_DIR}/install.sh" --tls-self-signed --help
    [[ "${status}" -eq 0 ]]
}

@test "install.sh --gpg-auto is accepted without error" {
    run bash "${SCRIPT_DIR}/install.sh" --gpg-auto --help
    [[ "${status}" -eq 0 ]]
}

@test "install.sh --approval-mode is accepted without error" {
    run bash "${SCRIPT_DIR}/install.sh" --approval-mode --help
    [[ "${status}" -eq 0 ]]
}

@test "install.sh --list-staging exits 0 (no root needed)" {
    MIRRORET_BASE_DIR="${TMPDIR}/mirroret"
    mkdir -p "${MIRRORET_BASE_DIR}/staging/pip" "${MIRRORET_BASE_DIR}/staging/npm"
    run bash -c "MIRRORET_BASE_DIR='${MIRRORET_BASE_DIR}' bash '${SCRIPT_DIR}/install.sh' --list-staging"
    [[ "${status}" -eq 0 ]]
}

@test "install.sh --help mentions --tls-self-signed" {
    run bash "${SCRIPT_DIR}/install.sh" --help
    [[ "${output}" =~ "--tls-self-signed" ]]
}

@test "install.sh --help mentions --gpg-auto" {
    run bash "${SCRIPT_DIR}/install.sh" --help
    [[ "${output}" =~ "--gpg-auto" ]]
}

@test "install.sh --help mentions --approval-mode" {
    run bash "${SCRIPT_DIR}/install.sh" --help
    [[ "${output}" =~ "--approval-mode" ]]
}

@test "install.sh --help mentions --approve-all-pip" {
    run bash "${SCRIPT_DIR}/install.sh" --help
    [[ "${output}" =~ "--approve-all-pip" ]]
}

# ── config example validity ───────────────────────────────────────────────────

@test "config example: new TLS variables have valid bash syntax" {
    run bash -n "${SCRIPT_DIR}/config/mirroret.conf.example"
    [[ "${status}" -eq 0 ]]
}

@test "config example: MIRRORET_TLS_SELF_SIGNED is documented" {
    grep -q "MIRRORET_TLS_SELF_SIGNED" "${SCRIPT_DIR}/config/mirroret.conf.example"
}

@test "config example: MIRRORET_GPG_AUTO is documented" {
    grep -q "MIRRORET_GPG_AUTO" "${SCRIPT_DIR}/config/mirroret.conf.example"
}

@test "config example: MIRRORET_APPROVAL_ENABLED is documented" {
    grep -q "MIRRORET_APPROVAL_ENABLED" "${SCRIPT_DIR}/config/mirroret.conf.example"
}

@test "config example: MIRRORET_DOCKER_BACKEND is documented" {
    grep -q "MIRRORET_DOCKER_BACKEND" "${SCRIPT_DIR}/config/mirroret.conf.example"
}

@test "config example: MIRRORET_APT_MIRROR_TOOL is documented" {
    grep -q "MIRRORET_APT_MIRROR_TOOL" "${SCRIPT_DIR}/config/mirroret.conf.example"
}

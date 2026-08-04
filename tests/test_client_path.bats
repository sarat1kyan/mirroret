#!/usr/bin/env bats
# End-to-end client path tests.
#
# The single most important property of this tool: a client host must be able
# to fetch packages from the server. That requires three independently
# generated things to agree on one path:
#
#   1. where the sync script writes packages on disk
#   2. what nginx maps a URL prefix onto
#   3. what baseurl the generated client config asks for
#
# Any one of those drifting breaks every client at once, and unit tests on
# each piece in isolation will not catch it. These tests serve the real tree
# over HTTP and fetch the exact URLs from the generated client config.

load 'test_helpers'

setup() {
    load_distro_lib
    TMPDIR="$(mktemp -d)"
    MIRRORET_BASE_DIR="${TMPDIR}/srv"
    MIRRORET_BACKUP_BASE="${TMPDIR}/bk"
    export MIRRORET_BACKUP_BASE
    mkdir -p "${MIRRORET_BASE_DIR}"/{scripts,config} "${MIRRORET_BACKUP_BASE}"
    DRY_RUN=0
    MIRRORET_SERVER_IP="127.0.0.1"
    source "${SCRIPT_DIR}/lib/backup.sh"
    source "${SCRIPT_DIR}/lib/rpm.sh"
    source "${SCRIPT_DIR}/lib/apt.sh"
    HTTP_PID=""
}

teardown() {
    if [[ -n "${HTTP_PID}" ]]; then
        kill "${HTTP_PID}" 2>/dev/null || true
        wait "${HTTP_PID}" 2>/dev/null || true
    fi
    cleanup_mock
    rm -rf "${TMPDIR}"
}

# _free_port - print a TCP port nothing is listening on.
_free_port() {
    python3 - <<'PY'
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
}

# _nginx_alias_for <location> - the alias lib/nginx.sh maps a location onto,
# with ${base_dir} expanded. Read from source so the test cannot drift from
# the config that is actually written.
_nginx_alias_for() {
    local loc="$1" tmpl
    tmpl="$(grep -A2 "location ${loc}" "${SCRIPT_DIR}/lib/nginx.sh" \
            | grep -oE 'alias +[^;]+' | head -1 | awk '{print $2}')"
    [[ -n "${tmpl}" ]] || return 1
    local base_dir="${MIRRORET_BASE_DIR}"
    eval printf '%s' "\"${tmpl}\""
}

# _serve <docroot> <port> - background static server, waits until it answers.
_serve() {
    local root="$1" port="$2"
    ( cd "${root}" && exec python3 -m http.server "${port}" --bind 127.0.0.1 ) \
        >/dev/null 2>&1 &
    HTTP_PID=$!
    local i
    for i in $(seq 1 60); do
        if curl -sf -o /dev/null "http://127.0.0.1:${port}/"; then return 0; fi
        sleep 0.1
    done
    return 1
}

_code() { curl -sS -o /dev/null -m 10 -w '%{http_code}' "$1"; }

# -- RPM: the path all three pieces must agree on -------------------------------

@test "client path: sync tree, nginx alias and client baseurl agree (RPM)" {
    mock_os_release "ol" "9.8"; detect_distro_from_mock
    MIRRORET_RHEL_VERSION=9
    MIRRORET_RPM_ARCH="x86_64 i686"
    configure_createrepo "id"

    # 1. Where the generated sync script writes.
    eval "$(grep -E '^(REPO_BASE|FLAVOR|RHEL_VER)=' \
            "${MIRRORET_BASE_DIR}/scripts/sync-redhat-repos.sh")"
    [ -n "${REPO_BASE}" ]

    # 2. What nginx maps /redhat/ onto.
    alias_dir="$(_nginx_alias_for '/redhat/')"
    [ -n "${alias_dir}" ]

    # The sync script must write underneath what nginx serves, or clients 404.
    [[ "${REPO_BASE}/" == "${alias_dir}"* ]] || \
        [[ "${alias_dir}" == "${REPO_BASE}/"* ]]
}

@test "client path: every generated baseurl resolves to a real file over HTTP" {
    mock_os_release "ol" "9.8"; detect_distro_from_mock
    MIRRORET_RHEL_VERSION=9
    MIRRORET_RPM_ARCH="x86_64 i686"
    port="$(_free_port)"
    MIRRORET_WEB_PORT="${port}"

    configure_createrepo "id"
    generate_rpm_client_config "${MIRRORET_BASE_DIR}/config/mirroret.repo"

    eval "$(grep -E '^(REPO_BASE|FLAVOR|RHEL_VER)=' \
            "${MIRRORET_BASE_DIR}/scripts/sync-redhat-repos.sh")"
    tree="${REPO_BASE}/${FLAVOR}/${RHEL_VER}"

    # Populate the tree exactly where the sync script would.
    while IFS= read -r repo; do
        mkdir -p "${tree}/${repo}/repodata"
        printf '<repomd/>\n' > "${tree}/${repo}/repodata/repomd.xml"
        : > "${tree}/${repo}/glibc-2.34-100.el9.i686.rpm"
    done < <(grep '^baseurl=' "${MIRRORET_BASE_DIR}/config/mirroret.repo" | sed 's#.*/##')

    # Serve through the same alias mapping nginx uses.
    alias_dir="$(_nginx_alias_for '/redhat/')"
    docroot="${TMPDIR}/docroot"; mkdir -p "${docroot}"
    ln -s "${alias_dir%/}" "${docroot}/redhat"
    _serve "${docroot}" "${port}"

    n=0
    while IFS= read -r url; do
        [ "$(_code "${url}/repodata/repomd.xml")" = "200" ]
        n=$((n + 1))
    done < <(grep '^baseurl=' "${MIRRORET_BASE_DIR}/config/mirroret.repo" | sed 's/^baseurl=//')
    # Oracle 9 defaults to four repos; assert we actually exercised them.
    [ "$n" -eq 4 ]
}

@test "client path: i686 package is fetchable at the client baseurl" {
    mock_os_release "ol" "9.8"; detect_distro_from_mock
    MIRRORET_RHEL_VERSION=9
    MIRRORET_RPM_ARCH="x86_64 i686"
    port="$(_free_port)"
    MIRRORET_WEB_PORT="${port}"
    configure_createrepo "id"
    generate_rpm_client_config "${MIRRORET_BASE_DIR}/config/mirroret.repo"

    eval "$(grep -E '^(REPO_BASE|FLAVOR|RHEL_VER)=' \
            "${MIRRORET_BASE_DIR}/scripts/sync-redhat-repos.sh")"
    url="$(grep -m1 '^baseurl=' "${MIRRORET_BASE_DIR}/config/mirroret.repo" | sed 's/^baseurl=//')"
    repo="${url##*/}"
    mkdir -p "${REPO_BASE}/${FLAVOR}/${RHEL_VER}/${repo}"
    : > "${REPO_BASE}/${FLAVOR}/${RHEL_VER}/${repo}/glibc-2.34-100.el9.i686.rpm"

    alias_dir="$(_nginx_alias_for '/redhat/')"
    docroot="${TMPDIR}/docroot"; mkdir -p "${docroot}"
    ln -s "${alias_dir%/}" "${docroot}/redhat"
    _serve "${docroot}" "${port}"

    [ "$(_code "${url}/glibc-2.34-100.el9.i686.rpm")" = "200" ]
}

# -- Shape of the client config -------------------------------------------------

@test "client path: one stanza per repo, no spaces in repo id or baseurl" {
    mock_os_release "ol" "9.8"; detect_distro_from_mock
    MIRRORET_RHEL_VERSION=9
    generate_rpm_client_config "${MIRRORET_BASE_DIR}/config/mirroret.repo"
    f="${MIRRORET_BASE_DIR}/config/mirroret.repo"

    # Four Oracle repos means four stanzas, not one stanza naming all four.
    [ "$(grep -c '^\[mirroret-' "$f")" -eq 4 ]
    [ "$(grep -c '^baseurl=' "$f")" -eq 4 ]
    # A repo id or URL containing a space makes the whole file invalid to dnf.
    ! grep -qE '^\[mirroret-[^]]* ' "$f"
    ! grep -qE '^baseurl=\S* ' "$f"
    # Every baseurl must be a single absolute http(s) URL.
    while IFS= read -r u; do
        [[ "$u" =~ ^https?://[^[:space:]]+$ ]]
    done < <(grep '^baseurl=' "$f" | sed 's/^baseurl=//')
}

@test "client path: gpgcheck=1 is always paired with a gpgkey" {
    mock_os_release "ol" "9.8"; detect_distro_from_mock
    MIRRORET_RHEL_VERSION=9
    MIRRORET_RPM_INSECURE=0
    MIRRORET_RPM_GPGKEY_URL=""
    generate_rpm_client_config "${MIRRORET_BASE_DIR}/config/mirroret.repo"
    f="${MIRRORET_BASE_DIR}/config/mirroret.repo"
    # gpgcheck=1 with no gpgkey makes every client dnf call fail.
    if grep -q '^gpgcheck=1' "$f"; then
        grep -q '^gpgkey=' "$f"
    fi
}

@test "client path: flavor in the baseurl matches the flavor in the sync tree" {
    # A mismatch here is the 'hardcoded rocky/' class of bug: packages land in
    # one directory and clients ask for another.
    mock_os_release "almalinux" "9.3"; detect_distro_from_mock
    MIRRORET_RHEL_VERSION=9
    MIRRORET_RPM_FLAVOR=""
    configure_createrepo "id"
    generate_rpm_client_config "${MIRRORET_BASE_DIR}/config/mirroret.repo"

    eval "$(grep -E '^FLAVOR=' "${MIRRORET_BASE_DIR}/scripts/sync-redhat-repos.sh")"
    [ "${FLAVOR}" = "almalinux" ]
    grep -q "/redhat/${FLAVOR}/9/" "${MIRRORET_BASE_DIR}/config/mirroret.repo"
}

# -- APT ------------------------------------------------------------------------

@test "client path: APT sources.list URL prefix matches the nginx location" {
    mock_os_release "ubuntu" "22.04" "jammy"; detect_distro_from_mock
    MIRRORET_APT_NGINX_PREFIX=/ubuntu
    MIRRORET_WEB_PORT=8080
    generate_apt_client_config "${MIRRORET_BASE_DIR}/config/sources.list"
    f="${MIRRORET_BASE_DIR}/config/sources.list"
    grep -q "http://127.0.0.1:8080/ubuntu " "$f"
    # nginx must define a matching location, or every apt-get update 404s.
    grep -q 'location /ubuntu' "${SCRIPT_DIR}/lib/nginx.sh" || \
        grep -q 'apt_nginx_prefix\|MIRRORET_APT_NGINX_PREFIX' "${SCRIPT_DIR}/lib/nginx.sh"
}

# -- Paths clients must NOT be able to reach ------------------------------------

@test "client path: logs and scripts are denied in the nginx config" {
    # These sit under the same base dir as the mirrors. Without an explicit
    # deny they are browsable by every client.
    grep -qE 'location.*(logs|scripts|staging)' "${SCRIPT_DIR}/lib/nginx.sh"
    grep -qE 'deny all|return 40[34]' "${SCRIPT_DIR}/lib/nginx.sh"
}

# BATS helper functions for mirroret tests.
# Source this in test files with: load 'test_helpers'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Source all lib modules with a minimal environment.
load_lib() {
    # Provide minimal stubs so modules don't fail to load.
    DRY_RUN=1
    MIRRORET_NON_INTERACTIVE=1
    LOG_LEVEL=DEBUG

    # shellcheck source=../lib/logging.sh
    source "${SCRIPT_DIR}/lib/logging.sh"
    # shellcheck source=../lib/common.sh
    source "${SCRIPT_DIR}/lib/common.sh"
}

# load_distro_lib - load the distro module with a mocked /etc/os-release.
load_distro_lib() {
    load_lib
    source "${SCRIPT_DIR}/lib/distro.sh"
}

# mock_os_release <id> <version_id> [codename] - write a fake /etc/os-release
# to a temp file and point OS detection at it.
mock_os_release() {
    local id="$1"
    local version_id="$2"
    local codename="${3:-}"
    MOCK_OS_RELEASE="$(mktemp)"
    {
        echo "ID=${id}"
        echo "VERSION_ID=${version_id}"
        [[ -n "$codename" ]] && echo "VERSION_CODENAME=${codename}"
    } > "$MOCK_OS_RELEASE"
    export MOCK_OS_RELEASE
}

# detect_distro_from_mock - run detect_distro sourcing the mock file.
detect_distro_from_mock() {
    if [[ -z "${MOCK_OS_RELEASE:-}" ]]; then
        echo "ERROR: call mock_os_release first" >&2
        return 1
    fi
    # Override the function to use mock file.
    detect_distro() {
        . "$MOCK_OS_RELEASE"
        OS_ID="${ID:-unknown}"
        OS_VER="${VERSION_ID:-unknown}"
        OS_CODENAME="${VERSION_CODENAME:-}"
        case "${OS_ID}" in
            ubuntu|debian|linuxmint|pop)
                DISTRO_TYPE="debian"
                PKG_MGR="apt-get"
                PKG_MGR_INSTALL="apt-get install -y --no-install-recommends"
                ;;
            centos|rhel|fedora|rocky|almalinux|ol)
                DISTRO_TYPE="rhel"
                PKG_MGR="dnf"
                PKG_MGR_INSTALL="dnf install -y"
                ;;
            *)
                echo "Unsupported: ${OS_ID}" >&2
                return 1
                ;;
        esac
        export DISTRO_TYPE OS_ID OS_VER OS_CODENAME PKG_MGR PKG_MGR_INSTALL
    }
    detect_distro
}

cleanup_mock() {
    if [[ -n "${MOCK_OS_RELEASE:-}" ]]; then
        rm -f "$MOCK_OS_RELEASE"
    fi
}

# -- Local upstream fixtures --------------------------------------------------
#
# The engine tests need a real HTTP server: verifying checksums, publish
# ordering and metadata rewriting against a mocked fetch would prove nothing
# about whether a client can install from the result.

# serve_fixture <dir> - start python3 -m http.server on a free port and echo
# the base URL.
#
# The PID goes to a FILE, not a variable. Callers use this as
# `url="$(serve_fixture ...)"`, which runs the function in a command
# substitution subshell - so a variable assignment (even an exported one)
# never reaches the caller, teardown finds nothing to kill, and every test
# leaks a server process for the rest of the run.
serve_fixture() {
    local dir="$1"
    local port
    # Ask the kernel for a free port rather than guessing, so parallel test
    # runs cannot collide.
    port="$(python3 -c 'import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()')"
    python3 -m http.server "${port}" --bind 127.0.0.1 --directory "${dir}" \
        >/dev/null 2>&1 &
    printf '%s\n' "$!" >> "$(_fixture_pidfile)"
    local i
    for i in $(seq 1 50); do
        if curl -fsS -o /dev/null --max-time 1 "http://127.0.0.1:${port}/" 2>/dev/null; then
            break
        fi
        sleep 0.1
    done
    echo "http://127.0.0.1:${port}"
}

# _fixture_pidfile - one file per test, keyed on the bats test PID so
# concurrent tests cannot kill each other's servers.
_fixture_pidfile() {
    printf '%s' "${BATS_TEST_TMPDIR:-${TMPDIR:-/tmp}}/mirroret-fixture-pids.$$"
}

stop_fixture() {
    local pidfile pid
    pidfile="$(_fixture_pidfile)"
    [[ -f "${pidfile}" ]] || return 0
    while read -r pid; do
        [[ -n "${pid}" ]] || continue
        kill "${pid}" 2>/dev/null || true
        wait "${pid}" 2>/dev/null || true
    done < "${pidfile}"
    rm -f "${pidfile}"
}

# The engines must never be given a proxy: the fixture server is on loopback.
no_proxy_env() {
    unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY
    export no_proxy="127.0.0.1,localhost"
    export NO_PROXY="127.0.0.1,localhost"
}

apt_engine() { echo "${SCRIPT_DIR}/engines/mirroret_apt.py"; }
rpm_engine() { echo "${SCRIPT_DIR}/engines/mirroret_rpm.py"; }

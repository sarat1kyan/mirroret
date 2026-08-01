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

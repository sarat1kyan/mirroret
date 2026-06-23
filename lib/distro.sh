#!/usr/bin/env bash
# Distribution detection for mirroret.
# Source this file; do not execute it directly.
# Sets: DISTRO_TYPE, OS_ID, OS_VER, OS_CODENAME, PKG_MGR, PKG_MGR_INSTALL

detect_distro() {
    section "Detecting Linux Distribution"

    if [[ ! -f /etc/os-release ]]; then
        die "Cannot detect distribution: /etc/os-release not found."
    fi

    # shellcheck source=/dev/null
    . /etc/os-release

    OS_ID="${ID:-unknown}"
    OS_VER="${VERSION_ID:-unknown}"
    OS_CODENAME="${VERSION_CODENAME:-}"

    case "${OS_ID}" in
        ubuntu|debian|linuxmint|pop)
            DISTRO_TYPE="debian"
            PKG_MGR="apt-get"
            PKG_MGR_INSTALL="apt-get install -y --no-install-recommends -o Dpkg::Options::=--force-confold"
            export DEBIAN_FRONTEND=noninteractive
            success "Detected: ${OS_ID} ${OS_VER} (Debian-based)"
            ;;
        centos|rhel|fedora|rocky|almalinux|ol)
            DISTRO_TYPE="rhel"
            if check_command dnf; then
                PKG_MGR="dnf"
                PKG_MGR_INSTALL="dnf install -y"
            else
                PKG_MGR="yum"
                PKG_MGR_INSTALL="yum install -y"
            fi
            success "Detected: ${OS_ID} ${OS_VER} (RHEL-based)"
            ;;
        *)
            die "Unsupported distribution: ${OS_ID}. Supported: ubuntu, debian, centos, rhel, fedora, rocky, almalinux."
            ;;
    esac

    export DISTRO_TYPE OS_ID OS_VER OS_CODENAME PKG_MGR PKG_MGR_INSTALL
}

# rhel_major_version — print just the major version number.
rhel_major_version() {
    echo "${OS_VER%%.*}"
}

# ubuntu_codename — print the Ubuntu codename.
# Priority: MIRRORET_UBUNTU_CODENAME > OS_CODENAME > derive from OS_VER.
ubuntu_codename() {
    if [[ -n "${MIRRORET_UBUNTU_CODENAME:-}" ]]; then
        echo "${MIRRORET_UBUNTU_CODENAME}"
        return 0
    fi
    if [[ -n "${OS_CODENAME:-}" ]]; then
        echo "${OS_CODENAME}"
    else
        # Derive from version if possible.
        case "${OS_VER}" in
            20.04) echo "focal" ;;
            22.04) echo "jammy" ;;
            24.04) echo "noble" ;;
            *)     die "Unknown Ubuntu version ${OS_VER}; set MIRRORET_UBUNTU_CODENAME manually." ;;
        esac
    fi
}

# selinux_enforcing — true if SELinux is in enforcing mode.
selinux_enforcing() {
    [[ -f /sys/fs/selinux/enforce ]] && [[ "$(cat /sys/fs/selinux/enforce)" == "1" ]]
}

# set_selinux_context <path> — set the correct SELinux context for web content.
set_selinux_context() {
    local path="$1"
    if selinux_enforcing; then
        if check_command semanage && check_command restorecon; then
            info "Setting SELinux context on ${path}"
            xrun semanage fcontext -a -t httpd_sys_content_t "${path}(/.*)?" 2>/dev/null || \
                xrun semanage fcontext -m -t httpd_sys_content_t "${path}(/.*)?" || true
            xrun restorecon -Rv "$path" || true
        else
            warn "SELinux is enforcing but semanage/restorecon not found."
            warn "nginx may be blocked from serving ${path}."
            warn "Install: policycoreutils-python-utils (RHEL 8+) or policycoreutils-python (RHEL 7)"
        fi
    fi
}

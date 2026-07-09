#!/usr/bin/env bash
# mirroret installer — unified package repository server
# Usage: sudo ./install.sh [options]
#
# Options:
#   --config <path>        Load config from file
#   --dry-run              Show what would be done without making changes
#   --non-interactive      Suppress all prompts (auto-decline confirmations)
#   --check                Validate existing installation and exit
#   --status               Print service status and exit
#   --validate             Alias for --check
#   --backup-only          Create a backup of current state and exit
#   --rollback <id>        Roll back to a specific backup
#   --list-backups         List available backups
#   --no-apt               Skip APT mirror setup
#   --no-rpm               Skip RPM mirror setup
#   --no-pip               Skip pip/pypiserver setup
#   --no-docker            Skip Docker registry setup
#   --no-npm               Skip npm/Verdaccio setup
#   --no-firewall          Skip firewall configuration
#   --insecure             Enable all insecure modes (LAB ONLY — see below)
#   --debug                Enable debug logging
#   --help                 Show this help

set -Eeuo pipefail

# ── Script location ───────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Load library modules ──────────────────────────────────────────────────────
# shellcheck source=lib/logging.sh
source "${SCRIPT_DIR}/lib/logging.sh"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/distro.sh
source "${SCRIPT_DIR}/lib/distro.sh"
# shellcheck source=lib/backup.sh
source "${SCRIPT_DIR}/lib/backup.sh"
# shellcheck source=lib/preflight.sh
source "${SCRIPT_DIR}/lib/preflight.sh"
# shellcheck source=lib/nginx.sh
source "${SCRIPT_DIR}/lib/nginx.sh"
# shellcheck source=lib/systemd.sh
source "${SCRIPT_DIR}/lib/systemd.sh"
# shellcheck source=lib/firewall.sh
source "${SCRIPT_DIR}/lib/firewall.sh"
# shellcheck source=lib/apt.sh
source "${SCRIPT_DIR}/lib/apt.sh"
# shellcheck source=lib/rpm.sh
source "${SCRIPT_DIR}/lib/rpm.sh"
# shellcheck source=lib/docker_registry.sh
source "${SCRIPT_DIR}/lib/docker_registry.sh"
# shellcheck source=lib/pip.sh
source "${SCRIPT_DIR}/lib/pip.sh"
# shellcheck source=lib/npm.sh
source "${SCRIPT_DIR}/lib/npm.sh"
# shellcheck source=lib/validation.sh
source "${SCRIPT_DIR}/lib/validation.sh"
# shellcheck source=lib/tls.sh
source "${SCRIPT_DIR}/lib/tls.sh"
# shellcheck source=lib/gpg.sh
source "${SCRIPT_DIR}/lib/gpg.sh"
# shellcheck source=lib/approval.sh
source "${SCRIPT_DIR}/lib/approval.sh"
# shellcheck source=lib/uninstall.sh
source "${SCRIPT_DIR}/lib/uninstall.sh"
# shellcheck source=lib/retention.sh
source "${SCRIPT_DIR}/lib/retention.sh"

# ── Defaults ──────────────────────────────────────────────────────────────────
MIRRORET_BASE_DIR="${MIRRORET_BASE_DIR:-/srv/mirroret}"
MIRRORET_WEB_PORT="${MIRRORET_WEB_PORT:-8080}"
MIRRORET_PIP_PORT="${MIRRORET_PIP_PORT:-8081}"
MIRRORET_DOCKER_REGISTRY_PORT="${MIRRORET_DOCKER_REGISTRY_PORT:-5000}"
MIRRORET_NPM_PORT="${MIRRORET_NPM_PORT:-4873}"
MIRRORET_SYNC_HOUR="${MIRRORET_SYNC_HOUR:-2}"
MIRRORET_MIN_DISK_GB="${MIRRORET_MIN_DISK_GB:-50}"
MIRRORET_NON_INTERACTIVE="${MIRRORET_NON_INTERACTIVE:-0}"
MIRRORET_ENABLE_APT="${MIRRORET_ENABLE_APT:-1}"
MIRRORET_ENABLE_RPM="${MIRRORET_ENABLE_RPM:-1}"
MIRRORET_ENABLE_PIP="${MIRRORET_ENABLE_PIP:-1}"
MIRRORET_ENABLE_DOCKER="${MIRRORET_ENABLE_DOCKER:-1}"
MIRRORET_ENABLE_NPM="${MIRRORET_ENABLE_NPM:-1}"
MIRRORET_APT_INSECURE="${MIRRORET_APT_INSECURE:-0}"
MIRRORET_RPM_INSECURE="${MIRRORET_RPM_INSECURE:-0}"
MIRRORET_DOCKER_INSECURE="${MIRRORET_DOCKER_INSECURE:-0}"
MIRRORET_PIP_INSECURE="${MIRRORET_PIP_INSECURE:-0}"

# Docker backend.
MIRRORET_DOCKER_BACKEND="${MIRRORET_DOCKER_BACKEND:-auto}"
MIRRORET_DOCKER_MODE="${MIRRORET_DOCKER_MODE:-cache}"
MIRRORET_DOCKER_UPSTREAM_URL="${MIRRORET_DOCKER_UPSTREAM_URL:-https://registry-1.docker.io}"
MIRRORET_DOCKER_IMAGES_FILE="${MIRRORET_DOCKER_IMAGES_FILE:-}"

# APT mirror tool / flavor / upstream.
MIRRORET_APT_MIRROR_TOOL="${MIRRORET_APT_MIRROR_TOOL:-auto}"
MIRRORET_APT_FLAVOR="${MIRRORET_APT_FLAVOR:-auto}"
MIRRORET_APT_UPSTREAM_HOST="${MIRRORET_APT_UPSTREAM_HOST:-}"
MIRRORET_APT_SECURITY_HOST="${MIRRORET_APT_SECURITY_HOST:-}"
MIRRORET_APT_COMPONENTS="${MIRRORET_APT_COMPONENTS:-}"
MIRRORET_APT_RESIGN="${MIRRORET_APT_RESIGN:-0}"

# RPM flavor / repos.
MIRRORET_RPM_FLAVOR="${MIRRORET_RPM_FLAVOR:-}"
MIRRORET_RPM_REPOS="${MIRRORET_RPM_REPOS:-}"

# Preflight network probe (off by default; on means outbound HTTPS).
MIRRORET_PREFLIGHT_NETWORK="${MIRRORET_PREFLIGHT_NETWORK:-0}"

# Retention (off by default — most operators want "keep everything").
MIRRORET_RETENTION_ENABLE="${MIRRORET_RETENTION_ENABLE:-0}"
MIRRORET_RETENTION_MODE="${MIRRORET_RETENTION_MODE:-report}"
MIRRORET_RPM_KEEP_VERSIONS="${MIRRORET_RPM_KEEP_VERSIONS:-3}"
MIRRORET_PIP_KEEP_VERSIONS="${MIRRORET_PIP_KEEP_VERSIONS:-3}"
MIRRORET_NPM_KEEP_DAYS="${MIRRORET_NPM_KEEP_DAYS:-180}"
MIRRORET_DOCKER_GC="${MIRRORET_DOCKER_GC:-0}"
MIRRORET_CLEANUP_HOUR="${MIRRORET_CLEANUP_HOUR:-3}"        # weekly Sun @03:00
MIRRORET_CLEANUP_DOW="${MIRRORET_CLEANUP_DOW:-0}"           # Sunday
MIRRORET_UPGRADE_MODE="${MIRRORET_UPGRADE_MODE:-0}"

# Approval workflow.
MIRRORET_APPROVAL_ENABLED="${MIRRORET_APPROVAL_ENABLED:-0}"

# TLS.
MIRRORET_TLS_SELF_SIGNED="${MIRRORET_TLS_SELF_SIGNED:-0}"
MIRRORET_TLS_CERT="${MIRRORET_TLS_CERT:-}"
MIRRORET_TLS_KEY="${MIRRORET_TLS_KEY:-}"
MIRRORET_TLS_PORT="${MIRRORET_TLS_PORT:-8443}"
MIRRORET_TLS_DIR="${MIRRORET_TLS_DIR:-/etc/mirroret/tls}"

# GPG signing.
MIRRORET_GPG_AUTO="${MIRRORET_GPG_AUTO:-0}"
MIRRORET_GPG_NAME="${MIRRORET_GPG_NAME:-mirroret}"
MIRRORET_GPG_EMAIL="${MIRRORET_GPG_EMAIL:-mirroret@localhost}"
MIRRORET_GPG_HOMEDIR="${MIRRORET_GPG_HOMEDIR:-/etc/mirroret/gnupg}"
MIRRORET_GPG_KEYID="${MIRRORET_GPG_KEYID:-}"

# npm extras.
MIRRORET_NPM_PACKAGES_FILE="${MIRRORET_NPM_PACKAGES_FILE:-}"
MIRRORET_NPM_ALLOW_ANON_PUBLISH="${MIRRORET_NPM_ALLOW_ANON_PUBLISH:-0}"

# Mode flags.
MODE_CHECK=0
MODE_STATUS=0
MODE_BACKUP_ONLY=0
MODE_ROLLBACK=""
MODE_LIST_BACKUPS=0
MODE_NO_FIREWALL=0
MODE_LIST_STAGING=0
MODE_APPROVE_ALL_PIP=0
MODE_APPROVE_ALL_NPM=0
MODE_APPROVE_PACKAGE=""
MODE_EXCLUDE_PIP=""
MODE_EXCLUDE_NPM=""
MODE_CLEANUP=0
MODE_CLEANUP_REPORT=0
MODE_UPGRADE=0

# ── Argument parsing ──────────────────────────────────────────────────────────
parse_args() {
    # Auto-load /etc/mirroret/mirroret.conf if present and --config not
    # given. Explicit --config overrides.
    if [[ -f /etc/mirroret/mirroret.conf ]] && [[ "$*" != *"--config"* ]]; then
        # shellcheck disable=SC1091
        source /etc/mirroret/mirroret.conf
        info "Loaded config: /etc/mirroret/mirroret.conf (auto)"
    fi

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --config)
                shift
                load_config "$1"
                ;;
            --dry-run)
                DRY_RUN=1
                info "DRY-RUN mode enabled: no system changes will be made."
                ;;
            --non-interactive)
                MIRRORET_NON_INTERACTIVE=1
                ;;
            --check|--validate)
                MODE_CHECK=1
                ;;
            --status)
                MODE_STATUS=1
                ;;
            --backup-only)
                MODE_BACKUP_ONLY=1
                ;;
            --rollback)
                shift
                MODE_ROLLBACK="$1"
                ;;
            --list-backups)
                MODE_LIST_BACKUPS=1
                ;;
            --no-apt)
                MIRRORET_ENABLE_APT=0
                ;;
            --no-rpm)
                MIRRORET_ENABLE_RPM=0
                ;;
            --no-pip)
                MIRRORET_ENABLE_PIP=0
                ;;
            --no-docker)
                MIRRORET_ENABLE_DOCKER=0
                ;;
            --no-npm)
                MIRRORET_ENABLE_NPM=0
                ;;
            --no-firewall)
                MODE_NO_FIREWALL=1
                ;;
            --insecure)
                MIRRORET_APT_INSECURE=1
                MIRRORET_RPM_INSECURE=1
                MIRRORET_DOCKER_INSECURE=1
                MIRRORET_PIP_INSECURE=1
                warn_insecure "--insecure flag set: ALL insecure modes enabled."
                warn_insecure "Use only in isolated lab/air-gapped environments."
                ;;
            --docker-mode)
                shift
                MIRRORET_DOCKER_MODE="$1"
                ;;
            --apt-flavor)
                shift
                MIRRORET_APT_FLAVOR="$1"
                ;;
            --network-preflight)
                MIRRORET_PREFLIGHT_NETWORK=1
                ;;
            --cleanup)
                MODE_CLEANUP=1
                ;;
            --cleanup-report)
                MODE_CLEANUP_REPORT=1
                ;;
            --upgrade)
                MODE_UPGRADE=1
                ;;
            --tls-self-signed)
                MIRRORET_TLS_SELF_SIGNED=1
                ;;
            --gpg-auto)
                MIRRORET_GPG_AUTO=1
                ;;
            --approval-mode)
                MIRRORET_APPROVAL_ENABLED=1
                ;;
            --list-staging)
                MODE_LIST_STAGING=1
                ;;
            --approve-all-pip)
                MODE_APPROVE_ALL_PIP=1
                ;;
            --approve-all-npm)
                MODE_APPROVE_ALL_NPM=1
                ;;
            --approve-package)
                shift
                MODE_APPROVE_PACKAGE="$1"
                ;;
            --exclude-pip)
                shift
                MODE_EXCLUDE_PIP="$1"
                ;;
            --exclude-npm)
                shift
                MODE_EXCLUDE_NPM="$1"
                ;;
            --debug)
                export LOG_LEVEL=DEBUG
                ;;
            --uninstall)
                # Hand off everything after --uninstall to the uninstaller.
                shift
                # --list / --dry-run are safe without root.
                case " $* " in
                    *" --list "*|*" --dry-run "*) : ;;
                    *) require_root ;;
                esac
                uninstall_main "$@"
                exit $?
                ;;
            --help|-h)
                usage
                exit 0
                ;;
            *)
                die "Unknown argument: $1. Run $0 --help for usage."
                ;;
        esac
        shift
    done

    export DRY_RUN
}

load_config() {
    local config_file="$1"
    if [[ ! -f "$config_file" ]]; then
        die "Config file not found: ${config_file}"
    fi
    # shellcheck source=/dev/null
    source "$config_file"
    info "Loaded config: ${config_file}"
}

usage() {
    cat <<'USAGE'
mirroret installer — unified package repository server

Usage: sudo ./install.sh [options]

Options:
  --config <path>        Load config from file (see config/mirroret.conf.example)
  --dry-run              Show what would be done without making changes
  --non-interactive      Suppress all prompts
  --check | --validate   Validate existing installation and exit
  --status               Print service status and exit
  --backup-only          Create a backup of current state and exit
  --rollback <id>        Roll back to a specific backup (see --list-backups)
  --list-backups         List available backups
  --no-apt               Skip APT mirror setup
  --no-rpm               Skip RPM mirror setup
  --no-pip               Skip pip/pypiserver setup
  --no-docker            Skip Docker registry setup
  --no-npm               Skip npm/Verdaccio setup
  --no-firewall          Skip firewall configuration
  --insecure             Enable all insecure modes (LAB ONLY)
  --docker-mode <cache|hosted>  cache: pull-through proxy (default).
                                hosted: accept docker push, no proxy.
  --apt-flavor <auto|ubuntu|debian>  override APT upstream flavor
  --network-preflight    run optional outbound HTTPS preflight probe
  --upgrade              Fast re-install: skip pkg install + user create; refresh
                         configs + systemd units + regenerated sync scripts
                         (managed files only — user-customized ones are preserved).
  --cleanup              Run mirror retention now (needs MIRRORET_RETENTION_ENABLE=1)
  --cleanup-report       Show what --cleanup would remove without deleting anything
  --tls-self-signed      Generate a self-signed TLS certificate during install
  --gpg-auto             Auto-generate a GPG signing key if none exists
  --approval-mode        Enable staging/approved workflow for pip and npm
  --list-staging         List packages awaiting approval and exit
  --approve-all-pip      Promote all staged pip packages to approved
  --approve-all-npm      Promote all staged npm packages to approved
  --approve-package <n>  Promote a specific staged pip package by name fragment
  --exclude-pip <n>      Remove a staged pip package (decline it)
  --exclude-npm <n>      Remove a staged npm package (decline it)
  --debug                Enable debug logging
  --uninstall [opts]     Run the uninstaller. Passes remaining args through
                         to ./uninstall.sh (see ./uninstall.sh --help).
  --help                 Show this help

Environment variables:
  See config/mirroret.conf.example for all supported variables.

Examples:
  # Standard installation
  sudo ./install.sh

  # Lab/air-gapped installation (no GPG)
  sudo ./install.sh --insecure

  # Dry-run to preview changes
  sudo ./install.sh --dry-run

  # APT only, restrict firewall to local subnet
  sudo ./install.sh --no-pip --no-docker --no-npm \
    MIRRORET_FIREWALL_SOURCE=10.0.0.0/8

  # Check existing installation
  sudo ./install.sh --check

  # Roll back to a previous backup
  sudo ./install.sh --list-backups
  sudo ./install.sh --rollback 20260601-020000
USAGE
}

# ── Error trap ────────────────────────────────────────────────────────────────
_on_error() {
    local exit_code=$?
    local line_no=${BASH_LINENO[0]}
    error "Installation failed at line ${line_no} with exit code ${exit_code}."
    error "Log file: ${MIRRORET_LOG_FILE:-/var/log/mirroret-install.log}"
    error "To roll back: $0 --list-backups && $0 --rollback <id>"
}
trap '_on_error' ERR

# ── Directory setup ───────────────────────────────────────────────────────────
create_directory_structure() {
    section "Creating Directory Structure"

    local dirs=(
        "${MIRRORET_BASE_DIR}/debian/mirror/ubuntu"
        "${MIRRORET_BASE_DIR}/debian/mirror/debian"
        "${MIRRORET_BASE_DIR}/debian/approved"
        "${MIRRORET_BASE_DIR}/redhat/mirror/rocky"
        "${MIRRORET_BASE_DIR}/redhat/approved"
        "${MIRRORET_BASE_DIR}/pip/approved"
        "${MIRRORET_BASE_DIR}/pip/staging"
        "${MIRRORET_BASE_DIR}/docker/registry"
        "${MIRRORET_BASE_DIR}/npm/approved"
        "${MIRRORET_BASE_DIR}/npm/staging"
        "${MIRRORET_BASE_DIR}/logs"
        "${MIRRORET_BASE_DIR}/scripts"
        "${MIRRORET_BASE_DIR}/config"
    )

    for dir in "${dirs[@]}"; do
        if [[ "${DRY_RUN}" == "1" ]]; then
            info "[DRY-RUN] would create: ${dir}"
        else
            mkdir -p "$dir"
        fi
    done

    success "Directory structure ready at ${MIRRORET_BASE_DIR}."
}

# ── Package installation ──────────────────────────────────────────────────────
install_system_packages() {
    section "Installing System Packages"

    if [[ "${DISTRO_TYPE}" == "debian" ]]; then
        # Repair any interrupted dpkg transactions from a previous broken install.
        DEBIAN_FRONTEND=noninteractive dpkg --configure -a 2>/dev/null || true
        xrun apt-get update -qq
        # python3-venv is a separate package on Debian/Ubuntu; required for the
        # pypiserver virtualenv fallback when python3-pypiserver is not in repos.
        local debian_pkgs=(dpkg-dev nginx gnupg wget curl rsync cron python3-venv python3-pip)
        # apt-mirror was removed from Debian 12 (bookworm).
        # MIRRORET_APT_MIRROR_TOOL controls which tool is used (auto/apt-mirror/debmirror).
        # When auto or apt-mirror, attempt to install; if missing, apt.sh will fall back.
        if [[ "${MIRRORET_ENABLE_APT}" == "1" ]]; then
            if apt-cache show apt-mirror &>/dev/null 2>&1; then
                debian_pkgs+=(apt-mirror)
            else
                warn "apt-mirror not in repos. apt.sh will fall back per MIRRORET_APT_MIRROR_TOOL."
                warn "Possible alternatives: apt-mirror2 (pip) or debmirror."
                warn "See docs/CONFIGURATION.md for MIRRORET_APT_MIRROR_TOOL."
            fi
        fi
        # Native Docker registry for Debian.
        if [[ "${MIRRORET_ENABLE_DOCKER}" == "1" ]] && \
           [[ "${MIRRORET_DOCKER_BACKEND}" == "native" || "${MIRRORET_DOCKER_BACKEND}" == "auto" ]]; then
            if apt-cache show docker-registry &>/dev/null 2>&1; then
                debian_pkgs+=(docker-registry)
            fi
        fi
        # debmirror optional install when selected.
        if [[ "${MIRRORET_ENABLE_APT}" == "1" ]] && \
           [[ "${MIRRORET_APT_MIRROR_TOOL}" == "debmirror" || "${MIRRORET_APT_MIRROR_TOOL}" == "auto" ]]; then
            if apt-cache show debmirror &>/dev/null 2>&1; then
                debian_pkgs+=(debmirror)
            fi
        fi
        # nodejs and npm are required for the Verdaccio npm registry.
        [[ "${MIRRORET_ENABLE_NPM}" == "1" ]] && debian_pkgs+=(nodejs npm)
        xrun ${PKG_MGR_INSTALL} "${debian_pkgs[@]}"
    else
        # policycoreutils-python-utils provides semanage for SELinux context labelling.
        local rhel_pkgs=(createrepo_c yum-utils nginx wget curl rsync cronie python3 python3-pip policycoreutils-python-utils)
        xrun ${PKG_MGR_INSTALL} "${rhel_pkgs[@]}"
        # nodejs and npm: in AppStream on RHEL 8/9. RHEL 8 may need the module stream enabled first.
        if [[ "${MIRRORET_ENABLE_NPM}" == "1" ]]; then
            if ! ${PKG_MGR_INSTALL} nodejs npm 2>/dev/null; then
                info "nodejs install failed — trying AppStream module enable..."
                dnf module enable nodejs -y 2>/dev/null || true
                xrun ${PKG_MGR_INSTALL} nodejs npm
            fi
        fi
        if [[ "${MIRRORET_ENABLE_DOCKER}" == "1" ]]; then
            # docker-distribution (native registry) is in RHEL 8/Rocky 8 extras.
            # On RHEL 9/Rocky 9 it may not be available — fall back to container backend.
            ${PKG_MGR_INSTALL} docker-distribution 2>/dev/null \
                || warn "docker-distribution not in repos; container backend will be used."
            # Podman is the RHEL-native container runtime (BaseOS on RHEL 8/9).
            # Install as the container backend fallback when docker-distribution is unavailable.
            # This is a no-op on systems that already have Docker or Podman installed.
            ${PKG_MGR_INSTALL} podman 2>/dev/null || true
        fi
        xrun systemctl enable --now crond || xrun systemctl enable --now cron || true
    fi

    success "System packages installed."
}

# ── Cron setup ────────────────────────────────────────────────────────────────
# We bracket our cron lines with sentinel comments. Re-runs replace only
# the bracketed region, so unrelated operator cron lines are preserved
# even if they mention "mirroret" or "sync" by coincidence.
MIRRORET_CRON_BEGIN="# >>> mirroret managed (do not edit between markers) >>>"
MIRRORET_CRON_END="# <<< mirroret managed <<<"

setup_cron() {
    local sync_script="${MIRRORET_BASE_DIR}/scripts/sync-all.sh"
    local cleanup_script="${MIRRORET_BASE_DIR}/scripts/cleanup-all.sh"
    local sync_entry="0 ${MIRRORET_SYNC_HOUR} * * * ${sync_script}"
    # Weekly cleanup on ${MIRRORET_CLEANUP_DOW} at ${MIRRORET_CLEANUP_HOUR}:00
    local cleanup_entry="0 ${MIRRORET_CLEANUP_HOUR} * * ${MIRRORET_CLEANUP_DOW} ${cleanup_script}"

    section "Setting Up Automated Sync (cron)"

    if [[ "${DRY_RUN}" == "1" ]]; then
        info "[DRY-RUN] would add cron: ${sync_entry}"
        info "[DRY-RUN] would add cron: ${cleanup_entry}"
        return 0
    fi

    if ! check_command crontab; then
        warn "crontab not found — skipping cron setup. Schedule ${sync_script} manually."
        return 0
    fi

    local existing
    existing="$(crontab -l 2>/dev/null || true)"

    # Strip only the previously-managed block. awk so we don't accidentally
    # match the sentinel inside other operator content.
    local stripped
    stripped="$(printf '%s\n' "${existing}" | awk -v b="${MIRRORET_CRON_BEGIN}" -v e="${MIRRORET_CRON_END}" '
        $0 == b { skip = 1; next }
        $0 == e { skip = 0; next }
        !skip { print }
    ')"

    # Build the new crontab: kept lines + our managed block.
    {
        # Preserve existing entries (trim trailing empty lines).
        if [[ -n "${stripped// /}" ]]; then
            printf '%s\n' "${stripped}"
        fi
        printf '%s\n' "${MIRRORET_CRON_BEGIN}"
        printf '%s\n' "${sync_entry}"
        printf '%s\n' "${cleanup_entry}"
        printf '%s\n' "${MIRRORET_CRON_END}"
    } | crontab -

    success "Cron: daily sync at ${MIRRORET_SYNC_HOUR}:00, weekly cleanup on DOW=${MIRRORET_CLEANUP_DOW} at ${MIRRORET_CLEANUP_HOUR}:00."
}

# ── Master sync script ────────────────────────────────────────────────────────
write_master_sync_script() {
    local sync_script="${MIRRORET_BASE_DIR}/scripts/sync-all.sh"

    if [[ "${DRY_RUN}" == "1" ]]; then
        info "[DRY-RUN] would write: ${sync_script}"
        return 0
    fi

    # Upgrade safety: don't clobber operator-edited sync-all.sh.
    if ! preserve_user_customization "${sync_script}"; then
        return 0
    fi

    # Choose the APT sync command based on whichever tool was resolved.
    # MIRRORET_APT_RESOLVED_TOOL is exported by configure_apt_mirror().
    local apt_sync_cmd=""
    if [[ "${MIRRORET_ENABLE_APT}" == "1" ]] && [[ "${DISTRO_TYPE}" == "debian" ]]; then
        case "${MIRRORET_APT_RESOLVED_TOOL:-apt-mirror}" in
            debmirror)   apt_sync_cmd="${MIRRORET_BASE_DIR}/scripts/sync-apt-debmirror.sh" ;;
            apt-mirror2) apt_sync_cmd="/usr/local/bin/apt-mirror2" ;;
            *)           apt_sync_cmd="/usr/bin/apt-mirror" ;;
        esac
    fi

    # Docker step only runs in hosted mode (cache mode rejects pushes).
    local docker_sync_cmd=""
    if [[ "${MIRRORET_ENABLE_DOCKER}" == "1" ]] && [[ "${MIRRORET_DOCKER_MODE:-cache}" == "hosted" ]]; then
        docker_sync_cmd="${MIRRORET_BASE_DIR}/scripts/sync-docker-images.sh"
    fi

    # We do NOT use `set -e` for the script body: we WANT the master to
    # run every step even if an earlier one fails, and we exit with the
    # accumulated failure count.
    cat > "$sync_script" <<SYNC_EOF
#!/usr/bin/env bash
set -Euo pipefail

${MIRRORET_MANAGED_MARKER}
# To disable individual sync steps, use --no-apt / --no-rpm / --no-pip
# / --no-docker / --no-npm at install time, or edit MIRRORET_ENABLE_*
# in /etc/mirroret/mirroret.conf and re-run install.sh.

BASE_DIR="${MIRRORET_BASE_DIR}"
LOG_DIR="\${BASE_DIR}/logs"
TIMESTAMP="\$(date +%Y%m%d-%H%M%S)"
mkdir -p "\$LOG_DIR"

LOG_FILE="\${LOG_DIR}/sync-all-\${TIMESTAMP}.log"
exec > >(tee -a "\$LOG_FILE") 2>&1

echo "=== Mirroret sync started: \$(date) ==="

FAILED=0

_run_step() {
    local name="\$1"; local script="\$2"
    if [[ -z "\$script" ]]; then
        echo "SKIP: \${name} (disabled by install configuration)"
        return 0
    fi
    if [[ -x "\$script" ]]; then
        echo "--- Syncing \${name}..."
        if "\$script"; then
            echo "OK: \${name}"
        else
            rc=\$?
            echo "FAILED: \${name} (exit \${rc})"
            FAILED=\$(( FAILED + 1 ))
        fi
    else
        echo "SKIP: \${name} (\${script} not found or not executable)"
    fi
}

_run_step "apt"         "${apt_sync_cmd}"
_run_step "RHEL repos"  "\${BASE_DIR}/scripts/sync-redhat-repos.sh"
_run_step "pip"         "\${BASE_DIR}/scripts/sync-pip-packages.sh"
_run_step "Docker"      "${docker_sync_cmd}"
_run_step "npm"         "\${BASE_DIR}/scripts/sync-npm-packages.sh"

echo "=== Mirroret sync completed: \$(date) (failures: \${FAILED}) ==="
exit "\${FAILED}"
SYNC_EOF

    chmod +x "$sync_script"
    success "Master sync script: ${sync_script}"
}

# ── Master cleanup script ────────────────────────────────────────────────────
# Generates a self-contained /srv/mirroret/scripts/cleanup-all.sh that
# performs retention (per-ecosystem prune + optional Docker GC). Weekly
# cron entry set up alongside the daily sync entry.
write_master_cleanup_script() {
    local cleanup_script="${MIRRORET_BASE_DIR}/scripts/cleanup-all.sh"

    if [[ "${DRY_RUN}" == "1" ]]; then
        info "[DRY-RUN] would write: ${cleanup_script}"
        return 0
    fi

    if ! preserve_user_customization "${cleanup_script}"; then
        return 0
    fi

    cat > "${cleanup_script}" <<CLEANUP_EOF
#!/usr/bin/env bash
set -Euo pipefail

${MIRRORET_MANAGED_MARKER}
# Retention / cleanup runner.
#
# Runs weekly via cron (Sunday ${MIRRORET_CLEANUP_HOUR}:00 by default).
# Also invokable manually: sudo ./install.sh --cleanup [--cleanup-report]
#
# All retention is OFF by default. Enable in /etc/mirroret/mirroret.conf:
#   MIRRORET_RETENTION_ENABLE=1
#   MIRRORET_RETENTION_MODE=prune       # (or 'report' for dry-run)
#   MIRRORET_RPM_KEEP_VERSIONS=3
#   MIRRORET_PIP_KEEP_VERSIONS=3
#   MIRRORET_NPM_KEEP_DAYS=180
#   MIRRORET_DOCKER_GC=0                # (1 needs brief registry restart)

BASE_DIR="${MIRRORET_BASE_DIR}"
LOG_DIR="\${BASE_DIR}/logs"
TIMESTAMP="\$(date +%Y%m%d-%H%M%S)"
mkdir -p "\$LOG_DIR"
LOG_FILE="\${LOG_DIR}/cleanup-\${TIMESTAMP}.log"
exec > >(tee -a "\$LOG_FILE") 2>&1

# Load /etc/mirroret/mirroret.conf if present.
if [[ -f /etc/mirroret/mirroret.conf ]]; then
    # shellcheck disable=SC1091
    . /etc/mirroret/mirroret.conf
fi

# Load retention library from the install tree.
INSTALL_DIR="${SCRIPT_DIR}"
if [[ ! -d "\${INSTALL_DIR}/lib" ]]; then
    echo "ERROR: mirroret install tree not found at \${INSTALL_DIR}"
    echo "Set INSTALL_DIR at the top of this script if you moved the repo."
    exit 2
fi
# shellcheck disable=SC1091
source "\${INSTALL_DIR}/lib/logging.sh"
# shellcheck disable=SC1091
source "\${INSTALL_DIR}/lib/common.sh"
# shellcheck disable=SC1091
source "\${INSTALL_DIR}/lib/retention.sh"

echo "=== Mirroret cleanup started: \$(date) ==="
run_retention
echo "=== Mirroret cleanup completed: \$(date) ==="
CLEANUP_EOF

    chmod +x "${cleanup_script}"
    success "Master cleanup script: ${cleanup_script}"
}

# ── Client config generation ──────────────────────────────────────────────────
generate_all_client_configs() {
    section "Generating Client Configuration Files"

    local config_dir="${MIRRORET_BASE_DIR}/config"
    mkdir -p "$config_dir"

    # APT and RPM client configs only make sense when this server actually
    # mirrors that ecosystem. Since configure_apt_mirror / configure_createrepo
    # are gated on DISTRO_TYPE, the client-config side must be too — otherwise
    # you get either a nonsense config or a hard fail (e.g. asking for the
    # Ubuntu codename of "9.8" on a RHEL host).
    if [[ "${MIRRORET_ENABLE_APT}" == "1" ]] && [[ "${DISTRO_TYPE}" == "debian" ]]; then
        generate_apt_client_config "${config_dir}/debian-client.list"
    fi

    if [[ "${MIRRORET_ENABLE_RPM}" == "1" ]] && [[ "${DISTRO_TYPE}" == "rhel" ]]; then
        generate_rpm_client_config "${config_dir}/redhat-client.repo"
    fi

    [[ "${MIRRORET_ENABLE_PIP}" == "1" ]] && \
        generate_pip_client_config "${config_dir}/pip.conf"

    [[ "${MIRRORET_ENABLE_DOCKER}" == "1" ]] && \
        generate_docker_client_config "${config_dir}/docker-daemon.json"

    [[ "${MIRRORET_ENABLE_NPM}" == "1" ]] && \
        generate_npm_client_config "${config_dir}/.npmrc"

    success "Client configs written to ${config_dir}/"
}

# ── Summary ───────────────────────────────────────────────────────────────────
print_summary() {
    local server_ip="${MIRRORET_SERVER_IP}"
    section "Installation Complete"

    echo ""
    echo "Server (HTTP):   http://${server_ip}:${MIRRORET_WEB_PORT}/"
    is_tls_ready && echo "Server (HTTPS):  https://${server_ip}:${MIRRORET_TLS_PORT}/"
    [[ "${MIRRORET_ENABLE_PIP}"    == "1" ]] && echo "pip index:       http://${server_ip}:${MIRRORET_PIP_PORT}/simple/"
    [[ "${MIRRORET_ENABLE_DOCKER}" == "1" ]] && echo "Docker registry: ${server_ip}:${MIRRORET_DOCKER_REGISTRY_PORT}"
    [[ "${MIRRORET_ENABLE_NPM}"    == "1" ]] && echo "npm registry:    http://${server_ip}:${MIRRORET_NPM_PORT}/"
    [[ "${MIRRORET_APPROVAL_ENABLED}" == "1" ]] && echo "Approval mode:   ON  (use --list-staging / --approve-all-pip etc.)"
    [[ -n "${MIRRORET_GPG_KEYID:-}" ]] && echo "GPG key:         ${MIRRORET_GPG_KEYID}"
    echo ""
    echo "Base directory:  ${MIRRORET_BASE_DIR}"
    echo "Client configs:  ${MIRRORET_BASE_DIR}/config/"
    echo "Sync scripts:    ${MIRRORET_BASE_DIR}/scripts/"
    echo "Logs:            ${MIRRORET_BASE_DIR}/logs/"
    echo ""
    echo "Next steps:"
    echo "  1. Run initial sync:  ${MIRRORET_BASE_DIR}/scripts/sync-all.sh"
    echo "  2. Verify:            $0 --check"
    echo "  3. Distribute client configs from ${MIRRORET_BASE_DIR}/config/"
    echo ""
    list_required_ports
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
    parse_args "$@"

    # Handle info-only modes first (no root required).
    if [[ "${MODE_LIST_BACKUPS}" == "1" ]]; then
        list_backups
        exit 0
    fi

    if [[ "${MODE_LIST_STAGING}" == "1" ]]; then
        list_staging
        exit 0
    fi

    # Set up log file (after root check for write permission).
    require_root

    local log_dir="/var/log"
    MIRRORET_LOG_FILE="${MIRRORET_LOG_FILE:-${log_dir}/mirroret-install.log}"
    export MIRRORET_LOG_FILE
    mkdir -p "$log_dir"
    info "Log file: ${MIRRORET_LOG_FILE}"

    # Handle non-install modes.
    if [[ "${MODE_CLEANUP}" == "1" ]] || [[ "${MODE_CLEANUP_REPORT}" == "1" ]]; then
        detect_distro
        if [[ "${MODE_CLEANUP_REPORT}" == "1" ]]; then
            retention_report
        else
            retention_prune
        fi
        exit $?
    fi

    if [[ "${MODE_CHECK}" == "1" ]]; then
        detect_distro
        run_validation
        exit $?
    fi

    if [[ "${MODE_STATUS}" == "1" ]]; then
        detect_distro
        print_status
        exit 0
    fi

    if [[ -n "${MODE_ROLLBACK}" ]]; then
        rollback "${MODE_ROLLBACK}"
        exit 0
    fi

    # Approval-workflow operations (require root for dir access).
    if [[ "${MODE_APPROVE_ALL_PIP}" == "1" ]]; then
        require_root
        approve_all_pip
        exit 0
    fi
    if [[ "${MODE_APPROVE_ALL_NPM}" == "1" ]]; then
        require_root
        approve_all_npm
        exit 0
    fi
    if [[ -n "${MODE_APPROVE_PACKAGE}" ]]; then
        require_root
        approve_pip_package "${MODE_APPROVE_PACKAGE}"
        exit 0
    fi
    if [[ -n "${MODE_EXCLUDE_PIP}" ]]; then
        require_root
        exclude_pip_package "${MODE_EXCLUDE_PIP}"
        exit 0
    fi
    if [[ -n "${MODE_EXCLUDE_NPM}" ]]; then
        require_root
        exclude_npm_package "${MODE_EXCLUDE_NPM}"
        exit 0
    fi

    # Detect distro before preflight so checks can use DISTRO_TYPE.
    detect_distro

    # Resolve server IP after distro detection (needs ip command).
    MIRRORET_SERVER_IP="${MIRRORET_SERVER_IP:-$(get_server_ip)}"
    export MIRRORET_SERVER_IP
    info "Server IP: ${MIRRORET_SERVER_IP}"

    # Pre-flight checks.
    run_preflight

    # Create a backup ID for this installation run.
    local backup_id
    backup_id="$(new_backup_id)"
    info "Backup ID: ${backup_id}"

    if [[ "${MODE_BACKUP_ONLY}" == "1" ]]; then
        info "Backup-only mode: backing up current state."
        _backup_existing_configs "$backup_id"
        info "Backup complete: ${MIRRORET_BACKUP_BASE}/${backup_id}/"
        exit 0
    fi

    # --upgrade fast-path assumes a prior install exists. Refuse if the
    # base directory doesn't yet exist — otherwise downstream steps
    # (nginx config, service start) fail with cryptic errors.
    if [[ "${MODE_UPGRADE}" == "1" ]] && [[ ! -d "${MIRRORET_BASE_DIR}" ]]; then
        die "--upgrade requires an existing install. ${MIRRORET_BASE_DIR} not found. Run a full install first: sudo ./install.sh"
    fi

    # Install system packages. In --upgrade mode we skip this because
    # dnf/apt-get with `-y` on already-installed packages is a slow no-op
    # (and can hit repo issues) — the operator is on the same code path
    # they already installed with, they just want configs refreshed.
    if [[ "${MODE_UPGRADE}" == "1" ]]; then
        info "Upgrade mode: skipping system package install."
    else
        install_system_packages
    fi

    # Create directory structure. Idempotent, but skip the noise on upgrade.
    if [[ "${MODE_UPGRADE}" == "1" ]]; then
        info "Upgrade mode: skipping directory structure step."
    else
        create_directory_structure
    fi

    # Ensure approval dirs exist when workflow is enabled.
    ensure_approval_dirs

    # TLS setup (before nginx so the TLS block can be appended).
    local tls_needs_setup=0
    [[ "${MIRRORET_TLS_SELF_SIGNED}" == "1" ]] && tls_needs_setup=1
    [[ -n "${MIRRORET_TLS_CERT}" && -n "${MIRRORET_TLS_KEY}" ]] && tls_needs_setup=1
    if [[ "${tls_needs_setup}" == "1" ]]; then
        setup_tls
    fi

    # GPG key provisioning.
    if [[ "${MIRRORET_GPG_AUTO}" == "1" ]] || [[ -n "${MIRRORET_GPG_KEYID}" ]]; then
        setup_gpg
        if [[ -n "${MIRRORET_APT_KEYRING:-}" ]]; then
            write_gpg_client_instructions \
                "${MIRRORET_BASE_DIR}/config/import-mirroret-gpg-key.sh"
        fi
    fi

    # Configure distro-specific APT/RPM mirror.
    if [[ "${MIRRORET_ENABLE_APT}" == "1" ]] && [[ "${DISTRO_TYPE}" == "debian" ]]; then
        configure_apt_mirror "$backup_id"
    fi
    if [[ "${MIRRORET_ENABLE_RPM}" == "1" ]] && [[ "${DISTRO_TYPE}" == "rhel" ]]; then
        configure_createrepo "$backup_id"
    fi

    # Configure additional services.
    [[ "${MIRRORET_ENABLE_PIP}"    == "1" ]] && setup_pip_repository    "$backup_id"
    [[ "${MIRRORET_ENABLE_DOCKER}" == "1" ]] && setup_docker_registry   "$backup_id"
    [[ "${MIRRORET_ENABLE_NPM}"    == "1" ]] && setup_npm_registry      "$backup_id"

    # Configure SELinux contexts on RHEL.
    if [[ "${DISTRO_TYPE}" == "rhel" ]]; then
        set_selinux_context "${MIRRORET_BASE_DIR}"
    fi

    # Configure nginx.
    configure_nginx_unified "$backup_id"

    # Generate client configs.
    generate_all_client_configs

    # Set up cron and master sync script.
    write_master_sync_script
    write_master_cleanup_script
    setup_cron

    # Configure firewall.
    if [[ "${MODE_NO_FIREWALL}" == "0" ]]; then
        local ports=("${MIRRORET_WEB_PORT}")
        is_tls_ready && ports+=("${MIRRORET_TLS_PORT}")
        [[ "${MIRRORET_ENABLE_PIP}"    == "1" ]] && ports+=("${MIRRORET_PIP_PORT}")
        [[ "${MIRRORET_ENABLE_DOCKER}" == "1" ]] && ports+=("${MIRRORET_DOCKER_REGISTRY_PORT}")
        [[ "${MIRRORET_ENABLE_NPM}"    == "1" ]] && ports+=("${MIRRORET_NPM_PORT}")
        configure_firewall "${ports[@]}"
    fi

    print_summary
}

_backup_existing_configs() {
    local backup_id="$1"
    backup_file "$backup_id" "/etc/apt/mirror.list"
    backup_file "$backup_id" "/etc/nginx/sites-available/mirroret-unified"
    backup_file "$backup_id" "/etc/nginx/sites-available/mirroret"
    backup_file "$backup_id" "/etc/nginx/conf.d/mirroret-unified.conf"
    backup_file "$backup_id" "/etc/nginx/conf.d/mirroret.conf"
    backup_file "$backup_id" "/etc/systemd/system/pypiserver.service"
    backup_file "$backup_id" "/etc/systemd/system/verdaccio.service"
    backup_file "$backup_id" "/etc/docker/registry/config.yml"
    backup_file "$backup_id" "/etc/docker-distribution/registry/config.yml"
    backup_file "$backup_id" "/etc/verdaccio/config.yaml"
}

main "$@"

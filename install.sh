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

# Mode flags.
MODE_CHECK=0
MODE_STATUS=0
MODE_BACKUP_ONLY=0
MODE_ROLLBACK=""
MODE_LIST_BACKUPS=0
MODE_NO_FIREWALL=0

# ── Argument parsing ──────────────────────────────────────────────────────────
parse_args() {
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
            --debug)
                LOG_LEVEL=DEBUG
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
  --debug                Enable debug logging
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
        xrun apt-get update -qq
        xrun ${PKG_MGR_INSTALL} \
            apt-mirror dpkg-dev nginx gnupg wget curl rsync cron
    else
        xrun ${PKG_MGR_INSTALL} \
            createrepo_c yum-utils nginx wget curl rsync cronie
        xrun systemctl enable --now crond || xrun systemctl enable --now cron || true
    fi

    success "System packages installed."
}

# ── Cron setup ────────────────────────────────────────────────────────────────
setup_cron() {
    local sync_script="${MIRRORET_BASE_DIR}/scripts/sync-all.sh"
    local cron_entry="0 ${MIRRORET_SYNC_HOUR} * * * ${sync_script}"

    section "Setting Up Automated Sync (cron)"

    if [[ "${DRY_RUN}" == "1" ]]; then
        info "[DRY-RUN] would add cron: ${cron_entry}"
        return 0
    fi

    # Idempotent: remove any existing mirroret sync entry, then add fresh.
    (crontab -l 2>/dev/null | grep -v "mirroret\|sync-all\.sh"; echo "$cron_entry") | crontab -
    success "Cron job: daily sync at ${MIRRORET_SYNC_HOUR}:00 AM."
}

# ── Master sync script ────────────────────────────────────────────────────────
write_master_sync_script() {
    local sync_script="${MIRRORET_BASE_DIR}/scripts/sync-all.sh"

    if [[ "${DRY_RUN}" == "1" ]]; then
        info "[DRY-RUN] would write: ${sync_script}"
        return 0
    fi

    cat > "$sync_script" <<SYNC_EOF
#!/usr/bin/env bash
set -Eeuo pipefail

BASE_DIR="${MIRRORET_BASE_DIR}"
LOG_DIR="\${BASE_DIR}/logs"
TIMESTAMP="\$(date +%Y%m%d-%H%M%S)"
mkdir -p "\$LOG_DIR"

echo "=== Mirroret sync started: \$(date) ==="

FAILED=0

_run_step() {
    local name="\$1"; local script="\$2"
    if [ -x "\$script" ]; then
        echo "--- Syncing \${name}..."
        "\$script" || { echo "FAILED: \${name}"; FAILED=\$(( FAILED + 1 )); }
    else
        echo "SKIP: \${name} (\${script} not found or not executable)"
    fi
}

_run_step "apt-mirror"  "/usr/bin/apt-mirror"
_run_step "RHEL repos"  "\${BASE_DIR}/scripts/sync-redhat-repos.sh"
_run_step "pip"         "\${BASE_DIR}/scripts/sync-pip-packages.sh"
_run_step "Docker"      "\${BASE_DIR}/scripts/sync-docker-images.sh"
_run_step "npm"         "\${BASE_DIR}/scripts/sync-npm-packages.sh"

echo "=== Mirroret sync completed: \$(date) (failures: \${FAILED}) ==="
exit "\${FAILED}"
SYNC_EOF

    chmod +x "$sync_script"
    success "Master sync script: ${sync_script}"
}

# ── Client config generation ──────────────────────────────────────────────────
generate_all_client_configs() {
    section "Generating Client Configuration Files"

    local config_dir="${MIRRORET_BASE_DIR}/config"
    mkdir -p "$config_dir"

    [[ "${MIRRORET_ENABLE_APT}" == "1" ]] && \
        generate_apt_client_config "${config_dir}/debian-client.list"

    [[ "${MIRRORET_ENABLE_RPM}" == "1" ]] && \
        generate_rpm_client_config "${config_dir}/redhat-client.repo"

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
    echo "Server:          http://${server_ip}:${MIRRORET_WEB_PORT}/"
    [[ "${MIRRORET_ENABLE_PIP}"    == "1" ]] && echo "pip index:       http://${server_ip}:${MIRRORET_PIP_PORT}/simple/"
    [[ "${MIRRORET_ENABLE_DOCKER}" == "1" ]] && echo "Docker registry: ${server_ip}:${MIRRORET_DOCKER_REGISTRY_PORT}"
    [[ "${MIRRORET_ENABLE_NPM}"    == "1" ]] && echo "npm registry:    http://${server_ip}:${MIRRORET_NPM_PORT}/"
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

    # Set up log file (after root check for write permission).
    require_root

    local log_dir="/var/log"
    MIRRORET_LOG_FILE="${MIRRORET_LOG_FILE:-${log_dir}/mirroret-install.log}"
    export MIRRORET_LOG_FILE
    mkdir -p "$log_dir"
    info "Log file: ${MIRRORET_LOG_FILE}"

    # Handle non-install modes.
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

    # Install system packages.
    install_system_packages

    # Create directory structure.
    create_directory_structure

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
    setup_cron

    # Configure firewall.
    if [[ "${MODE_NO_FIREWALL}" == "0" ]]; then
        local ports=("${MIRRORET_WEB_PORT}")
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
    backup_file "$backup_id" "/etc/verdaccio/config.yaml"
}

main "$@"

#!/usr/bin/env bash
# mirroret uninstaller - selective and full removal.
# Run --help for the full flag reference.

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load lib modules. logging.sh + common.sh first so xrun/info/warn exist;
# distro.sh provides selinux helpers that uninstall.sh's SELinux step uses;
# uninstall.sh is the actual remover.
# shellcheck source=lib/logging.sh
source "${SCRIPT_DIR}/lib/logging.sh"

# Load the operator's config BEFORE lib/uninstall.sh sets its defaults with
# ${VAR:-default}, so a custom MIRRORET_BASE_DIR / ports / service users are
# what gets removed rather than the stock paths.
MIRRORET_CONF="${MIRRORET_CONF:-/etc/mirroret/mirroret.conf}"
if [[ -f "${MIRRORET_CONF}" ]]; then
    # shellcheck source=/dev/null
    source "${MIRRORET_CONF}"
    debug "Loaded config: ${MIRRORET_CONF}"
fi

# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/distro.sh
source "${SCRIPT_DIR}/lib/distro.sh"
# shellcheck source=lib/uninstall.sh
source "${SCRIPT_DIR}/lib/uninstall.sh"

# Quick --help short-circuit (no root needed).
for arg in "$@"; do
    case "$arg" in
        -h|--help)
            _uninstall_usage
            exit 0
            ;;
        --list|--dry-run)
            : # handled inside uninstall_main, but allow without root
            ;;
    esac
done

# --list and --dry-run are safe without root. Everything else needs root.
case " $* " in
    *" --list "*|*" --dry-run "*)
        :
        ;;
    *)
        require_root
        ;;
esac

# Set up an uninstall-specific log file ONLY when we can actually write
# to it. Non-root --list / --dry-run runs leave MIRRORET_LOG_FILE unset
# rather than spamming permission-denied warnings.
if [[ "$(id -u)" == "0" ]] || [[ -n "${MIRRORET_LOG_FILE:-}" ]]; then
    MIRRORET_LOG_FILE="${MIRRORET_LOG_FILE:-/var/log/mirroret-uninstall.log}"
    mkdir -p "$(dirname "${MIRRORET_LOG_FILE}")" 2>/dev/null || true
    # Touch test: if the file isn't actually writable, drop the variable.
    if ! ( : >> "${MIRRORET_LOG_FILE}" ) 2>/dev/null; then
        unset MIRRORET_LOG_FILE
    else
        export MIRRORET_LOG_FILE
    fi
fi

uninstall_main "$@"

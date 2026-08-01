#!/usr/bin/env bash
# Logging utilities for mirroret.
# Source this file; do not execute it directly.

# Honour LOG_LEVEL=DEBUG to enable debug output. Anything else only shows
# info/warn/error/success.
LOG_LEVEL="${LOG_LEVEL:-INFO}"

# Output goes to stderr so it doesn't pollute stdout pipelines.
# All messages are also appended to MIRRORET_LOG_FILE when that variable is set.

_log() {
    local level="$1"; shift
    local ts
    ts="$(date '+%Y-%m-%d %H:%M:%S')"
    local line="[${level}] ${ts} $*"
    echo "$line" >&2
    # Append to the log file when one is configured, but never let a
    # permission/disk-full error abort the script. Caller's set -e/-u
    # must not see a non-zero exit from logging.
    if [[ -n "${MIRRORET_LOG_FILE:-}" ]]; then
        printf '%s\n' "$line" >> "$MIRRORET_LOG_FILE" 2>/dev/null || true
    fi
}

info() { _log "INFO " "$@"; }
warn() { _log "WARN " "$@"; }
error() { _log "ERROR" "$@"; }
success() { _log "OK " "$@"; }
debug() {
    [[ "${LOG_LEVEL}" == "DEBUG" ]] && _log "DEBUG" "$@" || true
}

# Print a section header so output is scannable.
section() {
    local msg="$1"
    local line="----------------------------------------------"
    _log "INFO " ""
    _log "INFO " "${line}"
    _log "INFO " " ${msg}"
    _log "INFO " "${line}"
}

# die <message> - print error then exit 1.
die() {
    error "$@"
    exit 1
}

# warn_insecure <message> - highly visible warning for insecure-mode paths.
warn_insecure() {
    local border="!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    echo "" >&2
    echo "$border" >&2
    echo "!! SECURITY WARNING: $*" >&2
    echo "$border" >&2
    echo "" >&2
    # Fail-soft like _log: a permission/disk error here must not abort a
    # caller running under set -e.
    if [[ -n "${MIRRORET_LOG_FILE:-}" ]]; then
        {
            printf '\n%s\n!! SECURITY WARNING: %s\n%s\n' \
                "$border" "$*" "$border"
        } >> "$MIRRORET_LOG_FILE" 2>/dev/null || true
    fi
}

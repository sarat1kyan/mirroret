#!/usr/bin/env bash
# Common utilities and DRY_RUN support for mirroret.
# Source this file; do not execute it directly.
# Requires logging.sh to be sourced first.

# ── DRY_RUN support ──────────────────────────────────────────────────────────
# Set DRY_RUN=1 (or pass --dry-run) to prevent any system modifications.
# The run() wrapper below honours this flag.
DRY_RUN="${DRY_RUN:-0}"

# run <cmd> [args...] — execute a command unless DRY_RUN is active.
xrun() {
    if [[ "${DRY_RUN}" == "1" ]]; then
        info "[DRY-RUN] would run: $*"
        return 0
    fi
    debug "running: $*"
    "$@"
}

# run_quietly <cmd> — run but suppress stdout/stderr (still logs on failure).
run_quietly() {
    if [[ "${DRY_RUN}" == "1" ]]; then
        info "[DRY-RUN] would run: $*"
        return 0
    fi
    debug "running quietly: $*"
    if ! "$@" > /tmp/mirroret_cmd_out 2>&1; then
        error "command failed: $*"
        cat /tmp/mirroret_cmd_out >&2
        return 1
    fi
}

# write_file <path> <content> — write content to a file (respects DRY_RUN).
# Use a here-string or process substitution for multi-line content.
write_file() {
    local path="$1"
    local content="$2"
    if [[ "${DRY_RUN}" == "1" ]]; then
        info "[DRY-RUN] would write to: ${path}"
        return 0
    fi
    printf '%s\n' "$content" > "$path"
}

# ── Root/privilege checks ─────────────────────────────────────────────────────

require_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        die "This script must be run as root (sudo $0 $*)."
    fi
}

# ── Command existence checks ─────────────────────────────────────────────────

require_command() {
    local cmd="$1"
    if ! command -v "$cmd" &>/dev/null; then
        die "Required command not found: ${cmd}. Install it and try again."
    fi
}

# check_command <cmd> — returns 0 if present, 1 if missing (non-fatal).
check_command() {
    command -v "$1" &>/dev/null
}

# ── Atomic file writes ───────────────────────────────────────────────────────

# atomic_write <dest> <tmpfile> — move tmpfile to dest only after validation.
# Use this to avoid leaving a broken config on disk if generation fails.
atomic_write() {
    local dest="$1"
    local tmp="$2"
    if [[ "${DRY_RUN}" == "1" ]]; then
        info "[DRY-RUN] would move ${tmp} -> ${dest}"
        return 0
    fi
    mv "$tmp" "$dest"
}

# ── Idempotency helpers ──────────────────────────────────────────────────────

# file_contains <file> <pattern> — true if file exists and contains the pattern.
file_contains() {
    local file="$1"
    local pattern="$2"
    [[ -f "$file" ]] && grep -qF "$pattern" "$file"
}

# service_is_active <name> — true if a systemd service is active.
service_is_active() {
    systemctl is-active --quiet "$1" 2>/dev/null
}

# service_is_enabled <name> — true if a systemd service is enabled.
service_is_enabled() {
    systemctl is-enabled --quiet "$1" 2>/dev/null
}

# container_exists <name> — true if a Docker container exists (any state).
container_exists() {
    docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$1"
}

# container_is_running <name> — true if a Docker container is running.
container_is_running() {
    docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$1"
}

# ── Temporary file helpers ───────────────────────────────────────────────────

# mktemp_file — create a temp file and print its path.
mktemp_file() {
    mktemp /tmp/mirroret.XXXXXX
}

# ── Misc ─────────────────────────────────────────────────────────────────────

# get_server_ip — return the primary non-loopback IPv4 address.
# Can be overridden by setting MIRRORET_SERVER_IP.
#
# Strategy (each step skipped silently on failure / empty output):
#   1. MIRRORET_SERVER_IP override
#   2. Address used to reach the default gateway (works air-gapped: a
#      default route only needs to exist, not actually go to the internet)
#   3. First non-loopback, non-link-local global-scope IPv4 address on
#      any interface (no route required)
#   4. Legacy `hostname -I` first field
#   5. Loud, actionable error
get_server_ip() {
    if [[ -n "${MIRRORET_SERVER_IP:-}" ]]; then
        echo "$MIRRORET_SERVER_IP"
        return 0
    fi

    local ip=""

    if check_command ip; then
        # Step 2: route via the default gateway. Does not require Internet.
        local gw
        gw="$(ip -4 route show default 2>/dev/null | awk '/default/ {print $3; exit}')"
        if [[ -n "$gw" ]]; then
            ip="$(ip -4 route get "$gw" 2>/dev/null | awk '/src/ {for (i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}')"
        fi

        # Step 3: first global-scope IPv4 on any interface.
        if [[ -z "$ip" ]]; then
            ip="$(ip -4 -o addr show scope global 2>/dev/null \
                | awk '{print $4}' | head -1 | cut -d/ -f1)"
        fi
    fi

    # Step 4: legacy fallback.
    if [[ -z "$ip" ]] && check_command hostname; then
        ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
    fi

    if [[ -z "$ip" ]]; then
        error "Could not determine the server's IPv4 address."
        error "Set MIRRORET_SERVER_IP explicitly, e.g.:"
        error "    sudo MIRRORET_SERVER_IP=192.168.1.10 ./install.sh"
        return 1
    fi

    echo "$ip"
}

# confirm <prompt> — ask the user y/n; returns 0 for yes, 1 for no.
# In non-interactive mode (MIRRORET_NON_INTERACTIVE=1), defaults to no.
confirm() {
    local prompt="${1:-Continue?}"
    if [[ "${MIRRORET_NON_INTERACTIVE:-0}" == "1" ]]; then
        warn "Non-interactive mode: auto-declining: ${prompt}"
        return 1
    fi
    read -r -p "${prompt} [y/N] " reply
    [[ "${reply}" =~ ^[Yy]$ ]]
}

# confirm_yes <prompt> — like confirm but defaults to yes in non-interactive.
confirm_yes() {
    local prompt="${1:-Continue?}"
    if [[ "${MIRRORET_NON_INTERACTIVE:-0}" == "1" ]]; then
        debug "Non-interactive mode: auto-confirming: ${prompt}"
        return 0
    fi
    read -r -p "${prompt} [Y/n] " reply
    [[ -z "$reply" || "${reply}" =~ ^[Yy]$ ]]
}

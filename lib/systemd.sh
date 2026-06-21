#!/usr/bin/env bash
# systemd unit management for mirroret.
# Source this file; do not execute it directly.
# Requires logging.sh, common.sh, backup.sh.

# write_systemd_unit <backup_id> <unit_name> <unit_content>
# Writes a systemd unit file and reloads the daemon only once.
write_systemd_unit() {
    local backup_id="$1"
    local unit_name="$2"
    local unit_content="$3"
    local unit_file="/etc/systemd/system/${unit_name}"

    backup_file "$backup_id" "$unit_file"

    if [[ "${DRY_RUN}" == "1" ]]; then
        info "[DRY-RUN] would write unit file: ${unit_file}"
        return 0
    fi

    printf '%s\n' "$unit_content" > "$unit_file"
    info "Wrote unit file: ${unit_file}"
    # Deferred daemon-reload — call systemd_daemon_reload once after all units are written.
}

# systemd_daemon_reload — run daemon-reload only when unit files have changed.
systemd_daemon_reload() {
    if [[ "${DRY_RUN}" == "1" ]]; then
        info "[DRY-RUN] would run: systemctl daemon-reload"
        return 0
    fi
    xrun systemctl daemon-reload
    debug "systemd daemon-reload complete."
}

# enable_and_start <service> — enable and start a systemd service.
# Idempotent: skips start if already running.
enable_and_start() {
    local svc="$1"

    if [[ "${DRY_RUN}" == "1" ]]; then
        info "[DRY-RUN] would enable and start: ${svc}"
        return 0
    fi

    xrun systemctl enable "$svc"

    if service_is_active "$svc"; then
        xrun systemctl restart "$svc"
    else
        xrun systemctl start "$svc"
    fi

    # Verify it started.
    if ! service_is_active "$svc"; then
        error "Service failed to start: ${svc}"
        error "Check: journalctl -u ${svc} -n 50 --no-pager"
        return 1
    fi

    success "Service ${svc} is running."
}

# check_service_status <service> — print human-readable status.
check_service_status() {
    local svc="$1"
    if service_is_active "$svc"; then
        success "${svc}: running"
    else
        warn "${svc}: not running"
    fi
}

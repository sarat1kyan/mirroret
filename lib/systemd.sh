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
    # Deferred daemon-reload - call systemd_daemon_reload once after all units are written.
}

# systemd_daemon_reload - run daemon-reload only when unit files have changed.
systemd_daemon_reload() {
    if [[ "${DRY_RUN}" == "1" ]]; then
        info "[DRY-RUN] would run: systemctl daemon-reload"
        return 0
    fi
    xrun systemctl daemon-reload
    debug "systemd daemon-reload complete."
}

# enable_and_start <service> - enable and start a systemd service.
# Idempotent: skips start if already running.
enable_and_start() {
    local svc="$1"

    if [[ "${DRY_RUN}" == "1" ]]; then
        info "[DRY-RUN] would enable and start: ${svc}"
        return 0
    fi

    xrun systemctl enable "$svc"

    # Clear failed state so start works cleanly on a broken previous install.
    systemctl reset-failed "$svc" 2>/dev/null || true

    if service_is_active "$svc"; then
        xrun systemctl restart "$svc"
    else
        xrun systemctl start "$svc"
    fi

    # Verify it started. A unit whose ExecStart path does not exist enters
    # "activating (auto-restart)" and never reaches active, so poll briefly
    # instead of checking once.
    local waited=0
    while [[ "$waited" -lt 10 ]]; do
        service_is_active "$svc" && break
        sleep 1
        waited=$(( waited + 1 ))
    done

    if ! service_is_active "$svc"; then
        error "Service failed to start: ${svc}"

        # status=203/EXEC means systemd could not exec ExecStart at all.
        # Surface the offending path directly; the generic
        # "check journalctl" message sent operators on a long detour.
        local exec_path=""
        exec_path="$(systemctl show -p ExecStart --value "$svc" 2>/dev/null \
            | sed -n 's/.*path=\([^ ;]*\).*/\1/p' | head -1)"
        if [[ -n "$exec_path" ]] && [[ ! -x "$exec_path" ]]; then
            error "ExecStart binary is missing or not executable: ${exec_path}"
            error "The unit cannot start until that path exists (systemd reports 203/EXEC)."
        fi

        local state
        state="$(systemctl is-active "$svc" 2>/dev/null || true)"
        [[ -n "$state" ]] && error "Current state: ${state}"
        error "Check: journalctl -u ${svc} -n 50 --no-pager"
        return 1
    fi

    success "Service ${svc} is running."
}

# check_service_status <service> - print human-readable status.
check_service_status() {
    local svc="$1"
    if service_is_active "$svc"; then
        success "${svc}: running"
    else
        warn "${svc}: not running"
    fi
}

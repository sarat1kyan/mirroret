#!/usr/bin/env bash
# Backup and restore utilities for mirroret.
# Source this file; do not execute it directly.
# Requires logging.sh and common.sh.

MIRRORET_BACKUP_BASE="${MIRRORET_BACKUP_BASE:-/var/backups/mirroret}"

# ── Backup ID ────────────────────────────────────────────────────────────────

# new_backup_id — create a new timestamped backup directory and print its ID.
new_backup_id() {
    local ts
    ts="$(date '+%Y%m%d-%H%M%S')"
    local dir="${MIRRORET_BACKUP_BASE}/${ts}"
    if [[ "${DRY_RUN}" == "1" ]]; then
        info "[DRY-RUN] would create backup dir: ${dir}"
        echo "${ts}"
        return 0
    fi
    mkdir -p "$dir"
    echo "$ts"
}

# ── File backup ──────────────────────────────────────────────────────────────

# backup_file <backup_id> <filepath> — copy filepath into the backup directory.
# If filepath does not exist, records a note but does not fail.
backup_file() {
    local backup_id="$1"
    local filepath="$2"
    local dest_dir="${MIRRORET_BACKUP_BASE}/${backup_id}"

    if [[ "${DRY_RUN}" == "1" ]]; then
        info "[DRY-RUN] would backup: ${filepath} -> ${dest_dir}/"
        return 0
    fi

    mkdir -p "$dest_dir"

    if [[ ! -e "$filepath" ]]; then
        echo "MISSING ${filepath}" >> "${dest_dir}/backup.manifest"
        debug "backup_file: ${filepath} does not exist, recorded as missing."
        return 0
    fi

    # Preserve directory structure within the backup.
    local rel="${filepath#/}"
    local dest_path="${dest_dir}/${rel}"
    mkdir -p "$(dirname "$dest_path")"
    cp -a "$filepath" "$dest_path"
    echo "OK ${filepath}" >> "${dest_dir}/backup.manifest"
    debug "Backed up ${filepath} -> ${dest_path}"
}

# ── List backups ─────────────────────────────────────────────────────────────

list_backups() {
    if [[ ! -d "${MIRRORET_BACKUP_BASE}" ]]; then
        info "No backups found (${MIRRORET_BACKUP_BASE} does not exist)."
        return 0
    fi
    local found=0
    for d in "${MIRRORET_BACKUP_BASE}"/*/; do
        [[ -d "$d" ]] || continue
        local id
        id="$(basename "$d")"
        local manifest="${d}/backup.manifest"
        local count=0
        [[ -f "$manifest" ]] && count=$(wc -l < "$manifest")
        echo "  ${id}  (${count} files)"
        found=1
    done
    [[ "$found" == "0" ]] && info "No backups found."
}

# ── Rollback ─────────────────────────────────────────────────────────────────

# rollback <backup_id> — restore files from a backup directory.
# Files that were MISSING at backup time are skipped.
# This is best-effort: individual failures are logged but do not abort.
rollback() {
    local backup_id="$1"
    local backup_dir="${MIRRORET_BACKUP_BASE}/${backup_id}"

    if [[ ! -d "$backup_dir" ]]; then
        die "Backup not found: ${backup_dir}"
    fi

    local manifest="${backup_dir}/backup.manifest"
    if [[ ! -f "$manifest" ]]; then
        die "Backup manifest missing: ${manifest}"
    fi

    section "Rolling back from backup: ${backup_id}"

    local restored=0
    local skipped=0
    local failed=0

    while IFS=" " read -r status original_path; do
        if [[ "$status" == "MISSING" ]]; then
            debug "Skipping (was missing at backup time): ${original_path}"
            (( skipped += 1 ))
            continue
        fi

        local rel="${original_path#/}"
        local src="${backup_dir}/${rel}"

        if [[ ! -e "$src" ]]; then
            warn "Backup copy not found: ${src} (skipping)"
            (( failed += 1 ))
            continue
        fi

        if [[ "${DRY_RUN}" == "1" ]]; then
            info "[DRY-RUN] would restore: ${src} -> ${original_path}"
            (( restored += 1 ))
            continue
        fi

        mkdir -p "$(dirname "$original_path")"
        if cp -a "$src" "$original_path"; then
            info "Restored: ${original_path}"
            (( restored += 1 ))
        else
            warn "Failed to restore: ${original_path}"
            (( failed += 1 ))
        fi
    done < "$manifest"

    info "Rollback complete: ${restored} restored, ${skipped} skipped, ${failed} failed."
    [[ "$failed" -gt 0 ]] && warn "Some files could not be restored. Check the above output."

    # Reload affected services.
    if [[ "${DRY_RUN}" != "1" ]]; then
        _post_rollback_reload
    fi
}

_post_rollback_reload() {
    info "Reloading services after rollback..."

    if check_command nginx && service_is_active nginx; then
        if nginx -t &>/dev/null; then
            xrun systemctl reload nginx || xrun systemctl restart nginx || true
        else
            warn "nginx config validation failed after rollback. Not reloading nginx."
        fi
    fi

    if service_is_active pypiserver; then
        xrun systemctl restart pypiserver || true
    fi

    if service_is_active verdaccio; then
        xrun systemctl restart verdaccio || true
    fi
}

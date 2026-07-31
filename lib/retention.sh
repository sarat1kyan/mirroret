#!/usr/bin/env bash
# Mirror-data retention / cleanup for mirroret.
# Source this file; do not execute it directly.
# Requires logging.sh, common.sh.
#
# Retention is OPT-IN. The default policy is "keep everything forever"
# because that's what most mirror operators want. Enable via env:
#
#   MIRRORET_RETENTION_ENABLE=1        turn cleanup on
#   MIRRORET_RETENTION_MODE=report     dry-run — logs what would be removed
#   MIRRORET_RETENTION_MODE=prune      actually delete
#
# Per-ecosystem knobs (all take effect only when RETENTION_ENABLE=1):
#   MIRRORET_RPM_KEEP_VERSIONS=3       keep 3 newest of each RPM (0 = disable)
#   MIRRORET_PIP_KEEP_VERSIONS=3       keep 3 newest wheels/sdists per pkg
#   MIRRORET_NPM_KEEP_DAYS=180         drop npm tarballs older than N days
#   MIRRORET_DOCKER_GC=0               run registry garbage-collect (needs
#                                      brief downtime; default off)
#
# Public API:
#   run_retention          run all enabled retention steps
#   retention_report       force report mode regardless of MODE env
#   retention_prune        force prune mode regardless of MODE env

MIRRORET_RETENTION_ENABLE="${MIRRORET_RETENTION_ENABLE:-0}"
MIRRORET_RETENTION_MODE="${MIRRORET_RETENTION_MODE:-report}"
MIRRORET_RPM_KEEP_VERSIONS="${MIRRORET_RPM_KEEP_VERSIONS:-3}"
MIRRORET_PIP_KEEP_VERSIONS="${MIRRORET_PIP_KEEP_VERSIONS:-3}"
MIRRORET_NPM_KEEP_DAYS="${MIRRORET_NPM_KEEP_DAYS:-180}"
MIRRORET_DOCKER_GC="${MIRRORET_DOCKER_GC:-0}"

# Set to 1 by retention_rpm_prune when packages were deleted but repodata
# could not be rebuilt. run_retention turns this into a non-zero exit.
RETENTION_METADATA_BROKEN=0

# ── Helpers ──────────────────────────────────────────────────────────────────

# _ret_int <name> <value> <default> - validate a numeric knob. A non-numeric
# value used to make `[[ "$keep" -le 0 ]]` evaluate true, silently disabling
# retention with no warning. Now it warns and falls back to the default.
_ret_int() {
    local name="$1" val="$2" def="$3"
    if [[ "$val" =~ ^[0-9]+$ ]]; then
        printf '%s' "$val"
        return 0
    fi
    warn "${name}='${val}' is not a number. Using default ${def}."
    printf '%s' "$def"
}

# _ret_mode - return the effective mode: prune | report. Anything unrecognised
# collapses to report (safest).
_ret_mode() {
    case "${MIRRORET_RETENTION_MODE:-report}" in
        prune) echo prune ;;
        *)     echo report ;;
    esac
}

# _ret_do <label> <cmd...> — in prune mode run the command; in report mode
# log what would run. Never let a single failure abort the caller.
_ret_do() {
    local label="$1"; shift
    if [[ "$(_ret_mode)" == "report" ]]; then
        info "[report] ${label}"
        return 0
    fi
    debug "retention: ${label}"
    if "$@"; then
        info "[pruned] ${label}"
    else
        warn "[fail]  ${label}"
    fi
}

# ── RPM: keep N newest of each package name ──────────────────────────────────

retention_rpm_prune() {
    local keep
    keep="$(_ret_int MIRRORET_RPM_KEEP_VERSIONS "${MIRRORET_RPM_KEEP_VERSIONS:-3}" 3)"
    [[ "$keep" -le 0 ]] && { debug "RPM retention disabled (keep=0)."; return 0; }

    local base_dir="${MIRRORET_BASE_DIR:-/srv/mirroret}"
    local mirror_root="${base_dir}/redhat/mirror"
    [[ -d "$mirror_root" ]] || { debug "No RPM mirror at ${mirror_root}."; return 0; }

    section "RPM retention (keep=${keep})"

    if ! check_command repomanage; then
        warn "repomanage not found (install dnf-utils). Skipping RPM retention."
        return 0
    fi

    local createrepo_cmd
    if check_command createrepo_c; then createrepo_cmd=createrepo_c
    elif check_command createrepo;   then createrepo_cmd=createrepo
    else warn "createrepo not found. Skipping RPM retention."; return 0
    fi

    # Walk each leaf repo (dir containing 'repodata/').
    while IFS= read -r -d '' repodata; do
        local repo_dir
        repo_dir="$(dirname "$repodata")"
        info "Repo: ${repo_dir}"

        # repomanage --old prints the list of RPMs older than the newest
        # KEEP for each package name. Empty output means nothing to prune.
        local old_list
        old_list="$(repomanage --keep="$keep" --old "$repo_dir" 2>/dev/null || true)"
        if [[ -z "$old_list" ]]; then
            info "  nothing to prune"
            continue
        fi

        local count
        count="$(printf '%s\n' "$old_list" | wc -l | tr -d ' ')"
        info "  ${count} old RPM(s) to prune"

        if [[ "$(_ret_mode)" == "prune" ]]; then
            printf '%s\n' "$old_list" | xargs -r rm -f
            # Metadata MUST be rebuilt after deleting packages, otherwise
            # repomd.xml still advertises files that are gone and every
            # client dnf call hard-fails. Retry once, then surface loudly.
            if ! "${createrepo_cmd}" --update "$repo_dir" >/dev/null 2>&1; then
                warn "  createrepo --update failed; retrying without --update"
                if ! "${createrepo_cmd}" "$repo_dir" >/dev/null 2>&1; then
                    error "  METADATA STALE for ${repo_dir}"
                    error "  Packages were deleted but repodata was not rebuilt."
                    error "  Clients will fail until you run: ${createrepo_cmd} ${repo_dir}"
                    RETENTION_METADATA_BROKEN=1
                    continue
                fi
            fi
            info "  [pruned] ${count} RPM(s) removed, metadata refreshed"
        else
            info "  [report] would remove ${count} RPM(s) — sample:"
            printf '%s\n' "$old_list" | head -3 | while IFS= read -r f; do
                info "    ${f}"
            done
        fi
    done < <(find "$mirror_root" -type d -name repodata -print0 2>/dev/null)
}

# ── pip: keep N newest wheels/sdists per package ─────────────────────────────

retention_pip_prune() {
    local keep
    keep="$(_ret_int MIRRORET_PIP_KEEP_VERSIONS "${MIRRORET_PIP_KEEP_VERSIONS:-3}" 3)"
    [[ "$keep" -le 0 ]] && { debug "pip retention disabled (keep=0)."; return 0; }

    local base_dir="${MIRRORET_BASE_DIR:-/srv/mirroret}"
    # Look in both approval-mode and standard-mode locations.
    local candidates=(
        "${base_dir}/pip/approved"
        "${base_dir}/approved/pip"
    )

    section "pip retention (keep=${keep} per package)"

    local dir
    for dir in "${candidates[@]}"; do
        [[ -d "$dir" ]] || continue
        info "Directory: ${dir}"

        # Extract unique package names (everything before the first "-<digit>").
        # We use POSIX-portable ls | sed instead of GNU find -printf, so this
        # works on BSD/macOS as well as Linux (retention is Linux-only in
        # production, but tests run on macOS).
        local pkg
        while IFS= read -r pkg; do
            [[ -z "$pkg" ]] && continue

            # Order by VERSION, newest last, then reverse. Ordering by mtime
            # (the old `ls -t`) deleted genuinely newer releases whenever an
            # older one happened to be re-downloaded more recently.
            # `sort -V` understands dotted version strings.
            local -a all=()
            while IFS= read -r f; do
                [[ -z "$f" ]] && continue
                all+=("$f")
            done < <(
                cd "$dir" 2>/dev/null || return 0
                # shellcheck disable=SC2012
                ls -1 "${pkg}"-[0-9]*.whl "${pkg}"-[0-9]*.tar.gz "${pkg}"-[0-9]*.zip 2>/dev/null \
                    | sort -V -r
            )

            local total="${#all[@]}"
            if [[ "$total" -le "$keep" ]]; then
                debug "  ${pkg}: ${total} version(s), within keep"
                continue
            fi

            local to_prune=$(( total - keep ))
            info "  ${pkg}: ${total} version(s), pruning ${to_prune}"

            local i=0
            for f in "${all[@]}"; do
                (( i += 1 )) || true
                (( i > keep )) || continue
                _ret_do "rm ${f}" rm -f "${dir}/${f}"
            done
        done < <(
            cd "$dir" 2>/dev/null || return 0
            # shellcheck disable=SC2012
            ls -1 *.whl *.tar.gz *.zip 2>/dev/null \
                | sed -E 's/-[0-9].*$//' | sort -u
        )
    done
}

# ── npm: delete tarballs older than N days ───────────────────────────────────

# _npm_storage_is_verdaccio <dir> - true when <dir> looks like a live
# Verdaccio storage root (it keeps a package.json per package dir).
_npm_storage_is_verdaccio() {
    local dir="$1"
    [[ -d "$dir" ]] || return 1
    find "$dir" -maxdepth 2 -name 'package.json' -print -quit 2>/dev/null | grep -q .
}

retention_npm_prune() {
    local days
    days="$(_ret_int MIRRORET_NPM_KEEP_DAYS "${MIRRORET_NPM_KEEP_DAYS:-180}" 180)"
    [[ "$days" -le 0 ]] && { debug "npm retention disabled (days=0)."; return 0; }

    local base_dir="${MIRRORET_BASE_DIR:-/srv/mirroret}"
    local candidates=(
        "${base_dir}/npm/approved"
        "${base_dir}/approved/npm"
    )

    section "npm retention (drop tarballs older than ${days} days)"

    local dir
    for dir in "${candidates[@]}"; do
        [[ -d "$dir" ]] || continue
        info "Directory: ${dir}"

        # Verdaccio keeps a package.json alongside each package's tarballs.
        # Deleting .tgz files underneath it leaves the metadata advertising
        # versions that then 404 for every client. Refuse to touch it unless
        # the operator has explicitly accepted that.
        if _npm_storage_is_verdaccio "$dir"; then
            if [[ "${MIRRORET_NPM_PRUNE_STORAGE:-0}" != "1" ]]; then
                warn "  ${dir} is a live Verdaccio storage root - skipping."
                warn "  Raw .tgz deletion desyncs Verdaccio metadata (clients get 404)."
                warn "  Prune properly with: npm unpublish <pkg>@<ver> --registry http://localhost:${MIRRORET_NPM_PORT:-4873}"
                warn "  Or set MIRRORET_NPM_PRUNE_STORAGE=1 to override (not recommended)."
                continue
            fi
            warn "  MIRRORET_NPM_PRUNE_STORAGE=1 - pruning a live Verdaccio store."
            warn "  Verdaccio metadata may advertise removed versions afterwards."
        fi

        local count
        count="$(find "$dir" -type f -name '*.tgz' -mtime "+${days}" 2>/dev/null | wc -l | tr -d ' ')"
        if [[ "$count" -eq 0 ]]; then
            info "  nothing older than ${days} days"
            continue
        fi

        info "  ${count} tarball(s) to prune"
        if [[ "$(_ret_mode)" == "prune" ]]; then
            find "$dir" -type f -name '*.tgz' -mtime "+${days}" -delete 2>/dev/null || \
                warn "  some tarballs could not be deleted"
            info "  [pruned] ${count} tarball(s) removed"
        else
            info "  [report] would remove:"
            find "$dir" -type f -name '*.tgz' -mtime "+${days}" 2>/dev/null | head -3 | \
                while IFS= read -r f; do info "    ${f}"; done
        fi
    done
}

# ── Docker registry: garbage-collect unreferenced blobs ──────────────────────
# Requires a brief downtime (few seconds) — the registry must be stopped.

retention_docker_gc() {
    [[ "${MIRRORET_DOCKER_GC:-0}" == "1" ]] || { debug "Docker GC disabled."; return 0; }

    local conf=""
    for c in /etc/docker-distribution/registry/config.yml /etc/docker/registry/config.yml; do
        [[ -f "$c" ]] && conf="$c" && break
    done
    if [[ -z "$conf" ]]; then
        warn "No registry config.yml found; skipping Docker GC."
        return 0
    fi

    section "Docker registry garbage-collect"
    info "Config: ${conf}"

    if [[ "$(_ret_mode)" == "report" ]]; then
        info "[report] would stop registry, run garbage-collect on ${conf}, restart"
        return 0
    fi

    # Detect service or container-managed registry.
    local svc=""
    for candidate in mirroret-registry docker-distribution docker-registry; do
        if systemctl list-unit-files --full --no-legend "${candidate}.service" 2>/dev/null \
                | grep -q "${candidate}.service"; then
            svc="$candidate"
            break
        fi
    done
    if [[ -z "$svc" ]]; then
        warn "Could not find a registry systemd unit. Skipping GC."
        return 0
    fi

    info "Stopping ${svc} for GC..."
    systemctl stop "${svc}.service" 2>/dev/null || true

    # If it's a native binary use that; otherwise fall back to podman run.
    if check_command registry; then
        registry garbage-collect "$conf" 2>&1 | while IFS= read -r line; do info "  $line"; done || \
            warn "GC returned non-zero"
    elif check_command podman; then
        info "Using podman to run garbage-collect against registry:2..."
        local base_dir="${MIRRORET_BASE_DIR:-/srv/mirroret}"
        podman run --rm \
            -v "${base_dir}/docker/registry:/var/lib/registry" \
            -v "${conf}:/etc/docker/registry/config.yml:ro" \
            registry:2 garbage-collect /etc/docker/registry/config.yml 2>&1 | \
            while IFS= read -r line; do info "  $line"; done || \
            warn "GC returned non-zero"
    else
        warn "Neither registry binary nor podman available. Skipping GC."
    fi

    info "Restarting ${svc}..."
    systemctl start "${svc}.service" 2>/dev/null || \
        warn "Failed to restart ${svc}. Run: systemctl start ${svc}"
}

# ── Public API ───────────────────────────────────────────────────────────────

# run_retention — run all enabled retention steps.
run_retention() {
    if [[ "${MIRRORET_RETENTION_ENABLE:-0}" != "1" ]]; then
        info "Retention disabled (MIRRORET_RETENTION_ENABLE=0). Nothing to do."
        return 0
    fi

    local mode
    mode="$(_ret_mode)"
    section "Mirror retention (mode: ${mode})"
    info "RPM keep-versions   : ${MIRRORET_RPM_KEEP_VERSIONS}"
    info "pip keep-versions   : ${MIRRORET_PIP_KEEP_VERSIONS}"
    info "npm keep-days       : ${MIRRORET_NPM_KEEP_DAYS}"
    info "Docker GC           : ${MIRRORET_DOCKER_GC}"

    RETENTION_METADATA_BROKEN=0
    retention_rpm_prune    || true
    retention_pip_prune    || true
    retention_npm_prune    || true
    retention_docker_gc    || true

    if [[ "${RETENTION_METADATA_BROKEN}" == "1" ]]; then
        error "Retention finished but at least one repo has STALE METADATA."
        error "Clients will fail against those repos until createrepo is re-run."
        return 1
    fi

    success "Retention complete (mode: ${mode})."
}

# retention_report / retention_prune — one-shot overrides.
retention_report() {
    MIRRORET_RETENTION_ENABLE=1 MIRRORET_RETENTION_MODE=report run_retention
}
retention_prune() {
    MIRRORET_RETENTION_ENABLE=1 MIRRORET_RETENTION_MODE=prune run_retention
}

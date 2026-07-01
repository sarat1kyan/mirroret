#!/usr/bin/env bash
# Uninstall logic for mirroret.
# Source this file; do not execute it directly.
# Requires logging.sh, common.sh, distro.sh.
#
# Each per-component remover is idempotent: missing files / dead services /
# nonexistent users are skipped silently rather than treated as errors.
# Anything destructive ("rm -rf data", "userdel") is gated behind an
# explicit flag or interactive confirmation.
#
# Design:
#  - All decisions are made up front in UNINST_PLAN[], so --dry-run and
#    --list can show the operator exactly what will happen.
#  - DRY_RUN=1 is fully honoured: every state-changing call goes through
#    xrun or a guarded branch.
#
# Public entry points:
#  uninstall_main      — top-level: parses targets, builds plan, executes
#  uninstall_plan_show — print the current plan without executing
#  uninstall_components_present — print which components look installed

# ── Defaults ─────────────────────────────────────────────────────────────────

MIRRORET_BASE_DIR="${MIRRORET_BASE_DIR:-/srv/mirroret}"
MIRRORET_BACKUP_BASE="${MIRRORET_BACKUP_BASE:-/var/backups/mirroret}"
MIRRORET_TLS_DIR="${MIRRORET_TLS_DIR:-/etc/mirroret/tls}"
MIRRORET_GPG_HOMEDIR="${MIRRORET_GPG_HOMEDIR:-/etc/mirroret/gnupg}"
MIRRORET_PYPI_USER="${MIRRORET_PYPI_USER:-mirroret-pip}"
MIRRORET_NPM_USER="${MIRRORET_NPM_USER:-mirroret-npm}"
MIRRORET_DOCKER_CONTAINER_NAME="${MIRRORET_DOCKER_CONTAINER_NAME:-mirroret-registry}"
MIRRORET_WEB_PORT="${MIRRORET_WEB_PORT:-8080}"
MIRRORET_PIP_PORT="${MIRRORET_PIP_PORT:-8081}"
MIRRORET_DOCKER_REGISTRY_PORT="${MIRRORET_DOCKER_REGISTRY_PORT:-5000}"
MIRRORET_NPM_PORT="${MIRRORET_NPM_PORT:-4873}"
MIRRORET_TLS_PORT="${MIRRORET_TLS_PORT:-8443}"

# Cron sentinel — must match install.sh.
UNINST_CRON_BEGIN="# >>> mirroret managed (do not edit between markers) >>>"
UNINST_CRON_END="# <<< mirroret managed <<<"

# Plan is an array of "step|description" lines we'll display + execute.
UNINST_PLAN=()
UNINST_REMOVED=0
UNINST_SKIPPED=0
UNINST_FAILED=0
# Labels of steps that returned non-zero — printed in the summary so the
# operator knows what to investigate.
UNINST_FAILED_LABELS=()

# Toggles populated by uninstall_main from CLI flags.
UNINST_T_APT=0
UNINST_T_RPM=0
UNINST_T_PIP=0
UNINST_T_NPM=0
UNINST_T_DOCKER=0
UNINST_T_COMMON=0       # nginx vhost, cron, base dir, GPG, TLS
UNINST_PURGE=0          # also delete mirror data, backups, GPG, TLS
UNINST_KEEP_USERS=0     # don't userdel mirroret-pip / mirroret-npm
UNINST_KEEP_FIREWALL=0  # don't reverse firewall rules
UNINST_ASSUME_YES=0
UNINST_LIST_ONLY=0

# ── Utility helpers ──────────────────────────────────────────────────────────

uninst_step() {
    # Record one planned removal step. Format: "tag|description".
    UNINST_PLAN+=("$1")
}

uninst_do() {
    # Run a removal command, honouring DRY_RUN. Counts result.
    local label="$1"; shift
    if [[ "${DRY_RUN:-0}" == "1" ]] || [[ "${UNINST_LIST_ONLY}" == "1" ]]; then
        info "[plan] ${label}"
        return 0
    fi
    debug "uninstall: ${label}"
    if "$@"; then
        info "[remove] ${label}"
        UNINST_REMOVED=$(( UNINST_REMOVED + 1 ))
    else
        local rc=$?
        warn "[fail] ${label} (rc=${rc})"
        UNINST_FAILED=$(( UNINST_FAILED + 1 ))
        UNINST_FAILED_LABELS+=("${label} (rc=${rc})")
        return "$rc"
    fi
}

# uninst_try — best-effort: run a command and count a non-zero exit as a
# skip, not a failure. Use for hygiene ops where the target state may
# legitimately be absent (systemctl reset-failed on a healthy unit,
# semanage fcontext -d on a rule that isn't in the policy store).
uninst_try() {
    local label="$1"; shift
    if [[ "${DRY_RUN:-0}" == "1" ]] || [[ "${UNINST_LIST_ONLY}" == "1" ]]; then
        info "[plan] ${label}"
        return 0
    fi
    debug "uninstall (try): ${label}"
    if "$@" >/dev/null 2>&1; then
        info "[remove] ${label}"
        UNINST_REMOVED=$(( UNINST_REMOVED + 1 ))
    else
        debug "[skip] ${label} (nothing to do)"
        UNINST_SKIPPED=$(( UNINST_SKIPPED + 1 ))
    fi
    return 0
}

uninst_skip() {
    debug "uninstall: skip ${1}"
    UNINST_SKIPPED=$(( UNINST_SKIPPED + 1 ))
}

uninst_confirm() {
    local prompt="$1"
    if [[ "${UNINST_ASSUME_YES}" == "1" ]]; then
        debug "auto-yes: ${prompt}"
        return 0
    fi
    if [[ "${MIRRORET_NON_INTERACTIVE:-0}" == "1" ]]; then
        warn "Non-interactive mode: auto-declining: ${prompt}"
        return 1
    fi
    read -r -p "${prompt} [y/N] " reply
    [[ "${reply}" =~ ^[Yy]$ ]]
}

# ── Detection ────────────────────────────────────────────────────────────────

# uninstall_components_present — print which components look installed.
# Prints lines like "docker  present (container=mirroret-registry)".
uninstall_components_present() {
    echo ""
    echo "Detected mirroret components on this host:"
    echo ""

    # nginx vhost
    if _has_nginx_vhost; then
        echo "  nginx vhost      : present"
    else
        echo "  nginx vhost      : not found"
    fi

    # pypiserver
    if _has_unit pypiserver || [[ -d /opt/mirroret-pypiserver ]]; then
        local extras=()
        _has_unit pypiserver && extras+=("systemd unit")
        [[ -d /opt/mirroret-pypiserver ]] && extras+=("venv")
        id "${MIRRORET_PYPI_USER}" &>/dev/null && extras+=("user=${MIRRORET_PYPI_USER}")
        echo "  pip (pypiserver) : present (${extras[*]})"
    else
        echo "  pip (pypiserver) : not found"
    fi

    # verdaccio
    if _has_unit verdaccio || [[ -d /etc/verdaccio ]]; then
        local extras=()
        _has_unit verdaccio && extras+=("systemd unit")
        [[ -d /etc/verdaccio ]] && extras+=("/etc/verdaccio")
        id "${MIRRORET_NPM_USER}" &>/dev/null && extras+=("user=${MIRRORET_NPM_USER}")
        echo "  npm (Verdaccio)  : present (${extras[*]})"
    else
        echo "  npm (Verdaccio)  : not found"
    fi

    # Docker registry
    if _has_docker_registry; then
        local extras=()
        _has_unit docker-distribution        && extras+=("docker-distribution")
        _has_unit docker-registry            && extras+=("docker-registry")
        _has_unit "${MIRRORET_DOCKER_CONTAINER_NAME}" && extras+=("podman unit")
        _docker_container_exists             && extras+=("container=${MIRRORET_DOCKER_CONTAINER_NAME}")
        [[ -f /etc/docker/registry/config.yml ]] && extras+=("/etc/docker/registry")
        [[ -f /etc/docker-distribution/registry/config.yml ]] && extras+=("/etc/docker-distribution/registry")
        echo "  Docker registry  : present (${extras[*]})"
    else
        echo "  Docker registry  : not found"
    fi

    # APT mirror tool config
    if [[ -f /etc/apt/mirror.list ]] || [[ -d /opt/mirroret-apt-mirror2 ]]; then
        local extras=()
        [[ -f /etc/apt/mirror.list ]]         && extras+=("/etc/apt/mirror.list")
        [[ -d /opt/mirroret-apt-mirror2 ]]    && extras+=("apt-mirror2 venv")
        echo "  APT mirror       : present (${extras[*]})"
    else
        echo "  APT mirror       : not found"
    fi

    # RPM sync script
    if [[ -f "${MIRRORET_BASE_DIR}/scripts/sync-redhat-repos.sh" ]]; then
        echo "  RPM mirror       : present (sync script)"
    else
        echo "  RPM mirror       : not found"
    fi

    # Mirror data
    if [[ -d "${MIRRORET_BASE_DIR}" ]]; then
        local size
        size="$(du -sh "${MIRRORET_BASE_DIR}" 2>/dev/null | awk '{print $1}')"
        echo "  Mirror data tree : ${MIRRORET_BASE_DIR} (${size:-unknown size})"
    else
        echo "  Mirror data tree : not found"
    fi

    # Cron block
    if crontab -l 2>/dev/null | grep -qF "${UNINST_CRON_BEGIN}"; then
        echo "  Cron entry       : present (managed block)"
    else
        echo "  Cron entry       : not found"
    fi

    echo ""
}

_has_unit() {
    local svc="$1"
    if ! check_command systemctl; then
        return 1
    fi
    systemctl list-unit-files --full --no-legend "${svc}.service" 2>/dev/null \
        | grep -q "${svc}.service"
}

_has_nginx_vhost() {
    for f in \
        /etc/nginx/sites-available/mirroret-unified \
        /etc/nginx/sites-available/mirroret \
        /etc/nginx/sites-enabled/mirroret-unified \
        /etc/nginx/sites-enabled/mirroret \
        /etc/nginx/conf.d/mirroret-unified.conf \
        /etc/nginx/conf.d/mirroret.conf
    do
        [[ -e "$f" ]] && return 0
    done
    return 1
}

_has_docker_registry() {
    _has_unit docker-distribution     && return 0
    _has_unit docker-registry         && return 0
    _has_unit "${MIRRORET_DOCKER_CONTAINER_NAME}" && return 0
    _docker_container_exists          && return 0
    [[ -f /etc/docker/registry/config.yml ]] && return 0
    [[ -f /etc/docker-distribution/registry/config.yml ]] && return 0
    return 1
}

_docker_container_exists() {
    if check_command docker; then
        docker ps -a --format '{{.Names}}' 2>/dev/null \
            | grep -qx "${MIRRORET_DOCKER_CONTAINER_NAME}" && return 0
    fi
    if check_command podman; then
        podman ps -a --format '{{.Names}}' 2>/dev/null \
            | grep -qx "${MIRRORET_DOCKER_CONTAINER_NAME}" && return 0
    fi
    return 1
}

# ── Per-component removers ───────────────────────────────────────────────────

uninst_remove_service() {
    # Stop + disable + delete a systemd unit and reset its failed state.
    local svc="$1"
    if ! _has_unit "$svc"; then
        uninst_skip "service ${svc} (not installed)"
        return 0
    fi
    uninst_do  "stop ${svc}.service"    systemctl stop    "${svc}.service" || true
    uninst_try "disable ${svc}.service" systemctl disable "${svc}.service"
    # reset-failed is hygiene: it returns non-zero on many systemd builds
    # when the unit ISN'T in a failed state (i.e. there's nothing to reset).
    # That is not a failure — treat it as best-effort.
    uninst_try "reset-failed ${svc}"    systemctl reset-failed "${svc}.service"
    local unit_file="/etc/systemd/system/${svc}.service"
    if [[ -f "${unit_file}" ]]; then
        uninst_do "rm ${unit_file}" rm -f "${unit_file}"
    fi
}

uninst_remove_user() {
    local user="$1"
    if [[ "${UNINST_KEEP_USERS}" == "1" ]]; then
        uninst_skip "user ${user} (--keep-users)"
        return 0
    fi
    if ! id "${user}" &>/dev/null; then
        uninst_skip "user ${user} (does not exist)"
        return 0
    fi
    if check_command userdel; then
        uninst_do "userdel ${user}" userdel "${user}" 2>/dev/null || true
    else
        warn "userdel not found; cannot remove user ${user}."
    fi
}

uninst_remove_file() {
    local path="$1"
    if [[ ! -e "$path" && ! -L "$path" ]]; then
        uninst_skip "${path} (not present)"
        return 0
    fi
    # `|| true` because the uninstaller's idempotency claim requires that
    # an immutable-bit / busy-mount / read-only-FS failure on one file
    # does not abort the rest of the run under set -e.
    uninst_do "rm ${path}" rm -f "$path" || true
}

uninst_remove_dir() {
    local path="$1"
    if [[ ! -d "$path" ]]; then
        uninst_skip "${path} (not a directory)"
        return 0
    fi
    uninst_do "rm -rf ${path}" rm -rf "$path" || true
}

# ── Component: pip / pypiserver ──────────────────────────────────────────────

uninstall_pip() {
    section "Removing pip / pypiserver"
    uninst_remove_service "pypiserver"
    uninst_remove_user    "${MIRRORET_PYPI_USER}"
    uninst_remove_file    "/usr/local/bin/pypi-server"
    uninst_remove_dir     "/opt/mirroret-pypiserver"
    uninst_remove_file    "${MIRRORET_BASE_DIR}/scripts/sync-pip-packages.sh"
    # Mirror data under pip/ is removed by --purge; not touched otherwise.
}

# ── Component: npm / Verdaccio ───────────────────────────────────────────────

uninstall_npm() {
    section "Removing npm / Verdaccio"
    uninst_remove_service "verdaccio"
    uninst_remove_user    "${MIRRORET_NPM_USER}"
    uninst_remove_dir     "/etc/verdaccio"
    uninst_remove_file    "${MIRRORET_BASE_DIR}/scripts/sync-npm-packages.sh"
    # We don't try to uninstall Verdaccio via `npm uninstall -g verdaccio` —
    # that may be shared with other tooling and the install path varies.
}

# ── Component: Docker registry ───────────────────────────────────────────────

uninstall_docker() {
    section "Removing Docker registry"

    # Native services first (RHEL/Debian OS packages).
    uninst_remove_service "docker-distribution"
    uninst_remove_service "docker-registry"

    # Podman-generated unit for the container backend.
    uninst_remove_service "${MIRRORET_DOCKER_CONTAINER_NAME}"

    # Stop / remove the registry container if it exists.
    if check_command docker; then
        if docker ps -a --format '{{.Names}}' 2>/dev/null \
                | grep -qx "${MIRRORET_DOCKER_CONTAINER_NAME}"; then
            uninst_do "docker rm -f ${MIRRORET_DOCKER_CONTAINER_NAME}" \
                docker rm -f "${MIRRORET_DOCKER_CONTAINER_NAME}" || true
        fi
    fi
    if check_command podman; then
        if podman ps -a --format '{{.Names}}' 2>/dev/null \
                | grep -qx "${MIRRORET_DOCKER_CONTAINER_NAME}"; then
            uninst_do "podman rm -f ${MIRRORET_DOCKER_CONTAINER_NAME}" \
                podman rm -f "${MIRRORET_DOCKER_CONTAINER_NAME}" || true
        fi
    fi

    # Config files.
    uninst_remove_dir  "/etc/docker/registry"
    uninst_remove_dir  "/etc/docker-distribution/registry"

    # Generated sync script (hosted mode only) + cache-mode-disabled stub.
    uninst_remove_file "${MIRRORET_BASE_DIR}/scripts/sync-docker-images.sh"
    uninst_remove_file "${MIRRORET_BASE_DIR}/scripts/sync-docker-images.sh.cache-mode-disabled"

    # We do NOT uninstall docker or podman — operators may use those for
    # other purposes. Removing the registry pieces only is the right scope.
}

# ── Component: APT mirror ────────────────────────────────────────────────────

uninstall_apt() {
    section "Removing APT mirror config"

    uninst_remove_file "/etc/apt/mirror.list"
    uninst_remove_file "${MIRRORET_BASE_DIR}/scripts/sync-apt-debmirror.sh"

    # apt-mirror2 venv created by lib/apt.sh when falling back via pip.
    if [[ -L /usr/local/bin/apt-mirror2 ]]; then
        uninst_remove_file "/usr/local/bin/apt-mirror2"
    fi
    uninst_remove_dir "/opt/mirroret-apt-mirror2"

    # We do not auto-uninstall the apt-mirror / debmirror OS packages —
    # operators may want to keep them.
}

# ── Component: RPM mirror ────────────────────────────────────────────────────

uninstall_rpm() {
    section "Removing RPM mirror config"
    uninst_remove_file "${MIRRORET_BASE_DIR}/scripts/sync-redhat-repos.sh"
    # RPM has no separate config file. Mirror data lives under
    # ${MIRRORET_BASE_DIR}/redhat/ and is handled by --purge.
}

# ── Common: nginx vhost, cron, firewall, base dir, GPG, TLS ──────────────────

uninstall_nginx_vhost() {
    section "Removing nginx vhost"
    local removed_any=0
    for f in \
        /etc/nginx/sites-enabled/mirroret-unified \
        /etc/nginx/sites-enabled/mirroret \
        /etc/nginx/sites-available/mirroret-unified \
        /etc/nginx/sites-available/mirroret \
        /etc/nginx/conf.d/mirroret-unified.conf \
        /etc/nginx/conf.d/mirroret.conf
    do
        if [[ -e "$f" || -L "$f" ]]; then
            uninst_remove_file "$f"
            removed_any=1
        fi
    done
    if [[ "$removed_any" == "1" ]] && [[ "${DRY_RUN:-0}" != "1" ]] && [[ "${UNINST_LIST_ONLY}" != "1" ]]; then
        if check_command nginx && nginx -t &>/dev/null; then
            uninst_do "reload nginx" systemctl reload nginx 2>/dev/null || true
        elif check_command nginx; then
            warn "nginx -t failed after vhost removal; nginx left untouched."
        fi
    fi
}

uninstall_cron() {
    section "Removing cron managed block"
    if ! check_command crontab; then
        uninst_skip "cron (crontab not installed)"
        return 0
    fi
    local existing
    existing="$(crontab -l 2>/dev/null || true)"
    # Strip CR so a CRLF-terminated crontab (from a Windows editor or a
    # round-trip through Outlook) still matches the sentinel via exact-eq.
    existing="$(printf '%s' "${existing}" | tr -d '\r')"
    if ! printf '%s\n' "${existing}" | grep -qF "${UNINST_CRON_BEGIN}"; then
        uninst_skip "cron (no managed block found)"
        return 0
    fi
    if [[ "${DRY_RUN:-0}" == "1" ]] || [[ "${UNINST_LIST_ONLY}" == "1" ]]; then
        info "[plan] strip cron managed block"
        return 0
    fi
    local stripped
    stripped="$(printf '%s\n' "${existing}" \
        | awk -v b="${UNINST_CRON_BEGIN}" -v e="${UNINST_CRON_END}" '
            $0 == b { skip = 1; next }
            $0 == e { skip = 0; next }
            !skip { print }
        ')"
    # If nothing else remains, clear the crontab outright (avoid blank line).
    if [[ -z "${stripped// /}" ]]; then
        crontab -r 2>/dev/null || true
    else
        if ! printf '%s\n' "${stripped}" | crontab -; then
            warn "[fail] crontab update — managed block left in place. Run: crontab -e"
            UNINST_FAILED=$(( UNINST_FAILED + 1 ))
            return 0
        fi
    fi
    info "[remove] cron managed block"
    UNINST_REMOVED=$(( UNINST_REMOVED + 1 ))
}

uninstall_firewall() {
    if [[ "${UNINST_KEEP_FIREWALL}" == "1" ]]; then
        uninst_skip "firewall (--keep-firewall)"
        return 0
    fi
    section "Reversing firewall rules"
    local ports=()
    [[ "${UNINST_T_COMMON}" == "1" ]] && ports+=("${MIRRORET_WEB_PORT}" "${MIRRORET_TLS_PORT}")
    [[ "${UNINST_T_PIP}"    == "1" ]] && ports+=("${MIRRORET_PIP_PORT}")
    [[ "${UNINST_T_DOCKER}" == "1" ]] && ports+=("${MIRRORET_DOCKER_REGISTRY_PORT}")
    [[ "${UNINST_T_NPM}"    == "1" ]] && ports+=("${MIRRORET_NPM_PORT}")
    [[ ${#ports[@]} -eq 0 ]] && return 0

    # The installer's lib/firewall.sh installs different RULE SHAPES based
    # on whether MIRRORET_FIREWALL_SOURCE was set. To actually remove the
    # rule, we have to delete the same shape — a "delete by port" call
    # does not match a "rule from <CIDR>" entry, on any of the three
    # supported firewalls.
    #
    # Strategy: try BOTH the source-restricted and the generic forms.
    # Whichever one matches gets removed; the other is a silent no-op.
    local source_cidr="${MIRRORET_FIREWALL_SOURCE:-}"

    if check_command ufw; then
        for p in "${ports[@]}"; do
            if [[ -n "$source_cidr" ]]; then
                uninst_do "ufw delete allow from ${source_cidr} to any port ${p} proto tcp" \
                    ufw delete allow from "$source_cidr" to any port "$p" proto tcp 2>/dev/null || true
            fi
            uninst_do "ufw delete allow ${p}/tcp" \
                ufw delete allow "${p}/tcp" 2>/dev/null || true
        done
    elif check_command firewall-cmd; then
        for p in "${ports[@]}"; do
            if [[ -n "$source_cidr" ]]; then
                uninst_do "firewall-cmd remove-rich-rule for ${source_cidr}:${p}" \
                    firewall-cmd --permanent --remove-rich-rule="rule family=ipv4 source address=${source_cidr} port port=${p} protocol=tcp accept" \
                    2>/dev/null || true
            fi
            uninst_do "firewall-cmd remove-port ${p}/tcp" \
                firewall-cmd --permanent --remove-port="${p}/tcp" 2>/dev/null || true
        done
        uninst_do "firewall-cmd --reload" firewall-cmd --reload 2>/dev/null || true
    elif check_command iptables; then
        for p in "${ports[@]}"; do
            if [[ -n "$source_cidr" ]]; then
                uninst_do "iptables -D INPUT -s ${source_cidr} -p tcp --dport ${p}" \
                    iptables -D INPUT -s "$source_cidr" -p tcp --dport "${p}" -j ACCEPT 2>/dev/null || true
            fi
            uninst_do "iptables -D INPUT -p tcp --dport ${p}" \
                iptables -D INPUT -p tcp --dport "${p}" -j ACCEPT 2>/dev/null || true
        done
        warn "iptables rules removed in-memory only; persist with iptables-save if you save rules elsewhere."
    else
        uninst_skip "firewall (no supported tool found)"
    fi
}

uninstall_selinux_restore() {
    # Drop our file-context rule and restore default labels. Do NOT toggle
    # httpd_can_network_connect — other services may rely on it.
    if ! selinux_active; then
        uninst_skip "SELinux context restore (not active)"
        return 0
    fi
    if ! check_command semanage || ! check_command restorecon; then
        uninst_skip "SELinux context restore (semanage/restorecon missing)"
        return 0
    fi
    if [[ -d "${MIRRORET_BASE_DIR}" ]]; then
        # semanage fcontext -d returns non-zero if the rule isn't in the
        # local policy store — that's not a failure, it just means there's
        # nothing to delete.
        uninst_try "semanage fcontext -d ${MIRRORET_BASE_DIR}(/.*)?" \
            semanage fcontext -d "${MIRRORET_BASE_DIR}(/.*)?"
        uninst_do "restorecon -Rv ${MIRRORET_BASE_DIR}" \
            restorecon -Rv "${MIRRORET_BASE_DIR}" >/dev/null || true
    fi
}

uninstall_master_sync() {
    uninst_remove_file "${MIRRORET_BASE_DIR}/scripts/sync-all.sh"
}

uninstall_purge_data() {
    if [[ "${UNINST_PURGE}" != "1" ]]; then
        uninst_skip "data tree ${MIRRORET_BASE_DIR} (--purge not set)"
        return 0
    fi
    section "Purging mirror data, backups, TLS, and GPG"
    # Mirror data — usually hundreds of GB. We ALWAYS confirm interactively
    # here unless --yes is set.
    if [[ -d "${MIRRORET_BASE_DIR}" ]]; then
        local size
        size="$(du -sh "${MIRRORET_BASE_DIR}" 2>/dev/null | awk '{print $1}')"
        if ! uninst_confirm "DELETE mirror data at ${MIRRORET_BASE_DIR} (${size:-unknown})?"; then
            warn "Skipping data deletion."
        else
            uninst_remove_dir "${MIRRORET_BASE_DIR}"
        fi
    fi
    uninst_remove_dir "${MIRRORET_BACKUP_BASE}"
    uninst_remove_dir "${MIRRORET_TLS_DIR}"

    # Removing the GPG homedir destroys the signing key irrecoverably.
    if [[ -d "${MIRRORET_GPG_HOMEDIR}" ]]; then
        if uninst_confirm "DELETE GPG signing key at ${MIRRORET_GPG_HOMEDIR} (irreversible)?"; then
            uninst_remove_dir "${MIRRORET_GPG_HOMEDIR}"
        else
            warn "Skipping GPG key deletion."
        fi
    fi

    # /etc/mirroret left only if the parent above didn't take it.
    if [[ -d /etc/mirroret ]] && [[ -z "$(ls -A /etc/mirroret 2>/dev/null)" ]]; then
        uninst_remove_dir /etc/mirroret
    fi
}

uninstall_common() {
    uninstall_nginx_vhost
    uninstall_cron
    uninstall_master_sync
    uninstall_selinux_restore
    uninstall_firewall
    uninstall_purge_data
}

# ── Plan + execution ─────────────────────────────────────────────────────────

uninstall_build_plan() {
    UNINST_PLAN=()
    if [[ "${UNINST_T_PIP}"    == "1" ]]; then uninst_step "remove pypiserver (service, user, venv, sync script)"; fi
    if [[ "${UNINST_T_NPM}"    == "1" ]]; then uninst_step "remove Verdaccio (service, user, /etc/verdaccio, sync script)"; fi
    if [[ "${UNINST_T_DOCKER}" == "1" ]]; then uninst_step "remove Docker registry (services, container, configs, sync script)"; fi
    if [[ "${UNINST_T_APT}"    == "1" ]]; then uninst_step "remove APT mirror config (/etc/apt/mirror.list, apt-mirror2 venv)"; fi
    if [[ "${UNINST_T_RPM}"    == "1" ]]; then uninst_step "remove RPM mirror config (sync script)"; fi
    if [[ "${UNINST_T_COMMON}" == "1" ]]; then
        uninst_step "remove nginx vhost (sites-available/enabled, conf.d, reload nginx)"
        uninst_step "strip cron managed block"
        uninst_step "remove ${MIRRORET_BASE_DIR}/scripts/sync-all.sh"
        uninst_step "restore SELinux file context on ${MIRRORET_BASE_DIR}"
        if [[ "${UNINST_KEEP_FIREWALL}" != "1" ]]; then
            uninst_step "reverse firewall rules for selected ports"
        fi
        if [[ "${UNINST_PURGE}" == "1" ]]; then
            uninst_step "PURGE mirror data ${MIRRORET_BASE_DIR}"
            uninst_step "PURGE backups ${MIRRORET_BACKUP_BASE}"
            uninst_step "PURGE TLS dir ${MIRRORET_TLS_DIR}"
            uninst_step "PURGE GPG homedir ${MIRRORET_GPG_HOMEDIR}"
        fi
    fi
}

uninstall_plan_show() {
    echo ""
    echo "Uninstall plan:"
    echo ""
    if [[ ${#UNINST_PLAN[@]} -eq 0 ]]; then
        echo "  (nothing — no targets selected)"
    else
        local i=1
        for entry in "${UNINST_PLAN[@]}"; do
            printf "  %d. %s\n" "$i" "$entry"
            i=$(( i + 1 ))
        done
    fi
    echo ""
    [[ "${UNINST_PURGE}"         == "1" ]] && echo "  PURGE       : YES (data, backups, GPG, TLS)"
    [[ "${UNINST_KEEP_USERS}"    == "1" ]] && echo "  Keep users  : YES"
    [[ "${UNINST_KEEP_FIREWALL}" == "1" ]] && echo "  Keep firewall rules : YES"
    [[ "${UNINST_ASSUME_YES}"    == "1" ]] && echo "  Assume yes  : YES"
    echo ""
}

uninstall_execute() {
    # daemon-reload once after we've removed unit files.
    local need_daemon_reload=0

    [[ "${UNINST_T_PIP}"    == "1" ]] && { uninstall_pip;    need_daemon_reload=1; }
    [[ "${UNINST_T_NPM}"    == "1" ]] && { uninstall_npm;    need_daemon_reload=1; }
    [[ "${UNINST_T_DOCKER}" == "1" ]] && { uninstall_docker; need_daemon_reload=1; }
    [[ "${UNINST_T_APT}"    == "1" ]] && uninstall_apt
    [[ "${UNINST_T_RPM}"    == "1" ]] && uninstall_rpm
    [[ "${UNINST_T_COMMON}" == "1" ]] && uninstall_common

    if [[ "${need_daemon_reload}" == "1" ]] && [[ "${DRY_RUN:-0}" != "1" ]] && [[ "${UNINST_LIST_ONLY}" != "1" ]]; then
        if check_command systemctl; then
            xrun systemctl daemon-reload || true
        fi
    fi
}

# uninstall_main <args...> — parse CLI flags, build plan, execute.
uninstall_main() {
    # Defaults: when no component is named, target ALL of them.
    local any_target=0

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --apt)          UNINST_T_APT=1;    any_target=1 ;;
            --rpm)          UNINST_T_RPM=1;    any_target=1 ;;
            --pip)          UNINST_T_PIP=1;    any_target=1 ;;
            --npm)          UNINST_T_NPM=1;    any_target=1 ;;
            --docker)       UNINST_T_DOCKER=1; any_target=1 ;;
            --common)       UNINST_T_COMMON=1; any_target=1 ;;
            --all)
                UNINST_T_APT=1; UNINST_T_RPM=1; UNINST_T_PIP=1
                UNINST_T_NPM=1; UNINST_T_DOCKER=1; UNINST_T_COMMON=1
                any_target=1
                ;;
            --purge)        UNINST_PURGE=1 ;;
            --keep-users)   UNINST_KEEP_USERS=1 ;;
            --keep-firewall) UNINST_KEEP_FIREWALL=1 ;;
            --yes|-y)       UNINST_ASSUME_YES=1 ;;
            --dry-run)      DRY_RUN=1 ;;
            --list)         UNINST_LIST_ONLY=1 ;;
            --base-dir)     shift; MIRRORET_BASE_DIR="$1" ;;
            -h|--help)      _uninstall_usage; return 0 ;;
            --check|--validate|--status|--backup-only|--rollback|--list-backups|--no-apt|--no-rpm|--no-pip|--no-docker|--no-npm|--no-firewall|--insecure|--tls-self-signed|--gpg-auto|--approval-mode|--list-staging|--approve-all-pip|--approve-all-npm|--config)
                die "Flag $1 is an install.sh flag, not an uninstall flag. See ./uninstall.sh --help."
                ;;
            *)              die "Unknown uninstall flag: $1. Run ./uninstall.sh --help for the flag list." ;;
        esac
        shift
    done

    if [[ "${any_target}" == "0" ]]; then
        # No component named — default to everything.
        UNINST_T_APT=1; UNINST_T_RPM=1; UNINST_T_PIP=1
        UNINST_T_NPM=1; UNINST_T_DOCKER=1; UNINST_T_COMMON=1
    fi

    # --purge only takes effect inside the --common path (it's what owns
    # the data tree, backups, TLS, and GPG). Warn rather than silently
    # ignoring the flag — the operator clearly wanted data removed.
    if [[ "${UNINST_PURGE}" == "1" ]] && [[ "${UNINST_T_COMMON}" != "1" ]]; then
        warn "--purge has no effect without --common or --all (data lives outside per-component scope)."
        warn "Add --common or --all if you actually want to delete ${MIRRORET_BASE_DIR}."
    fi

    section "Mirroret uninstaller"
    info "Base dir       : ${MIRRORET_BASE_DIR}"
    info "Dry-run        : ${DRY_RUN:-0}"
    info "List-only      : ${UNINST_LIST_ONLY}"
    info "Purge          : ${UNINST_PURGE}"
    info "Keep users     : ${UNINST_KEEP_USERS}"
    info "Keep firewall  : ${UNINST_KEEP_FIREWALL}"

    uninstall_components_present
    uninstall_build_plan
    uninstall_plan_show

    if [[ "${UNINST_LIST_ONLY}" == "1" ]]; then
        info "List-only mode: not executing."
        return 0
    fi
    if [[ "${DRY_RUN:-0}" == "1" ]]; then
        info "Dry-run mode: not executing."
        return 0
    fi
    if ! uninst_confirm "Proceed with the plan above?"; then
        warn "Aborted by user."
        return 1
    fi

    uninstall_execute

    echo ""
    info "Uninstall summary: removed=${UNINST_REMOVED}  skipped=${UNINST_SKIPPED}  failed=${UNINST_FAILED}"
    if [[ "${UNINST_FAILED}" -gt 0 ]]; then
        warn "Some items failed:"
        local lbl
        for lbl in "${UNINST_FAILED_LABELS[@]}"; do
            warn "  - ${lbl}"
        done
        warn "Re-run with --debug for more detail."
        return 1
    fi
    success "Uninstall complete."
}

_uninstall_usage() {
    cat <<'USAGE'
mirroret uninstaller — selective and full removal.

Usage:
  sudo ./uninstall.sh                       # remove everything (asks for confirmation)
  sudo ./uninstall.sh --docker              # remove only the Docker registry
  sudo ./uninstall.sh --pip --npm           # remove pip + npm only
  sudo ./uninstall.sh --all --purge --yes   # full wipe including data + GPG, no prompts
  sudo ./uninstall.sh --list                # show what would be removed, do nothing
  sudo ./uninstall.sh --dry-run             # detailed plan, do nothing

Component targets (combine freely; default is all):
  --apt        APT mirror config + apt-mirror2 venv
  --rpm        RPM mirror sync script
  --pip        pypiserver (service, user, venv)
  --npm        Verdaccio (service, user, /etc/verdaccio)
  --docker     Docker registry (services, container, config)
  --common     nginx vhost, cron, master sync, SELinux restore, firewall
  --all        every component (equivalent to listing them all)

Scope flags:
  --purge          ALSO delete mirror data, backups, TLS, GPG. PROMPTS.
  --keep-users     do not delete mirroret-pip / mirroret-npm
  --keep-firewall  do not reverse firewall rules
  --base-dir <p>   override MIRRORET_BASE_DIR (default /srv/mirroret)

Modes:
  --list           print the plan, exit
  --dry-run        print the plan, exit (alias-like, with [DRY-RUN] markers)
  --yes, -y        accept all confirmations
  --help, -h       show this help

The uninstaller never removes nginx, docker, podman, debmirror, or other
OS packages — operators may use those for unrelated purposes. It only
removes things mirroret itself created.
USAGE
}

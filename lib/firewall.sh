#!/usr/bin/env bash
# Firewall management for mirroret.
# Source this file; do not execute it directly.
# Requires logging.sh, common.sh.

# configure_firewall <port> [port...] - open one or more TCP ports.
# Does nothing if no firewall is detected.
# Uses MIRRORET_FIREWALL_SOURCE to restrict by source CIDR if set.
configure_firewall() {
    local ports=("$@")
    [[ ${#ports[@]} -eq 0 ]] && return 0

    local source_cidr="${MIRRORET_FIREWALL_SOURCE:-}"

    section "Configuring Firewall"
    info "Ports to open: ${ports[*]}"
    [[ -n "$source_cidr" ]] && info "Restricting to source: ${source_cidr}"

    # Pick the firewall that is actually RUNNING, not merely installed. A
    # RHEL box with firewalld installed but stopped makes `firewall-cmd
    # --permanent` exit 252 ("FirewallD is not running"), which under set -e
    # killed the install at its very last step with everything else already
    # configured.
    if check_command ufw && ufw status 2>/dev/null | grep -qi '^Status: active'; then
        _configure_ufw "$source_cidr" "${ports[@]}"
    elif check_command firewall-cmd && firewall-cmd --state >/dev/null 2>&1; then
        _configure_firewalld "$source_cidr" "${ports[@]}"
    elif check_command ufw || check_command firewall-cmd; then
        warn "A firewall is installed but not running; no rules were added."
        warn "If you enable it later, allow TCP ports: ${ports[*]}"
        return 0
    elif check_command iptables; then
        _configure_iptables "$source_cidr" "${ports[@]}"
    else
        warn "No supported firewall found (ufw, firewalld, iptables)."
        warn "Please manually allow TCP ports: ${ports[*]}"
        info "Required ports:"
        for p in "${ports[@]}"; do
            info " TCP ${p}"
        done
        return 0
    fi
}

_configure_ufw() {
    local source_cidr="$1"; shift
    local ports=("$@")

    for port in "${ports[@]}"; do
        if [[ -n "$source_cidr" ]]; then
            xrun ufw allow from "$source_cidr" to any port "$port" proto tcp
            success "UFW: allowed TCP ${port} from ${source_cidr}"
        else
            xrun ufw allow "$port/tcp"
            success "UFW: allowed TCP ${port} from any source"
        fi
    done
}

_configure_firewalld() {
    local source_cidr="$1"; shift
    local ports=("$@")

    for port in "${ports[@]}"; do
        if [[ -n "$source_cidr" ]]; then
            xrun firewall-cmd --permanent --add-rich-rule="rule family=ipv4 source address=${source_cidr} port port=${port} protocol=tcp accept"
            success "firewalld: allowed TCP ${port} from ${source_cidr}"
        else
            xrun firewall-cmd --permanent --add-port="${port}/tcp"
            success "firewalld: allowed TCP ${port} from any source"
        fi
    done
    xrun firewall-cmd --reload
}

_configure_iptables() {
    local source_cidr="$1"; shift
    local ports=("$@")

    for port in "${ports[@]}"; do
        if [[ -n "$source_cidr" ]]; then
            xrun iptables -A INPUT -s "$source_cidr" -p tcp --dport "$port" -j ACCEPT
            success "iptables: allowed TCP ${port} from ${source_cidr}"
        else
            xrun iptables -A INPUT -p tcp --dport "$port" -j ACCEPT
            success "iptables: allowed TCP ${port} from any source"
        fi
    done
    warn "iptables rules added but not persisted. Run 'iptables-save' to persist them."
}

# list_required_ports - print all ports required by the configured components.
list_required_ports() {
    echo ""
    echo "Required firewall ports:"
    echo " TCP ${MIRRORET_WEB_PORT:-8080} nginx (APT/RPM repository browser)"
    if [[ "${MIRRORET_ENABLE_PIP:-1}" == "1" ]]; then
        echo " TCP ${MIRRORET_PIP_PORT:-8081} pypiserver (pip index)"
    fi
    if [[ "${MIRRORET_ENABLE_DOCKER:-1}" == "1" ]]; then
        echo " TCP ${MIRRORET_DOCKER_REGISTRY_PORT:-5000} Docker registry"
    fi
    if [[ "${MIRRORET_ENABLE_NPM:-1}" == "1" ]]; then
        echo " TCP ${MIRRORET_NPM_PORT:-4873} Verdaccio (npm registry)"
    fi
    echo ""
}

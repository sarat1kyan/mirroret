#!/usr/bin/env bash
# nginx configuration management for mirroret.
# Source this file; do not execute it directly.
# Requires logging.sh, common.sh, backup.sh.

# configure_nginx_basic <backup_id> - write nginx config for APT/RPM-only setup.
configure_nginx_basic() {
    local backup_id="$1"
    local base_dir="${MIRRORET_BASE_DIR}"
    local web_port="${MIRRORET_WEB_PORT:-8080}"

    section "Configuring nginx (basic)"

    _write_nginx_config "$backup_id" "$base_dir" "$web_port" \
        "$(cat <<NGINX_EOF

    # APT/RPM repository browser
    location /mirror {
        alias ${base_dir}/mirror;
        autoindex on;
    }

    location /approved {
        alias ${base_dir}/approved;
        autoindex on;
    }

    location /config {
        alias ${base_dir}/config;
        autoindex on;
    }
NGINX_EOF
    )" "mirroret"
}

# configure_nginx_unified <backup_id> - write nginx config for the unified setup.
configure_nginx_unified() {
    local backup_id="$1"
    local base_dir="${MIRRORET_BASE_DIR}"
    local web_port="${MIRRORET_WEB_PORT:-8080}"
    local pip_port="${MIRRORET_PIP_PORT:-8081}"
    local npm_port="${MIRRORET_NPM_PORT:-4873}"
    local docker_port="${MIRRORET_DOCKER_REGISTRY_PORT:-5000}"

    section "Configuring nginx (unified)"

    # MIRRORET_APT_DATA_PATH is exported by apt.sh; fall back to the classic path.
    local apt_data_path="${MIRRORET_APT_DATA_PATH:-${base_dir}/debian/mirror/mirror/archive.ubuntu.com/ubuntu}"

    # One location per mirrored APT flavor. With the native engine each
    # flavor is a real archive root (dists/ + pool/) under apt/<flavor>, so
    # /ubuntu, /debian and /ubuntu-ports can all be served from one server -
    # which a single hardcoded /ubuntu location could not do.
    local apt_locations=""
    apt_locations="$(_nginx_apt_locations "${base_dir}" "${apt_data_path}")"

    # Approval-aware pip/npm paths: serve approved/ when enabled.
    local pip_serve_dir
    local npm_serve_dir
    if [[ "${MIRRORET_APPROVAL_ENABLED:-0}" == "1" ]]; then
        pip_serve_dir="${base_dir}/approved/pip"
        npm_serve_dir="${base_dir}/approved/npm"
    else
        pip_serve_dir="${base_dir}/pip/approved"
        npm_serve_dir=""
    fi

    _write_nginx_config "$backup_id" "$base_dir" "$web_port" \
        "$(cat <<NGINX_EOF
${apt_locations}

    # RPM mirror - reposync writes to redhat/mirror/rocky/VER/REPO/
    # Clients use: baseurl=http://server:PORT/redhat/rocky/VER/baseos
    location /redhat/ {
        alias ${base_dir}/redhat/mirror/;
        autoindex on;
    }

    location /config {
        alias ${base_dir}/config;
        autoindex on;
    }

    # PyPI proxy (pypiserver on ${pip_port})
    location /pip/ {
        proxy_pass http://127.0.0.1:${pip_port}/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_read_timeout 300s;
    }

    # npm proxy (Verdaccio on ${npm_port})
    location /npm/ {
        proxy_pass http://127.0.0.1:${npm_port}/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_read_timeout 300s;
    }

    # Docker registry proxy (on ${docker_port})
    location /v2/ {
        proxy_pass http://127.0.0.1:${docker_port}/v2/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        client_max_body_size 0;
        chunked_transfer_encoding on;
        proxy_read_timeout 900s;
    }

    # Approved pip packages (static files when approval workflow is active)
    location /pip-packages/ {
        alias ${pip_serve_dir}/;
        autoindex on;
    }

    # Approved npm packages (static files when approval workflow is active)
    location /npm-packages/ {
        alias ${npm_serve_dir:-${base_dir}/approved/npm}/;
        autoindex on;
    }
NGINX_EOF
    )" "mirroret-unified"

    # Append TLS server block when TLS is ready.
    if declare -f is_tls_ready >/dev/null 2>&1 && is_tls_ready; then
        local conf_file
        # Match the same DISTRO_TYPE keying used in _write_nginx_config.
        if [[ "${DISTRO_TYPE:-}" == "debian" ]]; then
            conf_file="/etc/nginx/sites-available/mirroret-unified"
        else
            conf_file="/etc/nginx/conf.d/mirroret-unified.conf"
        fi
        if [[ "${DRY_RUN}" != "1" ]] && [[ -f "${conf_file}" ]]; then
            if grep -qF '# -- TLS listener' "${conf_file}"; then
                info "TLS server block already present in ${conf_file} - skipping append."
            else
                tls_nginx_server_block "" "mirroret-unified" >> "${conf_file}"
                info "TLS server block appended to ${conf_file}"
            fi
            # Same SELinux gotcha applies - an append can carry over the
            # inherited context. Re-label to be safe.
            if [[ -e /sys/fs/selinux/enforce ]] && command -v restorecon >/dev/null 2>&1; then
                restorecon "${conf_file}" >/dev/null 2>&1 || true
            fi
            if nginx -t 2>/dev/null; then
                systemctl reload nginx 2>/dev/null || systemctl restart nginx
            else
                warn "nginx config test failed after TLS block insertion."
            fi
        fi
    fi
}

# _nginx_apt_locations <base_dir> <legacy_apt_data_path>
#
# Emits an nginx location block for each APT flavor this server mirrors.
# Native-engine trees live at <base>/apt/<flavor>/{dists,pool}; a legacy
# apt-mirror/debmirror tree lives wherever MIRRORET_APT_DATA_PATH points.
_nginx_apt_locations() {
    local base_dir="$1" legacy_path="$2"
    local -a dirs=()
    local sp dir

    for sp in "${MIRRORET_APT_SPECS[@]:-}"; do
        [[ -n "${sp}" ]] || continue
        [[ -f "${sp}" ]] || continue
        dir="$(mirroret_json_field "${sp}" dir)"
        [[ -z "${dir}" ]] && continue
        # De-duplicate: several releases of one flavor share an archive root.
        local seen=0 d
        for d in ${dirs[@]+"${dirs[@]}"}; do
            [[ "$d" == "${dir}" ]] && seen=1
        done
        [[ "${seen}" == "0" ]] && dirs+=("${dir}")
    done

    printf '\n    # APT mirrors. Clients use:\n'
    printf '    #   deb http://server:PORT/<flavor> <codename> <components>\n'
    if [[ ${#dirs[@]} -eq 0 ]]; then
        # No native targets: serve the legacy single-flavor tree so an
        # existing apt-mirror/debmirror install keeps working after upgrade.
        printf '    location /ubuntu/ {\n        alias %s/;\n        autoindex on;\n    }\n' \
            "${legacy_path}"
        return 0
    fi
    for dir in "${dirs[@]}"; do
        printf '    location /%s/ {\n' "${dir}"
        printf '        alias %s/apt/%s/;\n' "${base_dir}" "${dir}"
        printf '        autoindex on;\n'
        printf '    }\n'
    done
    # Browsable index of every APT tree at once.
    printf '    location /apt/ {\n        alias %s/apt/;\n        autoindex on;\n    }\n' \
        "${base_dir}"
}

# -- Internal helpers ---------------------------------------------------------

_write_nginx_config() {
    local backup_id="$1"
    local base_dir="$2"
    local web_port="$3"
    local extra_locations="$4"
    local config_name="$5"

    local conf_file
    local sites_enabled_symlink=""

    # Key off DISTRO_TYPE - not directory existence. A stale sites-available/
    # left over from a partial install could otherwise fool us into writing
    # Debian-style config on a RHEL host (whose nginx.conf includes conf.d/
    # but NOT sites-enabled/), and the symlink step would fail with
    # "No such file or directory".
    if [[ "${DISTRO_TYPE:-}" == "debian" ]]; then
        conf_file="/etc/nginx/sites-available/${config_name}"
        sites_enabled_symlink="/etc/nginx/sites-enabled/${config_name}"
        mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled
    else
        conf_file="/etc/nginx/conf.d/${config_name}.conf"
        mkdir -p /etc/nginx/conf.d
    fi

    # Back up existing config.
    backup_file "$backup_id" "$conf_file"
    [[ -n "$sites_enabled_symlink" ]] && backup_file "$backup_id" "$sites_enabled_symlink"

    # Write to a temp file first for safe validation.
    local tmpfile
    tmpfile="$(mktemp_file)"

    cat > "$tmpfile" <<NGINX_CONF
# Generated by mirroret - do not edit manually.
server {
    listen ${web_port};
    server_name _;

    root ${base_dir};
    autoindex on;

    # SECURITY: base_dir also contains logs/ (which can hold proxy URLs
    # with embedded credentials) and scripts/ (generated sync scripts).
    # The catch-all location below would otherwise serve both to any
    # client that can reach this port.
    location ~ ^/(logs|scripts|staging)(/|\$) {
        deny all;
        return 404;
    }

    location / {
        try_files \$uri \$uri/ =404;
    }
${extra_locations}

    # Allow large packages.
    client_max_body_size 0;

    access_log /var/log/nginx/${config_name}-access.log;
    error_log /var/log/nginx/${config_name}-error.log;
}
NGINX_CONF

    # Validate before placing on disk.
    if ! _validate_nginx_tmpconfig "$tmpfile"; then
        rm -f "$tmpfile"
        die "nginx config validation failed. Aborting to protect existing config."
    fi

    if [[ "${DRY_RUN}" == "1" ]]; then
        info "[DRY-RUN] would write nginx config to: ${conf_file}"
        rm -f "$tmpfile"
        return 0
    fi

    atomic_write "$conf_file" "$tmpfile"
    info "nginx config written: ${conf_file}"

    # SELinux (RHEL): a file created under /etc/nginx/ by an unconfined_t
    # process inherits etc_t, which httpd_t cannot read. nginx -t then
    # fails with "Permission denied" even though DAC permissions look fine.
    # restorecon relabels it to httpd_config_t.
    if [[ -e /sys/fs/selinux/enforce ]] && command -v restorecon >/dev/null 2>&1; then
        restorecon "$conf_file" >/dev/null 2>&1 || true
    fi

    # Enable the site on Debian/Ubuntu.
    if [[ -n "$sites_enabled_symlink" ]]; then
        ln -sf "$conf_file" "$sites_enabled_symlink"
        info "Site enabled: ${sites_enabled_symlink}"
        if [[ -e /sys/fs/selinux/enforce ]] && command -v restorecon >/dev/null 2>&1; then
            restorecon "$sites_enabled_symlink" >/dev/null 2>&1 || true
        fi
    fi

    # Remove default site to avoid port conflicts.
    _remove_default_site

    # Test the final config.
    if ! nginx -t 2>/dev/null; then
        error "nginx config test failed after writing. Rolling back."
        rollback "$backup_id"
        die "nginx configuration failed."
    fi

    xrun systemctl enable nginx
    xrun systemctl reload nginx 2>/dev/null || xrun systemctl restart nginx
    success "nginx configured and (re)loaded on port ${web_port}."
}

_validate_nginx_tmpconfig() {
    local tmpfile="$1"
    if ! check_command nginx; then
        debug "nginx not installed yet; skipping pre-write validation."
        return 0
    fi
    # nginx -t -c requires a full nginx.conf, not just a server block.
    # Wrap the server block in minimal http{} boilerplate so nginx can parse it.
    local wrapper
    wrapper="$(mktemp_file)"
    printf 'events {}\nhttp { include %s; }\n' "$tmpfile" > "$wrapper"
    local rc=0
    nginx -t -c "$wrapper" 2>/dev/null || rc=$?
    rm -f "$wrapper"
    return $rc
}

_remove_default_site() {
    # Remove the default nginx site to avoid conflicts on port 80/8080.
    local defaults=(
        "/etc/nginx/sites-enabled/default"
        "/etc/nginx/conf.d/default.conf"
    )
    for f in "${defaults[@]}"; do
        if [[ -f "$f" ]] || [[ -L "$f" ]]; then
            info "Removing default nginx site: ${f}"
            xrun rm -f "$f"
        fi
    done
}

# reload_nginx - reload or restart nginx safely.
reload_nginx() {
    if service_is_active nginx; then
        nginx -t &>/dev/null && xrun systemctl reload nginx || xrun systemctl restart nginx
    else
        xrun systemctl start nginx
    fi
}

#!/usr/bin/env bash
# Package approval/promotion workflow for mirroret.
# Source this file; do not execute it directly.
# Requires logging.sh, common.sh.
#
# When MIRRORET_APPROVAL_ENABLED=1:
# - pip/npm sync scripts download to BASE_DIR/staging/{pip,npm}/
# - Admin approves packages to BASE_DIR/approved/{pip,npm}/
# - nginx serves packages from BASE_DIR/approved/{pip,npm}/
#
# This file provides the admin-facing operations.
# The sync-side staging behaviour is implemented in pip.sh and npm.sh.

MIRRORET_APPROVAL_ENABLED="${MIRRORET_APPROVAL_ENABLED:-0}"

# -- Staging listing -----------------------------------------------------------

# list_staging - show packages waiting for approval.
list_staging() {
    local base_dir="${MIRRORET_BASE_DIR}"
    local pip_staging="${base_dir}/staging/pip"
    local npm_staging="${base_dir}/staging/npm"
    local found=0

    echo ""
    echo "=== Packages awaiting approval ==="
    echo ""

    if [[ -d "${pip_staging}" ]]; then
        local pip_files
        pip_files=$(find "${pip_staging}" -type f \( -name "*.whl" -o -name "*.tar.gz" -o -name "*.zip" \) 2>/dev/null | sort)
        if [[ -n "${pip_files}" ]]; then
            echo "--- pip (${pip_staging}) ---"
            echo "${pip_files}" | xargs -I{} basename {}
            echo ""
            found=1
        fi
    fi

    if [[ -d "${npm_staging}" ]]; then
        local npm_files
        npm_files=$(find "${npm_staging}" -type f -name "*.tgz" 2>/dev/null | sort)
        if [[ -n "${npm_files}" ]]; then
            echo "--- npm (${npm_staging}) ---"
            echo "${npm_files}" | xargs -I{} basename {}
            echo ""
            found=1
        fi
    fi

    if [[ "${found}" -eq 0 ]]; then
        echo " (no packages in staging)"
    fi
    echo ""
}

# -- pip approval -------------------------------------------------------------

# approve_all_pip - promote all staged pip packages to approved.
approve_all_pip() {
    local base_dir="${MIRRORET_BASE_DIR}"
    local src="${base_dir}/staging/pip"
    local dst="${base_dir}/approved/pip"

    [[ -d "${src}" ]] || { warn "No pip staging dir: ${src}"; return 0; }

    mkdir -p "${dst}"
    local count=0
    while IFS= read -r -d '' pkg; do
        local name
        name="$(basename "${pkg}")"
        if [[ "${DRY_RUN}" == "1" ]]; then
            info "[DRY-RUN] would approve pip: ${name}"
        else
            mv "${pkg}" "${dst}/${name}"
            info "Approved pip: ${name}"
        fi
        (( count++ )) || true
    done < <(find "${src}" -type f \( -name "*.whl" -o -name "*.tar.gz" -o -name "*.zip" \) -print0 2>/dev/null)

    success "pip: ${count} package(s) approved."
}

# approve_pip_package <name_fragment>
# Promote the first staging pip package whose filename matches the fragment.
approve_pip_package() {
    local fragment="$1"
    local base_dir="${MIRRORET_BASE_DIR}"
    local src="${base_dir}/staging/pip"
    local dst="${base_dir}/approved/pip"

    [[ -n "${fragment}" ]] || die "approve_pip_package: package name fragment required."
    [[ -d "${src}" ]] || die "No pip staging dir: ${src}"

    local match
    match=$(find "${src}" -type f -name "*${fragment}*" | head -1)
    [[ -n "${match}" ]] || die "No staged pip package matching: ${fragment}"

    local name
    name="$(basename "${match}")"
    mkdir -p "${dst}"
    if [[ "${DRY_RUN}" == "1" ]]; then
        info "[DRY-RUN] would approve pip: ${name}"
    else
        mv "${match}" "${dst}/${name}"
        success "Approved pip: ${name}"
    fi
}

# exclude_pip_package <name_fragment>
# Remove a staged pip package (decline it).
exclude_pip_package() {
    local fragment="$1"
    local base_dir="${MIRRORET_BASE_DIR}"
    local src="${base_dir}/staging/pip"

    [[ -n "${fragment}" ]] || die "exclude_pip_package: package name fragment required."
    [[ -d "${src}" ]] || die "No pip staging dir: ${src}"

    local match
    match=$(find "${src}" -type f -name "*${fragment}*" | head -1)
    [[ -n "${match}" ]] || die "No staged pip package matching: ${fragment}"

    local name
    name="$(basename "${match}")"
    if [[ "${DRY_RUN}" == "1" ]]; then
        info "[DRY-RUN] would exclude (delete) staged pip: ${name}"
    else
        rm -f "${match}"
        success "Excluded pip: ${name}"
    fi
}

# -- npm approval -------------------------------------------------------------

# approve_all_npm - promote all staged npm tarballs to approved.
approve_all_npm() {
    local base_dir="${MIRRORET_BASE_DIR}"
    local src="${base_dir}/staging/npm"
    local dst="${base_dir}/approved/npm"

    [[ -d "${src}" ]] || { warn "No npm staging dir: ${src}"; return 0; }

    mkdir -p "${dst}"
    local count=0
    while IFS= read -r -d '' pkg; do
        local name
        name="$(basename "${pkg}")"
        if [[ "${DRY_RUN}" == "1" ]]; then
            info "[DRY-RUN] would approve npm: ${name}"
        else
            mv "${pkg}" "${dst}/${name}"
            info "Approved npm: ${name}"
        fi
        (( count++ )) || true
    done < <(find "${src}" -type f -name "*.tgz" -print0 2>/dev/null)

    success "npm: ${count} package(s) approved."
}

# exclude_npm_package <name_fragment>
# Remove a staged npm tarball (decline it).
exclude_npm_package() {
    local fragment="$1"
    local base_dir="${MIRRORET_BASE_DIR}"
    local src="${base_dir}/staging/npm"

    [[ -n "${fragment}" ]] || die "exclude_npm_package: package name fragment required."
    [[ -d "${src}" ]] || die "No npm staging dir: ${src}"

    local match
    match=$(find "${src}" -type f -name "*${fragment}*" | head -1)
    [[ -n "${match}" ]] || die "No staged npm package matching: ${fragment}"

    local name
    name="$(basename "${match}")"
    if [[ "${DRY_RUN}" == "1" ]]; then
        info "[DRY-RUN] would exclude (delete) staged npm: ${name}"
    else
        rm -f "${match}"
        success "Excluded npm: ${name}"
    fi
}

# -- Dir setup ----------------------------------------------------------------

# ensure_approval_dirs - create staging/approved directory tree.
ensure_approval_dirs() {
    [[ "${MIRRORET_APPROVAL_ENABLED}" == "1" ]] || return 0
    local base_dir="${MIRRORET_BASE_DIR}"
    if [[ "${DRY_RUN}" == "1" ]]; then
        info "[DRY-RUN] would create approval dirs under ${base_dir}/{staging,approved}"
        return 0
    fi
    for d in \
        "${base_dir}/staging/pip" \
        "${base_dir}/staging/npm" \
        "${base_dir}/approved/pip" \
        "${base_dir}/approved/npm"
    do
        mkdir -p "${d}"
        chmod 755 "${d}"
    done
    info "Approval directories ready under ${base_dir}/{staging,approved}."
}

#!/usr/bin/env bash
# Package approval/promotion workflow for mirroret.
# Source this file; do not execute it directly.
# Requires logging.sh, common.sh.
#
# When MIRRORET_APPROVAL_ENABLED=1:
# - pip/npm sync scripts download to BASE_DIR/staging/{pip,npm}/
# - reposync writes to BASE_DIR/redhat/staging/ instead of redhat/mirror/
# - Admin approves packages to BASE_DIR/approved/{pip,npm}/ and, for RPMs,
#   into the live BASE_DIR/redhat/mirror/ tree
# - nginx serves packages from BASE_DIR/approved/{pip,npm}/ and, unchanged,
#   from BASE_DIR/redhat/mirror/
#
# This file provides the admin-facing operations.
# The sync-side staging behaviour is implemented in pip.sh, npm.sh and rpm.sh.
#
# Two things make approval real rather than cosmetic:
# - npm: Verdaccio must NOT proxy npmjs, or clients fetch upstream directly
#   and never touch the approved set. npm.sh drops the proxy when approval is
#   on; promotion here publishes the tarball into Verdaccio.
# - rpm: an approved .rpm is invisible until repodata lists it, so every
#   promotion rebuilds the metadata of the repos it touched.

MIRRORET_APPROVAL_ENABLED="${MIRRORET_APPROVAL_ENABLED:-0}"

# -- Shared helpers ------------------------------------------------------------

# _approval_refuse_if_syncing <pip|npm|redhat> - refuse to promote while the
# matching sync script holds its lock. The sync writes files into staging
# incrementally; promoting one mid-download would publish a truncated
# package. Lock paths must match the generated sync scripts.
_approval_refuse_if_syncing() {
    local eco="$1"
    local lock="/var/lock/mirroret-sync-${eco}.lock"
    [[ -e "${lock}" ]] || return 0
    command -v flock >/dev/null 2>&1 || return 0
    # flock -n exits 1 when the lock is held by another process.
    if flock -n "${lock}" true 2>/dev/null; then
        return 0
    fi
    if [[ "${DRY_RUN:-0}" == "1" ]]; then
        warn "[DRY-RUN] a ${eco} sync is running (${lock} is held); a real run would refuse to promote now."
        return 0
    fi
    die "A ${eco} sync is running right now (lock ${lock} is held). Refusing to promote - a half-written file must never reach clients. Re-run once it finishes (mirroretctl logs tail)."
}

# _approval_rpm_roots - echo "<staging_root> <mirror_root>".
_approval_rpm_roots() {
    local base_dir="${MIRRORET_BASE_DIR}"
    printf '%s %s' "${base_dir}/redhat/staging" "${base_dir}/redhat/mirror"
}

# _find_staged_rpms <staging_root> - print every staged .rpm, newline separated.
_find_staged_rpms() {
    local root="$1"
    [[ -d "${root}" ]] || return 0
    find "${root}" -type f -name '*.rpm' 2>/dev/null | sort
}

# _createrepo_bin - echo the available createrepo binary, or empty.
_createrepo_bin() {
    if command -v createrepo_c >/dev/null 2>&1; then
        printf 'createrepo_c'
    elif command -v createrepo >/dev/null 2>&1; then
        printf 'createrepo'
    fi
}

# _rpm_rebuild_metadata <repo_dir>...
# An approved rpm that is not in repodata does not exist as far as dnf is
# concerned, so this is not optional cleanup - it is what makes the promotion
# visible to clients.
_rpm_rebuild_metadata() {
    local cr
    cr="$(_createrepo_bin)"
    local d rc=0
    for d in "$@"; do
        [[ -d "${d}" ]] || continue
        if [[ "${DRY_RUN}" == "1" ]]; then
            info "[DRY-RUN] would rebuild metadata: ${d}"
            continue
        fi
        if [[ -z "${cr}" ]]; then
            warn "createrepo_c not found - metadata NOT rebuilt for ${d}."
            warn "Clients will not see the approved packages until you install"
            warn "createrepo_c and re-run the approval."
            rc=1
            continue
        fi
        local args=()
        [[ -f "${d}/repodata/repomd.xml" ]] && args+=(--update)
        info "Rebuilding metadata: ${d}"
        if ! "${cr}" "${args[@]}" "${d}"; then
            warn "createrepo failed for ${d} - clients may not see new packages."
            rc=1
        fi
    done
    return "${rc}"
}

# _promote_file <src> <staging_root> <mirror_root>
# Move one staged file into the mirror tree, preserving its path relative to
# the staging root. Echoes the destination directory.
_promote_file() {
    local src="$1" staging_root="$2" mirror_root="$3"
    local rel="${src#"${staging_root}"/}"
    local dst="${mirror_root}/${rel}"
    local dst_dir
    dst_dir="$(dirname "${dst}")"
    if [[ "${DRY_RUN}" == "1" ]]; then
        info "[DRY-RUN] would promote: ${rel}"
    else
        mkdir -p "${dst_dir}"
        # Same filesystem in a normal install, so this is atomic. Fall back to
        # copy+remove for the case where staging sits on another mount.
        mv "${src}" "${dst}" 2>/dev/null || { cp -f "${src}" "${dst}" && rm -f "${src}"; }
    fi
    printf '%s' "${dst_dir}"
}

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

    local rpm_staging
    rpm_staging="$(_approval_rpm_roots)"
    rpm_staging="${rpm_staging%% *}"
    if [[ -d "${rpm_staging}" ]]; then
        local rpm_files rpm_count
        rpm_files="$(_find_staged_rpms "${rpm_staging}")"
        if [[ -n "${rpm_files}" ]]; then
            rpm_count="$(printf '%s\n' "${rpm_files}" | wc -l | tr -d ' ')"
            echo "--- rpm (${rpm_staging}) - ${rpm_count} package(s) ---"
            # An RPM sync stages thousands of files; printing them all buries
            # the operator. Show a per-repo count and the first few names.
            printf '%s\n' "${rpm_files}" \
                | sed "s|^${rpm_staging}/||" \
                | awk -F/ '{c[$1"/"$2"/"$3]++} END {for (r in c) printf "  %-40s %d\n", r, c[r]}' \
                | sort
            echo "  (use 'mirroretctl approve list rpm' for the full file list)"
            echo ""
            found=1
        fi
    fi

    if [[ "${found}" -eq 0 ]]; then
        echo " (no packages in staging)"
    fi
    echo ""
}

# list_staging_rpm - full staged RPM file list (can be very long).
list_staging_rpm() {
    local rpm_staging
    rpm_staging="$(_approval_rpm_roots)"
    rpm_staging="${rpm_staging%% *}"
    local files
    files="$(_find_staged_rpms "${rpm_staging}")"
    if [[ -z "${files}" ]]; then
        echo " (no RPMs in staging)"
        return 0
    fi
    printf '%s\n' "${files}" | sed "s|^${rpm_staging}/||"
}

# -- pip approval -------------------------------------------------------------

# approve_all_pip - promote all staged pip packages to approved.
approve_all_pip() {
    local base_dir="${MIRRORET_BASE_DIR}"
    local src="${base_dir}/staging/pip"
    local dst="${base_dir}/approved/pip"

    [[ -d "${src}" ]] || { warn "No pip staging dir: ${src}"; return 0; }
    _approval_refuse_if_syncing pip

    [[ "${DRY_RUN:-0}" != "1" ]] && mkdir -p "${dst}"
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
    _approval_refuse_if_syncing pip

    local match
    match=$(find "${src}" -type f -name "*${fragment}*" | head -1)
    [[ -n "${match}" ]] || die "No staged pip package matching: ${fragment}"

    local name
    name="$(basename "${match}")"
    [[ "${DRY_RUN:-0}" != "1" ]] && mkdir -p "${dst}"
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

# _npm_publish_tarball <file> - push an approved tarball into Verdaccio.
#
# Moving a .tgz into a directory does NOT make it installable: npm clients
# talk to a registry, not a file tree. Without this step an "approved" npm
# package is unreachable, which is what made approval mode look like it
# worked while clients silently kept pulling from npmjs.
_npm_publish_tarball() {
    local tarball="$1"
    local url="http://localhost:${MIRRORET_NPM_PORT:-4873}/"
    local name
    name="$(basename "${tarball}")"

    if [[ "${DRY_RUN}" == "1" ]]; then
        info "[DRY-RUN] would publish to Verdaccio: ${name}"
        return 0
    fi
    if ! command -v npm >/dev/null 2>&1; then
        warn "npm not found - cannot publish ${name} into Verdaccio."
        return 1
    fi

    local out rc=0
    # Loopback must bypass any corporate proxy or the publish never reaches
    # Verdaccio (the proxy cannot connect to this host's localhost).
    out="$(npm_config_noproxy="localhost,127.0.0.1" \
           npm publish --loglevel=error "${tarball}" --registry "${url}" 2>&1)" || rc=$?
    if [[ ${rc} -eq 0 ]]; then
        info "Published to Verdaccio: ${name}"
        return 0
    fi
    if printf '%s' "${out}" | grep -qiE "EPUBLISHCONFLICT|cannot publish over|already present|previously published"; then
        info "Already in Verdaccio: ${name}"
        return 0
    fi
    if printf '%s' "${out}" | grep -qiE "ENEEDAUTH|unauthorized|forbidden"; then
        warn "Verdaccio rejected publish of ${name}: authentication required."
        warn "Either run: npm login --registry=${url}"
        warn "or set MIRRORET_NPM_ALLOW_ANON_PUBLISH=1 and re-run install.sh --upgrade."
        return 1
    fi
    warn "Publish failed for ${name}:"
    printf '%s\n' "${out}"
    return 1
}

# approve_all_npm - publish all staged npm tarballs and promote them.
#
# Publish FIRST, from staging, and move to approved/ only once Verdaccio has
# accepted the tarball (or already holds that version). Moving first left a
# failed publish stranded in approved/ where nothing would ever retry it.
approve_all_npm() {
    local base_dir="${MIRRORET_BASE_DIR}"
    local src="${base_dir}/staging/npm"
    local dst="${base_dir}/approved/npm"

    [[ -d "${src}" ]] || { warn "No npm staging dir: ${src}"; return 0; }
    _approval_refuse_if_syncing npm

    [[ "${DRY_RUN:-0}" != "1" ]] && mkdir -p "${dst}"
    local count=0 pub_failed=0
    while IFS= read -r -d '' pkg; do
        local name
        name="$(basename "${pkg}")"
        if [[ "${DRY_RUN}" == "1" ]]; then
            info "[DRY-RUN] would approve npm: ${name}"
        elif _npm_publish_tarball "${pkg}"; then
            mv "${pkg}" "${dst}/${name}"
            info "Approved npm: ${name}"
        else
            pub_failed=$(( pub_failed + 1 ))
            warn "Left in staging for retry: ${name}"
        fi
        (( count++ )) || true
    done < <(find "${src}" -type f -name "*.tgz" -print0 2>/dev/null)

    if [[ "${pub_failed}" -gt 0 ]]; then
        warn "npm: ${pub_failed} of ${count} could not be published and remain in staging."
        warn "Those packages are NOT yet installable by clients. Fix the cause and re-run the approval."
        return 1
    fi
    success "npm: ${count} package(s) approved."
}

# approve_npm_package <name_fragment> - promote and publish one tarball.
approve_npm_package() {
    local fragment="$1"
    local base_dir="${MIRRORET_BASE_DIR}"
    local src="${base_dir}/staging/npm"
    local dst="${base_dir}/approved/npm"

    [[ -n "${fragment}" ]] || die "approve_npm_package: package name fragment required."
    [[ -d "${src}" ]] || die "No npm staging dir: ${src}"
    _approval_refuse_if_syncing npm

    local match
    match=$(find "${src}" -type f -name "*${fragment}*.tgz" | head -1)
    [[ -n "${match}" ]] || die "No staged npm package matching: ${fragment}"

    local name
    name="$(basename "${match}")"
    if [[ "${DRY_RUN}" == "1" ]]; then
        info "[DRY-RUN] would approve npm: ${name}"
        return 0
    fi
    mkdir -p "${dst}"
    # Publish from staging; promote only once Verdaccio has accepted it.
    if ! _npm_publish_tarball "${match}"; then
        warn "Left in staging for retry: ${name}"
        return 1
    fi
    mv "${match}" "${dst}/${name}"
    success "Approved npm: ${name}"
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
        "${base_dir}/approved/npm" \
        "${base_dir}/redhat/staging"
    do
        mkdir -p "${d}"
        chmod 755 "${d}"
    done
    info "Approval directories ready under ${base_dir}/{staging,approved}."
}

# -- RPM approval --------------------------------------------------------------

# approve_all_rpm - promote every staged RPM into the live mirror tree,
# then rebuild the metadata of each repo that changed.
approve_all_rpm() {
    local roots staging_root mirror_root
    roots="$(_approval_rpm_roots)"
    staging_root="${roots%% *}"
    mirror_root="${roots##* }"

    [[ -d "${staging_root}" ]] || { warn "No RPM staging dir: ${staging_root}"; return 0; }
    _approval_refuse_if_syncing redhat

    local files
    files="$(_find_staged_rpms "${staging_root}")"
    if [[ -z "${files}" ]]; then
        info "No staged RPMs to approve."
        return 0
    fi

    local count=0
    local touched=()
    local f d
    while IFS= read -r f; do
        [[ -n "${f}" ]] || continue
        d="$(_promote_file "${f}" "${staging_root}" "${mirror_root}")"
        # Metadata lives at the repo root, not in the Packages/ subdir.
        d="$(_rpm_repo_root_of "${d}" "${mirror_root}")"
        touched+=("${d}")
        count=$(( count + 1 ))
    done <<< "${files}"

    # Deduplicate the repo list so createrepo runs once per repo.
    local uniq=()
    if [[ ${#touched[@]} -gt 0 ]]; then
        while IFS= read -r d; do
            [[ -n "${d}" ]] && uniq+=("${d}")
        done < <(printf '%s\n' "${touched[@]}" | sort -u)
    fi

    info "rpm: ${count} package(s) promoted."
    if [[ ${#uniq[@]} -gt 0 ]]; then
        _rpm_rebuild_metadata "${uniq[@]}" || true
    fi
    success "rpm: ${count} package(s) approved."
}

# _rpm_repo_root_of <dir> <mirror_root>
# reposync stores packages under <mirror>/<flavor>/<ver>/<repo>[/Packages/...].
# Metadata belongs at <mirror>/<flavor>/<ver>/<repo>, so walk up to depth 3.
_rpm_repo_root_of() {
    local dir="$1" mirror_root="$2"
    local rel="${dir#"${mirror_root}"/}"
    local flavor ver repo
    IFS=/ read -r flavor ver repo _ <<< "${rel}"
    if [[ -n "${flavor}" && -n "${ver}" && -n "${repo}" ]]; then
        printf '%s/%s/%s/%s' "${mirror_root}" "${flavor}" "${ver}" "${repo}"
    else
        printf '%s' "${dir}"
    fi
}

# approve_rpm_package <name_fragment>
# Promote every staged RPM whose filename matches the fragment. Unlike the pip
# helper this does NOT stop at the first match: a package normally ships as
# several rpms (base, -libs, -devel) and promoting one of them alone leaves an
# unresolvable dependency on the client.
approve_rpm_package() {
    local fragment="$1"
    local roots staging_root mirror_root
    roots="$(_approval_rpm_roots)"
    staging_root="${roots%% *}"
    mirror_root="${roots##* }"

    [[ -n "${fragment}" ]] || die "approve_rpm_package: package name fragment required."
    [[ -d "${staging_root}" ]] || die "No RPM staging dir: ${staging_root}"
    _approval_refuse_if_syncing redhat

    local matches
    matches="$(_find_staged_rpms "${staging_root}" | grep -F -- "${fragment}" || true)"
    [[ -n "${matches}" ]] || die "No staged RPM matching: ${fragment}"

    local count=0 touched=() f d
    while IFS= read -r f; do
        [[ -n "${f}" ]] || continue
        info "Approving rpm: $(basename "${f}")"
        d="$(_promote_file "${f}" "${staging_root}" "${mirror_root}")"
        d="$(_rpm_repo_root_of "${d}" "${mirror_root}")"
        touched+=("${d}")
        count=$(( count + 1 ))
    done <<< "${matches}"

    local uniq=()
    if [[ ${#touched[@]} -gt 0 ]]; then
        while IFS= read -r d; do
            [[ -n "${d}" ]] && uniq+=("${d}")
        done < <(printf '%s\n' "${touched[@]}" | sort -u)
        _rpm_rebuild_metadata "${uniq[@]}" || true
    fi
    success "rpm: ${count} package(s) matching '${fragment}' approved."
}

# exclude_rpm_package <name_fragment> - delete staged RPMs (decline them).
exclude_rpm_package() {
    local fragment="$1"
    local roots staging_root
    roots="$(_approval_rpm_roots)"
    staging_root="${roots%% *}"

    [[ -n "${fragment}" ]] || die "exclude_rpm_package: package name fragment required."
    [[ -d "${staging_root}" ]] || die "No RPM staging dir: ${staging_root}"

    local matches
    matches="$(_find_staged_rpms "${staging_root}" | grep -F -- "${fragment}" || true)"
    [[ -n "${matches}" ]] || die "No staged RPM matching: ${fragment}"

    local count=0 f
    while IFS= read -r f; do
        [[ -n "${f}" ]] || continue
        if [[ "${DRY_RUN}" == "1" ]]; then
            info "[DRY-RUN] would exclude (delete) staged rpm: $(basename "${f}")"
        else
            rm -f "${f}"
            info "Excluded rpm: $(basename "${f}")"
        fi
        count=$(( count + 1 ))
    done <<< "${matches}"
    success "rpm: ${count} package(s) matching '${fragment}' excluded."
}

#!/usr/bin/env bash
# RPM repository configuration for mirroret.
# Source this file; do not execute it directly.
# Requires logging.sh, common.sh, distro.sh, backup.sh.
#
# Configurable knobs:
# MIRRORET_RHEL_VERSION major version to mirror (default: derived from host)
# MIRRORET_RPM_FLAVOR directory name under redhat/mirror/ - defaults to OS_ID
# ("rocky", "almalinux", "rhel", "ol", "centos", "fedora")
# MIRRORET_RPM_REPOS space-separated repo list (default depends on distro)
# MIRRORET_RPM_GPGKEY_URL URL where clients fetch the repo's signing key
# MIRRORET_RPM_ARCH space-separated arch list (default: x86_64). noarch is
# always added. Add i686 when clients install 32-bit
# multilib packages such as glibc.i686, otherwise dnf on
# the client fails with "no package glibc-*.i686 available".
# MIRRORET_RPM_NEWEST_ONLY 1 (default) = only newest build of each package.
# 0 = full history (WARNING: terabytes on some repos).
# MIRRORET_RPM_SOURCE 0 (default) = skip .src.rpm. 1 = include source RPMs
# (WARNING: source RPMs are 400-600 MB each; the
# OL9 appstream repo has ~44k of them = multi-TB).
# MIRRORET_RPM_DELETE 1 (default) = delete local packages that upstream
# dropped. 0 = keep forever.
# MIRRORET_SYNC_MIN_FREE_GB abort a sync when free space drops below this
# (default 10). Prevents filling the disk mid-run.

# _rpm_resolve_flavor - print directory name for this distro's tree.
_rpm_resolve_flavor() {
    if [[ -n "${MIRRORET_RPM_FLAVOR:-}" ]]; then
        echo "${MIRRORET_RPM_FLAVOR}"
        return 0
    fi
    case "${OS_ID:-}" in
        rocky|almalinux|rhel|ol|centos|fedora)
            echo "${OS_ID}"
            ;;
        "")
            warn "OS_ID not set when resolving RPM flavor; defaulting to 'rocky'."
            echo "rocky"
            ;;
        *)
            warn "Unrecognised OS_ID='${OS_ID}'; using literal as RPM flavor."
            echo "${OS_ID}"
            ;;
    esac
}

# _rpm_default_repos <flavor> <major> - print default repo names.
_rpm_default_repos() {
    local flavor="$1" major="$2"

    if [[ -n "${MIRRORET_RPM_REPOS:-}" ]]; then
        echo "${MIRRORET_RPM_REPOS}"
        return 0
    fi

    # Sensible defaults that exist on each flavor's main release stream.
    # "extras" was discontinued on Rocky/Alma 9 but is harmless if listed -
    # reposync will warn and skip; the generated script treats this as
    # non-fatal but still surfaces it.
    case "${flavor}" in
        rocky|almalinux)
            if [[ "${major}" == "8" ]]; then
                echo "baseos appstream extras"
            else
                echo "baseos appstream"
            fi
            ;;
        rhel)
            if [[ "${major}" == "8" ]]; then
                echo "rhel-${major}-for-x86_64-baseos-rpms rhel-${major}-for-x86_64-appstream-rpms"
            else
                echo "rhel-${major}-for-x86_64-baseos-rpms rhel-${major}-for-x86_64-appstream-rpms"
            fi
            ;;
        ol)
            # Oracle Linux 9: add UEK R8 kernel channel + developer EPEL.
            # Older OL keeps the minimal pair; override with
            # MIRRORET_RPM_REPOS to add UEK/EPEL there too.
            if [[ "${major}" == "9" ]]; then
                echo "ol9_baseos_latest ol9_appstream ol9_UEKR8 ol9_developer_EPEL"
            else
                echo "ol${major}_baseos_latest ol${major}_appstream"
            fi
            ;;
        centos)
            echo "baseos appstream"
            ;;
        fedora)
            echo "fedora updates"
            ;;
        *)
            echo "baseos appstream"
            ;;
    esac
}

# configure_createrepo <backup_id> - write the RHEL/CentOS-family sync script.
configure_createrepo() {
    local backup_id="$1"
    local base_dir="${MIRRORET_BASE_DIR}"
    local rhel_ver
    rhel_ver="${MIRRORET_RHEL_VERSION:-$(rhel_major_version)}"

    local flavor
    flavor="$(_rpm_resolve_flavor)"

    local repos
    repos="$(_rpm_default_repos "${flavor}" "${rhel_ver}")"

    # Sync-safety knobs. Defaults are deliberately conservative: without
    # an arch pin and --newest-only, reposync on OL9 appstream pulls every
    # historical .src.rpm (~44k packages, 400-600 MB each = multi-TB).
    local rpm_arch="${MIRRORET_RPM_ARCH:-x86_64}"
    local newest_only="${MIRRORET_RPM_NEWEST_ONLY:-1}"
    local include_source="${MIRRORET_RPM_SOURCE:-0}"
    local delete_removed="${MIRRORET_RPM_DELETE:-1}"
    local min_free_gb="${MIRRORET_SYNC_MIN_FREE_GB:-10}"
    local sync_timeout="${MIRRORET_SYNC_TIMEOUT:-6h}"

    # Catch the config mistake that silently mirrors into the wrong tree:
    # naming ol9_* repos while the flavor is still the host's OS_ID (rhel).
    local _first_repo="${repos%% *}"
    case "${_first_repo}" in
        ol[0-9]*)
            if [[ "${flavor}" != "ol" ]]; then
                warn "MIRRORET_RPM_REPOS names Oracle repos (${_first_repo}) but flavor is '${flavor}'."
                warn "Data will land under redhat/mirror/${flavor}/ and client URLs will not match."
                warn "Set MIRRORET_RPM_FLAVOR=ol in /etc/mirroret/mirroret.conf."
            fi
            ;;
        rhel-*)
            if [[ "${flavor}" != "rhel" ]]; then
                warn "MIRRORET_RPM_REPOS names RHEL repos but flavor is '${flavor}'."
                warn "Set MIRRORET_RPM_FLAVOR=rhel."
            fi
            ;;
    esac

    section "Configuring createrepo (${flavor} ${rhel_ver})"
    info "Repo tree: ${base_dir}/redhat/mirror/${flavor}/${rhel_ver}/"
    info "Repos to sync: ${repos}"
    info "Arch: ${rpm_arch} (+noarch)"
    if [[ " ${rpm_arch} " != *" i686 "* ]]; then
        info "Note: i686 is not mirrored. Clients that install 32-bit multilib"
        info "      packages (glibc.i686, libstdc++.i686) need"
        info "      MIRRORET_RPM_ARCH=\"${rpm_arch} i686\"."
    fi
    info "Newest only: ${newest_only} Source RPMs: ${include_source} Delete removed: ${delete_removed}"
    info "Disk floor: ${min_free_gb} GB (sync aborts below this)"
    if [[ "${include_source}" == "1" ]]; then
        warn "MIRRORET_RPM_SOURCE=1 - source RPMs will be mirrored."
        warn "This can consume MULTIPLE TERABYTES. Ensure the volume is sized for it."
    fi

    local sync_script="${base_dir}/scripts/sync-redhat-repos.sh"
    backup_file "$backup_id" "$sync_script"

    if [[ "${DRY_RUN}" == "1" ]]; then
        info "[DRY-RUN] would write: ${sync_script}"
        return 0
    fi

    mkdir -p "${base_dir}/scripts"

    # Upgrade safety: don't clobber operator edits.
    if ! preserve_user_customization "${sync_script}"; then
        return 0
    fi

    # Detect the correct createrepo binary at script-generation time.
    local createrepo_cmd
    if command -v createrepo_c &>/dev/null; then
        createrepo_cmd="createrepo_c"
    elif command -v createrepo &>/dev/null; then
        createrepo_cmd="createrepo"
    else
        createrepo_cmd="createrepo_c" # let it fail with a clear error if missing
    fi

    # Export flavor + repos to nginx + client config callers.
    MIRRORET_RPM_FLAVOR="${flavor}"
    MIRRORET_RPM_REPOS="${repos}"
    export MIRRORET_RPM_FLAVOR MIRRORET_RPM_REPOS

    cat > "$sync_script" <<SYNC_EOF
#!/usr/bin/env bash
set -Eeuo pipefail

${MIRRORET_MANAGED_MARKER}
# To customize the repo list, set MIRRORET_RPM_REPOS="baseos appstream crb"
# before running install.sh - do NOT edit this file directly.

# RPM sync script - generated by mirroret.
# Flavor: ${flavor}
# Version: ${rhel_ver}
# Repos: ${repos}

REPO_BASE="${base_dir}/redhat/mirror"
LOG_DIR="${base_dir}/logs"
LOG_FILE="\${LOG_DIR}/sync-redhat-\$(date +%Y%m%d-%H%M%S).log"
FLAVOR="${flavor}"
RHEL_VER="${rhel_ver}"
ARCH="${rpm_arch}"
# reposync takes a repeated --arch flag, but dnf repoquery takes ONE
# comma-separated list. Passing the space-separated form to repoquery makes
# the argument invalid, it returns nothing, and the pre-sync size estimate
# silently reads 0, which defeats the disk guard.
ARCH_CSV="\${ARCH// /,}"
NEWEST_ONLY="${newest_only}"
INCLUDE_SOURCE="${include_source}"
DELETE_REMOVED="${delete_removed}"
MIN_FREE_GB="${min_free_gb}"
LOCK_FILE="/var/lock/mirroret-sync-redhat.lock"
SYNC_TIMEOUT="${sync_timeout}"
mkdir -p "\$LOG_DIR"
exec > >(tee -a "\$LOG_FILE") 2>&1

# -- Single-instance lock -------------------------------------------------
# Prevents a cron run from colliding with a manual run. Concurrent
# reposync + createrepo on the same tree corrupts repodata.
exec 9>"\$LOCK_FILE" || { echo "ERROR: cannot open lock \$LOCK_FILE"; exit 2; }
if ! flock -n 9; then
    echo "ERROR: another RPM sync is already running (lock: \$LOCK_FILE). Exiting."
    exit 3
fi
echo \$\$ >&9

# Kill the whole process group on exit so a cancelled run does not leave
# orphaned reposync/createrepo writing into the tree after the lock frees.
trap 'kill -- -\$\$ 2>/dev/null || true' INT TERM

$(mirroret_script_preamble)

echo "Starting RPM sync: \$(date)"
echo " arch=\${ARCH} newest_only=\${NEWEST_ONLY} source=\${INCLUDE_SOURCE} delete=\${DELETE_REMOVED}"

for _cmd in reposync ${createrepo_cmd} flock; do
    if ! command -v "\$_cmd" >/dev/null 2>&1; then
        echo "ERROR: \$_cmd not found. Install yum-utils, createrepo_c, util-linux."
        exit 2
    fi
done

# -- Disk guard -----------------------------------------------------------
# reposync has no size cap. On repos that carry source RPMs a single sync
# can pull terabytes. Abort before we fill the filesystem.
_free_gb() {
    df -BG --output=avail "\$REPO_BASE" 2>/dev/null | tail -1 | tr -dc '0-9'
}
_check_disk() {
    local free
    free="\$(_free_gb)"
    if [[ -z "\$free" ]]; then
        echo "WARN: cannot determine free space on \$REPO_BASE"
        return 0
    fi
    if [[ "\$free" -lt "\$MIN_FREE_GB" ]]; then
        echo "ABORT: only \${free} GB free on \$REPO_BASE (floor: \${MIN_FREE_GB} GB)."
        echo "Free space or raise MIRRORET_SYNC_MIN_FREE_GB, then re-run."
        return 1
    fi
    return 0
}

mkdir -p "\$REPO_BASE"
_check_disk || exit 4

# -- reposync flags -------------------------------------------------------
# --arch pins the architecture. WITHOUT this, reposync on some repos
# (notably OL9 appstream) also pulls every .src.rpm - 44k packages at
# 400-600 MB each. That is the single most destructive default here.
REPOSYNC_ARGS=(--download-metadata
    --setopt=timeout=60 --setopt=minrate=1000 --setopt=retries=3)
# ARCH may list several architectures. noarch is always included; without
# it every architecture-independent package is skipped.
for _a in \${ARCH} noarch; do
    REPOSYNC_ARGS+=(--arch "\${_a}")
done

# Estimate the download before committing to it. reposync gives no size
# preview, so a 4-repo OL9 sync could silently need more than the volume
# has. repoquery is cheap (metadata only) and turns a multi-hour surprise
# into a one-line decision.
_estimate_gb() {
    local repo="\$1" bytes
    command -v dnf >/dev/null 2>&1 || { printf '0'; return 0; }
    bytes="\$(dnf repoquery --repo="\${repo}" --arch="\${ARCH_CSV},noarch" \
        \${NEWEST_ONLY:+--latest-limit=1} \
        --queryformat='%{downloadsize}\\n' 2>/dev/null \
        | awk '/^[0-9]+\$/ {t+=\$1} END {print t+0}')"
    [[ -z "\$bytes" ]] && bytes=0
    printf '%s' "\$(( bytes / 1024 / 1024 / 1024 ))"
}

if [[ "\${MIRRORET_SYNC_ESTIMATE:-1}" == "1" ]]; then
    echo "--- Estimating download size (metadata only)"
    est_total=0
    for repo in \${REPOS[@]+"\${REPOS[@]}"}; do
        est="\$(_estimate_gb "\$repo")"
        echo " \${repo}: ~\${est} GB"
        est_total=\$(( est_total + est ))
    done
    free_now="\$(_free_gb)"
    echo " total: ~\${est_total} GB free: \${free_now:-?} GB"
    if [[ -n "\${free_now}" ]] && [[ "\${est_total}" -gt 0 ]] \
       && [[ \$(( free_now - est_total )) -lt "\${MIN_FREE_GB}" ]]; then
        echo "ABORT: estimated \${est_total} GB would leave less than \${MIN_FREE_GB} GB free."
        echo "Free space, reduce MIRRORET_RPM_REPOS, or set MIRRORET_SYNC_ESTIMATE=0 to skip this check."
        exit 5
    fi
fi

# Be a good neighbour: a 44k-package createrepo at 02:00 otherwise pegs
# every core and saturates the proxy.
NICE=""
if command -v nice >/dev/null 2>&1; then
    NICE="nice -n \${MIRRORET_SYNC_NICE:-10}"
    if command -v ionice >/dev/null 2>&1; then
        NICE="ionice -c 2 -n 7 \${NICE}"
    fi
fi
[[ "\${NEWEST_ONLY}" == "1" ]] && REPOSYNC_ARGS+=(--newest-only)
[[ "\${DELETE_REMOVED}" == "1" ]] && REPOSYNC_ARGS+=(--delete)
[[ "\${INCLUDE_SOURCE}" == "1" ]] && REPOSYNC_ARGS+=(--source)

REPOS=(${repos})

sync_failed=0
metadata_failed=0
aborted=0

for repo in "\${REPOS[@]}"; do
    if ! _check_disk; then
        echo "Stopping before \${repo} - disk floor reached."
        aborted=1
        break
    fi
    target="\${REPO_BASE}/\${FLAVOR}/\${RHEL_VER}/\${repo}"
    mkdir -p "\$target"
    echo "--- reposync \${repo} (free: \$(_free_gb) GB)"
    # shellcheck disable=SC2086 # NICE must word-split
    if ! timeout -k 60 "\${SYNC_TIMEOUT}" \\
            \${NICE} reposync -p "\${REPO_BASE}/\${FLAVOR}/\${RHEL_VER}" \\
            "\${REPOSYNC_ARGS[@]}" --repo "\${repo}"; then
        echo "FAIL: reposync \${repo}"
        sync_failed=\$(( sync_failed + 1 ))
        continue
    fi
done

# --download-metadata already fetched upstream repodata, INCLUDING its
# signatures (repomd.xml.asc). Running createrepo over that regenerates
# repomd.xml and destroys the upstream signature, breaking any client
# using repo_gpgcheck=1 - and burns hours of CPU rebuilding metadata we
# already have. Only build metadata when upstream metadata is absent.
for repo in "\${REPOS[@]}"; do
    target="\${REPO_BASE}/\${FLAVOR}/\${RHEL_VER}/\${repo}"
    [[ -d "\$target" ]] || continue
    if [[ -f "\${target}/repodata/repomd.xml" ]]; then
        echo "--- \${repo}: upstream repodata present, keeping signed metadata"
        continue
    fi
    echo "--- createrepo \${repo} (no upstream repodata found)"
    # shellcheck disable=SC2086
    if ! \${NICE} ${createrepo_cmd} "\$target"; then
        echo "FAIL: createrepo \${repo}"
        metadata_failed=\$(( metadata_failed + 1 ))
    fi
done

# Smoke test: a mirror with unreadable metadata is worse than no mirror,
# because clients only find out at install time. Ask dnf to parse each
# repo straight off disk.
smoke_failed=0
if [[ "\${MIRRORET_SYNC_SMOKE_TEST:-1}" == "1" ]] && command -v dnf >/dev/null 2>&1; then
    echo "--- Smoke testing generated repodata"
    _tmpcache="\$(mktemp -d)"
    for repo in \${REPOS[@]+"\${REPOS[@]}"}; do
        target="\${REPO_BASE}/\${FLAVOR}/\${RHEL_VER}/\${repo}"
        [[ -d "\${target}/repodata" ]] || continue
        if dnf --quiet --disablerepo='*' \
               --repofrompath="smoke-\${repo},file://\${target}" \
               --repo="smoke-\${repo}" \
               --setopt=cachedir="\${_tmpcache}" \
               repoquery --queryformat='%{name}' 2>/dev/null | head -1 | grep -q .; then
            echo " OK: \${repo} is readable by dnf"
        else
            echo " FAIL: \${repo} repodata is not readable by dnf"
            smoke_failed=\$(( smoke_failed + 1 ))
        fi
    done
    rm -rf "\${_tmpcache}"
fi

echo "RPM sync completed: \$(date) (sync_failed=\${sync_failed} metadata_failed=\${metadata_failed} aborted=\${aborted} smoke_failed=\${smoke_failed})"
echo "Free space now: \$(_free_gb) GB"
total=\$(( sync_failed + metadata_failed + aborted + smoke_failed ))
if [[ \$total -ne 0 ]]; then
    exit 1
fi
SYNC_EOF

    chmod +x "$sync_script"
    success "RPM sync script written: ${sync_script}"
}

# generate_rpm_client_config <output_file> - write a .repo file for clients.
generate_rpm_client_config() {
    local output_file="$1"
    local server_ip="${MIRRORET_SERVER_IP}"
    local web_port="${MIRRORET_WEB_PORT:-8080}"
    local rhel_ver
    rhel_ver="${MIRRORET_RHEL_VERSION:-$(rhel_major_version)}"

    local flavor
    flavor="$(_rpm_resolve_flavor)"

    local repos
    repos="$(_rpm_default_repos "${flavor}" "${rhel_ver}")"

    local insecure="${MIRRORET_RPM_INSECURE:-0}"

    section "Generating RPM client config (${flavor} ${rhel_ver})"

    if [[ "${DRY_RUN}" == "1" ]]; then
        info "[DRY-RUN] would write RPM client config to: ${output_file}"
        return 0
    fi

    local gpg_check_line gpg_key_line
    if [[ "${insecure}" == "1" ]]; then
        warn_insecure "RPM client config generated with gpgcheck=0 (GPG checking DISABLED)."
        warn_insecure "Use only in isolated lab environments."
        gpg_check_line="gpgcheck=0"
        gpg_key_line=""
    elif [[ -n "${MIRRORET_RPM_GPGKEY_URL:-}" ]]; then
        gpg_check_line="gpgcheck=1"
        gpg_key_line="gpgkey=${MIRRORET_RPM_GPGKEY_URL}"
    else
        # gpgcheck=1 with NO gpgkey makes every client dnf call fail
        # ("package not signed / no gpgkey available"). Mirrored packages
        # keep their UPSTREAM signature, so point at the upstream vendor
        # key that stock clients already ship in /etc/pki/rpm-gpg/.
        gpg_check_line="gpgcheck=1"
        case "${flavor}" in
            ol) gpg_key_line="gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-oracle" ;;
            rhel) gpg_key_line="gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-redhat-release" ;;
            rocky) gpg_key_line="gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-Rocky-${rhel_ver}" ;;
            almalinux) gpg_key_line="gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-AlmaLinux-${rhel_ver}" ;;
            centos) gpg_key_line="gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-centosofficial" ;;
            fedora) gpg_key_line="gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-fedora-${rhel_ver}-primary" ;;
            *) gpg_key_line="# gpgkey= # set MIRRORET_RPM_GPGKEY_URL" ;;
        esac
        info "RPM client config: gpgcheck=1 using the upstream ${flavor} vendor key."
        info "Override with MIRRORET_RPM_GPGKEY_URL if you re-sign locally."
    fi

    {
        printf '# mirroret RPM client config - %s %s\n' "${flavor}" "${rhel_ver}"
        printf '# Place in /etc/yum.repos.d/ on clients.\n\n'
        for repo in ${repos}; do
            printf '[mirroret-%s]\n' "${repo}"
            printf 'name=Mirroret - %s\n' "${repo}"
            printf 'baseurl=http://%s:%s/redhat/%s/%s/%s\n' \
                "${server_ip}" "${web_port}" "${flavor}" "${rhel_ver}" "${repo}"
            printf 'enabled=1\n'
            printf '%s\n' "${gpg_check_line}"
            [[ -n "${gpg_key_line}" ]] && printf '%s\n' "${gpg_key_line}"
            printf '\n'
        done
        printf '# -- Client setup ---------------------------------------------\n'
        printf '# After installing this file, DISABLE the upstream repos or dnf\n'
        printf '# will keep reaching the internet and bypass this mirror:\n'
        printf '#\n'
        printf '# sudo dnf config-manager --disable %s\n' "${repos}"
        printf '# sudo dnf clean all && sudo dnf repolist\n'
    } > "$output_file"

    success "RPM client config written: ${output_file}"
}

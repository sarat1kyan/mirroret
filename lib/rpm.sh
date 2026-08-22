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
    local approval="${MIRRORET_APPROVAL_ENABLED:-0}"
    # Approval mode stages downloads outside the served tree. Clients keep
    # reading redhat/mirror, so a sync can run without exposing anything new.
    local rpm_repo_base="${base_dir}/redhat/mirror"
    if [[ "${approval}" == "1" ]]; then
        rpm_repo_base="${base_dir}/redhat/staging"
    fi
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

REPO_BASE="${rpm_repo_base}"
# 1 when MIRRORET_APPROVAL_ENABLED=1: packages land in redhat/staging and are
# invisible to clients until promoted into redhat/mirror by the approval step.
APPROVAL_MODE="${approval}"
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
# Any explicit arch list is a filter, so upstream metadata will advertise
# packages this mirror does not have.
ARCH_FILTERED=1
[[ -z "\${ARCH// /}" ]] && ARCH_FILTERED=0
NEWEST_ONLY="${newest_only}"
INCLUDE_SOURCE="${include_source}"
DELETE_REMOVED="${delete_removed}"
MIN_FREE_GB="${min_free_gb}"
LOCK_FILE="/var/lock/mirroret-sync-redhat.lock"
SYNC_TIMEOUT="${sync_timeout}"
mkdir -p "\$LOG_DIR"

# -- Single-instance lock -------------------------------------------------
# Prevents a cron run from colliding with a manual run. Concurrent
# reposync + createrepo on the same tree corrupts repodata.
#
# Taken BEFORE the log redirect: redirecting first is taken BEFORE stdout is redirected into the log. Redirecting
# first sends "another sync is already running" to the log file only, so an
# operator who starts a sync while the nightly cron run is in progress sees
# the command exit with no output at all.
exec 9>"\$LOCK_FILE" || { echo "ERROR: cannot open lock \$LOCK_FILE"; exit 2; }
if ! flock -n 9; then
    echo "ERROR: another RPM sync is already running (lock: \$LOCK_FILE)."
    echo "       Nothing was started. Watch the running one with:"
    echo "         mirroretctl logs tail"
    exit 3
fi
exec > >(tee -a "\$LOG_FILE") 2>&1
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

REPOS=(${repos})

# Estimate the download before committing to it. reposync gives no size
# preview, so a 4-repo OL9 sync could silently need more than the volume
# has. repoquery is cheap (metadata only) and turns a multi-hour surprise
# into a one-line decision.
#
# REPOS must be declared ABOVE this block. It used to be declared below it,
# so the estimate loop iterated an unset array, the estimate came out as
# 0 GB for every repo, and this guard never once fired.
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

# Metadata must describe exactly what is on disk.
#
# --download-metadata fetches the UPSTREAM repodata, including its signature
# (repomd.xml.asc). Keeping it preserves repo_gpgcheck=1 and saves hours of
# CPU. That is only correct for a FULL mirror.
#
# With --newest-only or an --arch filter, what we downloaded is a SUBSET of
# what upstream metadata advertises. Clients then resolve against packages
# that were never mirrored and fail with 404s or "no match", which is how
# 32-bit multilib (glibc.i686) appeared broken while the i686 rpms were
# sitting on disk. In that case the metadata has to be rebuilt locally.
#
# Rebuilding is safe for gpgcheck=1: that verifies PACKAGE signatures, which
# survive mirroring untouched. Only repo_gpgcheck=1 needs upstream's signed
# repomd.xml, and that is incompatible with a filtered mirror by definition.
if [[ "\${NEWEST_ONLY}" == "1" ]] || [[ "\${ARCH_FILTERED}" == "1" ]]; then
    REBUILD_METADATA=1
else
    REBUILD_METADATA=0
fi

# In approval mode nothing here is served. Building metadata over a staging
# tree of tens of thousands of rpms would burn an hour of CPU for a repo no
# client can reach; the metadata that matters is rebuilt in redhat/mirror
# when packages are actually promoted.
if [[ "\${APPROVAL_MODE}" == "1" ]]; then
    echo ""
    echo "--- Approval mode: packages staged, NOT published."
    echo "    Staged under: \${REPO_BASE}"
    echo "    Review:  mirroretctl approve list"
    echo "    Publish: sudo mirroretctl approve all rpm"
    echo "    Nothing reaches clients until you do."
    echo "RPM sync completed: \$(date) (sync_failed=\${sync_failed} aborted=\${aborted} staged=1)"
    echo "Free space now: \$(_free_gb) GB"
    # Still report download failures. Exiting 0 here would tell cron the run
    # was clean even when half the repos failed to sync.
    if [[ \$(( sync_failed + aborted )) -ne 0 ]]; then
        exit 1
    fi
    exit 0
fi
if [[ "\${MIRRORET_RPM_KEEP_UPSTREAM_METADATA:-0}" == "1" ]]; then
    REBUILD_METADATA=0
    echo "--- MIRRORET_RPM_KEEP_UPSTREAM_METADATA=1: keeping upstream metadata."
    echo "    WARNING: with --newest-only or an --arch filter this metadata lists"
    echo "    packages that were not mirrored. Clients will see 404s."
fi

for repo in "\${REPOS[@]}"; do
    target="\${REPO_BASE}/\${FLAVOR}/\${RHEL_VER}/\${repo}"
    [[ -d "\$target" ]] || continue

    if [[ "\${REBUILD_METADATA}" == "0" ]]; then
        if [[ -f "\${target}/repodata/repomd.xml" ]]; then
            echo "--- \${repo}: full mirror, keeping upstream signed metadata"
            continue
        fi
        echo "--- createrepo \${repo} (no upstream repodata found)"
    else
        echo "--- createrepo \${repo} (filtered mirror: metadata must match disk)"
    fi

    # --update reuses the existing metadata cache where possible, so repeated
    # runs are incremental rather than a full rebuild every night.
    CR_ARGS=()
    [[ -f "\${target}/repodata/repomd.xml" ]] && CR_ARGS+=(--update)
    # shellcheck disable=SC2086
    if ! \${NICE} ${createrepo_cmd} "\${CR_ARGS[@]}" "\$target"; then
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

# -- Native engine ------------------------------------------------------------
#
# MIRRORET_RPM_ENGINE=auto|native|reposync
#   auto     - native, unless MIRRORET_RPM_REPOS names repos the catalog does
#              not know (e.g. subscription repo ids like
#              rhel-9-for-x86_64-baseos-rpms), in which case reposync is used
#              because only the host's own dnf knows their URLs.
#   native   - engines/mirroret_rpm.py. Needs only python3, mirrors any
#              distro from any host, and always publishes metadata that
#              matches what is on disk.
#   reposync - the legacy path: requires dnf, requires the repos to be
#              configured on the mirror server itself, and can only mirror
#              what that server is entitled to.

MIRRORET_RPM_ENGINE="${MIRRORET_RPM_ENGINE:-auto}"

# _rpm_engine_path - absolute path to the installed RPM engine.
_rpm_engine_path() {
    echo "${MIRRORET_BASE_DIR}/engines/mirroret_rpm.py"
}

# _rpm_specs_have_repos - true when every generated RPM spec resolved at
# least one upstream URL. A spec with an empty repo list means the operator
# named repo ids the catalog does not know.
_rpm_specs_have_repos() {
    local sp
    for sp in "${MIRRORET_RPM_SPECS[@]:-}"; do
        [[ -z "${sp}" ]] && continue
        [[ -f "${sp}" ]] || return 1
        [[ -n "$(mirroret_json_field "${sp}" repos)" ]] || return 1
    done
    return 0
}

# _rpm_resolve_engine - print the engine that will actually be used.
_rpm_resolve_engine() {
    case "${MIRRORET_RPM_ENGINE}" in
        native|reposync)
            echo "${MIRRORET_RPM_ENGINE}"
            return 0
            ;;
        auto) ;;
        *)
            die "Unknown MIRRORET_RPM_ENGINE: '${MIRRORET_RPM_ENGINE}'. Use auto, native, or reposync."
            ;;
    esac

    if ! check_command python3; then
        warn "python3 not found - falling back to reposync for RPM mirroring."
        echo "reposync"
        return 0
    fi
    if _rpm_specs_have_repos; then
        echo "native"
        return 0
    fi
    if check_command reposync; then
        warn "Some RPM repo names are not in mirroret's upstream catalog"
        warn "  (subscription repo ids look like rhel-9-for-x86_64-baseos-rpms)."
        warn "  Using reposync, which reads them from this host's own dnf config."
        warn "  For catalog-driven mirroring use MIRRORET_RPM_TARGETS=\"rhel:9\"."
        echo "reposync"
        return 0
    fi
    warn "Unknown RPM repo names and no reposync available - using the native engine."
    warn "  It will report which repo names it could not resolve."
    echo "native"
}

# configure_rpm_mirroring <backup_id> - top-level RPM setup entry point.
configure_rpm_mirroring() {
    local backup_id="$1"
    local engine
    engine="$(_rpm_resolve_engine)"
    MIRRORET_RPM_RESOLVED_ENGINE="${engine}"
    export MIRRORET_RPM_RESOLVED_ENGINE
    case "${engine}" in
        native)   _configure_rpm_native "${backup_id}" "${MIRRORET_BASE_DIR}" ;;
        reposync) configure_createrepo "${backup_id}" ;;
    esac
}

# _configure_rpm_native <backup_id> <base_dir>
_configure_rpm_native() {
    local backup_id="$1" base_dir="$2"

    section "Configuring RPM mirroring (native engine)"

    if [[ -z "${MIRRORET_RPM_SPECS+set}" ]] && \
       declare -f generate_target_specs >/dev/null 2>&1; then
        generate_target_specs
    fi

    local -a real_specs=()
    local sp
    for sp in "${MIRRORET_RPM_SPECS[@]:-}"; do
        [[ -n "${sp}" ]] && real_specs+=("${sp}")
    done

    if [[ ${#real_specs[@]} -eq 0 ]]; then
        warn "No RPM targets configured - skipping RPM mirror setup."
        warn "  Set MIRRORET_RPM_TARGETS in /etc/mirroret/mirroret.conf, e.g.:"
        warn "    MIRRORET_RPM_TARGETS=\"ol:9 rocky:9 epel:9\""
        return 0
    fi

    for sp in "${real_specs[@]}"; do
        info "  target: $(_rpm_spec_field "${sp}" id) -> $(_rpm_spec_field "${sp}" dest)"
    done
    if [[ "${MIRRORET_RPM_ARCH:-x86_64}" != *i686* ]]; then
        info "Note: i686 is not mirrored. Clients installing 32-bit multilib"
        info "      packages (glibc.i686) need MIRRORET_RPM_ARCH=\"x86_64 i686\"."
    fi

    if [[ "${DRY_RUN}" == "1" ]]; then
        info "[DRY-RUN] would write ${base_dir}/scripts/sync-rpm-repos.sh"
        return 0
    fi

    mkdir -p "${base_dir}/redhat/mirror" "${base_dir}/scripts"
    _write_rpm_native_sync_script "${base_dir}" "${real_specs[@]}"
    success "RPM mirroring configured for ${#real_specs[@]} target(s)."
}

_rpm_spec_field() {
    mirroret_json_field "$1" "$2"
}


_write_rpm_native_sync_script() {
    local base_dir="$1"; shift
    local -a specs=("$@")
    local sync_script="${base_dir}/scripts/sync-rpm-repos.sh"

    if ! preserve_user_customization "${sync_script}"; then
        return 0
    fi

    local spec_args="" sp
    for sp in "${specs[@]}"; do
        spec_args+=" --spec '${sp}'"
    done

    cat > "${sync_script}" <<RPM_SYNC
#!/usr/bin/env bash
set -Euo pipefail

${MIRRORET_MANAGED_MARKER}
# RPM sync - generated by mirroret. Do NOT edit; change
# MIRRORET_RPM_TARGETS in /etc/mirroret/mirroret.conf and re-run
# 'sudo mirroretctl upgrade'.
#
# Mirrors every configured RPM target with engines/mirroret_rpm.py. Needs no
# dnf, no reposync, no createrepo, and no .repo file on this host - the
# upstream URL comes from the target spec, which is why this works for
# Oracle Linux, Rocky, Alma, CentOS Stream, Fedora and EPEL from the same
# server whatever that server runs.
#
# Metadata always matches what is on disk: a full mirror republishes
# upstream's signed repodata verbatim, a filtered one (arch subset or
# newest-only) gets metadata rewritten to list exactly the packages that
# were downloaded. That is what stops clients resolving a package and then
# getting a 404.

ENGINE="${base_dir}/engines/mirroret_rpm.py"
LOG_DIR="${base_dir}/logs"
LOG_FILE="\${LOG_DIR}/sync-rpm-\$(date +%Y%m%d-%H%M%S).log"
LOCK_FILE="/var/lock/mirroret-sync-redhat.lock"
mkdir -p "\$LOG_DIR"

# The lock is taken BEFORE stdout is redirected into the log. Redirecting
# first sends "another sync is already running" to the log file only, so an
# operator who starts a sync while the nightly cron run is in progress sees
# the command exit with no output at all.
exec 9>"\$LOCK_FILE" || { echo "ERROR: cannot open lock \$LOCK_FILE"; exit 2; }
if ! flock -n 9; then
    echo "ERROR: another RPM sync is already running (lock: \$LOCK_FILE)."
    echo "       Nothing was started. Watch the running one with:"
    echo "         mirroretctl logs tail"
    exit 3
fi
exec > >(tee -a "\$LOG_FILE") 2>&1
trap 'kill -- -\$\$ 2>/dev/null || true' INT TERM

$(mirroret_script_preamble)

echo "Starting RPM sync: \$(date)"

if ! command -v python3 >/dev/null 2>&1; then
    echo "ERROR: python3 not found. The native RPM engine needs python3."
    echo "       Install it, or set MIRRORET_RPM_ENGINE=reposync on a RHEL host."
    exit 2
fi
if [[ ! -f "\$ENGINE" ]]; then
    echo "ERROR: engine not found at \$ENGINE."
    echo "       Re-run: sudo ./install.sh --upgrade"
    exit 2
fi

ARGS=()
[[ "\${MIRRORET_RPM_DELETE:-1}" == "0" ]] && ARGS+=(--no-delete)
[[ "\${MIRRORET_SYNC_ESTIMATE:-1}" == "0" ]] && ARGS+=(--no-estimate)
[[ -n "\${MIRRORET_RPM_JOBS:-}" ]] && ARGS+=(--jobs "\${MIRRORET_RPM_JOBS}")
[[ -n "\${MIRRORET_CA_BUNDLE:-}" ]] && ARGS+=(--ca-bundle "\${MIRRORET_CA_BUNDLE}")
[[ -n "\${MIRRORET_RPM_CLIENT_CERT:-}" ]] && ARGS+=(--client-cert "\${MIRRORET_RPM_CLIENT_CERT}")
[[ -n "\${MIRRORET_RPM_CLIENT_KEY:-}" ]] && ARGS+=(--client-key "\${MIRRORET_RPM_CLIENT_KEY}")

NICE=""
if command -v nice >/dev/null 2>&1; then
    NICE="nice -n \${MIRRORET_SYNC_NICE:-10}"
    command -v ionice >/dev/null 2>&1 && NICE="ionice -c 2 -n 7 \${NICE}"
fi

rc=0
# shellcheck disable=SC2086 # NICE must word-split
timeout -k 60 "\${MIRRORET_SYNC_TIMEOUT:-12h}" \\
    \${NICE} python3 "\$ENGINE"${spec_args} \\
    --min-free-gb "\${MIRRORET_SYNC_MIN_FREE_GB:-10}" \\
    "\${ARGS[@]}" || rc=\$?

echo "RPM sync finished: \$(date) (exit \${rc})"
exit "\${rc}"
RPM_SYNC

    chmod +x "${sync_script}"
    success "RPM sync script written: ${sync_script}"
}

# -- Per-target client configs -----------------------------------------------

# generate_rpm_client_configs <config_dir> - one .repo file per RPM target.
generate_rpm_client_configs() {
    local config_dir="$1"
    local server_ip="${MIRRORET_SERVER_IP}"
    local web_port="${MIRRORET_WEB_PORT:-8080}"
    local insecure="${MIRRORET_RPM_INSECURE:-0}"

    local -a real_specs=()
    local sp
    for sp in "${MIRRORET_RPM_SPECS[@]:-}"; do
        [[ -n "${sp}" ]] && real_specs+=("${sp}")
    done
    [[ ${#real_specs[@]} -eq 0 ]] && return 0

    section "Generating RPM client configs (${#real_specs[@]} target(s))"

    if [[ "${DRY_RUN}" == "1" ]]; then
        info "[DRY-RUN] would write RPM client configs to ${config_dir}/"
        return 0
    fi

    mkdir -p "${config_dir}"
    local first=1

    for sp in "${real_specs[@]}"; do
        local flavor major repo_ids
        flavor="$(_rpm_spec_field "${sp}" flavor)"
        major="$(_rpm_spec_field "${sp}" version)"
        repo_ids="$(mirroret_json_field "${sp}" repos)"
        [[ -z "${repo_ids}" ]] && continue

        local gpg_check_line gpg_key_line
        if [[ "${insecure}" == "1" ]]; then
            warn_insecure "RPM client config for ${flavor}${major}: gpgcheck=0 (GPG DISABLED)."
            gpg_check_line="gpgcheck=0"
            gpg_key_line=""
        elif [[ -n "${MIRRORET_RPM_GPGKEY_URL:-}" ]]; then
            gpg_check_line="gpgcheck=1"
            gpg_key_line="gpgkey=${MIRRORET_RPM_GPGKEY_URL}"
        else
            # gpgcheck=1 with no gpgkey fails EVERY client dnf call. Mirrored
            # rpms keep their upstream signature, so point at the vendor key
            # a stock client already ships.
            gpg_check_line="gpgcheck=1"
            local key
            key="$(rpm_flavor_gpgkey "${flavor}" "${major}")"
            if [[ -n "${key}" ]]; then
                gpg_key_line="gpgkey=${key}"
            else
                gpg_key_line="# gpgkey= # set MIRRORET_RPM_GPGKEY_URL"
            fi
        fi

        local out="${config_dir}/${flavor}${major}.repo"
        {
            printf '# mirroret RPM client config - %s %s\n' "${flavor}" "${major}"
            printf '# Install as /etc/yum.repos.d/mirroret.repo on clients.\n'
            printf '#\n'
            printf '# repo_gpgcheck is deliberately absent: a filtered mirror\n'
            printf '# (arch subset or newest-only) has locally rebuilt repodata,\n'
            printf '# so upstream signature on repomd.xml no longer applies.\n'
            printf '# Package signatures are untouched, which is what gpgcheck=1\n'
            printf '# below verifies.\n\n'
            local repo
            for repo in ${repo_ids}; do
                printf '[mirroret-%s-%s]\n' "${flavor}${major}" "${repo}"
                printf 'name=Mirroret %s %s - %s\n' "${flavor}" "${major}" "${repo}"
                printf 'baseurl=http://%s:%s/redhat/%s/%s/%s\n' \
                    "${server_ip}" "${web_port}" "${flavor}" "${major}" "${repo}"
                printf 'enabled=1\n'
                printf '%s\n' "${gpg_check_line}"
                [[ -n "${gpg_key_line}" ]] && printf '%s\n' "${gpg_key_line}"
                printf '\n'
            done
            printf '# -- Client setup --------------------------------------------\n'
            printf '# After installing this file, DISABLE the upstream repos or\n'
            printf '# dnf keeps reaching the internet and bypasses this mirror:\n'
            printf '#\n'
            printf '#   sudo dnf config-manager --set-disabled "*"\n'
            printf '#   sudo dnf config-manager --set-enabled "mirroret-*"\n'
            printf '#   sudo dnf clean all && sudo dnf repolist\n'
        } > "${out}"

        info "  ${out}"
        if [[ "${first}" == "1" ]]; then
            cp -f "${out}" "${config_dir}/redhat-client.repo"
            first=0
        fi
    done

    success "RPM client configs written to ${config_dir}/"
}

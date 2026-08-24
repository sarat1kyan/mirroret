#!/usr/bin/env bash
# Multi-distribution mirror targets for mirroret.
# Source this file; do not execute it directly.
# Requires logging.sh, common.sh.
#
# WHY THIS EXISTS
#
# mirroret used to mirror whatever the mirror SERVER ran: APT setup was
# gated on the host being Debian-based and RPM setup on it being
# RHEL-based. A RHEL mirror server therefore never downloaded a single
# Ubuntu package, silently, and mirroring Oracle Linux from RHEL needed a
# hand-written .repo file whose $ociregion/$ocidomain dnf variables only
# expand on an Oracle host.
#
# Here the upstream is DATA. One server mirrors Ubuntu, Debian, Rocky,
# AlmaLinux, Oracle Linux, CentOS Stream, Fedora and EPEL side by side,
# regardless of what it runs itself.
#
#   MIRRORET_APT_TARGETS="ubuntu:jammy ubuntu:noble debian:bookworm"
#   MIRRORET_RPM_TARGETS="ol:9 rocky:9 epel:9"
#
# Target syntax:  flavor:release[:arch,arch...]
#
# All Ubuntu releases share one archive tree (and therefore one pool), which
# is how upstream is laid out and means two releases cost far less than
# twice one release.

# -- APT catalog --------------------------------------------------------------

MIRRORET_APT_FLAVORS="ubuntu ubuntu-ports debian"

# apt_flavor_default_arches <flavor>
apt_flavor_default_arches() {
    case "$1" in
        ubuntu-ports) echo "arm64" ;;
        *) echo "amd64" ;;
    esac
}

# apt_flavor_components <flavor>
apt_flavor_components() {
    case "$1" in
        ubuntu|ubuntu-ports) echo "main restricted universe multiverse" ;;
        debian) echo "main contrib non-free non-free-firmware" ;;
        *) echo "main" ;;
    esac
}

# apt_flavor_keyring <flavor> - path clients/servers verify Release with.
apt_flavor_keyring() {
    case "$1" in
        ubuntu|ubuntu-ports) echo "/usr/share/keyrings/ubuntu-archive-keyring.gpg" ;;
        debian) echo "/usr/share/keyrings/debian-archive-keyring.gpg" ;;
        *) echo "" ;;
    esac
}

# apt_flavor_dir <flavor> - directory + URL prefix name.
apt_flavor_dir() {
    case "$1" in
        ubuntu-ports) echo "ubuntu-ports" ;;
        *) echo "$1" ;;
    esac
}

# MIRRORET_APT_SCHEME - http (default) or https for the upstream archives.
#
# http is what stock sources.list uses and what every public mirror serves:
# the archive is GPG-signed, so the transport is not what protects it. Switch
# to https when the proxy only permits CONNECT on 443, which is a common
# corporate policy and otherwise blocks every APT fetch.
MIRRORET_APT_SCHEME="${MIRRORET_APT_SCHEME:-http}"

_apt_scheme() {
    case "${MIRRORET_APT_SCHEME:-http}" in
        http|https) printf '%s' "${MIRRORET_APT_SCHEME:-http}" ;;
        *)
            warn "Unknown MIRRORET_APT_SCHEME='${MIRRORET_APT_SCHEME}'. Using http."
            printf 'http'
            ;;
    esac
}

# apt_suites <flavor> <codename> - print "suite|url" lines.
#
# Every URL here was verified against the live archives. The Debian
# security archive is the one that bites: it lives at
# deb.debian.org/debian-security, NOT security.debian.org/debian, and the
# old code's URL 404'd for every Debian release from bullseye on.
apt_suites() {
    local flavor="$1" code="$2"
    local main sec proto
    proto="$(_apt_scheme)"
    case "${flavor}" in
        ubuntu)
            main="${proto}://${MIRRORET_APT_UPSTREAM_HOST:-archive.ubuntu.com}/ubuntu"
            sec="${proto}://${MIRRORET_APT_SECURITY_HOST:-security.ubuntu.com}/ubuntu"
            printf '%s|%s\n' "${code}" "${main}"
            printf '%s|%s\n' "${code}-updates" "${main}"
            printf '%s|%s\n' "${code}-security" "${sec}"
            [[ "${MIRRORET_APT_BACKPORTS:-0}" == "1" ]] && \
                printf '%s|%s\n' "${code}-backports" "${main}"
            ;;
        ubuntu-ports)
            main="${proto}://${MIRRORET_APT_PORTS_HOST:-ports.ubuntu.com}/ubuntu-ports"
            printf '%s|%s\n' "${code}" "${main}"
            printf '%s|%s\n' "${code}-updates" "${main}"
            printf '%s|%s\n' "${code}-security" "${main}"
            [[ "${MIRRORET_APT_BACKPORTS:-0}" == "1" ]] && \
                printf '%s|%s\n' "${code}-backports" "${main}"
            ;;
        debian)
            main="${proto}://${MIRRORET_APT_UPSTREAM_HOST:-deb.debian.org}/debian"
            sec="${proto}://${MIRRORET_APT_SECURITY_HOST:-deb.debian.org}/debian-security"
            printf '%s|%s\n' "${code}" "${main}"
            printf '%s|%s\n' "${code}-updates" "${main}"
            printf '%s|%s\n' "${code}-security" "${sec}"
            [[ "${MIRRORET_APT_BACKPORTS:-0}" == "1" ]] && \
                printf '%s|%s\n' "${code}-backports" "${main}"
            ;;
        *)
            return 1
            ;;
    esac
    return 0
}

# apt_codename_for <flavor> <release> - normalise a release to a codename.
# Accepts either a codename ("jammy") or a version ("22.04"), so operators
# do not have to remember Ubuntu's animal names.
apt_codename_for() {
    local flavor="$1" release="$2"
    case "${flavor}" in
        ubuntu|ubuntu-ports)
            case "${release}" in
                20.04|focal) echo focal ;;
                22.04|jammy) echo jammy ;;
                24.04|noble) echo noble ;;
                26.04|resolute) echo resolute ;;
                *) echo "${release}" ;;
            esac
            ;;
        debian)
            case "${release}" in
                10|buster) echo buster ;;
                11|bullseye) echo bullseye ;;
                12|bookworm) echo bookworm ;;
                13|trixie) echo trixie ;;
                *) echo "${release}" ;;
            esac
            ;;
        *) echo "${release}" ;;
    esac
}

# -- RPM catalog --------------------------------------------------------------

MIRRORET_RPM_FLAVORS="rocky almalinux ol centos fedora epel rhel"

# rpm_flavor_default_repos <flavor> <major>
rpm_flavor_default_repos() {
    local flavor="$1" major="$2"
    case "${flavor}" in
        rocky|almalinux)
            if [[ "${major}" == "8" ]]; then
                echo "baseos appstream powertools extras"
            else
                echo "baseos appstream crb extras"
            fi
            ;;
        centos) echo "baseos appstream crb" ;;
        ol)
            if [[ "${major}" == "8" ]]; then
                echo "baseos appstream uek codeready epel"
            else
                echo "baseos appstream uek codeready epel"
            fi
            ;;
        fedora) echo "everything updates" ;;
        epel) echo "everything" ;;
        rhel) echo "baseos appstream" ;;
        *) echo "baseos appstream" ;;
    esac
}

# rpm_repo_alias <flavor> <major> <repo> - normalise a legacy dnf repo id.
#
# Existing configs (including the ones this project's own earlier runbook
# told operators to write) name repos the way the HOST's dnf does:
#   ol9_baseos_latest  ol9_appstream  ol9_UEKR8  ol9_developer_EPEL
#   rhel-9-for-x86_64-baseos-rpms
# The catalog uses short names. Silently dropping the long forms produced a
# target with zero repos - a mirror that downloads nothing and reports
# nothing - so translate them instead.
rpm_repo_alias() {
    local flavor="$1" major="$2" repo="$3"
    local stripped="${repo}"

    case "${flavor}" in
        ol)
            # ol9_baseos_latest -> baseos, ol9_UEKR8 -> uekr8, ...
            stripped="${repo#ol${major}_}"
            stripped="${stripped#ol_}"
            case "${stripped}" in
                baseos_latest|baseos*)   printf 'baseos'    ; return 0 ;;
                appstream*)              printf 'appstream' ; return 0 ;;
                UEKR6|uekr6)             printf 'uekr6'     ; return 0 ;;
                UEKR7|uekr7)             printf 'uekr7'     ; return 0 ;;
                UEKR8|uekr8)             printf 'uekr8'     ; return 0 ;;
                developer_EPEL|developer_epel|epel*) printf 'epel'; return 0 ;;
                codeready_builder|codeready*) printf 'codeready'; return 0 ;;
                addons*)                 printf 'addons'    ; return 0 ;;
                kvm*)                    printf 'kvm'       ; return 0 ;;
            esac
            ;;
        rhel)
            # rhel-9-for-x86_64-appstream-rpms -> appstream
            case "${repo}" in
                *-baseos-rpms|*baseos*)        printf 'baseos'       ; return 0 ;;
                *-appstream-rpms|*appstream*)  printf 'appstream'    ; return 0 ;;
                *codeready*|*crb*)             printf 'codeready'    ; return 0 ;;
                *supplementary*)               printf 'supplementary'; return 0 ;;
            esac
            ;;
        rocky|almalinux|centos)
            # Directory-cased forms: BaseOS -> baseos.
            printf '%s' "$(printf '%s' "${repo}" | tr '[:upper:]' '[:lower:]')"
            return 0
            ;;
    esac
    printf '%s' "${repo}"
}

# rpm_repo_url <flavor> <major> <repo> <arch> - print the upstream baseurl.
#
# Returns 1 for an unknown repo so callers can report it instead of
# silently mirroring nothing (which is what a bad repo name used to do).
rpm_repo_url() {
    local flavor="$1" major="$2" repo="$3" arch="${4:-x86_64}"
    local rocky="${MIRRORET_RPM_ROCKY_BASE:-https://dl.rockylinux.org/pub/rocky}"
    local alma="${MIRRORET_RPM_ALMA_BASE:-https://repo.almalinux.org/almalinux}"
    local oracle="${MIRRORET_RPM_ORACLE_BASE:-https://yum.oracle.com/repo/OracleLinux}"
    local stream="${MIRRORET_RPM_CENTOS_BASE:-https://mirror.stream.centos.org}"
    local fedora="${MIRRORET_RPM_FEDORA_BASE:-https://dl.fedoraproject.org/pub/fedora/linux}"
    local epel="${MIRRORET_RPM_EPEL_BASE:-https://dl.fedoraproject.org/pub/epel}"
    local cdn="${MIRRORET_RPM_RHEL_CDN:-https://cdn.redhat.com/content/dist}"

    case "${flavor}" in
        rocky|almalinux)
            local base dir
            [[ "${flavor}" == "rocky" ]] && base="${rocky}/${major}" || base="${alma}/${major}"
            case "${repo}" in
                baseos|BaseOS)         dir="BaseOS" ;;
                appstream|AppStream)   dir="AppStream" ;;
                crb|CRB)               dir="CRB" ;;
                powertools|PowerTools) dir="PowerTools" ;;
                extras)                dir="extras" ;;
                devel)                 dir="devel" ;;
                plus)                  dir="plus" ;;
                highavailability|HighAvailability) dir="HighAvailability" ;;
                resilientstorage|ResilientStorage) dir="ResilientStorage" ;;
                nfv|NFV)               dir="NFV" ;;
                rt|RT)                 dir="RT" ;;
                *) return 1 ;;
            esac
            echo "${base}/${dir}/${arch}/os/"
            ;;
        centos)
            local dir
            case "${repo}" in
                baseos|BaseOS)       dir="BaseOS" ;;
                appstream|AppStream) dir="AppStream" ;;
                crb|CRB)             dir="CRB" ;;
                highavailability|HighAvailability) dir="HighAvailability" ;;
                nfv|NFV)             dir="NFV" ;;
                rt|RT)               dir="RT" ;;
                *) return 1 ;;
            esac
            echo "${stream}/${major}-stream/${dir}/${arch}/os/"
            ;;
        ol)
            # Oracle's own .repo file uses $ociregion/$ocidomain dnf
            # variables that are defined by oraclelinux-release, which is
            # not installed on a non-Oracle host. Hardcoding the public
            # hostnames is what makes mirroring OL from RHEL work at all.
            local sub
            case "${repo}" in
                baseos)    sub="baseos/latest" ;;
                appstream) sub="appstream" ;;
                uek)
                    if [[ "${major}" == "8" ]]; then sub="UEKR7"; else sub="UEKR8"; fi ;;
                uekr6)     sub="UEKR6" ;;
                uekr7)     sub="UEKR7" ;;
                uekr8)     sub="UEKR8" ;;
                codeready) sub="codeready/builder" ;;
                epel)      sub="developer/EPEL" ;;
                addons)    sub="addons" ;;
                developer) sub="developer" ;;
                kvm)       sub="kvm/utils" ;;
                *) return 1 ;;
            esac
            echo "${oracle}/OL${major}/${sub}/${arch}/"
            ;;
        fedora)
            case "${repo}" in
                everything) echo "${fedora}/releases/${major}/Everything/${arch}/os/" ;;
                updates)    echo "${fedora}/updates/${major}/Everything/${arch}/" ;;
                *) return 1 ;;
            esac
            ;;
        epel)
            case "${repo}" in
                everything) echo "${epel}/${major}/Everything/${arch}/" ;;
                next)       echo "${epel}/next/${major}/Everything/${arch}/" ;;
                *) return 1 ;;
            esac
            ;;
        rhel)
            # Needs the host's entitlement certificate; the engine picks it
            # up from /etc/pki/entitlement automatically.
            case "${repo}" in
                baseos)    echo "${cdn}/rhel${major}/${major}/${arch}/baseos/os" ;;
                appstream) echo "${cdn}/rhel${major}/${major}/${arch}/appstream/os" ;;
                codeready) echo "${cdn}/rhel${major}/${major}/${arch}/codeready-builder/os" ;;
                supplementary) echo "${cdn}/rhel${major}/${major}/${arch}/supplementary/os" ;;
                *) return 1 ;;
            esac
            ;;
        *) return 1 ;;
    esac
    return 0
}

# rpm_flavor_gpgkey <flavor> <major> - vendor key a stock client already has.
#
# Mirrored packages keep their UPSTREAM signature, so the client verifies
# with the vendor key it already ships. gpgcheck=1 with no gpgkey makes
# every client dnf call fail, which is why this is never left empty.
rpm_flavor_gpgkey() {
    local flavor="$1" major="$2"
    case "${flavor}" in
        ol)        echo "file:///etc/pki/rpm-gpg/RPM-GPG-KEY-oracle" ;;
        rhel)      echo "file:///etc/pki/rpm-gpg/RPM-GPG-KEY-redhat-release" ;;
        rocky)     echo "file:///etc/pki/rpm-gpg/RPM-GPG-KEY-Rocky-${major}" ;;
        almalinux) echo "file:///etc/pki/rpm-gpg/RPM-GPG-KEY-AlmaLinux-${major}" ;;
        centos)    echo "file:///etc/pki/rpm-gpg/RPM-GPG-KEY-centosofficial" ;;
        fedora)    echo "file:///etc/pki/rpm-gpg/RPM-GPG-KEY-fedora-${major}-primary" ;;
        epel)      echo "file:///etc/pki/rpm-gpg/RPM-GPG-KEY-EPEL-${major}" ;;
        *)         echo "" ;;
    esac
}

# rpm_flavor_dir <flavor> - directory name under redhat/mirror/.
rpm_flavor_dir() { echo "$1"; }

# -- target string parsing ----------------------------------------------------

# _split_target <target> - echo "flavor release arches" for flavor:release[:arches]
_split_target() {
    local t="$1"
    local flavor release arches
    flavor="${t%%:*}"
    local rest="${t#*:}"
    if [[ "${rest}" == "${t}" ]]; then
        release=""
        arches=""
    else
        release="${rest%%:*}"
        if [[ "${rest}" == *:* ]]; then
            arches="${rest#*:}"
        else
            arches=""
        fi
    fi
    printf '%s %s %s\n' "${flavor}" "${release}" "${arches//,/ }"
}

# -- default targets (backwards compatibility) -------------------------------

# default_apt_targets - what to mirror when MIRRORET_APT_TARGETS is unset.
#
# Falls back to the legacy single-flavor knobs so an existing
# /etc/mirroret/mirroret.conf keeps working unchanged. On a host that is
# neither Debian nor Ubuntu there is nothing sensible to guess, so this
# prints nothing and the caller says so out loud rather than dying with
# "Unknown Ubuntu version 9.8" (which is what the old code did).
default_apt_targets() {
    local flavor="${MIRRORET_APT_FLAVOR:-auto}"
    local release=""
    case "${flavor}" in
        auto)
            case "${OS_ID:-}" in
                ubuntu|linuxmint|pop) flavor="ubuntu" ;;
                debian)               flavor="debian" ;;
                *)                    return 0 ;;
            esac
            ;;
    esac
    case "${flavor}" in
        ubuntu|ubuntu-ports) release="${MIRRORET_UBUNTU_CODENAME:-}" ;;
        debian)              release="${MIRRORET_DEBIAN_CODENAME:-}" ;;
    esac
    if [[ -z "${release}" ]]; then
        if [[ "${OS_ID:-}" == "${flavor}" && -n "${OS_CODENAME:-}" ]]; then
            release="${OS_CODENAME}"
        elif [[ "${OS_ID:-}" == "${flavor}" && -n "${OS_VER:-}" ]]; then
            release="$(apt_codename_for "${flavor}" "${OS_VER}")"
        else
            return 0
        fi
    fi
    printf '%s:%s\n' "${flavor}" "${release}"
}

# default_rpm_targets - what to mirror when MIRRORET_RPM_TARGETS is unset.
default_rpm_targets() {
    local flavor="${MIRRORET_RPM_FLAVOR:-}"
    if [[ -z "${flavor}" ]]; then
        case "${OS_ID:-}" in
            rocky|almalinux|rhel|ol|centos|fedora) flavor="${OS_ID}" ;;
            *) return 0 ;;
        esac
    fi
    local major="${MIRRORET_RHEL_VERSION:-${OS_VER%%.*}}"
    [[ -z "${major}" || "${major}" == "unknown" ]] && return 0
    printf '%s:%s\n' "${flavor}" "${major}"
}

# -- spec generation ----------------------------------------------------------

MIRRORET_TARGETS_DIR="${MIRRORET_TARGETS_DIR:-/etc/mirroret/targets}"

_json_str_array() {
    local first=1 item
    printf '['
    for item in "$@"; do
        [[ "${first}" == 1 ]] || printf ', '
        printf '"%s"' "${item}"
        first=0
    done
    printf ']'
}

# write_apt_target_spec <flavor> <codename> <arches...> - print JSON to stdout.
write_apt_target_spec() {
    local flavor="$1" code="$2"; shift 2
    local -a arches=("$@")
    [[ ${#arches[@]} -eq 0 ]] && read -r -a arches <<< "$(apt_flavor_default_arches "${flavor}")"
    local dir components keyring
    dir="$(apt_flavor_dir "${flavor}")"
    components="${MIRRORET_APT_COMPONENTS:-$(apt_flavor_components "${flavor}")}"
    keyring="$(apt_flavor_keyring "${flavor}")"

    local -a comps=()
    read -r -a comps <<< "${components}"

    local suites_json="" line suite url
    while IFS= read -r line; do
        [[ -z "${line}" ]] && continue
        suite="${line%%|*}"
        url="${line#*|}"
        [[ -n "${suites_json}" ]] && suites_json+=", "
        suites_json+="{\"suite\": \"${suite}\", \"url\": \"${url}\"}"
    done < <(apt_suites "${flavor}" "${code}")

    local keyrings_json="[]"
    [[ -n "${keyring}" ]] && keyrings_json="$(_json_str_array "${keyring}")"

    cat <<JSON
{
  "id": "${dir}-${code}",
  "kind": "apt",
  "flavor": "${flavor%%-*}",
  "dir": "${dir}",
  "codename": "${code}",
  "dest": "${MIRRORET_BASE_DIR}/apt/${dir}",
  "arches": $(_json_str_array "${arches[@]}"),
  "components": $(_json_str_array "${comps[@]}"),
  "keyrings": ${keyrings_json},
  "require_signature": ${MIRRORET_APT_REQUIRE_SIGNATURE:-false},
  "sources": $([[ "${MIRRORET_APT_SOURCE:-0}" == "1" ]] && echo true || echo false),
  "translations": $([[ "${MIRRORET_APT_TRANSLATIONS:-1}" == "1" ]] && echo true || echo false),
  "dep11": $([[ "${MIRRORET_APT_DEP11:-1}" == "1" ]] && echo true || echo false),
  "contents": $([[ "${MIRRORET_APT_CONTENTS:-0}" == "1" ]] && echo true || echo false),
  "delete": $([[ "${MIRRORET_APT_DELETE:-1}" == "1" ]] && echo true || echo false),
  "min_free_gb": ${MIRRORET_SYNC_MIN_FREE_GB:-10},
  "suites": [${suites_json}]
}
JSON
}

# write_rpm_target_spec <flavor> <major> <arches...> - print JSON to stdout.
write_rpm_target_spec() {
    local flavor="$1" major="$2"; shift 2
    local -a arches=("$@")
    if [[ ${#arches[@]} -eq 0 ]]; then
        read -r -a arches <<< "${MIRRORET_RPM_ARCH:-x86_64}"
    fi
    # noarch is not optional: without it every architecture-independent
    # package (which is most of appstream) is silently skipped.
    local have_noarch=0 a
    for a in "${arches[@]}"; do [[ "$a" == "noarch" ]] && have_noarch=1; done
    [[ "${have_noarch}" == 0 ]] && arches+=("noarch")

    local primary_arch="${arches[0]}"
    local repos
    repos="${MIRRORET_RPM_REPOS:-$(rpm_flavor_default_repos "${flavor}" "${major}")}"

    local repos_json="" repo url
    for repo in ${repos}; do
        local canon
        canon="$(rpm_repo_alias "${flavor}" "${major}" "${repo}")"
        if ! url="$(rpm_repo_url "${flavor}" "${major}" "${canon}" "${primary_arch}")"; then
            warn "Unknown ${flavor} repo '${repo}' - skipping it."
            warn "  Known: $(rpm_flavor_default_repos "${flavor}" "${major}")"
            continue
        fi
        if [[ "${canon}" != "${repo}" ]]; then
            info "  repo '${repo}' recognised as '${canon}'"
            repo="${canon}"
        fi
        [[ -n "${repos_json}" ]] && repos_json+=", "
        repos_json+="{\"id\": \"${repo}\", \"url\": \"${url}\"}"
    done

    if [[ -z "${repos_json}" ]]; then
        warn "Target ${flavor}:${major} resolved ZERO repos - it would mirror nothing."
        warn "  Requested: ${repos}"
        warn "  Valid ids: $(rpm_flavor_default_repos "${flavor}" "${major}")"
        warn "  Set MIRRORET_RPM_REPOS to those, or unset it to take the defaults."
    fi

    cat <<JSON
{
  "id": "${flavor}${major}",
  "kind": "rpm",
  "flavor": "${flavor}",
  "version": "${major}",
  "dest": "${MIRRORET_BASE_DIR}/redhat/mirror/${flavor}/${major}",
  "arches": $(_json_str_array "${arches[@]}"),
  "newest_only": $([[ "${MIRRORET_RPM_NEWEST_ONLY:-1}" == "1" ]] && echo true || echo false),
  "sources": $([[ "${MIRRORET_RPM_SOURCE:-0}" == "1" ]] && echo true || echo false),
  "delete": $([[ "${MIRRORET_RPM_DELETE:-1}" == "1" ]] && echo true || echo false),
  "min_free_gb": ${MIRRORET_SYNC_MIN_FREE_GB:-10},
  "repos": [${repos_json}]
}
JSON
}

# resolved_apt_targets / resolved_rpm_targets - print the effective target list.
resolved_apt_targets() {
    if [[ -n "${MIRRORET_APT_TARGETS:-}" ]]; then
        printf '%s\n' ${MIRRORET_APT_TARGETS}
    else
        default_apt_targets
    fi
}

resolved_rpm_targets() {
    if [[ -n "${MIRRORET_RPM_TARGETS:-}" ]]; then
        printf '%s\n' ${MIRRORET_RPM_TARGETS}
    else
        default_rpm_targets
    fi
}

# generate_target_specs - write every enabled target's JSON spec.
# Sets MIRRORET_APT_SPECS / MIRRORET_RPM_SPECS to the file lists.
generate_target_specs() {
    local dir="${MIRRORET_TARGETS_DIR}"
    MIRRORET_APT_SPECS=()
    MIRRORET_RPM_SPECS=()

    # In DRY_RUN the specs still get written - into a scratch directory, and
    # nothing outside it is touched. Everything downstream (the nginx
    # locations, the client configs, which RPM engine gets chosen, the
    # summary) is derived FROM the specs, so skipping them entirely made
    # --dry-run report blank target names and potentially the wrong engine.
    # A dry run that does not predict the real run is worse than no dry run.
    local write_dir="${dir}"
    if [[ "${DRY_RUN:-0}" == "1" ]]; then
        write_dir="$(mktemp -d "${TMPDIR:-/tmp}/mirroret-dryrun-targets.XXXXXX")"
        MIRRORET_DRYRUN_TARGETS_DIR="${write_dir}"
        export MIRRORET_DRYRUN_TARGETS_DIR
    else
        mkdir -p "${dir}"
        # Drop specs from a previous run so a removed target stops syncing.
        rm -f "${dir}"/apt-*.json "${dir}"/rpm-*.json
    fi

    local target flavor release arches spec_file
    if [[ "${MIRRORET_ENABLE_APT:-1}" == "1" ]]; then
        while read -r target; do
            [[ -z "${target}" ]] && continue
            read -r flavor release arches <<< "$(_split_target "${target}")"
            if [[ -z "${release}" ]]; then
                warn "APT target '${target}' has no release. Use flavor:release, e.g. ubuntu:jammy."
                continue
            fi
            if ! apt_suites "${flavor}" x >/dev/null 2>&1; then
                warn "Unknown APT flavor '${flavor}' in target '${target}'."
                warn "  Known: ${MIRRORET_APT_FLAVORS}"
                continue
            fi
            release="$(apt_codename_for "${flavor}" "${release}")"
            local spec_name
            spec_name="apt-$(apt_flavor_dir "${flavor}")-${release}.json"
            spec_file="${write_dir}/${spec_name}"
            if [[ "${DRY_RUN:-0}" == "1" ]]; then
                info "[DRY-RUN] would write APT target spec: ${dir}/${spec_name}"
            fi
            # shellcheck disable=SC2086 # arches is a deliberate word split
            write_apt_target_spec "${flavor}" "${release}" ${arches} > "${spec_file}"
            chmod 0644 "${spec_file}"
            MIRRORET_APT_SPECS+=("${spec_file}")
            info "APT target: ${flavor} ${release} ${arches:+(${arches})}"
        done < <(resolved_apt_targets)
        if [[ ${#MIRRORET_APT_SPECS[@]} -eq 0 ]]; then
            warn "APT mirroring is enabled but no target resolved."
            warn "  This host is not Debian/Ubuntu, so there is nothing to guess."
            warn "  Set it explicitly, e.g.:"
            warn "    MIRRORET_APT_TARGETS=\"ubuntu:jammy ubuntu:noble debian:bookworm\""
            warn "  Then re-run: sudo ./install.sh --upgrade"
        fi
    fi

    if [[ "${MIRRORET_ENABLE_RPM:-1}" == "1" ]]; then
        while read -r target; do
            [[ -z "${target}" ]] && continue
            read -r flavor release arches <<< "$(_split_target "${target}")"
            if [[ -z "${release}" ]]; then
                warn "RPM target '${target}' has no release. Use flavor:major, e.g. ol:9."
                continue
            fi
            if ! rpm_repo_url "${flavor}" "${release}" baseos x86_64 >/dev/null 2>&1 \
               && ! rpm_repo_url "${flavor}" "${release}" everything x86_64 >/dev/null 2>&1; then
                warn "Unknown RPM flavor '${flavor}' in target '${target}'."
                warn "  Known: ${MIRRORET_RPM_FLAVORS}"
                continue
            fi
            local spec_name
            spec_name="rpm-${flavor}-${release}.json"
            spec_file="${write_dir}/${spec_name}"
            if [[ "${DRY_RUN:-0}" == "1" ]]; then
                info "[DRY-RUN] would write RPM target spec: ${dir}/${spec_name}"
            fi
            # shellcheck disable=SC2086 # arches is a deliberate word split
            write_rpm_target_spec "${flavor}" "${release}" ${arches} > "${spec_file}"
            chmod 0644 "${spec_file}"
            MIRRORET_RPM_SPECS+=("${spec_file}")
            info "RPM target: ${flavor} ${release} ${arches:+(${arches})}"
        done < <(resolved_rpm_targets)
        if [[ ${#MIRRORET_RPM_SPECS[@]} -eq 0 ]]; then
            warn "RPM mirroring is enabled but no target resolved."
            warn "  Set it explicitly, e.g.:"
            warn "    MIRRORET_RPM_TARGETS=\"ol:9 rocky:9 epel:9\""
        fi
    fi

    export MIRRORET_APT_SPECS MIRRORET_RPM_SPECS
}

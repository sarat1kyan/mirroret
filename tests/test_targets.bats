#!/usr/bin/env bats
# Tests for multi-distribution mirror targets.
#
# The behaviour under test is the one thing that made mirroret not a central
# mirror: it used to mirror only the ecosystem matching the mirror SERVER's
# own distro. Every test here runs with a mocked RHEL 9.8 host - the exact
# configuration where the old code silently mirrored zero Ubuntu packages.

load 'test_helpers'

setup() {
    load_lib
    source "${SCRIPT_DIR}/lib/backup.sh"
    source "${SCRIPT_DIR}/lib/distro.sh"
    source "${SCRIPT_DIR}/lib/targets.sh"
    source "${SCRIPT_DIR}/lib/apt.sh"
    source "${SCRIPT_DIR}/lib/rpm.sh"
    source "${SCRIPT_DIR}/lib/nginx.sh"

    TMPDIR_TEST="$(mktemp -d)"
    MIRRORET_BASE_DIR="${TMPDIR_TEST}/srv"
    MIRRORET_TARGETS_DIR="${TMPDIR_TEST}/targets"
    MIRRORET_SERVER_IP="192.168.30.110"
    MIRRORET_ENABLE_APT=1
    MIRRORET_ENABLE_RPM=1
    DRY_RUN=0
    mkdir -p "${MIRRORET_BASE_DIR}"/{scripts,config,engines}

    # A RHEL 9.8 mirror server, i.e. neither Debian nor Ubuntu.
    OS_ID=rhel; OS_VER=9.8; OS_CODENAME=""; DISTRO_TYPE=rhel
    export OS_ID OS_VER OS_CODENAME DISTRO_TYPE
    unset MIRRORET_APT_TARGETS MIRRORET_RPM_TARGETS
    unset MIRRORET_APT_SPECS MIRRORET_RPM_SPECS
    unset MIRRORET_RPM_REPOS MIRRORET_RPM_FLAVOR MIRRORET_APT_COMPONENTS
    MIRRORET_APT_MIRROR_TOOL=auto
    MIRRORET_RPM_ENGINE=auto
}

teardown() {
    [[ -n "${TMPDIR_TEST:-}" ]] && rm -rf "${TMPDIR_TEST}"
    cleanup_mock
}

# -- catalog ------------------------------------------------------------------

@test "targets: Ubuntu security comes from security.ubuntu.com" {
    run apt_suites ubuntu jammy
    [ "$status" -eq 0 ]
    [[ "$output" == *"jammy|http://archive.ubuntu.com/ubuntu"* ]]
    [[ "$output" == *"jammy-updates|http://archive.ubuntu.com/ubuntu"* ]]
    [[ "$output" == *"jammy-security|http://security.ubuntu.com/ubuntu"* ]]
}

@test "targets: Debian security uses /debian-security, not /debian" {
    # Regression: the old code built the security URL as
    # http://security.debian.org/debian, which 404s for every Debian release
    # from bullseye onward. The archive is deb.debian.org/debian-security.
    run apt_suites debian bookworm
    [ "$status" -eq 0 ]
    [[ "$output" == *"bookworm-security|http://deb.debian.org/debian-security"* ]]
    ! [[ "$output" == *"security.debian.org/debian "* ]]
}

@test "targets: Ubuntu ports serves non-amd64 architectures" {
    run apt_suites ubuntu-ports noble
    [ "$status" -eq 0 ]
    [[ "$output" == *"ports.ubuntu.com/ubuntu-ports"* ]]
    run apt_flavor_default_arches ubuntu-ports
    [ "$output" = "arm64" ]
}

@test "targets: backports are opt-in" {
    MIRRORET_APT_BACKPORTS=0
    run apt_suites ubuntu jammy
    ! [[ "$output" == *"backports"* ]]
    MIRRORET_APT_BACKPORTS=1
    run apt_suites ubuntu jammy
    [[ "$output" == *"jammy-backports"* ]]
}

@test "targets: a version number is accepted in place of a codename" {
    run apt_codename_for ubuntu 22.04
    [ "$output" = "jammy" ]
    run apt_codename_for ubuntu 24.04
    [ "$output" = "noble" ]
    run apt_codename_for debian 12
    [ "$output" = "bookworm" ]
    # An unknown value passes through so a new release works before we know it.
    run apt_codename_for ubuntu somethingnew
    [ "$output" = "somethingnew" ]
}

@test "targets: Oracle URLs are literal, never dnf variables" {
    # Oracle's own public-yum repo file uses \$ociregion/\$ocidomain, which are
    # defined by oraclelinux-release. On a RHEL host dnf leaves them literal
    # and every fetch fails with an SSL error against the host "yum\$ociregion".
    run rpm_repo_url ol 9 baseos x86_64
    [ "$status" -eq 0 ]
    [ "$output" = "https://yum.oracle.com/repo/OracleLinux/OL9/baseos/latest/x86_64/" ]
    ! [[ "$output" == *'$'* ]]
}

@test "targets: Oracle UEK maps to the right release per OL major" {
    run rpm_repo_url ol 9 uek x86_64
    [[ "$output" == *"/UEKR8/"* ]]
    run rpm_repo_url ol 8 uek x86_64
    [[ "$output" == *"/UEKR7/"* ]]
}

@test "targets: Rocky/Alma CRB vs PowerTools follows the major version" {
    run rpm_repo_url rocky 9 crb x86_64
    [[ "$output" == *"/CRB/x86_64/os/"* ]]
    run rpm_flavor_default_repos rocky 8
    [[ "$output" == *"powertools"* ]]
    run rpm_flavor_default_repos rocky 9
    [[ "$output" == *"crb"* ]]
    ! [[ "$output" == *"powertools"* ]]
}

@test "targets: every catalogued flavor resolves its default repos" {
    local flavor major url repo
    for flavor in rocky almalinux ol centos fedora epel rhel; do
        for major in 9; do
            for repo in $(rpm_flavor_default_repos "$flavor" "$major"); do
                run rpm_repo_url "$flavor" "$major" "$repo" x86_64
                [ "$status" -eq 0 ]
                [[ "$output" == https://* ]]
                # A URL with an unexpanded variable is the Oracle bug again.
                ! [[ "$output" == *'$'* ]]
            done
        done
    done
}

@test "targets: an unknown repo name is reported, not silently mirrored" {
    run rpm_repo_url rocky 9 nosuchrepo x86_64
    [ "$status" -ne 0 ]
}

@test "targets: every RPM flavor has a client-usable gpg key" {
    # gpgcheck=1 with no gpgkey fails every client dnf call, so no flavor may
    # come back empty.
    local flavor
    for flavor in rocky almalinux ol centos fedora epel rhel; do
        run rpm_flavor_gpgkey "$flavor" 9
        [ -n "$output" ]
        [[ "$output" == file:///* ]]
    done
}

# -- spec generation on a RHEL host -------------------------------------------

@test "targets: a RHEL host generates Ubuntu and Debian APT specs" {
    MIRRORET_APT_TARGETS="ubuntu:jammy ubuntu:noble debian:bookworm"
    MIRRORET_RPM_TARGETS="ol:9"
    generate_target_specs
    [ -f "${MIRRORET_TARGETS_DIR}/apt-ubuntu-jammy.json" ]
    [ -f "${MIRRORET_TARGETS_DIR}/apt-ubuntu-noble.json" ]
    [ -f "${MIRRORET_TARGETS_DIR}/apt-debian-bookworm.json" ]
    [ "${#MIRRORET_APT_SPECS[@]}" -eq 3 ]
}

@test "targets: releases of one flavor share a single archive root" {
    # Upstream shares pool/ across suites; so must we, or two Ubuntu releases
    # cost twice the disk for largely identical packages.
    MIRRORET_APT_TARGETS="ubuntu:jammy ubuntu:noble"
    generate_target_specs
    local a b
    a="$(mirroret_json_field "${MIRRORET_TARGETS_DIR}/apt-ubuntu-jammy.json" dest)"
    b="$(mirroret_json_field "${MIRRORET_TARGETS_DIR}/apt-ubuntu-noble.json" dest)"
    [ "$a" = "$b" ]
    [ "$a" = "${MIRRORET_BASE_DIR}/apt/ubuntu" ]
}

@test "targets: generated specs are valid JSON with the fields engines need" {
    MIRRORET_APT_TARGETS="ubuntu:jammy"
    MIRRORET_RPM_TARGETS="ol:9 rocky:9 epel:9"
    generate_target_specs
    local spec
    for spec in "${MIRRORET_TARGETS_DIR}"/*.json; do
        run python3 - "$spec" <<'PY'
import json
import sys

with open(sys.argv[1]) as fh:
    d = json.load(fh)
assert d["kind"] in ("apt", "rpm"), d.get("kind")
for key in ("id", "dest", "arches"):
    assert d.get(key), "%s missing %s" % (sys.argv[1], key)
if d["kind"] == "apt":
    assert d["suites"], "no suites"
    for s in d["suites"]:
        assert s["suite"] and s["url"].startswith("http"), s
    assert d["components"], "no components"
else:
    assert d["repos"], "no repos"
    for r in d["repos"]:
        assert r["id"] and r["url"].startswith("http"), r
    # noarch is not optional.
    assert "noarch" in d["arches"], d["arches"]
print("ok")
PY
        [ "$status" -eq 0 ]
    done
}

@test "targets: a removed target stops being synced" {
    MIRRORET_APT_TARGETS="ubuntu:jammy ubuntu:noble"
    generate_target_specs
    [ -f "${MIRRORET_TARGETS_DIR}/apt-ubuntu-noble.json" ]
    MIRRORET_APT_TARGETS="ubuntu:jammy"
    generate_target_specs
    [ -f "${MIRRORET_TARGETS_DIR}/apt-ubuntu-jammy.json" ]
    [ ! -f "${MIRRORET_TARGETS_DIR}/apt-ubuntu-noble.json" ]
}

@test "targets: an unknown flavor warns and skips, it does not abort" {
    MIRRORET_APT_TARGETS="ubuntu:jammy bogus:1"
    MIRRORET_RPM_TARGETS="ol:9 alsobogus:9"
    run generate_target_specs
    [ "$status" -eq 0 ]
    [[ "$output" == *"Unknown APT flavor 'bogus'"* ]]
    [[ "$output" == *"Unknown RPM flavor 'alsobogus'"* ]]
    [ -f "${MIRRORET_TARGETS_DIR}/apt-ubuntu-jammy.json" ]
    [ -f "${MIRRORET_TARGETS_DIR}/rpm-ol-9.json" ]
}

@test "targets: a per-target arch override is honoured" {
    MIRRORET_APT_TARGETS="ubuntu-ports:noble:arm64,armhf"
    generate_target_specs
    run mirroret_json_field "${MIRRORET_TARGETS_DIR}/apt-ubuntu-ports-noble.json" arches
    [ "$output" = "arm64 armhf" ]
}

@test "targets: no APT target on a RHEL host says so instead of guessing" {
    # The old code called _apt_codename on a RHEL host and died with
    # "Unknown Ubuntu version '9.8'". Silence and a hard crash are both wrong;
    # the right answer is an actionable message.
    unset MIRRORET_APT_TARGETS
    run generate_target_specs
    [ "$status" -eq 0 ]
    [[ "$output" == *"no target resolved"* ]]
    [[ "$output" == *"MIRRORET_APT_TARGETS"* ]]
    ! [[ "$output" == *"Unknown Ubuntu version"* ]]
}

@test "targets: an Ubuntu host still auto-detects its own release" {
    OS_ID=ubuntu; OS_VER=22.04; OS_CODENAME=jammy; DISTRO_TYPE=debian
    unset MIRRORET_APT_TARGETS
    run default_apt_targets
    [ "$output" = "ubuntu:jammy" ]
}

@test "targets: a RHEL host still auto-detects its own RPM release" {
    unset MIRRORET_RPM_TARGETS MIRRORET_RPM_FLAVOR
    run default_rpm_targets
    [ "$output" = "rhel:9" ]
}

# -- wiring: sync scripts, nginx, client configs ------------------------------

@test "wiring: a RHEL host gets an APT sync script" {
    MIRRORET_APT_TARGETS="ubuntu:jammy"
    generate_target_specs
    configure_apt_mirror "bk"
    [ "${MIRRORET_APT_RESOLVED_TOOL}" = "native" ]
    [ -x "${MIRRORET_BASE_DIR}/scripts/sync-apt-repos.sh" ]
    run bash -n "${MIRRORET_BASE_DIR}/scripts/sync-apt-repos.sh"
    [ "$status" -eq 0 ]
    # It must reference the spec, so adding a target changes what syncs.
    grep -q "apt-ubuntu-jammy.json" "${MIRRORET_BASE_DIR}/scripts/sync-apt-repos.sh"
}

@test "wiring: a RHEL host gets an RPM sync script using the native engine" {
    MIRRORET_RPM_TARGETS="ol:9"
    generate_target_specs
    configure_rpm_mirroring "bk"
    [ "${MIRRORET_RPM_RESOLVED_ENGINE}" = "native" ]
    [ -x "${MIRRORET_BASE_DIR}/scripts/sync-rpm-repos.sh" ]
    run bash -n "${MIRRORET_BASE_DIR}/scripts/sync-rpm-repos.sh"
    [ "$status" -eq 0 ]
    grep -q "rpm-ol-9.json" "${MIRRORET_BASE_DIR}/scripts/sync-rpm-repos.sh"
}

@test "wiring: generated sync scripts load the proxy preamble" {
    # cron hands a script a minimal environment. Without this every nightly
    # sync fails behind a proxy while manual runs succeed.
    MIRRORET_APT_TARGETS="ubuntu:jammy"
    MIRRORET_RPM_TARGETS="ol:9"
    generate_target_specs
    configure_apt_mirror "bk"
    configure_rpm_mirroring "bk"
    local s
    for s in sync-apt-repos.sh sync-rpm-repos.sh; do
        grep -q 'mirroret.conf' "${MIRRORET_BASE_DIR}/scripts/${s}"
        grep -q 'https_proxy' "${MIRRORET_BASE_DIR}/scripts/${s}"
        # And take a lock, so cron cannot collide with a manual run.
        grep -q 'flock -n 9' "${MIRRORET_BASE_DIR}/scripts/${s}"
    done
}

@test "wiring: nginx serves one location per mirrored APT flavor" {
    MIRRORET_APT_TARGETS="ubuntu:jammy ubuntu:noble debian:bookworm"
    generate_target_specs
    run _nginx_apt_locations "${MIRRORET_BASE_DIR}" "/legacy"
    [ "$status" -eq 0 ]
    [[ "$output" == *"location /ubuntu/"* ]]
    [[ "$output" == *"location /debian/"* ]]
    [[ "$output" == *"alias ${MIRRORET_BASE_DIR}/apt/ubuntu/"* ]]
    [[ "$output" == *"alias ${MIRRORET_BASE_DIR}/apt/debian/"* ]]
    # Two Ubuntu releases share one archive root, so one location only.
    [ "$(echo "$output" | grep -c 'location /ubuntu/')" -eq 1 ]
}

@test "wiring: nginx falls back to the legacy tree when no target is native" {
    MIRRORET_APT_SPECS=()
    run _nginx_apt_locations "${MIRRORET_BASE_DIR}" "/legacy/apt-mirror/path"
    [ "$status" -eq 0 ]
    [[ "$output" == *"alias /legacy/apt-mirror/path/"* ]]
}

@test "wiring: APT client configs are generated per target on a RHEL host" {
    MIRRORET_APT_TARGETS="ubuntu:jammy debian:bookworm"
    generate_target_specs
    generate_apt_client_configs "${MIRRORET_BASE_DIR}/config"
    [ -f "${MIRRORET_BASE_DIR}/config/ubuntu-jammy.list" ]
    [ -f "${MIRRORET_BASE_DIR}/config/debian-bookworm.list" ]
    # deb822 too: Ubuntu 24.04 and Debian 12 ship that format by default.
    [ -f "${MIRRORET_BASE_DIR}/config/ubuntu-jammy.sources" ]
    grep -q "192.168.30.110:8080/ubuntu jammy " \
        "${MIRRORET_BASE_DIR}/config/ubuntu-jammy.list"
    grep -q "jammy-security" "${MIRRORET_BASE_DIR}/config/ubuntu-jammy.list"
}

@test "wiring: APT client configs point signed-by at the UPSTREAM keyring" {
    # Mirrored Release files carry the upstream signature. Pointing signed-by
    # at a mirroret key would make apt update fail on every client.
    MIRRORET_APT_TARGETS="ubuntu:jammy"
    MIRRORET_APT_KEYRING="/etc/apt/keyrings/mirroret.gpg"
    generate_target_specs
    generate_apt_client_configs "${MIRRORET_BASE_DIR}/config"
    local f="${MIRRORET_BASE_DIR}/config/ubuntu-jammy.list"
    grep -q "signed-by=/usr/share/keyrings/ubuntu-archive-keyring.gpg" "$f"
    ! grep -q "mirroret.gpg" "$f"
}

@test "wiring: RPM client configs are generated per target with a gpgkey" {
    MIRRORET_RPM_TARGETS="ol:9 rocky:9"
    generate_target_specs
    generate_rpm_client_configs "${MIRRORET_BASE_DIR}/config"
    [ -f "${MIRRORET_BASE_DIR}/config/ol9.repo" ]
    [ -f "${MIRRORET_BASE_DIR}/config/rocky9.repo" ]
    grep -q "baseurl=http://192.168.30.110:8080/redhat/ol/9/baseos" \
        "${MIRRORET_BASE_DIR}/config/ol9.repo"
    # gpgcheck=1 with no gpgkey breaks every client dnf call.
    grep -q "^gpgcheck=1" "${MIRRORET_BASE_DIR}/config/ol9.repo"
    grep -q "^gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-oracle" \
        "${MIRRORET_BASE_DIR}/config/ol9.repo"
    # A filtered mirror rebuilds repomd.xml, so repo_gpgcheck must be off.
    ! grep -q "^repo_gpgcheck=1" "${MIRRORET_BASE_DIR}/config/ol9.repo"
}

@test "wiring: legacy single-target config names are still produced" {
    # docs, older runbooks and 'mirroretctl client verify' refer to these.
    MIRRORET_APT_TARGETS="ubuntu:jammy"
    MIRRORET_RPM_TARGETS="ol:9"
    generate_target_specs
    generate_apt_client_configs "${MIRRORET_BASE_DIR}/config"
    generate_rpm_client_configs "${MIRRORET_BASE_DIR}/config"
    [ -f "${MIRRORET_BASE_DIR}/config/debian-client.list" ]
    [ -f "${MIRRORET_BASE_DIR}/config/redhat-client.repo" ]
}

@test "wiring: a legacy APT tool still takes the legacy code path" {
    # Operators who pinned debmirror must not be switched silently.
    MIRRORET_APT_MIRROR_TOOL=debmirror
    OS_ID=debian; OS_VER=12; OS_CODENAME=bookworm; DISTRO_TYPE=debian
    DRY_RUN=1
    run configure_apt_mirror "bk"
    [ "$status" -eq 0 ]
    [[ "$output" == *"debmirror"* ]]
}

@test "wiring: MIRRORET_RPM_ENGINE=reposync is respected" {
    MIRRORET_RPM_ENGINE=reposync
    run _rpm_resolve_engine
    [ "$output" = "reposync" ]
}

@test "wiring: an unknown RPM engine name is rejected with the valid list" {
    MIRRORET_RPM_ENGINE=magic
    run _rpm_resolve_engine
    [ "$status" -ne 0 ]
    [[ "$output" == *"auto, native, or reposync"* ]]
}

# -- client verify: does the server's own view match what a client sees? ------

@test "verify: an advertised APT suite with no published Release is flagged" {
    # This is the exact failure a client reports as
    #   E: Failed to fetch .../dists/<suite>/main/binary-amd64/Packages 404
    # The server looks fine until you ask a client, so mirroretctl has to
    # notice it too.
    MIRRORET_APT_TARGETS="ubuntu:jammy"
    generate_target_specs
    generate_apt_client_configs "${MIRRORET_BASE_DIR}/config"
    # Publish only the base suite, not -updates / -security.
    mkdir -p "${MIRRORET_BASE_DIR}/apt/ubuntu/dists/jammy"
    touch "${MIRRORET_BASE_DIR}/apt/ubuntu/dists/jammy/Release"

    run env MIRRORET_BASE_DIR="${MIRRORET_BASE_DIR}" \
        bash "${SCRIPT_DIR}/mirroretctl" client verify
    [[ "$output" == *"not published yet"* ]]
    [[ "$output" == *"jammy-updates"* ]]
    [[ "$output" == *"jammy-security"* ]]
    # ...and it must not claim the published one is missing.
    ! [[ "$output" == *"not published yet: jammy jammy-updates"* ]]
}

@test "verify: all suites published reports clean" {
    MIRRORET_APT_TARGETS="ubuntu:jammy"
    generate_target_specs
    generate_apt_client_configs "${MIRRORET_BASE_DIR}/config"
    local suite
    for suite in jammy jammy-updates jammy-security; do
        mkdir -p "${MIRRORET_BASE_DIR}/apt/ubuntu/dists/${suite}"
        touch "${MIRRORET_BASE_DIR}/apt/ubuntu/dists/${suite}/Release"
    done

    run env MIRRORET_BASE_DIR="${MIRRORET_BASE_DIR}" \
        bash "${SCRIPT_DIR}/mirroretctl" client verify
    [[ "$output" == *"all 3 advertised suite(s) are published"* ]]
    ! [[ "$output" == *"not published yet"* ]]
}

@test "verify: an RPM repo with no repodata is flagged" {
    MIRRORET_RPM_TARGETS="rocky:9"
    MIRRORET_RPM_REPOS="baseos appstream"
    generate_target_specs
    generate_rpm_client_configs "${MIRRORET_BASE_DIR}/config"
    # Publish baseos only.
    mkdir -p "${MIRRORET_BASE_DIR}/redhat/mirror/rocky/9/baseos/repodata"
    touch "${MIRRORET_BASE_DIR}/redhat/mirror/rocky/9/baseos/repodata/repomd.xml"

    run env MIRRORET_BASE_DIR="${MIRRORET_BASE_DIR}" \
        bash "${SCRIPT_DIR}/mirroretctl" client verify
    [[ "$output" == *"no published metadata yet"* ]]
    [[ "$output" == *"appstream"* ]]
}

@test "targets: the report distinguishes synced from not-yet-synced" {
    MIRRORET_APT_TARGETS="ubuntu:jammy"
    MIRRORET_RPM_TARGETS="rocky:9"
    MIRRORET_RPM_REPOS="baseos"
    generate_target_specs

    run env MIRRORET_BASE_DIR="${MIRRORET_BASE_DIR}" \
        MIRRORET_TARGETS_DIR="${MIRRORET_TARGETS_DIR}" \
        bash "${SCRIPT_DIR}/mirroretctl" targets
    [ "$status" -eq 0 ]
    [[ "$output" == *"not synced yet"* ]]

    # Now publish everything and it must say so.
    local suite
    for suite in jammy jammy-updates jammy-security; do
        mkdir -p "${MIRRORET_BASE_DIR}/apt/ubuntu/dists/${suite}"
        touch "${MIRRORET_BASE_DIR}/apt/ubuntu/dists/${suite}/Release"
    done
    mkdir -p "${MIRRORET_BASE_DIR}/redhat/mirror/rocky/9/baseos/repodata"
    touch "${MIRRORET_BASE_DIR}/redhat/mirror/rocky/9/baseos/repodata/repomd.xml"

    run env MIRRORET_BASE_DIR="${MIRRORET_BASE_DIR}" \
        MIRRORET_TARGETS_DIR="${MIRRORET_TARGETS_DIR}" \
        bash "${SCRIPT_DIR}/mirroretctl" targets
    [ "$status" -eq 0 ]
    [[ "$output" == *"suites published"* ]]
    [[ "$output" == *"repos published"* ]]
    ! [[ "$output" == *"not synced yet"* ]]
}

@test "targets: MIRRORET_APT_SCHEME switches the upstream to https" {
    # Needed where the proxy only permits CONNECT on 443, which otherwise
    # blocks every APT fetch.
    MIRRORET_APT_SCHEME=https
    run apt_suites ubuntu jammy
    [ "$status" -eq 0 ]
    [[ "$output" == *"https://archive.ubuntu.com/ubuntu"* ]]
    [[ "$output" == *"https://security.ubuntu.com/ubuntu"* ]]
    ! [[ "$output" == *"http://archive"* ]]
}

@test "targets: an invalid scheme warns and falls back to http" {
    MIRRORET_APT_SCHEME=ftp
    run apt_suites ubuntu jammy
    [ "$status" -eq 0 ]
    [[ "$output" == *"Unknown MIRRORET_APT_SCHEME"* ]]
    [[ "$output" == *"http://archive.ubuntu.com/ubuntu"* ]]
}

# -- doctor: does the diagnostic notice silence? ------------------------------

@test "doctor: warns when APT is configured with no target" {
    # The whole failure mode is silence. A server with no APT target
    # downloads no .deb and reports nothing wrong, because doing nothing is
    # exactly what it was told to do. The diagnostic has to say so.
    run env MIRRORET_BASE_DIR="${MIRRORET_BASE_DIR}" \
        MIRRORET_TARGETS_DIR="${TMPDIR_TEST}/none" \
        bash "${SCRIPT_DIR}/scripts/mirroret-debug.sh"
    [[ "$output" == *"no target configured"* ]]
    [[ "$output" == *"MIRRORET_APT_TARGETS"* ]]
}

@test "doctor: reports published suites and repos when they exist" {
    MIRRORET_APT_TARGETS="ubuntu:jammy"
    MIRRORET_RPM_TARGETS="rocky:9"
    MIRRORET_RPM_REPOS="baseos"
    generate_target_specs
    mkdir -p "${MIRRORET_BASE_DIR}/apt/ubuntu/dists/jammy"
    touch "${MIRRORET_BASE_DIR}/apt/ubuntu/dists/jammy/Release"
    mkdir -p "${MIRRORET_BASE_DIR}/redhat/mirror/rocky/9/baseos/repodata"
    touch "${MIRRORET_BASE_DIR}/redhat/mirror/rocky/9/baseos/repodata/repomd.xml"

    run env MIRRORET_BASE_DIR="${MIRRORET_BASE_DIR}" \
        MIRRORET_TARGETS_DIR="${MIRRORET_TARGETS_DIR}" \
        bash "${SCRIPT_DIR}/scripts/mirroret-debug.sh"
    [[ "$output" == *"suite(s) published"* ]]
    [[ "$output" == *"repo(s) with published metadata"* ]]
    ! [[ "$output" == *"no target configured"* ]]
}

@test "doctor: a legacy mirroring tool is reported as such, not as missing" {
    mkdir -p "${MIRRORET_BASE_DIR}/scripts"
    touch "${MIRRORET_BASE_DIR}/scripts/sync-apt-debmirror.sh"
    touch "${MIRRORET_BASE_DIR}/scripts/sync-redhat-repos.sh"
    run env MIRRORET_BASE_DIR="${MIRRORET_BASE_DIR}" \
        MIRRORET_TARGETS_DIR="${TMPDIR_TEST}/none" \
        bash "${SCRIPT_DIR}/scripts/mirroret-debug.sh"
    [[ "$output" == *"legacy mirroring tool"* ]]
    [[ "$output" == *"legacy reposync path"* ]]
}

@test "cli: config diff sees the native sync scripts and specs" {
    # Regression: config diff only ever grepped the legacy
    # sync-redhat-repos.sh, so on a native install it reported
    # "no generated RPM sync script" while the mirror was working fine -
    # and it said nothing at all about APT.
    MIRRORET_APT_TARGETS="ubuntu:jammy"
    MIRRORET_RPM_TARGETS="rocky:9"
    generate_target_specs
    configure_apt_mirror "bk"
    configure_rpm_mirroring "bk"

    run env MIRRORET_BASE_DIR="${MIRRORET_BASE_DIR}" \
        MIRRORET_TARGETS_DIR="${MIRRORET_TARGETS_DIR}" \
        bash "${SCRIPT_DIR}/mirroretctl" config diff
    [ "$status" -eq 0 ]
    [[ "$output" == *"sync-apt-repos.sh"* ]]
    [[ "$output" == *"sync-rpm-repos.sh"* ]]
    [[ "$output" == *"generated APT specs"*"ubuntu-jammy"* ]]
    [[ "$output" == *"generated RPM specs"*"rocky9"* ]]
    ! [[ "$output" == *"no generated RPM sync script"* ]]
}

@test "cli: config diff flags a target that was never applied" {
    # The conf asks for a target but upgrade was never run, so nothing syncs
    # it. That must be a visible error, not silence.
    MIRRORET_APT_TARGETS="ubuntu:jammy"
    MIRRORET_RPM_TARGETS="rocky:9"
    generate_target_specs
    configure_apt_mirror "bk"
    configure_rpm_mirroring "bk"

    local conf="${TMPDIR_TEST}/mirroret.conf"
    cat > "$conf" <<CONF
MIRRORET_APT_TARGETS="ubuntu:jammy debian:bookworm"
MIRRORET_RPM_TARGETS="rocky:9 ol:9"
CONF

    run env MIRRORET_CONF="$conf" \
        MIRRORET_BASE_DIR="${MIRRORET_BASE_DIR}" \
        MIRRORET_TARGETS_DIR="${MIRRORET_TARGETS_DIR}" \
        bash "${SCRIPT_DIR}/mirroretctl" config diff
    [ "$status" -ne 0 ]
    [[ "$output" == *"requested but NOT generated"* ]]
    [[ "$output" == *"ol:9"* ]]
    [[ "$output" == *"mirroretctl upgrade"* ]]
}

@test "cli: config diff is clean when the conf matches what is generated" {
    MIRRORET_APT_TARGETS="ubuntu:jammy"
    MIRRORET_RPM_TARGETS="rocky:9"
    generate_target_specs
    configure_apt_mirror "bk"
    configure_rpm_mirroring "bk"

    local conf="${TMPDIR_TEST}/mirroret.conf"
    cat > "$conf" <<CONF
MIRRORET_APT_TARGETS="ubuntu:jammy"
MIRRORET_RPM_TARGETS="rocky:9"
CONF

    run env MIRRORET_CONF="$conf" \
        MIRRORET_BASE_DIR="${MIRRORET_BASE_DIR}" \
        MIRRORET_TARGETS_DIR="${MIRRORET_TARGETS_DIR}" \
        bash "${SCRIPT_DIR}/mirroretctl" config diff
    [ "$status" -eq 0 ]
    [[ "$output" == *"every requested target has a generated spec"* ]]
    ! [[ "$output" == *"requested but NOT generated"* ]]
}

@test "cli: every interactive menu entry maps to a dispatcher branch" {
    # Renumbering the menu without renumbering the case block silently
    # rewires options - e.g. picking "sync stop" running a retention prune.
    run python3 - "${SCRIPT_DIR}/mirroretctl" <<'PYEOF'
import re
import sys

src = open(sys.argv[1]).read()
start = src.index("cat <<'MENU'")
menu_text = src[start:src.index("MENU\n", start)]
menu = set(re.findall(r"^\s*(\d+)\)", menu_text, re.M))

cstart = src.index('case "$choice" in')
case_text = src[cstart:src.index("esac", cstart)]
cases = set(re.findall(r"^\s*(\d+)\)", case_text, re.M))

assert menu, "no menu entries found"
assert menu == cases, "menu %s vs cases %s" % (
    sorted(menu - cases, key=int), sorted(cases - menu, key=int))
print("%d menu entries, all mapped" % len(menu))
PYEOF
    [ "$status" -eq 0 ]
    [[ "$output" == *"all mapped"* ]]
}

@test "cli: the menu offers per-ecosystem syncs, not just sync all" {
    grep -q 'sync apt' "${SCRIPT_DIR}/mirroretctl"
    grep -q 'sync rpm' "${SCRIPT_DIR}/mirroretctl"
    run bash "${SCRIPT_DIR}/mirroretctl" help
    [[ "$output" == *"sync all|apt|rpm|pip|npm|docker"* ]]
}

# -- setup scripts ------------------------------------------------------------

@test "setup scripts: both parse and lint clean" {
    bash -n "${SCRIPT_DIR}/scripts/setup-mirror-server.sh"
    bash -n "${SCRIPT_DIR}/scripts/setup-mirror-client.sh"
    [ -x "${SCRIPT_DIR}/scripts/setup-mirror-server.sh" ]
    [ -x "${SCRIPT_DIR}/scripts/setup-mirror-client.sh" ]
}

@test "setup scripts: --help works and does not leak code into the text" {
    # A hardcoded sed line-range used to print 'set -Eeuo pipefail' as if it
    # were documentation the moment the header grew by a line.
    local s
    for s in setup-mirror-server.sh setup-mirror-client.sh; do
        run bash "${SCRIPT_DIR}/scripts/${s}" --help
        [ "$status" -eq 0 ]
        [[ "$output" == *"Options:"* ]]
        ! [[ "$output" == *"set -Eeuo pipefail"* ]]
        ! [[ "$output" == *'"${BASH_SOURCE'* ]]
    done
}

@test "setup server: refuses to run with no targets given" {
    # Guessing what to mirror from the server's own OS is the bug this whole
    # rewrite removed. The setup script must not reintroduce it.
    run env bash "${SCRIPT_DIR}/scripts/setup-mirror-server.sh" --dry-run --yes
    [ "$status" -ne 0 ]
    [[ "$output" == *"No mirror targets given"* ]]
}

@test "setup server: rejects an unknown flavor before doing any work" {
    run env bash "${SCRIPT_DIR}/scripts/setup-mirror-server.sh" \
        --apt-targets "windows:11" --dry-run --yes
    [ "$status" -ne 0 ]
    [[ "$output" == *"Unrecognised target"* ]]
    [[ "$output" == *"ubuntu ubuntu-ports debian"* ]]
}

@test "setup server: rejects a target with no release" {
    run env bash "${SCRIPT_DIR}/scripts/setup-mirror-server.sh" \
        --rpm-targets "rocky" --dry-run --yes
    [ "$status" -ne 0 ]
    [[ "$output" == *"no release"* ]]
}

@test "setup client: requires --server" {
    run env bash "${SCRIPT_DIR}/scripts/setup-mirror-client.sh" --dry-run --yes
    [ "$status" -ne 0 ]
    [[ "$output" == *"--server is required"* ]]
}

@test "setup client: an unreachable server is diagnosed, not retried forever" {
    # Port 1 is reserved and nothing listens there.
    run env bash "${SCRIPT_DIR}/scripts/setup-mirror-client.sh" \
        --server 127.0.0.1:1 --dry-run --yes
    [ "$status" -ne 0 ]
    [[ "$output" == *"Cannot reach"* ]]
    # The message must name the actual checks to run.
    [[ "$output" == *"mirroretctl serve"* ]]
    [[ "$output" == *"no_proxy"* ]]
}

@test "setup client: rollback with no backup says so instead of failing oddly" {
    run env MIRRORET_CLIENT_BACKUP_ROOT="${BATS_TEST_TMPDIR}/nope" \
        bash -c "sed 's|^BACKUP_ROOT=.*|BACKUP_ROOT=\"${BATS_TEST_TMPDIR}/nope\"|' \
                 '${SCRIPT_DIR}/scripts/setup-mirror-client.sh' > '${BATS_TEST_TMPDIR}/c.sh'
                 bash '${BATS_TEST_TMPDIR}/c.sh' --rollback --yes"
    [ "$status" -ne 0 ]
    [[ "$output" == *"No backup found"* ]]
}

@test "setup client: the download test pins the mirror's own version" {
    # Testing with a bare package name lets apt satisfy the request from the
    # installed copy, so the test passes while nothing came from the mirror.
    grep -q 'print p "=" \$2' "${SCRIPT_DIR}/scripts/setup-mirror-client.sh"
    grep -q "pinned to the mirror's own version" \
        "${SCRIPT_DIR}/scripts/setup-mirror-client.sh"
}

@test "setup client: verifies the config points at the given host AND port" {
    # Matching only the host lets a stale MIRRORET_SERVER_IP through, and the
    # client then fails with a bare 'connection refused' that looks like a
    # network fault rather than a server misconfiguration.
    grep -q 'https\?://\${SERVER}:\${WEB_PORT}' \
        "${SCRIPT_DIR}/scripts/setup-mirror-client.sh"
}

@test "install: publishes the client bootstrap script for clients to fetch" {
    grep -q 'setup-mirror-client.sh' "${SCRIPT_DIR}/install.sh"
    section="$(awk '/^generate_all_client_configs/,/^}/' "${SCRIPT_DIR}/install.sh")"
    [[ "$section" == *'setup-mirror-client.sh'* ]]
}

@test "setup scripts: a failed curl probe is never '|| echo 000'" {
    # `|| echo 000` APPENDS to the value curl already printed via -w, so a
    # failed request yields "000\n000" - which is not equal to "000". Every
    # reachability gate then silently passed, including the one whose entire
    # purpose is to catch a proxy-blocked upstream.
    ! grep -q 'echo 000' "${SCRIPT_DIR}/scripts/setup-mirror-server.sh"
    ! grep -q 'echo 000' "${SCRIPT_DIR}/scripts/setup-mirror-client.sh"
    # The client compares the code and must treat empty as unreachable.
    grep -q '\-z "\$code" || "\$code" == "000"' \
        "${SCRIPT_DIR}/scripts/setup-mirror-client.sh"
    # The server probe keys off curl's own exit status instead, because that
    # is what distinguishes a proxy refusal from a TLS failure from a
    # timeout - and the reason decides the fix.
    grep -q 'rc=\$?' "${SCRIPT_DIR}/scripts/setup-mirror-server.sh"
    grep -q '_curl_reason' "${SCRIPT_DIR}/scripts/setup-mirror-server.sh"
}

@test "setup server: a blocked upstream is reported with its reason" {
    # Pointing the proxy at a dead port makes every probe fail, which is
    # what a restrictive corporate proxy looks like from here.
    run env bash "${SCRIPT_DIR}/scripts/setup-mirror-server.sh" \
        --apt-targets "debian:bookworm" --proxy http://127.0.0.1:1 \
        --dry-run --yes
    [[ "$output" == *"FAIL"* ]]
    # The reason must be named, not just the fact.
    [[ "$output" == *"proxy refused CONNECT"* || "$output" == *"TLS handshake"* \
       || "$output" == *"unreachable"* || "$output" == *"timed out"* ]]
    [[ "$output" == *"cannot sync yet"* ]]
    # And it must name the trap that quietly costs people security updates.
    [[ "$output" == *"security.ubuntu.com is a DIFFERENT host"* ]]
}

@test "setup server: an entirely unreachable target set is fatal" {
    # Dropping the only target would leave nothing to mirror, so this must
    # stop rather than "succeed" with an empty configuration.
    run env bash "${SCRIPT_DIR}/scripts/setup-mirror-server.sh" \
        --apt-targets "debian:bookworm" --proxy http://127.0.0.1:1 \
        --dry-run --yes
    [ "$status" -ne 0 ]
    [[ "$output" == *"Every configured target is unreachable"* ]]
}

@test "setup server: only probes upstreams the chosen targets need" {
    # A Debian-only mirror must not be told Oracle is unreachable.
    run env bash "${SCRIPT_DIR}/scripts/setup-mirror-server.sh" \
        --apt-targets "debian:bookworm" --proxy http://127.0.0.1:1 \
        --dry-run --yes
    # Scope to the probe list: the STOP advice text legitimately mentions
    # archive.ubuntu.com when explaining the security-host trap.
    local probes
    probes="$(printf '%s\n' "$output" \
              | sed -n '/Probing the exact URLs/,/cannot sync yet/p' \
              | grep -E '^\s+(FAIL|[0-9]{3})\s' || true)"
    [[ "$probes" == *"deb.debian.org"* ]]
    ! [[ "$probes" == *"yum.oracle.com"* ]]
    ! [[ "$probes" == *"archive.ubuntu.com"* ]]
}

# -- reported from a live OL9 server, 2026-08-23 --------------------------------

@test "cli: a failing menu action returns to the menu, it does not exit" {
    # Observed on a live server: picking "sync apt" (or any sync while the
    # nightly cron run held the lock) made the whole menu vanish with no
    # message. The menu is a loop inside a function in a `set -e` script, so
    # a bare `cmd_sync all` returning non-zero exits mirroretctl entirely.
    grep -q '_menu_run()' "${SCRIPT_DIR}/mirroretctl"
    # EVERY numbered action must go through the wrapper.
    local bare
    bare="$(sed -n '/case "\$choice" in/,/esac/p' "${SCRIPT_DIR}/mirroretctl" \
            | grep -E '^\s+[0-9]+\)' | grep -vc '_menu_run' || true)"
    [ "$bare" -eq 0 ]
}

@test "cli: _menu_run reports a failure and still returns success" {
    run bash -c "
        source '${SCRIPT_DIR}/lib/logging.sh'
        source '${SCRIPT_DIR}/lib/common.sh'
        _wa() { printf 'warn  %s\n' \"\$*\"; }
        _in() { printf '      %s\n' \"\$*\"; }
        $(sed -n '/^_menu_run()/,/^}/p' "${SCRIPT_DIR}/mirroretctl")
        set -e
        _menu_run false
        echo STILL_ALIVE"
    [ "$status" -eq 0 ]
    [[ "$output" == *"exited with status 1"* ]]
    [[ "$output" == *"STILL_ALIVE"* ]]
}

@test "sync scripts: the lock is taken BEFORE stdout is redirected" {
    # Observed on a live server: starting a sync while cron held the lock
    # exited silently. Every generated script did
    #   exec > >(tee -a LOG) 2>&1
    # BEFORE flock, so "another sync is already running" went only to a log
    # file the operator had no reason to look at.
    MIRRORET_APT_TARGETS="ubuntu:jammy"
    MIRRORET_RPM_TARGETS="ol:9"
    generate_target_specs
    configure_apt_mirror "bk"
    configure_rpm_mirroring "bk"

    local s
    for s in sync-apt-repos.sh sync-rpm-repos.sh; do
        local f="${MIRRORET_BASE_DIR}/scripts/${s}"
        [ -f "$f" ]
        local lock_line redirect_line
        lock_line="$(grep -n 'flock -n 9' "$f" | head -1 | cut -d: -f1)"
        redirect_line="$(grep -n 'exec > >(tee' "$f" | head -1 | cut -d: -f1)"
        [ -n "$lock_line" ]
        [ -n "$redirect_line" ]
        # The lock must come first.
        [ "$lock_line" -lt "$redirect_line" ]
    done
}

@test "sync scripts: lock contention prints to the terminal and creates no log" {
    MIRRORET_RPM_TARGETS="ol:9"
    generate_target_specs
    configure_rpm_mirroring "bk"
    local script="${MIRRORET_BASE_DIR}/scripts/sync-rpm-repos.sh"
    [ -x "$script" ]

    local lock="${BATS_TEST_TMPDIR}/contended.lock"
    # Rewrite the lock path so this test cannot collide with a real sync.
    sed -i "s|^LOCK_FILE=.*|LOCK_FILE=\"${lock}\"|" "$script"

    # Hold the lock, then try to run.
    flock -n "$lock" -c 'sleep 12' &
    local holder=$!
    sleep 1
    run "$script"
    kill "$holder" 2>/dev/null || true
    wait "$holder" 2>/dev/null || true

    [ "$status" -eq 3 ]
    [[ "$output" == *"already running"* ]]
    [[ "$output" == *"logs tail"* ]]
    # And it must not have littered a log file for a run that never started.
    [ "$(find "${MIRRORET_BASE_DIR}/logs" -name 'sync-rpm-*.log' 2>/dev/null | wc -l)" -eq 0 ]
}

@test "targets: legacy dnf repo ids are translated, not silently dropped" {
    # This project's own earlier runbook told operators to write
    # MIRRORET_RPM_REPOS="ol9_baseos_latest ol9_appstream ol9_UEKR8
    # ol9_developer_EPEL". Dropping those produced a target with zero repos:
    # a mirror that downloads nothing and reports nothing.
    MIRRORET_RPM_TARGETS="ol:9"
    MIRRORET_RPM_REPOS="ol9_baseos_latest ol9_appstream ol9_UEKR8 ol9_developer_EPEL"
    generate_target_specs
    run mirroret_json_field "${MIRRORET_TARGETS_DIR}/rpm-ol-9.json" repos
    [ "$status" -eq 0 ]
    [[ "$output" == *"baseos"* ]]
    [[ "$output" == *"appstream"* ]]
    [[ "$output" == *"uekr8"* ]]
    [[ "$output" == *"epel"* ]]
}

@test "targets: legacy RHEL subscription repo ids are translated too" {
    MIRRORET_RPM_TARGETS="rhel:9"
    MIRRORET_RPM_REPOS="rhel-9-for-x86_64-baseos-rpms rhel-9-for-x86_64-appstream-rpms"
    generate_target_specs
    run mirroret_json_field "${MIRRORET_TARGETS_DIR}/rpm-rhel-9.json" repos
    [[ "$output" == *"baseos"* ]]
    [[ "$output" == *"appstream"* ]]
}

@test "targets: an alias resolves to a real catalog URL, never a literal id" {
    run rpm_repo_alias ol 9 ol9_developer_EPEL
    [ "$output" = "epel" ]
    run rpm_repo_url ol 9 "$(rpm_repo_alias ol 9 ol9_UEKR8)" x86_64
    [ "$status" -eq 0 ]
    [[ "$output" == *"/UEKR8/"* ]]
}

@test "targets: a target resolving to zero repos is a FAILURE, not '0/0 ok'" {
    # The silent-nothing failure mode, in the reporting layer this time:
    # "ok 0/0 repos published" for a target that mirrors nothing at all.
    mkdir -p "${MIRRORET_TARGETS_DIR}"
    python3 - "${MIRRORET_TARGETS_DIR}/rpm-ol-9.json" "${MIRRORET_BASE_DIR}" <<'PYEOF'
import json
import sys
json.dump({"id": "ol9", "kind": "rpm", "flavor": "ol", "version": "9",
           "dest": sys.argv[2] + "/redhat/mirror/ol/9",
           "arches": ["x86_64", "noarch"], "repos": []},
          open(sys.argv[1], "w"))
PYEOF
    run env MIRRORET_BASE_DIR="${MIRRORET_BASE_DIR}" \
        MIRRORET_TARGETS_DIR="${MIRRORET_TARGETS_DIR}" \
        bash "${SCRIPT_DIR}/mirroretctl" targets
    [ "$status" -ne 0 ]
    [[ "$output" == *"would mirror NOTHING"* ]]
    [[ "$output" == *"baseos appstream"* ]]
    ! [[ "$output" == *"0/0 repos published"* ]]
}

@test "targets: a spec with no suites is a FAILURE, not silently ok" {
    mkdir -p "${MIRRORET_TARGETS_DIR}"
    python3 - "${MIRRORET_TARGETS_DIR}/apt-ubuntu-jammy.json" "${MIRRORET_BASE_DIR}" <<'PYEOF'
import json
import sys
json.dump({"id": "ubuntu-jammy", "kind": "apt", "flavor": "ubuntu",
           "dir": "ubuntu", "codename": "jammy",
           "dest": sys.argv[2] + "/apt/ubuntu", "arches": ["amd64"],
           "components": ["main"], "suites": []},
          open(sys.argv[1], "w"))
PYEOF
    run env MIRRORET_BASE_DIR="${MIRRORET_BASE_DIR}" \
        MIRRORET_TARGETS_DIR="${MIRRORET_TARGETS_DIR}" \
        bash "${SCRIPT_DIR}/mirroretctl" targets
    [ "$status" -ne 0 ]
    [[ "$output" == *"would mirror NOTHING"* ]]
}

@test "verify: a .repo file with no baseurl is flagged" {
    mkdir -p "${MIRRORET_BASE_DIR}/config"
    printf '# empty\n[mirroret-nothing]\nname=nothing\nenabled=1\ngpgcheck=1\ngpgkey=file:///x\n' \
        > "${MIRRORET_BASE_DIR}/config/broken9.repo"
    run env MIRRORET_BASE_DIR="${MIRRORET_BASE_DIR}" \
        bash "${SCRIPT_DIR}/mirroretctl" client verify
    [[ "$output" == *"contains no baseurl"* ]]
}

@test "setup server: probes the real URLs, not bare host roots" {
    # A bare host root proves less than it looks: an allow-list can permit
    # the host while the path we fetch is blocked, and Debian's security
    # archive is a different PATH on the same host - which a root probe
    # cannot distinguish at all.
    run bash -c "
        APT_TARGETS='ubuntu:jammy debian:bookworm'
        RPM_TARGETS='ol:9'
        APT_SCHEME=''
        $(sed -n '/^upstream_probes()/,/^}/p' "${SCRIPT_DIR}/scripts/setup-mirror-server.sh")
        upstream_probes"
    [ "$status" -eq 0 ]
    [[ "$output" == *"archive.ubuntu.com/ubuntu/dists/jammy/Release"* ]]
    # The security host is separate and must be probed separately.
    [[ "$output" == *"security.ubuntu.com/ubuntu/dists/jammy-security/Release"* ]]
    # Debian security is a different PATH, not a different host.
    [[ "$output" == *"deb.debian.org/debian/dists/bookworm/Release"* ]]
    [[ "$output" == *"deb.debian.org/debian-security/dists/bookworm-security/Release"* ]]
    [[ "$output" == *"yum.oracle.com/repo/OracleLinux/OL9/"*"repomd.xml"* ]]
    # Each line must be tagged with the target it belongs to.
    [[ "$output" == *"debian:bookworm|"* ]]
}

@test "setup server: curl failure reasons are named, not just 'BLOCKED'" {
    # These exit codes each have a different fix, and this project's own
    # FIXME doc records hitting several of them. "BLOCKED" sends people to
    # the wrong place.
    local fn
    fn="$(sed -n '/^_curl_reason()/,/^}/p' "${SCRIPT_DIR}/scripts/setup-mirror-server.sh")"
    run bash -c "${fn}; _curl_reason 56"
    [[ "$output" == *"proxy refused CONNECT"* ]]
    run bash -c "${fn}; _curl_reason 35"
    [[ "$output" == *"TLS handshake"* ]]
    run bash -c "${fn}; _curl_reason 60"
    [[ "$output" == *"corporate CA"* ]]
    run bash -c "${fn}; _curl_reason 6"
    [[ "$output" == *"DNS"* ]]
}

@test "setup server: a target whose upstream is blocked can be dropped" {
    # Waiting on a proxy ticket before mirroring ANYTHING is the wrong
    # default: the RPM tree is usually the bulk of the data.
    local src="${SCRIPT_DIR}/scripts/setup-mirror-server.sh"
    grep -q 'Continue with only the reachable targets' "$src"
    grep -q 'keep_apt' "$src"
    grep -q 'keep_rpm' "$src"
    # And when nothing at all is reachable it must stop, not proceed empty.
    grep -q 'Every configured target is unreachable' "$src"
}

@test "setup server: warns before a long sync on a bare SSH session" {
    # The sync scripts trap INT and TERM but not HUP, so a dropped SSH
    # connection takes a multi-hour download with it. Losing that to a
    # flaky VPN is avoidable if we say so first.
    grep -q 'SSH_CONNECTION' "${SCRIPT_DIR}/scripts/setup-mirror-server.sh"
    grep -q 'not inside screen or tmux' "${SCRIPT_DIR}/scripts/setup-mirror-server.sh"
    # And it must not warn when already inside a multiplexer.
    grep -q 'STY:-}${TMUX:-}' "${SCRIPT_DIR}/scripts/setup-mirror-server.sh"
    # The suggestion must include the skip-sync escape hatch.
    local section
    section="$(sed -n '/not inside screen or tmux/,/Start the first sync/p' \
               "${SCRIPT_DIR}/scripts/setup-mirror-server.sh")"
    [[ "$section" == *"--skip-sync"* ]]
    [[ "$section" == *"tmux new"* ]]
}

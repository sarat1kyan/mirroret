#!/usr/bin/env bats
# Tests for scripts/mirroret-collect.sh, the single-file evidence collector.
#
# The collector's contract is unusual: it must NEVER abort. Every probe that
# fails has to become a recorded line. These tests seed a fake install tree
# with known faults and assert each one is detected, that secrets are masked,
# and that a host missing every Linux tool still produces a full report.

load 'test_helpers'

setup() {
    TMPDIR="$(mktemp -d)"
    COLLECT="${SCRIPT_DIR}/scripts/mirroret-collect.sh"
    FAKE="${TMPDIR}/srv"
    CONF="${TMPDIR}/mirroret.conf"
    OUT="${TMPDIR}/report.txt"
    mkdir -p "${FAKE}"/{scripts,logs,config,pip/approved,staging/pip,approved/pip}
    mkdir -p "${FAKE}/redhat/mirror/ol/9/ol9_appstream"
    cat > "${CONF}" <<EOF
MIRRORET_BASE_DIR=${FAKE}
MIRRORET_RPM_ARCH="x86_64"
MIRRORET_APPROVAL_ENABLED=1
EOF
}

teardown() { rm -rf "${TMPDIR}"; }

run_collect() { run bash "${COLLECT}" --no-net --conf "${CONF}" -o "${OUT}"; }

# -- Contract: never abort ------------------------------------------------------

@test "collect: exists, executable, parses" {
    [ -x "${COLLECT}" ]
    bash -n "${COLLECT}"
}

@test "collect: exits 0 even with nothing installed" {
    rm -f "${CONF}"
    run bash "${COLLECT}" --no-net --conf "${TMPDIR}/absent.conf" -o "${OUT}"
    [ "$status" -eq 0 ]
    [ -f "${OUT}" ]
}

@test "collect: reaches every section despite missing tools" {
    # Run with a PATH holding only the bare minimum, so getenforce, ss, dnf,
    # systemctl and friends are all absent. The report must still complete.
    run env PATH="/usr/bin:/bin" bash "${COLLECT}" --no-net --conf "${CONF}" -o "${OUT}"
    [ "$status" -eq 0 ]
    grep -q "END OF REPORT" "${OUT}"
    # 33 numbered sections are emitted.
    n="$(grep -c '^== \[' "${OUT}")"
    [ "$n" -ge 30 ]
}

@test "collect: report is mode 600 (it can contain host detail)" {
    run_collect
    perms="$(stat -c '%a' "${OUT}" 2>/dev/null || stat -f '%Lp' "${OUT}")"
    [ "$perms" = "600" ]
}

@test "collect: findings appear before the evidence sections" {
    run_collect
    f_line="$(grep -n '^== FINDINGS' "${OUT}" | head -1 | cut -d: -f1)"
    e_line="$(grep -n '^== \[01\]' "${OUT}" | head -1 | cut -d: -f1)"
    [ "$f_line" -lt "$e_line" ]
}

# -- Redaction ------------------------------------------------------------------

@test "collect: masks passwords, tokens, secrets and proxy credentials" {
    cat >> "${CONF}" <<'EOF'
MIRRORET_NPM_TOKEN=tok_LEAKCANARY_A
REGISTRY_PASSWORD=LEAKCANARY_B
MIRRORET_SOME_SECRET=LEAKCANARY_C
http_proxy=http://bob:LEAKCANARY_D@proxy.corp:3128
EOF
    run_collect
    ! grep -q "LEAKCANARY_A" "${OUT}"
    ! grep -q "LEAKCANARY_B" "${OUT}"
    ! grep -q "LEAKCANARY_C" "${OUT}"
    ! grep -q "LEAKCANARY_D" "${OUT}"
    grep -q "REDACTED" "${OUT}"
    # The non-secret part of the proxy URL must survive, or the report is useless.
    grep -q "proxy.corp:3128" "${OUT}"
}

# -- Fault detection ------------------------------------------------------------

@test "collect: flags a sync script with no managed marker" {
    printf '#!/bin/bash\necho stale\n' > "${FAKE}/scripts/sync-all.sh"
    run_collect
    grep -q "has no MIRRORET-MANAGED marker" "${OUT}"
}

@test "collect: does not flag a script that has the managed marker" {
    printf '#!/bin/bash\n# MIRRORET-MANAGED\ntrue\n' > "${FAKE}/scripts/sync-all.sh"
    run_collect
    ! grep -q "sync-all.sh has no MIRRORET-MANAGED marker" "${OUT}"
}

@test "collect: flags a sync script that fails bash -n" {
    printf '#!/bin/bash\n# MIRRORET-MANAGED\nif [ 1 ; then\n' > "${FAKE}/scripts/sync-pip-packages.sh"
    run_collect
    grep -q "does not parse" "${OUT}"
}

@test "collect: flags missing i686 when MIRRORET_RPM_ARCH lacks it" {
    run_collect
    grep -q "no i686" "${OUT}"
}

@test "collect: does not flag i686 when the arch list includes it" {
    sed -i.bak 's/MIRRORET_RPM_ARCH="x86_64"/MIRRORET_RPM_ARCH="x86_64 i686"/' "${CONF}"
    run_collect
    ! grep -q "with no i686" "${OUT}"
}

@test "collect: counts src.rpm exactly once, not once per parent dir" {
    d="${FAKE}/redhat/mirror/ol/9/ol9_appstream"
    touch "$d/kernel-5.14.src.rpm" "$d/bash-5.1.x86_64.rpm"
    run_collect
    # Regression: enumerating repo dirs with 'find -type d' matched ol, 9 and
    # ol9_appstream, and each recursive count tallied the same file again.
    n="$(grep -c '\.src\.rpm files in the mirror' "${OUT}")"
    [ "$n" -eq 1 ]
    grep -q "^FAIL 1 \.src\.rpm files in the mirror" "${OUT}"
}

@test "collect: flags a repo holding RPMs with no repodata" {
    d="${FAKE}/redhat/mirror/ol/9/ol9_appstream"
    touch "$d/bash-5.1.x86_64.rpm"
    run_collect
    grep -q "holds RPMs but no repodata/repomd.xml exists" "${OUT}"
}

@test "collect: does not flag a repo that has repomd.xml" {
    d="${FAKE}/redhat/mirror/ol/9/ol9_appstream"
    touch "$d/bash-5.1.x86_64.rpm"
    mkdir -p "$d/repodata"; touch "$d/repodata/repomd.xml"
    run_collect
    ! grep -q "holds RPMs but no repodata" "${OUT}"
}

@test "collect: reports zero i686 packages per repo" {
    d="${FAKE}/redhat/mirror/ol/9/ol9_appstream"
    touch "$d/bash-5.1.x86_64.rpm"
    run_collect
    grep -q "Zero i686 packages in" "${OUT}"
}

@test "collect: detects the heredoc backtick signature in logs" {
    printf 'line 214: registry: command not found\n' > "${FAKE}/logs/sync.log"
    run_collect
    grep -q "expanding-heredoc backtick bug" "${OUT}"
}

@test "collect: flags approval mode with staged but nothing approved" {
    touch "${FAKE}/staging/pip/numpy-1.26.0-py3-none-any.whl"
    run_collect
    grep -q "packages waiting in staging and nothing approved" "${OUT}"
    # Counts must not carry wc -l space padding into the prose. Two or more
    # spaces before the number means the padding leaked through.
    ! grep -qE "with {2,}[0-9]+ packages waiting" "${OUT}"
    grep -qE "with [0-9]+ packages waiting" "${OUT}"
}

@test "collect: flags a client template pointing at localhost" {
    printf 'baseurl=http://127.0.0.1:8080/redhat/\n' > "${FAKE}/config/mirroret.repo"
    run_collect
    grep -q "127.0.0.1 or localhost" "${OUT}"
}

@test "collect: no false disk finding when df output is unparseable" {
    run_collect
    # A GNU-only df flag used to yield "" and read as 0 GB free.
    ! grep -q "Only 0 GB free" "${OUT}"
}

@test "collect: reports the missing base dir as a failure" {
    rm -rf "${FAKE}"
    run_collect
    grep -q "does not exist" "${OUT}"
}

# -- Read-only contract ---------------------------------------------------------

@test "collect: writes nothing except the report" {
    before="$(find "${FAKE}" | sort | md5sum 2>/dev/null || find "${FAKE}" | sort | md5)"
    run_collect
    after="$(find "${FAKE}" | sort | md5sum 2>/dev/null || find "${FAKE}" | sort | md5)"
    [ "$before" = "$after" ]
}

@test "collect: --no-net really skips outbound tests" {
    run_collect
    grep -q "skipped: --no-net" "${OUT}"
}

@test "collect: --help works and exits 0" {
    run bash "${COLLECT}" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"read-only"* ]]
}

@test "collect: rejects an unknown option instead of guessing" {
    run bash "${COLLECT}" --banana
    [ "$status" -eq 2 ]
}

# -- Vendor repo layouts --------------------------------------------------------
#
# reposync mirrors the upstream layout. Oracle serves <repo>/getPackage/*.rpm
# with <repo>/repodata/ one level up; Fedora and EPEL nest as Packages/<letter>/.
# Assuming repodata sits beside the packages reported every Oracle repo broken.

_mk_repo() {  # _mk_repo <name> <pkgsubdir> [--no-meta]
    local name="$1" sub="$2" meta="${3:-meta}"
    local d="${FAKE}/redhat/mirror/ol/9/${name}"
    mkdir -p "${d}/${sub}"
    touch "${d}/${sub}/bash-5.1-1.el9.x86_64.rpm" "${d}/${sub}/tzdata-2024a.noarch.rpm"
    if [[ "${meta}" != "--no-meta" ]]; then
        mkdir -p "${d}/repodata"
        printf '<repomd/>\n' > "${d}/repodata/repomd.xml"
    fi
    printf '%s' "$d"
}

@test "collect: Oracle getPackage layout is not reported as missing repodata" {
    _mk_repo ol9_appstream getPackage
    _mk_repo ol9_baseos_latest getPackage
    run_collect
    ! grep -q 'ol9_appstream.*no repodata' "${OUT}"
    ! grep -q 'getPackage holds RPMs' "${OUT}"
}

@test "collect: EPEL-style Packages/<letter> layout resolves to the repo root" {
    _mk_repo epel 'Packages/b'
    run_collect
    ! grep -q 'holds RPMs but no repodata' "${OUT}"
    # The table row is the repo root, not the nested package dir.
    grep -qE '^ol/9/epel +[0-9]' "${OUT}"
}

@test "collect: package counts aggregate at the repo root across subdirs" {
    d="$(_mk_repo ol9_baseos_latest getPackage)"
    touch "${d}/getPackage/glibc-2.34-1.el9.i686.rpm"
    run_collect
    # 2 from _mk_repo plus the i686 = 3 total, 1 i686.
    grep -qE '^ol/9/ol9_baseos_latest +3 +1 +1 +1 ' "${OUT}"
}

@test "collect: reports the package subdirectory it found" {
    _mk_repo ol9_appstream getPackage
    run_collect
    grep -qE '^ol/9/ol9_appstream .*getPackage' "${OUT}"
}

@test "collect: still flags RPMs with no repodata anywhere above them" {
    _mk_repo orphan getPackage --no-meta
    run_collect
    grep -q 'holds RPMs but no repodata/repomd.xml exists there or in any parent' "${OUT}"
}

@test "collect: flags repodata older than the newest package" {
    d="$(_mk_repo stale getPackage)"
    # Metadata predating the packages means dnf cannot see them: it installs
    # only what repomd.xml lists.
    touch -t 202601010000 "${d}/repodata/repomd.xml"
    touch "${d}/getPackage/brandnew-1.0-1.el9.x86_64.rpm"
    run_collect
    grep -q 'OLDER than the newest package' "${OUT}"
}

@test "collect: does not flag a repo whose metadata is newer than its packages" {
    d="$(_mk_repo fresh getPackage)"
    touch -t 202601010000 "${d}/getPackage/"*.rpm
    touch "${d}/repodata/repomd.xml"
    run_collect
    ! grep -q 'fresh.*OLDER than the newest package' "${OUT}"
}

@test "collect: i686 warning names the repo root, not the getPackage dir" {
    _mk_repo ol9_appstream getPackage
    run_collect
    grep -q 'Zero i686 packages in' "${OUT}"
    ! grep -q 'Zero i686 packages in.*getPackage' "${OUT}"
}

# -- False positives found on a real, working server ----------------------------
#
# A non-root run cannot read root's crontab, a 0600 nginx config, or another
# user's containers. Reporting those as FAIL sends an operator chasing
# problems that do not exist on a server that is working correctly.

@test "collect: cron absence is INFO not WARN when running non-root" {
    [ "$(id -u)" -ne 0 ]
    run_collect
    # "crontab -l" reads the invoking user's crontab; mirroret schedules under
    # root, so a non-root run always sees nothing.
    ! grep -q '^WARN No mirroret cron entries for root' "${OUT}"
    grep -q "cannot see root's crontab" "${OUT}"
}

@test "collect: localhost scan ignores GPG key material" {
    # A key whose UID is mirroret@localhost is not a misconfigured template.
    mkdir -p "${FAKE}/config"
    printf -- '-----BEGIN PGP PUBLIC KEY BLOCK-----\nmirroret <mirroret@localhost>\n' \
        > "${FAKE}/config/GPG-KEY.asc"
    printf 'binary localhost bytes\n' > "${FAKE}/config/mirroret.gpg"
    run_collect
    ! grep -q 'reference 127.0.0.1 or localhost' "${OUT}"
}

@test "collect: localhost scan still flags a real client template" {
    mkdir -p "${FAKE}/config"
    printf 'baseurl=http://127.0.0.1:8080/redhat/\n' > "${FAKE}/config/client.repo"
    run_collect
    grep -q 'reference 127.0.0.1 or localhost' "${OUT}"
    grep -q 'client.repo' "${OUT}"
}

@test "collect: dotfile client configs are included" {
    # A plain * glob misses .npmrc, which is a client config.
    mkdir -p "${FAKE}/config"
    printf 'registry=http://192.168.1.5:4873/\n' > "${FAKE}/config/.npmrc"
    run_collect
    grep -q 'config/.npmrc' "${OUT}"
    grep -q '192.168.1.5:4873' "${OUT}"
}

@test "collect: key material is summarized, not dumped as base64" {
    mkdir -p "${FAKE}/config"
    { printf -- '-----BEGIN PGP PUBLIC KEY BLOCK-----\n'
      for _ in $(seq 1 60); do printf 'mQINBGo69UQBEACUNIQUEBASE64LINE%s\n' "$_"; done
      printf -- '-----END PGP PUBLIC KEY BLOCK-----\n'; } > "${FAKE}/config/GPG-KEY.asc"
    run_collect
    grep -q 'key material, summarized' "${OUT}"
    # The base64 body must not be copied into the report.
    ! grep -q 'UNIQUEBASE64LINE30' "${OUT}"
}

@test "collect: report contains no control bytes (stays grep/sed safe)" {
    # Captured output can include binary. Left in, the finished report breaks
    # grep, sed and awk for whoever reads it.
    mkdir -p "${FAKE}/logs"
    printf 'before\001\002\007\016\037after\n' > "${FAKE}/logs/binary.log"
    run_collect
    run bash -c "LC_ALL=C grep -c $'[\\001-\\010\\013\\014\\016-\\037]' '${OUT}' || true"
    [ "$output" = "0" ]
}

@test "collect: version reflects the false-positive fixes" {
    grep -q 'COLLECT_VERSION="1.1"' "${COLLECT}"
    run_collect
    grep -q 'mirroret-collect.sh 1.1' "${OUT}"
}

@test "collect: loopback-only bind detection logic is present" {
    # A service on 127.0.0.1 or [::1] only serves this host; every client host
    # gets connection refused. This was the actual npm failure in the field.
    grep -q 'bound to LOOPBACK ONLY' "${COLLECT}"
    grep -q '127\.\*|' "${COLLECT}"
}

@test "collect: unit discovery does not rely only on assumed names" {
    grep -q 'DISCOVERED_UNITS' "${COLLECT}"
    grep -q 'list-unit-files' "${COLLECT}"
}

@test "collect: socket-activated units are not flagged as failed" {
    grep -q 'TriggeredBy' "${COLLECT}"
    grep -q 'socket-activated' "${COLLECT}"
}

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
    grep -q "holds RPMs but has no repodata/repomd.xml" "${OUT}"
}

@test "collect: does not flag a repo that has repomd.xml" {
    d="${FAKE}/redhat/mirror/ol/9/ol9_appstream"
    touch "$d/bash-5.1.x86_64.rpm"
    mkdir -p "$d/repodata"; touch "$d/repodata/repomd.xml"
    run_collect
    ! grep -q "holds RPMs but has no repodata" "${OUT}"
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
    grep -q "references 127.0.0.1 or localhost" "${OUT}"
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

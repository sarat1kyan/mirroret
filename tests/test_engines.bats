#!/usr/bin/env bats
# Tests for the native mirroring engines.
#
# These are end-to-end against a real HTTP server serving a real (small)
# archive: the whole value of these engines is that a client can install from
# what they produce, and only an end-to-end test can show that. Every
# fixture's checksums genuinely match its bytes, so hash verification,
# publish ordering, arch filtering, newest-only selection, metadata rewriting
# and pruning are all exercised for real.

load 'test_helpers'

setup() {
    load_lib
    TMPDIR_TEST="$(mktemp -d)"
    no_proxy_env
}

teardown() {
    stop_fixture
    [[ -n "${TMPDIR_TEST:-}" ]] && rm -rf "${TMPDIR_TEST}"
}

_mk_apt_fixture() {
    python3 "${SCRIPT_DIR}/tests/fixtures/make_apt_repo.py" "$@" >/dev/null
}

_mk_rpm_fixture() {
    python3 "${SCRIPT_DIR}/tests/fixtures/make_rpm_repo.py" "$@" >/dev/null
}

# -- rpmvercmp ----------------------------------------------------------------

@test "rpm engine: rpmvercmp matches RPM's own test vectors" {
    # Getting this wrong makes --newest-only keep the wrong build, which is
    # invisible until a client installs a downgraded package.
    run python3 - <<'PY'
import sys
sys.path.insert(0, "engines")
from mirroret_rpm import rpmvercmp

# Selected vectors from rpm's tests/rpmvercmp.at, including the tilde
# (pre-release) and caret (post-release) rules.
V = [
    ("1.0", "1.0", 0), ("1.0", "2.0", -1), ("2.0", "1.0", 1),
    ("2.0", "2.0.1", -1), ("2.0.1a", "2.0.1", 1),
    ("5.5p1", "5.5p2", -1), ("5.5p10", "5.5p1", 1),
    ("10xyz", "10.1xyz", -1), ("xyz.4", "8", -1), ("8", "xyz.4", 1),
    ("6.0.rc1", "6.0", 1), ("10b2", "10a1", 1),
    ("10.0001", "10.1", 0), ("10.0039", "10.0001", 1),
    ("4.999.9", "5.0", -1), ("2.0", "2_0", 0),
    ("1.0~rc1", "1.0", -1), ("1.0~rc1", "1.0~rc2", -1),
    ("1.0~rc1~git123", "1.0~rc1", -1),
    ("1.0^", "1.0", 1), ("1.0^git1", "1.01", -1),
    ("1.0^20160101", "1.0.1", -1),
    ("1.0^git1~pre", "1.0^git1", -1),
    ("70.el9", "500.el9", -1),
]
bad = 0
for a, b, want in V:
    got = rpmvercmp(a, b)
    if got != want:
        bad += 1
        print("MISMATCH %r %r -> %d want %d" % (a, b, got, want))
print("checked %d" % len(V))
sys.exit(1 if bad else 0)
PY
    [ "$status" -eq 0 ]
    [[ "$output" == *"checked"* ]]
}

@test "rpm engine: evr_cmp puts epoch ahead of version" {
    run python3 -c '
import sys
sys.path.insert(0, "engines")
from mirroret_rpm import evr_cmp
assert evr_cmp(("1", "0.1", "1"), ("0", "9.9", "9")) == 1
assert evr_cmp(("0", "1.0", "2"), ("0", "1.0", "1")) == 1
print("ok")'
    [ "$status" -eq 0 ]
}

# -- APT engine ---------------------------------------------------------------

@test "apt engine: mirrors a suite and publishes a usable archive" {
    _mk_apt_fixture "${TMPDIR_TEST}/up" --packages 4
    local url
    url="$(serve_fixture "${TMPDIR_TEST}/up")"

    run python3 "$(apt_engine)" --dest "${TMPDIR_TEST}/mirror" --url "${url}" \
        --suite testsuite --component main --arch amd64 --min-free-gb 0
    [ "$status" -eq 0 ]

    # A published suite has its Release file...
    [ -f "${TMPDIR_TEST}/mirror/dists/testsuite/Release" ]
    # ...the index it references...
    [ -f "${TMPDIR_TEST}/mirror/dists/testsuite/main/binary-amd64/Packages.gz" ]
    # ...and every .deb that index lists.
    [ "$(find "${TMPDIR_TEST}/mirror/pool" -name '*.deb' | wc -l)" -eq 4 ]
}

@test "apt engine: pool layout matches upstream exactly" {
    # The mirrored Packages index keeps upstream's Filename field verbatim, so
    # a .deb stored anywhere else resolves to a 404 for every client.
    _mk_apt_fixture "${TMPDIR_TEST}/up" --packages 2
    local url
    url="$(serve_fixture "${TMPDIR_TEST}/up")"
    python3 "$(apt_engine)" --dest "${TMPDIR_TEST}/mirror" --url "${url}" \
        --suite testsuite --component main --arch amd64 --min-free-gb 0 >/dev/null

    run bash -c "cd '${TMPDIR_TEST}/mirror' && find pool -name '*.deb' | sort"
    [ "$status" -eq 0 ]
    [[ "$output" == *"pool/main/p/pkg0/pkg0_1.0_amd64.deb"* ]]
}

@test "apt engine: every mirrored .deb matches the index checksum" {
    _mk_apt_fixture "${TMPDIR_TEST}/up" --packages 3
    local url
    url="$(serve_fixture "${TMPDIR_TEST}/up")"
    python3 "$(apt_engine)" --dest "${TMPDIR_TEST}/mirror" --url "${url}" \
        --suite testsuite --component main --arch amd64 --min-free-gb 0 >/dev/null

    run python3 - "${TMPDIR_TEST}/mirror" <<'PY'
import gzip
import hashlib
import os
import sys

root = sys.argv[1]
idx = os.path.join(root, "dists/testsuite/main/binary-amd64/Packages.gz")
text = gzip.decompress(open(idx, "rb").read()).decode()
checked = 0
for para in text.split("\n\n"):
    fields = dict(
        line.split(": ", 1) for line in para.splitlines() if ": " in line
    )
    if "Filename" not in fields:
        continue
    path = os.path.join(root, fields["Filename"])
    assert os.path.exists(path), "missing %s" % fields["Filename"]
    got = hashlib.sha256(open(path, "rb").read()).hexdigest()
    assert got == fields["SHA256"], "checksum mismatch %s" % fields["Filename"]
    assert os.path.getsize(path) == int(fields["Size"])
    checked += 1
assert checked == 3, checked
print("verified %d packages" % checked)
PY
    [ "$status" -eq 0 ]
}

@test "apt engine: a bad package checksum stops the suite being published" {
    # This is the property that keeps a mirror trustworthy: publishing a
    # Release that references packages which failed verification would give
    # clients hash errors at install time.
    _mk_apt_fixture "${TMPDIR_TEST}/up" --packages 3 --corrupt-pool pkg1
    local url
    url="$(serve_fixture "${TMPDIR_TEST}/up")"

    run python3 "$(apt_engine)" --dest "${TMPDIR_TEST}/mirror" --url "${url}" \
        --suite testsuite --component main --arch amd64 --min-free-gb 0 --retries 1
    [ "$status" -ne 0 ]
    [[ "$output" == *"sha256 mismatch"* ]]
    [[ "$output" == *"NOT published"* ]]
    # No Release means apt simply does not see this suite yet.
    [ ! -f "${TMPDIR_TEST}/mirror/dists/testsuite/Release" ]
}

@test "apt engine: re-running downloads nothing and stays consistent" {
    _mk_apt_fixture "${TMPDIR_TEST}/up" --packages 3
    local url
    url="$(serve_fixture "${TMPDIR_TEST}/up")"
    python3 "$(apt_engine)" --dest "${TMPDIR_TEST}/mirror" --url "${url}" \
        --suite testsuite --component main --arch amd64 --min-free-gb 0 >/dev/null

    run python3 "$(apt_engine)" --dest "${TMPDIR_TEST}/mirror" --url "${url}" \
        --suite testsuite --component main --arch amd64 --min-free-gb 0
    [ "$status" -eq 0 ]
    [[ "$output" == *"already complete"* ]]
    [ "$(find "${TMPDIR_TEST}/mirror/pool" -name '*.deb' | wc -l)" -eq 3 ]
}

@test "apt engine: --delete prunes pool files upstream dropped" {
    _mk_apt_fixture "${TMPDIR_TEST}/up" --packages 2
    local url
    url="$(serve_fixture "${TMPDIR_TEST}/up")"
    python3 "$(apt_engine)" --dest "${TMPDIR_TEST}/mirror" --url "${url}" \
        --suite testsuite --component main --arch amd64 --min-free-gb 0 >/dev/null

    mkdir -p "${TMPDIR_TEST}/mirror/pool/main/z/zombie"
    echo stale > "${TMPDIR_TEST}/mirror/pool/main/z/zombie/zombie_1_amd64.deb"

    run python3 "$(apt_engine)" --dest "${TMPDIR_TEST}/mirror" --url "${url}" \
        --suite testsuite --component main --arch amd64 --min-free-gb 0 --delete
    [ "$status" -eq 0 ]
    [[ "$output" == *"pruned"* ]]
    [ ! -f "${TMPDIR_TEST}/mirror/pool/main/z/zombie/zombie_1_amd64.deb" ]
    # ...and it must not have taken the real packages with it.
    [ "$(find "${TMPDIR_TEST}/mirror/pool" -name '*.deb' | wc -l)" -eq 2 ]
}

@test "apt engine: a missing suite fails loudly, not silently" {
    _mk_apt_fixture "${TMPDIR_TEST}/up" --packages 1
    local url
    url="$(serve_fixture "${TMPDIR_TEST}/up")"

    run python3 "$(apt_engine)" --dest "${TMPDIR_TEST}/mirror" --url "${url}" \
        --suite nosuchsuite --component main --arch amd64 --min-free-gb 0
    [ "$status" -ne 0 ]
    [[ "$output" == *"cannot fetch Release"* ]]
}

@test "apt engine: --require-signature refuses an unsigned archive" {
    # The fixture publishes no InRelease/Release.gpg. By default that is a
    # warning (the operator may be mirroring an internal archive); with
    # --require-signature it must be fatal.
    _mk_apt_fixture "${TMPDIR_TEST}/up" --packages 1
    local url
    url="$(serve_fixture "${TMPDIR_TEST}/up")"

    run python3 "$(apt_engine)" --dest "${TMPDIR_TEST}/mirror" --url "${url}" \
        --suite testsuite --component main --arch amd64 --min-free-gb 0 \
        --require-signature
    [ "$status" -ne 0 ]
    [[ "$output" == *"require-signature"* ]]
    [ ! -f "${TMPDIR_TEST}/mirror/dists/testsuite/Release" ]
}

@test "apt engine: the disk floor aborts before downloading" {
    _mk_apt_fixture "${TMPDIR_TEST}/up" --packages 3
    local url
    url="$(serve_fixture "${TMPDIR_TEST}/up")"

    # A floor larger than the whole filesystem can never be satisfied.
    run python3 "$(apt_engine)" --dest "${TMPDIR_TEST}/mirror" --url "${url}" \
        --suite testsuite --component main --arch amd64 --min-free-gb 100000000
    [ "$status" -ne 0 ]
    [[ "$output" == *"ABORT"* ]]
}

@test "apt engine: --dry-run writes nothing" {
    _mk_apt_fixture "${TMPDIR_TEST}/up" --packages 2
    local url
    url="$(serve_fixture "${TMPDIR_TEST}/up")"

    run python3 "$(apt_engine)" --dest "${TMPDIR_TEST}/mirror" --url "${url}" \
        --suite testsuite --component main --arch amd64 --min-free-gb 0 --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"dry run"* ]]
    [ ! -d "${TMPDIR_TEST}/mirror/pool" ]
    [ ! -d "${TMPDIR_TEST}/mirror/dists" ]
}

@test "apt engine: leaves no temp files behind" {
    _mk_apt_fixture "${TMPDIR_TEST}/up" --packages 2
    local url
    url="$(serve_fixture "${TMPDIR_TEST}/up")"
    python3 "$(apt_engine)" --dest "${TMPDIR_TEST}/mirror" --url "${url}" \
        --suite testsuite --component main --arch amd64 --min-free-gb 0 >/dev/null

    run bash -c "find '${TMPDIR_TEST}/mirror' -name '*mirroret-tmp*' -o -name '.mirroret-apt-*' | wc -l"
    [ "$output" = "0" ]
}

# -- RPM engine ---------------------------------------------------------------

@test "rpm engine: filtered mirror produces self-consistent repodata" {
    # x86_64+noarch out of a repo that also carries i686 and src makes this a
    # SUBSET, so upstream metadata would advertise packages we did not
    # download. The engine must rewrite it to match the disk.
    _mk_rpm_fixture "${TMPDIR_TEST}/up"
    local url
    url="$(serve_fixture "${TMPDIR_TEST}/up")"

    run python3 "$(rpm_engine)" --dest "${TMPDIR_TEST}/mirror" \
        --repo baseos="${url}" --arch x86_64 --arch noarch --min-free-gb 0
    [ "$status" -eq 0 ]
    [[ "$output" == *"repomd.xml rewritten"* ]]

    run python3 "${SCRIPT_DIR}/tests/fixtures/validate_rpm_repo.py" \
        "${TMPDIR_TEST}/mirror/baseos"
    [ "$status" -eq 0 ]
    [[ "$output" == *"CONSISTENT"* ]]
}

@test "rpm engine: newest-only keeps the highest release, not the last seen" {
    _mk_rpm_fixture "${TMPDIR_TEST}/up"
    local url
    url="$(serve_fixture "${TMPDIR_TEST}/up")"
    python3 "$(rpm_engine)" --dest "${TMPDIR_TEST}/mirror" \
        --repo baseos="${url}" --arch x86_64 --arch noarch --min-free-gb 0 >/dev/null

    # bash 9.el9 beats 6.el9, kernel 500.el9 beats 70.el9 (numeric compare,
    # not string: "70" > "500" lexically).
    [ -f "${TMPDIR_TEST}/mirror/baseos/Packages/bash-5.1.8-9.el9.x86_64.rpm" ]
    [ ! -f "${TMPDIR_TEST}/mirror/baseos/Packages/bash-5.1.8-6.el9.x86_64.rpm" ]
    [ -f "${TMPDIR_TEST}/mirror/baseos/Packages/kernel-5.14.0-500.el9.x86_64.rpm" ]
    [ ! -f "${TMPDIR_TEST}/mirror/baseos/Packages/kernel-5.14.0-70.el9.x86_64.rpm" ]
}

@test "rpm engine: arch filter excludes i686 and src by default" {
    _mk_rpm_fixture "${TMPDIR_TEST}/up"
    local url
    url="$(serve_fixture "${TMPDIR_TEST}/up")"
    python3 "$(rpm_engine)" --dest "${TMPDIR_TEST}/mirror" \
        --repo baseos="${url}" --arch x86_64 --arch noarch --min-free-gb 0 >/dev/null

    run bash -c "find '${TMPDIR_TEST}/mirror' -name '*.i686.rpm' -o -name '*.src.rpm' | wc -l"
    [ "$output" = "0" ]
    # noarch must be included, or most of appstream silently disappears.
    [ -f "${TMPDIR_TEST}/mirror/baseos/Packages/tzdata-2025a-1.el9.noarch.rpm" ]
}

@test "rpm engine: i686 is mirrored when asked for (32-bit multilib)" {
    _mk_rpm_fixture "${TMPDIR_TEST}/up"
    local url
    url="$(serve_fixture "${TMPDIR_TEST}/up")"
    python3 "$(rpm_engine)" --dest "${TMPDIR_TEST}/mirror" \
        --repo baseos="${url}" --arch x86_64 --arch i686 --arch noarch \
        --min-free-gb 0 >/dev/null

    [ -f "${TMPDIR_TEST}/mirror/baseos/Packages/glibc-2.34-100.el9.i686.rpm" ]
    run python3 "${SCRIPT_DIR}/tests/fixtures/validate_rpm_repo.py" \
        "${TMPDIR_TEST}/mirror/baseos"
    [ "$status" -eq 0 ]
}

@test "rpm engine: a complete mirror keeps upstream's signed repodata" {
    # When nothing is filtered out, upstream metadata describes the mirror
    # exactly - keeping it verbatim is both cheaper and lets clients use
    # repo_gpgcheck=1.
    _mk_rpm_fixture "${TMPDIR_TEST}/up"
    local url
    url="$(serve_fixture "${TMPDIR_TEST}/up")"

    run python3 "$(rpm_engine)" --dest "${TMPDIR_TEST}/mirror" \
        --repo baseos="${url}" --arch x86_64 --arch i686 --arch noarch --arch src \
        --sources --all-versions --min-free-gb 0
    [ "$status" -eq 0 ]
    [[ "$output" == *"kept verbatim"* ]]

    run python3 "${SCRIPT_DIR}/tests/fixtures/validate_rpm_repo.py" \
        "${TMPDIR_TEST}/mirror/baseos"
    [ "$status" -eq 0 ]
    [[ "$output" == *"CONSISTENT"* ]]
}

@test "rpm engine: package-independent metadata is passed through" {
    # comps (group_gz) drives 'dnf group install'. Dropping it during a
    # metadata rewrite would silently break group installs.
    _mk_rpm_fixture "${TMPDIR_TEST}/up"
    local url
    url="$(serve_fixture "${TMPDIR_TEST}/up")"
    python3 "$(rpm_engine)" --dest "${TMPDIR_TEST}/mirror" \
        --repo baseos="${url}" --arch x86_64 --arch noarch --min-free-gb 0 >/dev/null

    grep -q 'type="group_gz"' "${TMPDIR_TEST}/mirror/baseos/repodata/repomd.xml"
    [ -f "${TMPDIR_TEST}/mirror/baseos/repodata/comps.xml.gz" ]
}

@test "rpm engine: a filtered mirror does NOT keep a repomd signature" {
    # repomd.xml is rewritten, so upstream's detached signature could never
    # verify. Shipping it would break every client using repo_gpgcheck=1.
    _mk_rpm_fixture "${TMPDIR_TEST}/up"
    local url
    url="$(serve_fixture "${TMPDIR_TEST}/up")"
    python3 "$(rpm_engine)" --dest "${TMPDIR_TEST}/mirror" \
        --repo baseos="${url}" --arch x86_64 --min-free-gb 0 >/dev/null

    [ ! -f "${TMPDIR_TEST}/mirror/baseos/repodata/repomd.xml.asc" ]
}

@test "rpm engine: a bad package checksum stops repodata being republished" {
    _mk_rpm_fixture "${TMPDIR_TEST}/up" --corrupt glibc
    local url
    url="$(serve_fixture "${TMPDIR_TEST}/up")"

    run python3 "$(rpm_engine)" --dest "${TMPDIR_TEST}/mirror" \
        --repo baseos="${url}" --arch x86_64 --arch noarch --min-free-gb 0 --retries 1
    [ "$status" -ne 0 ]
    [[ "$output" == *"sha256 mismatch"* ]]
    [[ "$output" == *"NOT republished"* ]]
    [ ! -d "${TMPDIR_TEST}/mirror/baseos/repodata" ]
}

@test "rpm engine: pruning removes rpms upstream dropped" {
    _mk_rpm_fixture "${TMPDIR_TEST}/up"
    local url
    url="$(serve_fixture "${TMPDIR_TEST}/up")"
    python3 "$(rpm_engine)" --dest "${TMPDIR_TEST}/mirror" \
        --repo baseos="${url}" --arch x86_64 --arch noarch --min-free-gb 0 >/dev/null

    touch "${TMPDIR_TEST}/mirror/baseos/Packages/ghost-1.0-1.el9.x86_64.rpm"
    run python3 "$(rpm_engine)" --dest "${TMPDIR_TEST}/mirror" \
        --repo baseos="${url}" --arch x86_64 --arch noarch --min-free-gb 0
    [ "$status" -eq 0 ]
    [[ "$output" == *"pruned"* ]]
    [ ! -f "${TMPDIR_TEST}/mirror/baseos/Packages/ghost-1.0-1.el9.x86_64.rpm" ]

    run python3 "${SCRIPT_DIR}/tests/fixtures/validate_rpm_repo.py" \
        "${TMPDIR_TEST}/mirror/baseos"
    [ "$status" -eq 0 ]
}

@test "rpm engine: --no-delete keeps rpms upstream dropped" {
    _mk_rpm_fixture "${TMPDIR_TEST}/up"
    local url
    url="$(serve_fixture "${TMPDIR_TEST}/up")"
    python3 "$(rpm_engine)" --dest "${TMPDIR_TEST}/mirror" \
        --repo baseos="${url}" --arch x86_64 --arch noarch --min-free-gb 0 >/dev/null

    touch "${TMPDIR_TEST}/mirror/baseos/Packages/keepme-1.0-1.el9.x86_64.rpm"
    run python3 "$(rpm_engine)" --dest "${TMPDIR_TEST}/mirror" \
        --repo baseos="${url}" --arch x86_64 --arch noarch --min-free-gb 0 --no-delete
    [ "$status" -eq 0 ]
    [ -f "${TMPDIR_TEST}/mirror/baseos/Packages/keepme-1.0-1.el9.x86_64.rpm" ]
}

@test "rpm engine: a bad baseurl reports the URL, not a stack trace" {
    run python3 "$(rpm_engine)" --dest "${TMPDIR_TEST}/mirror" \
        --repo baseos="http://127.0.0.1:1/nope/" --arch x86_64 --min-free-gb 0 \
        --retries 1
    [ "$status" -ne 0 ]
    [[ "$output" == *"cannot fetch"* ]]
    [[ "$output" != *"Traceback"* ]]
}

@test "rpm engine: an HTML proxy error page is diagnosed, not parsed" {
    # A proxy that answers with a block page used to surface as an opaque
    # XML parse error. It must name the proxy as the likely cause.
    mkdir -p "${TMPDIR_TEST}/up/repodata"
    printf '<html><body>403 Forbidden by policy</body></html>\n' \
        > "${TMPDIR_TEST}/up/repodata/repomd.xml"
    local url
    url="$(serve_fixture "${TMPDIR_TEST}/up")"

    run python3 "$(rpm_engine)" --dest "${TMPDIR_TEST}/mirror" \
        --repo baseos="${url}" --arch x86_64 --min-free-gb 0
    [ "$status" -ne 0 ]
    [[ "$output" == *"proxy error page"* ]]
    [[ "$output" == *"not <repomd>"* ]]
}

@test "rpm engine: --dry-run writes no packages" {
    _mk_rpm_fixture "${TMPDIR_TEST}/up"
    local url
    url="$(serve_fixture "${TMPDIR_TEST}/up")"

    run python3 "$(rpm_engine)" --dest "${TMPDIR_TEST}/mirror" \
        --repo baseos="${url}" --arch x86_64 --min-free-gb 0 --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"dry run"* ]]
    run bash -c "find '${TMPDIR_TEST}/mirror' -name '*.rpm' 2>/dev/null | wc -l"
    [ "$output" = "0" ]
}

# -- shared fetch layer -------------------------------------------------------

@test "fetch layer: a truncated download is retried, not accepted" {
    # A TLS-inspecting proxy will hand back a short body with a 200 status.
    # Accepting it would put a corrupt package on the mirror; failing without
    # retrying would fail a nightly sync over one dropped connection.
    run python3 - <<'PY'
import sys
sys.path.insert(0, "engines")
import mirroret_fetch as mf

calls = {"n": 0}


class FakeResp:
    def __init__(self, data):
        self.data = data
        self.pos = 0

    def read(self, n=None):
        chunk = self.data[self.pos:] if n is None else self.data[self.pos:self.pos + n]
        self.pos += len(chunk)
        return chunk

    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False


full = b"x" * 100


class F(mf.Fetcher):
    def _open(self, url):
        calls["n"] += 1
        # First attempt truncates, second is complete.
        return FakeResp(full[:40] if calls["n"] == 1 else full)


f = F(retries=3, backoff=0)
n = f.download("http://example.invalid/x", "/tmp/mirroret-retry-test.bin",
               size=len(full))
assert n == 100, n
assert calls["n"] == 2, calls["n"]
print("retried and succeeded")
PY
    [ "$status" -eq 0 ]
    [[ "$output" == *"retried and succeeded"* ]]
}

@test "fetch layer: a failed download leaves no partial file" {
    run python3 - <<'PY'
import os
import sys
sys.path.insert(0, "engines")
import mirroret_fetch as mf

dest = "/tmp/mirroret-partial-test.bin"
if os.path.exists(dest):
    os.unlink(dest)


class FakeResp:
    """Delivers a short body, then EOF - a truncated transfer."""

    def __init__(self):
        self.sent = False

    def read(self, n=None):
        if self.sent:
            return b""
        self.sent = True
        return b"short"

    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False


class F(mf.Fetcher):
    def _open(self, url):
        return FakeResp()


f = F(retries=1, backoff=0)
try:
    f.download("http://example.invalid/x", dest, size=999)
    raise SystemExit("should have raised")
except mf.VerifyError:
    pass
assert not os.path.exists(dest), "partial file was left behind"
assert not [p for p in os.listdir("/tmp") if "mirroret-partial-test" in p], \
    "temp file was left behind"
print("clean")
PY
    [ "$status" -eq 0 ]
}

@test "fetch layer: join_url does not eat path segments" {
    # urljoin would turn (".../OL9/baseos", "repodata/repomd.xml") into
    # ".../OL9/repodata/repomd.xml", which is a 404 that looks like a
    # missing repo.
    run python3 -c '
import sys
sys.path.insert(0, "engines")
from mirroret_fetch import join_url
assert join_url("http://h/repo/OL9/baseos", "repodata/repomd.xml") == \
    "http://h/repo/OL9/baseos/repodata/repomd.xml"
assert join_url("http://h/repo/", "/a/", "/b") == "http://h/repo/a/b"
print("ok")'
    [ "$status" -eq 0 ]
}

@test "fetch layer: a server streaming past its declared size is cut off" {
    # Without a cap, a server that never stops sending (or a proxy injecting
    # a body into a chunked response) fills the filesystem with a single
    # "download" - this test previously wrote 2.6 GB before anyone noticed.
    # The write must be bounded by the advertised size.
    run python3 - <<'PYEOF'
import os
import sys
sys.path.insert(0, "engines")
import mirroret_fetch as mf

dest = "/tmp/mirroret-oversize-test.bin"
if os.path.exists(dest):
    os.unlink(dest)


class Endless:
    """Never returns EOF - the pathological case."""

    def read(self, n=None):
        return b"x" * (n or 4096)

    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False


class F(mf.Fetcher):
    def _open(self, url):
        return Endless()


f = F(retries=1, backoff=0)
try:
    f.download("http://example.invalid/x", dest, size=1024)
    raise SystemExit("should have raised")
except mf.VerifyError as exc:
    assert "advertised" in str(exc), str(exc)
assert not os.path.exists(dest)
leftovers = [p for p in os.listdir("/tmp") if "mirroret-oversize-test" in p]
assert not leftovers, leftovers
print("bounded")
PYEOF
    [ "$status" -eq 0 ]
    [[ "$output" == *"bounded"* ]]
}

@test "fetch layer: a CA bundle ADDS trust, it does not replace the system store" {
    # Behind a TLS-inspecting proxy the natural thing to set
    # MIRRORET_CA_BUNDLE to is the single corporate root. With
    # create_default_context(cafile=X) that trusts ONLY X, which silently
    # breaks every upstream the proxy does NOT re-sign.
    run python3 - <<'PYEOF'
import os
import subprocess
import sys
import tempfile
sys.path.insert(0, "engines")
from mirroret_fetch import build_opener

d = tempfile.mkdtemp()
crt = os.path.join(d, "corp.pem")
subprocess.run(
    ["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
     "-keyout", os.path.join(d, "k.pem"), "-out", crt,
     "-days", "1", "-subj", "/CN=Corp Root"],
    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True,
)

opener = build_opener(ca_bundle=crt)
ctxs = [h._context for h in opener.handlers if hasattr(h, "_context")]
assert ctxs, "no TLS context on the opener"
n = len(ctxs[0].get_ca_certs())
# A real system store has dozens of roots; trusting only the corporate one
# would leave exactly 1.
assert n > 5, "system trust store was replaced (only %d roots)" % n
print("trusted roots: %d" % n)
PYEOF
    [ "$status" -eq 0 ]
    [[ "$output" == *"trusted roots:"* ]]
}

@test "fetch layer: an unreadable CA bundle fails with an actionable message" {
    run python3 - <<'PYEOF'
import sys
sys.path.insert(0, "engines")
from mirroret_fetch import build_opener

try:
    build_opener(ca_bundle="/nonexistent/corp-ca.pem")
    raise AssertionError("should have exited")
except SystemExit as exc:
    msg = str(exc)
    assert "MIRRORET_CA_BUNDLE" in msg, msg
    print("actionable")
PYEOF
    [ "$status" -eq 0 ]
    [[ "$output" == *"actionable"* ]]
}

@test "apt engine: a nonexistent keyring path is filtered, not fatal" {
    # Reported from a live RHEL mirror server: the spec always names
    # /usr/share/keyrings/ubuntu-archive-keyring.gpg so the client's
    # signed-by= can point at it - but that file does not exist on RHEL.
    # gpgv then failed with "keyblock resource ... No such file or
    # directory" and every suite was refused. Mirror-side verification is
    # defence in depth anyway (the client re-verifies with its own
    # keyring), so a missing keyring on the mirror host must degrade to a
    # warning, not a hard stop.
    _mk_apt_fixture "${TMPDIR_TEST}/up" --packages 2
    local url
    url="$(serve_fixture "${TMPDIR_TEST}/up")"

    run python3 "$(apt_engine)" --dest "${TMPDIR_TEST}/mirror" --url "${url}" \
        --suite testsuite --component main --arch amd64 --min-free-gb 0 \
        --keyring /does/not/exist/anywhere.gpg --flavor ubuntu
    [ "$status" -eq 0 ]
    [[ "$output" == *"NOT verified locally"* ]]
    [ -f "${TMPDIR_TEST}/mirror/dists/testsuite/Release" ]
}

@test "apt engine: --require-signature still fails when no keyring exists" {
    # The escape hatch stays honest: an operator who explicitly demands
    # mirror-side verification must get a hard stop when no usable keyring
    # is available.
    _mk_apt_fixture "${TMPDIR_TEST}/up" --packages 1
    local url
    url="$(serve_fixture "${TMPDIR_TEST}/up")"

    run python3 "$(apt_engine)" --dest "${TMPDIR_TEST}/mirror" --url "${url}" \
        --suite testsuite --component main --arch amd64 --min-free-gb 0 \
        --keyring /does/not/exist.gpg --flavor ubuntu --require-signature
    [ "$status" -ne 0 ]
    [[ "$output" == *"require-signature"* ]]
    [ ! -f "${TMPDIR_TEST}/mirror/dists/testsuite/Release" ]
}

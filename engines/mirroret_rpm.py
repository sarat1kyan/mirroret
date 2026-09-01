#!/usr/bin/env python3
"""mirroret RPM mirroring engine.

Mirrors a yum/dnf repository over plain HTTP(S) using only Python 3 and the
standard library. No reposync, no createrepo, no dnf, and - crucially - no
requirement that the repository be configured in the mirror server's own
package manager.

That last point is the reason this module exists. reposync can only mirror
repos the HOST's dnf already knows about, which meant:

* mirroring Oracle Linux from a RHEL host needed a hand-written .repo file
  on the mirror server, and OL's own .repo uses $ociregion/$ocidomain dnf
  variables that only exist on Oracle hosts, so the URLs came out literal
  and every sync failed;
* mirroring anything RPM from a Debian host was impossible;
* the mirror server's subscription state leaked into what it could serve.

Here the upstream URL is data, so one server mirrors Rocky, Alma, Oracle,
CentOS Stream, Fedora and EPEL side by side regardless of what it runs.

Metadata handling is the subtle part. When every package upstream lists is
mirrored, upstream's signed repodata is kept byte-for-byte (so clients can
use repo_gpgcheck=1). When the mirror is FILTERED - an arch subset, or
--newest-only - upstream metadata advertises packages that are not on disk,
which is what makes clients fail with 404s at install time. In that case
this engine writes filtered metadata by splicing out the package records it
did not mirror, preserving upstream's own XML for the packages it kept. That
is strictly more faithful than re-deriving metadata with createrepo, and it
needs no RPM tooling on the mirror server.
"""

import argparse
import gzip
import hashlib
import io
import json
import os
import re
import shutil
import sys
import tempfile
import threading
import time
import xml.etree.ElementTree as ET
from concurrent.futures import ThreadPoolExecutor, as_completed

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from mirroret_fetch import (  # noqa: E402
    EXIT_DISK,
    EXIT_FAIL,
    EXIT_OK,
    EXIT_UPSTREAM,
    EXIT_USAGE,
    DiskFloor,
    Fetcher,
    FetchError,
    VerifyError,
    decompress,
    file_matches,
    free_gb,
    human,
    join_url,
    log,
)

REPO_NS = "http://linux.duke.edu/metadata/repo"
COMMON_NS = "http://linux.duke.edu/metadata/common"
RPM_NS = "http://linux.duke.edu/metadata/rpm"

# Where RHEL's entitlement certificates live. Mirroring cdn.redhat.com needs
# a TLS client certificate; on a registered RHEL host these are already
# there, which lets the engine mirror RHEL content without reposync.
ENTITLEMENT_DIR = "/etc/pki/entitlement"


# -- rpmvercmp ---------------------------------------------------------------


_ALNUM = frozenset("0123456789abcdefghijklmnopqrstuvwxyz"
                   "ABCDEFGHIJKLMNOPQRSTUVWXYZ")


def _isalnum(ch):
    # Explicit ASCII set: rpmvercmp is defined over bytes, and str.isalnum()
    # would happily accept non-ASCII digits that rpm itself does not.
    return ch in _ALNUM


def rpmvercmp(a, b):
    """Compare two RPM version strings the way rpm itself does.

    This is a direct transliteration of rpmvercmp() from RPM's
    lib/rpmvercmp.c, including the tilde (pre-release, sorts before
    everything) and caret (post-release) rules. Getting this wrong would
    make --newest-only keep the wrong build, so it is covered by the
    upstream test vectors in tests/test_engines.bats.
    """
    if a == b:
        return 0
    a = a or ""
    b = b or ""
    i = j = 0
    la, lb = len(a), len(b)

    while i < la or j < lb:
        while i < la and not (_isalnum(a[i]) or a[i] in "~^"):
            i += 1
        while j < lb and not (_isalnum(b[j]) or b[j] in "~^"):
            j += 1

        # A tilde sorts before everything, including the end of the string.
        if (i < la and a[i] == "~") or (j < lb and b[j] == "~"):
            if i >= la or a[i] != "~":
                return 1
            if j >= lb or b[j] != "~":
                return -1
            i += 1
            j += 1
            continue

        # A caret sorts after the end of a string but before anything else.
        if (i < la and a[i] == "^") or (j < lb and b[j] == "^"):
            if i >= la:
                return -1
            if j >= lb:
                return 1
            if a[i] != "^":
                return 1
            if b[j] != "^":
                return -1
            i += 1
            j += 1
            continue

        if i >= la or j >= lb:
            break

        numeric = a[i].isdigit()
        si, sj = i, j
        if numeric:
            while i < la and a[i].isdigit():
                i += 1
            while j < lb and b[j].isdigit():
                j += 1
        else:
            while i < la and a[i].isalpha():
                i += 1
            while j < lb and b[j].isalpha():
                j += 1

        seg_a, seg_b = a[si:i], b[sj:j]
        if not seg_b:
            # One side has a numeric run where the other has letters:
            # numeric always wins.
            return 1 if numeric else -1
        if numeric:
            seg_a = seg_a.lstrip("0")
            seg_b = seg_b.lstrip("0")
            if len(seg_a) != len(seg_b):
                return 1 if len(seg_a) > len(seg_b) else -1
        if seg_a != seg_b:
            return 1 if seg_a > seg_b else -1

    if i >= la and j >= lb:
        return 0
    return 1 if i < la else -1


def evr_cmp(a, b):
    """Compare (epoch, version, release) tuples."""
    ea = int(a[0] or 0)
    eb = int(b[0] or 0)
    if ea != eb:
        return 1 if ea > eb else -1
    rc = rpmvercmp(a[1], b[1])
    if rc:
        return rc
    return rpmvercmp(a[2], b[2])


# -- repodata parsing --------------------------------------------------------


class RepomdEntry(object):
    __slots__ = ("type", "href", "checksum", "checksum_type",
                 "open_checksum", "open_checksum_type", "size", "open_size",
                 "timestamp", "raw")

    def __init__(self, type_):
        self.type = type_
        self.href = None
        self.checksum = None
        self.checksum_type = "sha256"
        self.open_checksum = None
        self.open_checksum_type = "sha256"
        self.size = None
        self.open_size = None
        self.timestamp = None
        self.raw = None


class NotRepomd(Exception):
    """The URL answered, but with something that is not a repomd.xml."""


def parse_repomd(data):
    """Parse repomd.xml into {type: RepomdEntry} plus the revision string."""
    root = ET.fromstring(data)
    # A proxy block page is often well-formed XML/HTML, so "it parsed" is not
    # evidence that we got repository metadata. Check the root element: the
    # alternative is reporting "no primary metadata", which sends operators
    # looking for a broken repo instead of a blocked request.
    tag = root.tag.split("}")[-1]
    if tag != "repomd":
        raise NotRepomd(tag)
    entries = {}
    revision = None
    for child in root:
        tag = child.tag.split("}")[-1]
        if tag == "revision":
            revision = (child.text or "").strip()
            continue
        if tag != "data":
            continue
        entry = RepomdEntry(child.get("type"))
        for sub in child:
            stag = sub.tag.split("}")[-1]
            if stag == "location":
                entry.href = sub.get("href")
            elif stag == "checksum":
                entry.checksum = (sub.text or "").strip()
                entry.checksum_type = sub.get("type", "sha256")
            elif stag == "open-checksum":
                entry.open_checksum = (sub.text or "").strip()
                entry.open_checksum_type = sub.get("type", "sha256")
            elif stag == "size":
                entry.size = int((sub.text or "0").strip() or 0)
            elif stag == "open-size":
                entry.open_size = int((sub.text or "0").strip() or 0)
            elif stag == "timestamp":
                entry.timestamp = (sub.text or "").strip()
        if entry.href:
            entries[entry.type] = entry
    return entries, revision


class Package(object):
    __slots__ = ("name", "arch", "epoch", "version", "release",
                 "href", "checksum", "checksum_type", "size", "pkgid")

    def __init__(self, name, arch, epoch, version, release, href,
                 checksum, checksum_type, size):
        self.name = name
        self.arch = arch
        self.epoch = epoch
        self.version = version
        self.release = release
        self.href = href
        self.checksum = checksum
        self.checksum_type = checksum_type
        self.size = size
        self.pkgid = checksum

    @property
    def evr(self):
        return (self.epoch, self.version, self.release)

    @property
    def nevra(self):
        return "%s-%s:%s-%s.%s" % (self.name, self.epoch or "0",
                                   self.version, self.release, self.arch)


def safe_relpath(href, repo_id):
    """Validate an upstream location href for use as a local path.

    The mirrored metadata keeps upstream's <location href> verbatim, so the
    package MUST be stored at exactly that relative path. Flattening to the
    basename is the classic way to produce a mirror whose metadata resolves
    to 404s - clients see the package listed and the download fails.
    """
    if "://" in href:
        raise SystemExit(
            "ERROR: %s: metadata uses an absolute package URL (%s).\n"
            "       mirroret mirrors repositories with archive-relative "
            "locations; this repo cannot be mirrored faithfully." % (repo_id, href)
        )
    rel = href.lstrip("/")
    parts = [p for p in rel.split("/") if p not in ("", ".")]
    if any(p == ".." for p in parts):
        raise SystemExit(
            "ERROR: %s: metadata location escapes the repository root (%s)."
            % (repo_id, href)
        )
    return os.path.join(*parts) if parts else ""


def parse_primary(xml_bytes):
    """Stream primary.xml and yield Package objects.

    iterparse + clear() keeps memory flat: OL9 AppStream's primary.xml is
    several hundred megabytes uncompressed and a naive fromstring() would
    need gigabytes of RAM on a mirror server that has better uses for it.
    """
    pkg_tag = "{%s}package" % COMMON_NS
    for _event, elem in ET.iterparse(io.BytesIO(xml_bytes), events=("end",)):
        if elem.tag != pkg_tag:
            continue
        name = elem.findtext("{%s}name" % COMMON_NS) or ""
        arch = elem.findtext("{%s}arch" % COMMON_NS) or ""
        vnode = elem.find("{%s}version" % COMMON_NS)
        epoch = vnode.get("epoch", "0") if vnode is not None else "0"
        version = vnode.get("ver", "") if vnode is not None else ""
        release = vnode.get("rel", "") if vnode is not None else ""
        loc = elem.find("{%s}location" % COMMON_NS)
        href = loc.get("href") if loc is not None else None
        cnode = elem.find("{%s}checksum" % COMMON_NS)
        checksum = (cnode.text or "").strip() if cnode is not None else None
        ctype = cnode.get("type", "sha256") if cnode is not None else "sha256"
        snode = elem.find("{%s}size" % COMMON_NS)
        size = int(snode.get("package", "0")) if snode is not None else 0
        elem.clear()
        if not href:
            continue
        yield Package(name, arch, epoch, version, release, href,
                      checksum, ctype, size)


# -- filtered metadata writer ------------------------------------------------

_PKG_BLOCK_RE = re.compile(rb"<package\b.*?</package>", re.DOTALL)
_PRIMARY_PKGID_RE = re.compile(rb'<checksum[^>]*\bpkgid="YES"[^>]*>([0-9a-fA-F]+)<')
_ATTR_PKGID_RE = re.compile(rb'<package\b[^>]*\bpkgid="([0-9a-fA-F]+)"')
_ROOT_OPEN_RE = re.compile(rb"<(metadata|filelists|otherdata)\b[^>]*>")
_PACKAGES_ATTR_RE = re.compile(rb'(\bpackages=")(\d+)(")')


def _block_pkgid(block, primary):
    match = (_PRIMARY_PKGID_RE if primary else _ATTR_PKGID_RE).search(block)
    return match.group(1).decode("ascii").lower() if match else None


def filter_metadata_xml(xml_bytes, keep_pkgids, primary=False):
    """Return XML containing only the <package> records we mirrored.

    Works on the raw bytes rather than an ElementTree round-trip so each
    kept record stays byte-identical to upstream's - same checksums, same
    provides/requires, same everything. Only the root element's `packages`
    count is rewritten.
    """
    root_match = _ROOT_OPEN_RE.search(xml_bytes)
    if not root_match:
        raise ValueError("not a repodata XML document")
    root_open = root_match.group(0)
    root_name = root_match.group(1)

    kept = []
    for match in _PKG_BLOCK_RE.finditer(xml_bytes, root_match.end()):
        block = match.group(0)
        pkgid = _block_pkgid(block, primary)
        if pkgid is not None and pkgid in keep_pkgids:
            kept.append(block)

    new_root = _PACKAGES_ATTR_RE.sub(
        lambda m: m.group(1) + str(len(kept)).encode() + m.group(3), root_open
    )
    out = io.BytesIO()
    out.write(b'<?xml version="1.0" encoding="UTF-8"?>\n')
    out.write(new_root)
    out.write(b"\n")
    for block in kept:
        out.write(block)
        out.write(b"\n")
    out.write(b"</" + root_name + b">\n")
    return out.getvalue(), len(kept)


def _gz(data):
    buf = io.BytesIO()
    # mtime=0 so identical content produces identical bytes: repeated syncs
    # then leave the repodata checksums alone and clients skip the refetch.
    with gzip.GzipFile(fileobj=buf, mode="wb", mtime=0) as fh:
        fh.write(data)
    return buf.getvalue()


def build_repomd(entries, revision):
    """Serialise a repomd.xml from {type: dict(...)} descriptors."""
    lines = [
        '<?xml version="1.0" encoding="UTF-8"?>',
        '<repomd xmlns="%s" xmlns:rpm="%s">' % (REPO_NS, RPM_NS),
        "  <revision>%s</revision>" % (revision or str(int(time.time()))),
    ]
    for type_ in sorted(entries):
        e = entries[type_]
        lines.append('  <data type="%s">' % type_)
        lines.append('    <checksum type="%s">%s</checksum>'
                     % (e["checksum_type"], e["checksum"]))
        if e.get("open_checksum"):
            lines.append('    <open-checksum type="%s">%s</open-checksum>'
                         % (e["open_checksum_type"], e["open_checksum"]))
        lines.append('    <location href="%s"/>' % e["href"])
        lines.append("    <timestamp>%s</timestamp>" % e["timestamp"])
        if e.get("size") is not None:
            lines.append("    <size>%s</size>" % e["size"])
        if e.get("open_size") is not None:
            lines.append("    <open-size>%s</open-size>" % e["open_size"])
        lines.append("  </data>")
    lines.append("</repomd>")
    return ("\n".join(lines) + "\n").encode()


# -- the mirror run ----------------------------------------------------------

# Metadata we rewrite when the mirror is filtered.
FILTERABLE = {"primary": True, "filelists": False, "other": False}
# Metadata that is package-independent and is copied through untouched.
PASSTHROUGH = (
    "group", "group_gz", "group_xz", "updateinfo", "modules",
    "prestodelta", "deltainfo", "productid",
)


class RpmRepoMirror(object):
    def __init__(self, spec, repo, fetcher, args):
        self.spec = spec
        self.repo = repo
        self.repo_id = repo["id"]
        self.url = repo["url"]
        self.fetcher = fetcher
        self.args = args
        self.arches = set(spec.get("arches") or ["x86_64", "noarch"])
        self.newest_only = bool(spec.get("newest_only", True))
        self.include_source = bool(spec.get("sources", False))
        self.dest = os.path.join(os.path.abspath(spec["dest"]), self.repo_id)
        self.floor = DiskFloor(spec["dest"], spec.get("min_free_gb",
                                                      args.min_free_gb))
        self.downloaded = 0
        self.skipped = 0
        self.failed = 0
        # Set once selection has run: True when we mirrored a strict subset of
        # what upstream advertises, which is exactly the condition under which
        # upstream's metadata must NOT be reused (it would list packages that
        # are not on disk, and clients would 404 at install time). Determined
        # by counting, not by guessing from the flags, so a genuinely complete
        # mirror still gets upstream's signed repodata.
        self.filtered = True
        self._lock = threading.Lock()
        self._last_report = 0.0

    # -- metadata -----------------------------------------------------------

    def _fetch_repomd(self):
        repomd_url = join_url(self.url, "repodata/repomd.xml")
        try:
            repomd_raw = self.fetcher.get_bytes(repomd_url)
        except FetchError as exc:
            raise SystemExit(
                "ERROR: %s: cannot fetch %s (%s).\n"
                "       Check the baseurl and that the host is reachable "
                "through your proxy." % (self.repo_id, repomd_url, exc.reason)
            )
        try:
            entries, revision = parse_repomd(repomd_raw)
        except ET.ParseError as exc:
            raise SystemExit(
                "ERROR: %s: repomd.xml is not valid XML (%s).\n"
                "       A proxy error page is the usual cause - the first bytes "
                "were: %r" % (self.repo_id, exc, repomd_raw[:120])
            )
        except NotRepomd as exc:
            raise SystemExit(
                "ERROR: %s: %s did not return repository metadata.\n"
                "       The response parsed as XML but its root element is "
                "<%s>, not <repomd>.\n"
                "       A proxy error page is the usual cause. First bytes: "
                "%r\n"
                "       Check that your proxy allows CONNECT to this host."
                % (self.repo_id, repomd_url, exc, repomd_raw[:120])
            )
        if "primary" not in entries:
            raise SystemExit(
                "ERROR: %s: repomd.xml has no primary metadata." % self.repo_id
            )
        # The detached signature only ever matches UPSTREAM's repomd.xml, so
        # it is published only for a full mirror. A filtered mirror rewrites
        # repomd.xml, and shipping a signature that cannot verify is worse
        # than shipping none.
        asc = None
        try:
            asc = self.fetcher.get_bytes(join_url(self.url, "repodata/repomd.xml.asc"))
        except FetchError:
            asc = None
        return entries, revision, repomd_raw, asc

    def _fetch_meta(self, entries, types, staging, required=()):
        """Download the named repodata files into `staging`."""
        files = {}
        for type_ in types:
            entry = entries.get(type_)
            if entry is None:
                continue
            target = os.path.join(staging, os.path.basename(entry.href))
            try:
                self.fetcher.download(
                    join_url(self.url, entry.href), target,
                    checksum=entry.checksum, algo=entry.checksum_type,
                    size=entry.size,
                )
            except (FetchError, VerifyError) as exc:
                if type_ in required:
                    raise SystemExit(
                        "ERROR: %s: metadata %s failed: %s"
                        % (self.repo_id, entry.href, exc)
                    )
                log("  WARN: optional metadata %s skipped (%s)" % (type_, exc))
                continue
            files[type_] = target
        return files

    def _fetch_meta_into(self, entries, types, staging, files, required=()):
        files.update(self._fetch_meta(entries, types, staging, required))
        return files

    # -- selection ----------------------------------------------------------

    def _select(self, primary_xml):
        """Apply the arch / source / newest-only filters."""
        best = {}
        total_seen = 0
        for pkg in parse_primary(primary_xml):
            total_seen += 1
            if pkg.arch == "src":
                if not self.include_source:
                    continue
            elif self.arches and pkg.arch not in self.arches:
                continue
            if not self.newest_only:
                best[(pkg.name, pkg.arch, pkg.evr)] = pkg
                continue
            key = (pkg.name, pkg.arch)
            current = best.get(key)
            if current is None or evr_cmp(pkg.evr, current.evr) > 0:
                best[key] = pkg
        return list(best.values()), total_seen

    # -- downloads ----------------------------------------------------------

    def _report(self, total, force=False):
        now = time.time()
        if not force and now - self._last_report < 20:
            return
        self._last_report = now
        done = self.downloaded + self.failed
        log("    %d/%d packages  %s downloaded  %.1f GB free"
            % (done, total, human(self.fetcher.bytes_downloaded),
               free_gb(self.dest)))

    def _download(self, packages):
        need = []
        for pkg in packages:
            local = os.path.join(self.dest, safe_relpath(pkg.href, self.repo_id))
            if file_matches(local, pkg.checksum, pkg.checksum_type, pkg.size or None):
                self.skipped += 1
                continue
            need.append((pkg, local))

        total = len(need)
        want_bytes = sum(p.size for p, _ in need)
        log("  packages: %d selected, %d to download (%s), %d already on disk"
            % (len(packages), total, human(want_bytes), self.skipped))

        if not total:
            return True

        if self.args.estimate and want_bytes:
            avail = free_gb(self.dest)
            need_gb = want_bytes / float(1 << 30)
            if avail - need_gb < self.floor.min_free_gb:
                log("ABORT: %s of packages would leave less than %.1f GB free "
                    "(%.1f GB available)."
                    % (human(want_bytes), self.floor.min_free_gb, avail))
                log("       Reduce MIRRORET_RPM_REPOS/arches, free space, or "
                    "lower MIRRORET_SYNC_MIN_FREE_GB.")
                return False

        if self.args.dry_run:
            for pkg, _ in need[:20]:
                log("    [dry-run] would fetch %s (%s)"
                    % (pkg.href, human(pkg.size)))
            if total > 20:
                log("    [dry-run] ... and %d more" % (total - 20))
            return True

        os.makedirs(self.dest, exist_ok=True)
        aborted = {"disk": False}

        def one(item):
            pkg, local = item
            if aborted["disk"]:
                return None
            if not self.floor.ok():
                aborted["disk"] = True
                return None
            try:
                self.fetcher.download(
                    join_url(self.url, pkg.href), local,
                    checksum=pkg.checksum, algo=pkg.checksum_type,
                    size=pkg.size or None,
                )
                return None
            except (FetchError, VerifyError) as exc:
                return "%s: %s" % (pkg.nevra, exc)

        errors = []
        with ThreadPoolExecutor(max_workers=self.args.jobs) as pool:
            futures = [pool.submit(one, item) for item in need]
            for fut in as_completed(futures):
                err = fut.result()
                with self._lock:
                    if err:
                        self.failed += 1
                        if len(errors) < 25:
                            errors.append(err)
                    else:
                        self.downloaded += 1
                    self._report(total)
        self._report(total, force=True)
        for err in errors:
            log("    FAIL %s" % err)
        if self.failed > len(errors):
            log("    ... and %d more failures" % (self.failed - len(errors)))
        if aborted["disk"]:
            log("ABORT: disk floor of %.1f GB reached mid-download."
                % self.floor.min_free_gb)
            return False
        return self.failed == 0

    # -- publish ------------------------------------------------------------

    def _publish_metadata(self, entries, revision, files, repomd_raw, asc,
                          packages):
        """Write repodata/ for this repo, atomically and last.

        Written into repodata.new/ and renamed over repodata/ so a client
        polling mid-publish either sees the whole old set or the whole new
        one, never a repomd.xml pointing at a primary.xml that is not there
        yet.
        """
        repodata = os.path.join(self.dest, "repodata")
        staging = repodata + ".new"
        shutil.rmtree(staging, ignore_errors=True)
        os.makedirs(staging, exist_ok=True)

        if not self.filtered:
            # Full mirror: upstream's signed repodata describes exactly what
            # is on disk, so keep it verbatim (and keep repo_gpgcheck usable).
            for _type, path in files.items():
                shutil.copy2(path, os.path.join(staging, os.path.basename(path)))
            with open(os.path.join(staging, "repomd.xml"), "wb") as fh:
                fh.write(repomd_raw)
            if asc:
                with open(os.path.join(staging, "repomd.xml.asc"), "wb") as fh:
                    fh.write(asc)
            log("  metadata: upstream repodata kept verbatim (full mirror)")
        else:
            keep = set()
            for pkg in packages:
                if pkg.checksum:
                    keep.add(pkg.checksum.lower())
            new_entries = {}
            now = str(int(time.time()))
            for type_, primary in FILTERABLE.items():
                path = files.get(type_)
                if not path:
                    continue
                with open(path, "rb") as fh:
                    raw = fh.read()
                plain = decompress(raw, path)
                filtered, count = filter_metadata_xml(plain, keep, primary=primary)
                gz = _gz(filtered)
                href = "repodata/%s.xml.gz" % type_
                with open(os.path.join(staging, "%s.xml.gz" % type_), "wb") as fh:
                    fh.write(gz)
                new_entries[type_] = {
                    "href": href,
                    "checksum": hashlib.sha256(gz).hexdigest(),
                    "checksum_type": "sha256",
                    "open_checksum": hashlib.sha256(filtered).hexdigest(),
                    "open_checksum_type": "sha256",
                    "size": len(gz),
                    "open_size": len(filtered),
                    "timestamp": now,
                }
                log("  metadata: %s rewritten with %d of %d package records"
                    % (type_, count, len(packages)))
            for type_ in PASSTHROUGH:
                path = files.get(type_)
                entry = entries.get(type_)
                if not path or not entry:
                    continue
                base = os.path.basename(path)
                shutil.copy2(path, os.path.join(staging, base))
                new_entries[type_] = {
                    "href": "repodata/%s" % base,
                    "checksum": entry.checksum,
                    "checksum_type": entry.checksum_type,
                    "open_checksum": entry.open_checksum,
                    "open_checksum_type": entry.open_checksum_type,
                    "size": entry.size,
                    "open_size": entry.open_size,
                    "timestamp": entry.timestamp or now,
                }
            with open(os.path.join(staging, "repomd.xml"), "wb") as fh:
                fh.write(build_repomd(new_entries, revision))
            log("  metadata: repomd.xml rewritten (filtered mirror - "
                "repo_gpgcheck must be 0, gpgcheck on packages still works)")

        old = repodata + ".old"
        shutil.rmtree(old, ignore_errors=True)
        if os.path.isdir(repodata):
            os.rename(repodata, old)
        os.rename(staging, repodata)
        shutil.rmtree(old, ignore_errors=True)

    def prune(self, packages):
        """Delete RPMs upstream no longer lists.

        Walks the tree rather than one flat directory: packages keep their
        upstream relative path (Packages/, or getPackage/ on older repos),
        because the mirrored metadata points at exactly that path.
        """
        if not os.path.isdir(self.dest):
            return 0
        if not packages:
            # Belt and braces: run() already refuses an empty selection, but
            # "delete everything not in the empty set" must never be reachable
            # from any future caller either.
            log("  prune skipped: no packages listed, nothing can be safely "
                "identified as obsolete.")
            return 0
        wanted = set(
            safe_relpath(p.href, self.repo_id) for p in packages
        )
        removed = freed = 0
        for dirpath, _dirnames, filenames in os.walk(self.dest, topdown=False):
            if os.path.basename(dirpath) == "repodata":
                continue
            if os.sep + "repodata" + os.sep in dirpath + os.sep:
                continue
            for name in filenames:
                if not name.endswith(".rpm"):
                    continue
                full = os.path.join(dirpath, name)
                rel = os.path.relpath(full, self.dest)
                if rel in wanted:
                    continue
                try:
                    freed += os.path.getsize(full)
                    os.unlink(full)
                    removed += 1
                except OSError:
                    pass
            try:
                if dirpath != self.dest and not os.listdir(dirpath):
                    os.rmdir(dirpath)
            except OSError:
                pass
        if removed:
            log("  pruned: %d obsolete rpms (%s reclaimed)"
                % (removed, human(freed)))
        return removed

    # -- driver -------------------------------------------------------------

    def run(self):
        log("--- repo %s <- %s" % (self.repo_id, self.url))
        # The repo id becomes a directory name under the target root, and
        # prune() walks that directory. An empty id resolves to the root and
        # would prune every sibling repo; '..' or '/' would walk outside it.
        if (not self.repo_id or "/" in self.repo_id
                or self.repo_id in (".", "..") or "\x00" in self.repo_id):
            raise SystemExit(
                "ERROR: invalid repo id %r - must be a single plain path "
                "component (e.g. baseos, appstream)." % self.repo_id
            )
        os.makedirs(self.dest, exist_ok=True)
        # Crash recovery for the two-step repodata swap in _publish_metadata:
        # a kill between "rename repodata -> repodata.old" and "rename staging
        # -> repodata" leaves clients with no repomd.xml at all. If that
        # happened last time, put the previous metadata back before doing
        # anything else, so the repo is never left worse than we found it.
        live = os.path.join(self.dest, "repodata")
        stale = live + ".old"
        if not os.path.isdir(live) and os.path.isdir(stale):
            os.rename(stale, live)
            log("  recovered repodata from an interrupted previous run")
        staging = tempfile.mkdtemp(prefix=".mirroret-repodata-", dir=self.dest)
        try:
            entries, revision, repomd_raw, asc = self._fetch_repomd()
            files = self._fetch_meta(entries, ["primary"], staging,
                                     required=("primary",))
            with open(files["primary"], "rb") as fh:
                primary_xml = decompress(fh.read(), files["primary"])
            if "modules" in entries and self.newest_only:
                # A modular repo (RHEL/Alma/OL AppStream) advertises several
                # streams of one package name - nodejs:18 and nodejs:20 are
                # different builds under the same name. Collapsing to the
                # single newest build would strip every non-default stream's
                # RPMs while modules.yaml, passed through verbatim, still
                # advertises them: `dnf module install nodejs:18` then 404s.
                log("  modular repo (modules.yaml present): newest-only "
                    "disabled so every module stream stays installable")
                self.newest_only = False
            packages, seen = self._select(primary_xml)
            # "Filtered" is an observed fact, not a guess from the flags: if
            # every package upstream advertises was selected, upstream's own
            # signed repodata describes the mirror exactly and is kept.
            self.filtered = len(packages) != seen
            log("  upstream lists %d packages; %d selected "
                "(arches=%s newest_only=%s source=%s)"
                % (seen, len(packages), ",".join(sorted(self.arches)) or "all",
                   self.newest_only, self.include_source))
            if not packages:
                # Never a warning. Publishing an empty primary.xml would
                # advertise zero packages to every client, and with delete
                # enabled prune() would then remove every RPM on disk against
                # an empty wanted-set. Whether upstream is transiently empty or
                # the arch filter is a typo (x86_64 vs amd64), the safe answer
                # is to leave the previous metadata and packages untouched.
                raise SystemExit(
                    "ERROR: %s: no packages matched arches=%s out of %d "
                    "upstream. Check MIRRORET_RPM_ARCH against what this repo "
                    "publishes. Refusing to publish empty metadata."
                    % (self.repo_id, ",".join(sorted(self.arches)) or "all",
                       seen)
                )

            if self.filtered:
                # Only what we can rewrite or pass through. The sqlite *_db
                # variants are yum-era, unused by dnf, and cannot be filtered
                # consistently, so a filtered mirror drops them.
                wanted_meta = ["filelists", "other"] + list(PASSTHROUGH)
                self._fetch_meta_into(entries, wanted_meta, staging, files,
                                      required=())
            else:
                # Full mirror: repomd.xml is republished byte-for-byte, so
                # EVERY file it references must be on disk - including the
                # sqlite variants - or the metadata would name files that
                # 404.
                rest = [t for t in entries if t != "primary"]
                self._fetch_meta_into(entries, rest, staging, files,
                                      required=tuple(rest))

            if not self._download(packages):
                log("  RESULT: %s incomplete - repodata NOT republished, "
                    "clients keep using the previous metadata." % self.repo_id)
                return EXIT_FAIL

            if self.args.dry_run:
                log("  RESULT: %s dry run - nothing written." % self.repo_id)
                return EXIT_OK

            # Publish first, prune second. The other order leaves a window
            # in which the live metadata still references rpms that have
            # already been deleted, and any client syncing during that window
            # gets a 404 mid-transaction.
            self._publish_metadata(entries, revision, files, repomd_raw, asc,
                                   packages)
            if self.spec.get("delete", True) and not self.args.no_delete:
                self.prune(packages)
        except SystemExit as exc:
            log(str(exc))
            return EXIT_UPSTREAM
        finally:
            shutil.rmtree(staging, ignore_errors=True)

        log("  RESULT: %s - downloaded %d, already had %d, failed %d"
            % (self.repo_id, self.downloaded, self.skipped, self.failed))
        return EXIT_OK


def _entitlement_pair():
    """Find a RHEL entitlement cert/key pair, if this host has one."""
    try:
        names = sorted(os.listdir(ENTITLEMENT_DIR))
    except OSError:
        return None, None
    certs = [n for n in names if n.endswith(".pem") and not n.endswith("-key.pem")]
    for cert in certs:
        key = cert[:-4] + "-key.pem"
        if key in names:
            return (os.path.join(ENTITLEMENT_DIR, cert),
                    os.path.join(ENTITLEMENT_DIR, key))
    return None, None


def run_spec(spec, args):
    log("=== RPM target: %s" % spec.get("id", "?"))
    log("  dest       : %s" % spec.get("dest"))
    log("  arches     : %s" % " ".join(spec.get("arches") or []))
    log("  newest only: %s" % spec.get("newest_only", True))
    repos = spec.get("repos") or []
    if not repos:
        log("ERROR: target lists no repos.")
        return EXIT_USAGE

    cert = args.client_cert
    key = args.client_key
    if not cert and any("cdn.redhat.com" in (r.get("url") or "") for r in repos):
        cert, key = _entitlement_pair()
        if cert:
            log("  auth       : using RHEL entitlement certificate %s"
                % os.path.basename(cert))
        else:
            log("  WARN: this target includes cdn.redhat.com but no entitlement")
            log("        certificate was found in %s. Register this host with"
                % ENTITLEMENT_DIR)
            log("        subscription-manager, or pass --client-cert/--client-key.")

    fetcher = Fetcher(
        # Pass through as given; build_opener reports a missing bundle by
        # name instead of a per-file CERTIFICATE_VERIFY_FAILED.
        ca_bundle=args.ca_bundle or None,
        client_cert=cert,
        client_key=key,
        insecure=args.insecure_tls,
        retries=args.retries,
        timeout=args.timeout,
    )

    os.makedirs(spec["dest"], exist_ok=True)
    floor = DiskFloor(spec["dest"], spec.get("min_free_gb", args.min_free_gb))
    if not floor.ok():
        log("ABORT: only %.1f GB free on %s (floor: %.1f GB)."
            % (free_gb(spec["dest"]), spec["dest"], floor.min_free_gb))
        return EXIT_DISK

    worst = EXIT_OK
    for repo in repos:
        if not floor.ok():
            log("ABORT: disk floor reached before %s." % repo.get("id"))
            return EXIT_DISK
        rc = RpmRepoMirror(spec, repo, fetcher, args).run()
        if rc != EXIT_OK and worst == EXIT_OK:
            worst = rc
    return worst


def spec_from_args(args):
    if not args.repo:
        raise SystemExit("ERROR: --repo ID=URL is required when --spec is absent.")
    repos = []
    for item in args.repo:
        if "=" not in item:
            raise SystemExit("ERROR: --repo expects ID=URL, got %r" % item)
        rid, _, url = item.partition("=")
        repos.append({"id": rid, "url": url})
    return {
        "id": args.id or "rpm",
        "kind": "rpm",
        "dest": args.dest,
        "arches": args.arch or ["x86_64", "noarch"],
        "newest_only": not args.all_versions,
        "sources": args.sources,
        "delete": not args.no_delete,
        "repos": repos,
    }


def main(argv=None):
    ap = argparse.ArgumentParser(
        prog="mirroret_rpm.py",
        description="Mirror a yum/dnf repository (stdlib only, runs anywhere).",
    )
    ap.add_argument("--spec", action="append", help="JSON target spec (repeatable)")
    ap.add_argument("--dest", help="destination root for this target")
    ap.add_argument("--id", help="target id for log lines")
    ap.add_argument("--repo", action="append", metavar="ID=URL",
                    help="repository to mirror (repeatable)")
    ap.add_argument("--arch", action="append", help="architecture (repeatable)")
    ap.add_argument("--all-versions", action="store_true",
                    help="keep every build, not just the newest (can be TB)")
    ap.add_argument("--sources", action="store_true", help="include .src.rpm")
    ap.add_argument("--no-delete", action="store_true",
                    help="keep rpms upstream has dropped")
    ap.add_argument("--jobs", type=int, default=int(os.environ.get("MIRRORET_JOBS", "8")))
    ap.add_argument("--retries", type=int, default=3)
    ap.add_argument("--timeout", type=int, default=60)
    ap.add_argument("--min-free-gb", type=float,
                    default=float(os.environ.get("MIRRORET_SYNC_MIN_FREE_GB", "10")))
    ap.add_argument("--no-estimate", dest="estimate", action="store_false")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--ca-bundle", default=os.environ.get("MIRRORET_CA_BUNDLE"))
    ap.add_argument("--client-cert", help="TLS client certificate (RHEL CDN)")
    ap.add_argument("--client-key", help="TLS client key (RHEL CDN)")
    ap.add_argument("--insecure-tls", action="store_true")
    args = ap.parse_args(argv)

    specs = []
    if args.spec:
        for path in args.spec:
            with open(path) as fh:
                loaded = json.load(fh)
            specs.extend(loaded if isinstance(loaded, list) else [loaded])
    else:
        if not args.dest:
            ap.error("either --spec or --dest is required")
        specs.append(spec_from_args(args))

    worst = EXIT_OK
    for spec in specs:
        if spec.get("kind", "rpm") != "rpm":
            continue
        rc = run_spec(spec, args)
        if rc != EXIT_OK and worst == EXIT_OK:
            worst = rc
    return worst


if __name__ == "__main__":
    sys.exit(main())

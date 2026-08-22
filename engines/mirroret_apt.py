#!/usr/bin/env python3
"""mirroret APT mirroring engine.

Mirrors a Debian/Ubuntu archive using nothing but Python 3 and the standard
library, so it runs on the mirror server whatever that server happens to
be. That is the whole reason this exists: apt-mirror is Perl and was
dropped from Debian 12, debmirror needs dpkg tooling, and neither is
installable on a RHEL host - which meant a RHEL mirror server could not
serve Ubuntu clients at all.

Design notes that matter for correctness:

* The mirrored tree is byte-identical to upstream, including
  InRelease/Release/Release.gpg. Clients therefore verify the archive with
  their own ubuntu-/debian-archive-keyring, exactly as they would against
  the real archive. mirroret never re-signs anything, so there is no key to
  distribute and no trust to bootstrap.

* Publication order is: indices -> packages -> Release. A suite's Release
  file is only moved into place once every Packages index it references and
  every .deb those indices list is on disk. An interrupted sync therefore
  leaves the previous (consistent) state serving, never a Release that
  promises packages which 404.

* Every download is checksum-verified against the signed Release and
  renamed into place atomically. Nothing half-written is ever visible.

Usage:
    mirroret_apt.py --spec /etc/mirroret/targets/apt-ubuntu.json
    mirroret_apt.py --dest /srv/... --suite jammy --url http://... \
        --component main --arch amd64
"""

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import time
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
    decompress,
    FetchError,
    VerifyError,
    file_matches,
    free_gb,
    human,
    join_url,
    log,
)

# Preference order when a Release lists several compressions of one index.
# .xz first: Ubuntu's universe Packages.xz is roughly a third of the .gz.
COMPRESSION_PREFERENCE = (".xz", ".gz", ".bz2", "")

# Keyrings shipped by the distros themselves. Present on a Debian/Ubuntu
# mirror server; absent on RHEL, which is handled explicitly (see
# _verify_release).
KNOWN_KEYRINGS = {
    "ubuntu": (
        "/usr/share/keyrings/ubuntu-archive-keyring.gpg",
        "/etc/apt/trusted.gpg.d/ubuntu-keyring-2018-archive.gpg",
    ),
    "debian": (
        "/usr/share/keyrings/debian-archive-keyring.gpg",
        "/etc/apt/trusted.gpg.d/debian-archive-bookworm-stable.gpg",
    ),
}


# -- Release / Packages parsing ----------------------------------------------


def parse_rfc822(text):
    """Parse a deb822 paragraph into {field: value}, folding continuations.

    Only the first paragraph is read - Release files are a single
    paragraph, and callers that need many paragraphs use
    iter_paragraphs() instead.
    """
    fields = {}
    key = None
    for line in text.splitlines():
        if not line.strip():
            if fields:
                break
            continue
        if line[0] in " \t":
            if key:
                fields[key] += "\n" + line.strip()
            continue
        if ":" not in line:
            continue
        key, _, value = line.partition(":")
        key = key.strip()
        fields[key] = value.strip()
    return fields


def iter_paragraphs(text, wanted):
    """Yield dicts of the `wanted` fields for each paragraph in text.

    Written as a streaming scan rather than text.split("\\n\\n") because a
    single Ubuntu universe Packages file is tens of megabytes and we only
    ever care about three fields out of forty.
    """
    current = {}
    key = None
    for line in text.splitlines():
        if not line.strip():
            if current:
                yield current
                current = {}
            key = None
            continue
        if line[0] in " \t":
            continue  # continuation of a field we do not need
        head, _, value = line.partition(":")
        key = head.strip()
        if key in wanted:
            current[key] = value.strip()
    if current:
        yield current


def clearsigned_payload(text):
    """Extract the signed body from a clearsigned InRelease file."""
    start = text.find("-----BEGIN PGP SIGNED MESSAGE-----")
    if start < 0:
        return text
    body = text[start:]
    # Skip the armour headers: everything up to the first blank line.
    blank = body.find("\n\n")
    if blank < 0:
        blank = body.find("\r\n\r\n")
        if blank < 0:
            return text
        body = body[blank + 4 :]
    else:
        body = body[blank + 2 :]
    end = body.find("-----BEGIN PGP SIGNATURE-----")
    if end >= 0:
        body = body[:end]
    # Undo dash-escaping performed by the clearsign armour.
    return re.sub(r"^- ", "", body, flags=re.MULTILINE)


class ReleaseIndex(object):
    """The hash table from a suite's signed Release file."""

    def __init__(self, text):
        self.fields = parse_rfc822(clearsigned_payload(text))
        self.entries = {}  # path -> (algo, hexdigest, size)
        # Prefer the strongest hash the Release offers. Ubuntu and Debian
        # both publish SHA256; SHA1/MD5 are legacy and are only used when a
        # third-party archive offers nothing better.
        for algo, field in (("sha256", "SHA256"), ("sha1", "SHA1"), ("md5", "MD5Sum")):
            raw = self.fields.get(field)
            if not raw:
                continue
            for line in raw.splitlines():
                parts = line.split()
                if len(parts) != 3:
                    continue
                digest, size, path = parts
                if path not in self.entries:
                    self.entries[path] = (algo, digest, int(size))
            if self.entries:
                break

    @property
    def components(self):
        return self.fields.get("Components", "").split()

    @property
    def architectures(self):
        return self.fields.get("Architectures", "").split()

    def pick(self, base, all_variants=False):
        """Return [(path, algo, digest, size)] for an index whose
        uncompressed name is `base`.

        By default only the best available compression is mirrored (.xz is
        about a third of the .gz for Ubuntu universe, and apt prefers it).
        Pass all_variants to mirror every compression the Release lists,
        which is what a client with a restricted
        Acquire::CompressionTypes needs.
        """
        found = []
        for suffix in COMPRESSION_PREFERENCE:
            path = base + suffix
            if path in self.entries:
                algo, digest, size = self.entries[path]
                found.append((path, algo, digest, size))
                if not all_variants:
                    break
        return found

    def has(self, path):
        return path in self.entries


# -- signature verification --------------------------------------------------


def _gpgv_available():
    return shutil.which("gpgv") is not None


def _default_keyrings(flavor):
    return [p for p in KNOWN_KEYRINGS.get(flavor, ()) if os.path.exists(p)]


def verify_release(tmpdir, suite, keyrings, require, flavor):
    """Verify a suite's Release signature with gpgv.

    Returns True when verified, False when skipped.

    Mirror-side verification is defence in depth, not the security
    boundary: because the archive is mirrored byte-for-byte, every client
    re-verifies the same signature with its own trusted keyring. So a
    missing keyring (the normal case on a RHEL mirror server, which has no
    ubuntu-archive-keyring) is a warning, not a failure - unless the
    operator asked for --require-signature.
    """
    inrelease = os.path.join(tmpdir, "InRelease")
    release = os.path.join(tmpdir, "Release")
    relgpg = os.path.join(tmpdir, "Release.gpg")

    if os.path.exists(inrelease):
        verify_args = [inrelease]
    elif os.path.exists(release) and os.path.exists(relgpg):
        verify_args = [relgpg, release]
    else:
        verify_args = None

    if verify_args is None:
        _skip_or_die(
            require, suite,
            "this archive publishes no signature (no InRelease, no Release.gpg)",
            "Clients cannot verify it either - they will need "
            "[trusted=yes] in sources.list.",
        )
        return False

    if not keyrings:
        keyrings = _default_keyrings(flavor)

    if not keyrings or not _gpgv_available():
        why = "no archive keyring found" if not keyrings else "gpgv not installed"
        _skip_or_die(
            require, suite, why,
            "The upstream signature is mirrored verbatim, so clients still "
            "verify it against their own archive keyring.",
        )
        return False

    cmd = ["gpgv"]
    for kr in keyrings:
        cmd += ["--keyring", kr]
    cmd += verify_args

    proc = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if proc.returncode != 0:
        detail = (proc.stderr or b"").decode("utf-8", "replace").strip()
        raise SystemExit(
            "ERROR: %s: Release signature verification FAILED.\n%s\n"
            "       Refusing to mirror an archive we cannot authenticate."
            % (suite, detail)
        )
    log("  signature: verified with %s"
        % ", ".join(os.path.basename(k) for k in keyrings))
    return True


def _skip_or_die(require, suite, why, note):
    if require:
        raise SystemExit(
            "ERROR: %s: --require-signature was given but %s.\n"
            "       Install the archive keyring, pass --keyring, or drop\n"
            "       --require-signature." % (suite, why)
        )
    log("  signature: NOT verified locally (%s)" % why)
    log("             %s" % note)


# -- the mirror run ----------------------------------------------------------


class AptMirror(object):
    def __init__(self, spec, fetcher, args):
        self.spec = spec
        self.fetcher = fetcher
        self.args = args
        self.dest = os.path.abspath(spec["dest"])
        self.arches = list(spec.get("arches") or ["amd64"])
        self.components = list(spec.get("components") or ["main"])
        self.floor = DiskFloor(self.dest, spec.get("min_free_gb", args.min_free_gb))
        self.wanted = {}  # relative pool path -> (size, algo, digest, url)
        self.suite_failures = 0
        self.downloaded = 0
        self.skipped = 0
        self.failed = 0
        self._lock = threading.Lock()
        self._last_report = 0.0

    # -- indices ------------------------------------------------------------

    def _index_bases(self, release):
        """Index files to mirror, as uncompressed names relative to the suite."""
        bases = []
        for comp in self.components:
            if release.components and comp not in release.components:
                log("  WARN: component '%s' is not in this suite's Release "
                    "(has: %s)" % (comp, " ".join(release.components) or "-"))
                continue
            for arch in self.arches:
                bases.append("%s/binary-%s/Packages" % (comp, arch))
                bases.append("%s/binary-%s/Release" % (comp, arch))
            if self.spec.get("sources") or self.args.sources:
                bases.append("%s/source/Sources" % comp)
                bases.append("%s/source/Release" % comp)
            if self.spec.get("translations", True):
                for lang in self.spec.get("languages") or ["en"]:
                    bases.append("%s/i18n/Translation-%s" % (comp, lang))
            if self.spec.get("dep11"):
                for arch in self.arches:
                    bases.append("%s/dep11/Components-%s.yml" % (comp, arch))
                bases.append("%s/dep11/icons-64x64.tar" % comp)
        if self.spec.get("contents"):
            for arch in self.arches:
                bases.append("Contents-%s" % arch)
        return bases

    def _fetch_suite_indices(self, suite, base_url, staging):
        """Download+verify one suite's Release and indices into `staging`.

        Returns (ReleaseIndex, [(relative_path, staged_path)]).
        """
        dists = join_url(base_url, "dists", suite)

        release_text = None
        got = []
        for name in ("InRelease", "Release", "Release.gpg"):
            if name == "Release.gpg" and any(g[0] == "InRelease" for g in got):
                continue  # a verified InRelease makes the detached sig moot
            try:
                data = self.fetcher.get_bytes(join_url(dists, name))
            except FetchError as exc:
                # InRelease and Release.gpg are both optional on their own:
                # a modern archive publishes InRelease, an older one
                # Release + Release.gpg, and a plain internal archive may
                # publish an unsigned Release. Only "no Release at all" is
                # fatal, and that is checked after the loop.
                if name in ("InRelease", "Release.gpg"):
                    continue
                raise SystemExit(
                    "ERROR: %s: cannot fetch %s (%s).\n"
                    "       Check the suite name and that the upstream host is "
                    "reachable through your proxy." % (suite, name, exc.reason)
                )
            path = os.path.join(staging, name)
            with open(path, "wb") as fh:
                fh.write(data)
            got.append((name, path))
            if name in ("InRelease", "Release") and release_text is None:
                release_text = data.decode("utf-8", "replace")

        if release_text is None:
            raise SystemExit("ERROR: %s: neither InRelease nor Release found" % suite)

        verify_release(
            staging,
            suite,
            self.args.keyring or self.spec.get("keyrings") or [],
            self.args.require_signature or self.spec.get("require_signature", False),
            self.spec.get("flavor", ""),
        )

        release = ReleaseIndex(release_text)
        if not release.entries:
            raise SystemExit(
                "ERROR: %s: Release carries no checksum table - refusing to "
                "mirror an unverifiable archive." % suite
            )

        for arch in self.arches:
            if release.architectures and arch not in release.architectures:
                log("  WARN: arch '%s' is not published for %s (has: %s)"
                    % (arch, suite, " ".join(release.architectures)))

        staged = [(name, path) for name, path in got]
        packages_indices = []

        all_variants = self.args.all_index_compressions or self.spec.get(
            "all_index_compressions", False)
        for base in self._index_bases(release):
            picked = release.pick(base, all_variants)
            if not picked:
                # Release/Translation/dep11 entries are genuinely optional in
                # some archives; a missing Packages index is not.
                if base.endswith("/Packages"):
                    log("  WARN: %s not listed in Release for %s" % (base, suite))
                continue
            first = True
            for path, algo, digest, size in picked:
                target = os.path.join(staging, path)
                try:
                    self.fetcher.download(
                        join_url(dists, path), target,
                        checksum=digest, algo=algo, size=size,
                    )
                except (FetchError, VerifyError) as exc:
                    raise SystemExit(
                        "ERROR: %s: index %s failed: %s\n"
                        "       Aborting this suite rather than publishing a "
                        "Release that references indices we do not have."
                        % (suite, path, exc)
                    )
                staged.append((path, target))
                if first and os.path.basename(base) == "Packages":
                    packages_indices.append(target)
                first = False

        return release, staged, packages_indices

    # -- package list -------------------------------------------------------

    def _collect_packages(self, base_url, packages_indices):
        """Add every package listed in the given indices to self.wanted."""
        added = 0
        for path in packages_indices:
            with open(path, "rb") as fh:
                raw = fh.read()
            text = decompress(raw, path).decode("utf-8", "replace")
            for pkg in iter_paragraphs(text, {"Filename", "Size", "SHA256", "MD5sum"}):
                filename = pkg.get("Filename")
                if not filename:
                    continue
                if filename in self.wanted:
                    continue
                if pkg.get("SHA256"):
                    algo, digest = "sha256", pkg["SHA256"]
                elif pkg.get("MD5sum"):
                    algo, digest = "md5", pkg["MD5sum"]
                else:
                    algo, digest = None, None
                try:
                    size = int(pkg.get("Size", "0"))
                except ValueError:
                    size = 0
                self.wanted[filename] = (
                    size, algo, digest, join_url(base_url, filename),
                )
                added += 1
        return added

    # -- downloads ----------------------------------------------------------

    def _needed(self):
        need = []
        for rel, (size, algo, digest, url) in self.wanted.items():
            local = os.path.join(self.dest, rel)
            if file_matches(local, digest, algo or "sha256", size or None):
                self.skipped += 1
                continue
            need.append((rel, size, algo, digest, url, local))
        return need

    def _report(self, total, force=False):
        now = time.time()
        if not force and now - self._last_report < 20:
            return
        self._last_report = now
        done = self.downloaded + self.failed
        log("    %d/%d packages  %s downloaded  %.1f GB free"
            % (done, total, human(self.fetcher.bytes_downloaded), free_gb(self.dest)))

    def _download_all(self, need):
        total = len(need)
        if not total:
            log("  packages: already complete (%d on disk)" % self.skipped)
            return True
        want_bytes = sum(n[1] for n in need)
        log("  packages: %d to download (%s), %d already on disk"
            % (total, human(want_bytes), self.skipped))

        if self.args.estimate and want_bytes:
            avail = free_gb(self.dest)
            need_gb = want_bytes / float(1 << 30)
            if avail - need_gb < self.floor.min_free_gb:
                log("ABORT: %s of packages would leave less than %.1f GB free "
                    "(%.1f GB available)."
                    % (human(want_bytes), self.floor.min_free_gb, avail))
                log("       Reduce components/arches, free space, or lower "
                    "MIRRORET_SYNC_MIN_FREE_GB.")
                return False
        if self.args.dry_run:
            for rel, size, _algo, _digest, _url, _local in need[:20]:
                log("    [dry-run] would fetch %s (%s)" % (rel, human(size)))
            if total > 20:
                log("    [dry-run] ... and %d more" % (total - 20))
            return True

        aborted = {"disk": False}

        def one(item):
            rel, size, algo, digest, url, local = item
            if aborted["disk"]:
                return None
            if not self.floor.ok():
                aborted["disk"] = True
                return None
            try:
                self.fetcher.download(
                    url, local, checksum=digest,
                    algo=algo or "sha256", size=size or None,
                )
                return None
            except (FetchError, VerifyError) as exc:
                return "%s: %s" % (rel, exc)

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

    def _publish(self, suite, staged):
        """Move a suite's staged indices into dists/, Release LAST.

        The ordering is the entire point: apt reads Release first and then
        trusts it absolutely. Publishing Release before the indices it
        hashes would make every client fail with a hash mismatch until the
        rest of the move completed.
        """
        suite_dir = os.path.join(self.dest, "dists", suite)
        release_names = ("InRelease", "Release", "Release.gpg")
        ordered = [s for s in staged if s[0] not in release_names]
        ordered += [s for s in staged if s[0] in release_names]
        for rel, src in ordered:
            dst = os.path.join(suite_dir, rel)
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            os.chmod(src, 0o644)
            os.replace(src, dst)
        log("  published: dists/%s (%d index files)" % (suite, len(ordered)))

    # -- pruning ------------------------------------------------------------

    def prune(self):
        """Delete pool files upstream no longer lists.

        Only ever called when every suite succeeded: pruning against a
        partial package list would delete the whole archive.
        """
        pool_root = os.path.join(self.dest, "pool")
        if not os.path.isdir(pool_root):
            return 0
        removed = 0
        freed = 0
        for dirpath, _dirnames, filenames in os.walk(pool_root, topdown=False):
            for name in filenames:
                full = os.path.join(dirpath, name)
                rel = os.path.relpath(full, self.dest)
                if rel in self.wanted:
                    continue
                try:
                    freed += os.path.getsize(full)
                    os.unlink(full)
                    removed += 1
                except OSError:
                    pass
            try:
                if not os.listdir(dirpath) and dirpath != pool_root:
                    os.rmdir(dirpath)
            except OSError:
                pass
        if removed:
            log("  pruned: %d obsolete pool files (%s reclaimed)"
                % (removed, human(freed)))
        return removed

    # -- driver -------------------------------------------------------------

    def run(self):
        suites = self.spec.get("suites") or []
        if not suites:
            log("ERROR: target '%s' lists no suites." % self.spec.get("id", "?"))
            return EXIT_USAGE

        log("=== APT target: %s" % self.spec.get("id", "?"))
        log("  dest       : %s" % self.dest)
        log("  arches     : %s" % " ".join(self.arches))
        log("  components : %s" % " ".join(self.components))
        log("  suites     : %s" % " ".join(s["suite"] for s in suites))
        os.makedirs(self.dest, exist_ok=True)
        try:
            self.floor.require()
        except SystemExit as exc:
            log(str(exc))
            return EXIT_DISK

        pending = []
        staging_root = tempfile.mkdtemp(
            prefix=".mirroret-apt-", dir=self.dest
        )
        try:
            for entry in suites:
                suite = entry["suite"]
                url = entry.get("url") or self.spec.get("url")
                if not url:
                    log("ERROR: suite %s has no upstream url" % suite)
                    self.suite_failures += 1
                    continue
                log("--- suite %s <- %s" % (suite, url))
                staging = os.path.join(staging_root, suite.replace("/", "_"))
                os.makedirs(staging, exist_ok=True)
                try:
                    _release, staged, indices = self._fetch_suite_indices(
                        suite, url, staging
                    )
                except SystemExit as exc:
                    log(str(exc))
                    self.suite_failures += 1
                    continue
                added = self._collect_packages(url, indices)
                log("  indices: %d files, %d packages listed" % (len(staged), added))
                pending.append((suite, staged))

            if not pending:
                log("RESULT: no suite could be prepared - nothing published.")
                return EXIT_UPSTREAM

            ok = self._download_all(self._needed())

            if self.args.dry_run:
                log("RESULT: dry run - nothing written, nothing published.")
                return EXIT_OK

            if not ok:
                log("RESULT: package downloads incomplete (%d failed) - Release "
                    "files NOT published." % self.failed)
                log("        The previously published tree is untouched, so "
                    "clients keep working. Re-run to resume.")
                return EXIT_FAIL

            for suite, staged in pending:
                self._publish(suite, staged)

            if (self.args.delete or self.spec.get("delete")) and not self.suite_failures:
                self.prune()
            elif self.suite_failures:
                log("  prune skipped: %d suite(s) failed, so the package list is "
                    "incomplete." % self.suite_failures)

        finally:
            shutil.rmtree(staging_root, ignore_errors=True)

        log("RESULT: %s - downloaded %d, already had %d, failed %d, %s transferred"
            % (self.spec.get("id", "?"), self.downloaded, self.skipped,
               self.failed, human(self.fetcher.bytes_downloaded)))
        return EXIT_OK if not self.suite_failures else EXIT_FAIL


# -- CLI ---------------------------------------------------------------------


def spec_from_args(args):
    if not args.suite:
        raise SystemExit("ERROR: --suite is required when --spec is not given.")
    if not args.url:
        raise SystemExit("ERROR: --url is required when --spec is not given.")
    return {
        "id": args.id or (args.suite[0] if args.suite else "apt"),
        "kind": "apt",
        "flavor": args.flavor or "",
        "dest": args.dest,
        "arches": args.arch or ["amd64"],
        "components": args.component or ["main"],
        "sources": args.sources,
        "delete": args.delete,
        "suites": [{"suite": s, "url": args.url} for s in args.suite],
    }


def main(argv=None):
    ap = argparse.ArgumentParser(
        prog="mirroret_apt.py",
        description="Mirror a Debian/Ubuntu archive (stdlib only, runs anywhere).",
    )
    ap.add_argument("--spec", help="JSON target spec (repeatable)", action="append")
    ap.add_argument("--dest", help="destination archive root")
    ap.add_argument("--id", help="target id for log lines")
    ap.add_argument("--flavor", help="ubuntu|debian (selects the default keyring)")
    ap.add_argument("--url", help="upstream archive root URL")
    ap.add_argument("--suite", action="append", help="suite/codename (repeatable)")
    ap.add_argument("--component", action="append", help="component (repeatable)")
    ap.add_argument("--arch", action="append", help="architecture (repeatable)")
    ap.add_argument("--sources", action="store_true", help="also mirror source packages")
    ap.add_argument("--all-index-compressions", action="store_true",
                    help="mirror every compression of each index, not just the best")
    ap.add_argument("--delete", action="store_true",
                    help="prune pool files upstream no longer lists")
    ap.add_argument("--keyring", action="append",
                    help="keyring for Release verification (repeatable)")
    ap.add_argument("--require-signature", action="store_true",
                    help="fail instead of warning when the Release cannot be verified")
    ap.add_argument("--jobs", type=int, default=int(os.environ.get("MIRRORET_JOBS", "8")))
    ap.add_argument("--retries", type=int, default=3)
    ap.add_argument("--timeout", type=int, default=60)
    ap.add_argument("--min-free-gb", type=float,
                    default=float(os.environ.get("MIRRORET_SYNC_MIN_FREE_GB", "10")))
    ap.add_argument("--no-estimate", dest="estimate", action="store_false",
                    help="skip the pre-download size check")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--ca-bundle", default=os.environ.get("MIRRORET_CA_BUNDLE"))
    ap.add_argument("--insecure-tls", action="store_true",
                    help="do not verify upstream TLS (lab use only)")
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

    fetcher = Fetcher(
        ca_bundle=args.ca_bundle if args.ca_bundle and os.path.exists(args.ca_bundle) else None,
        insecure=args.insecure_tls,
        retries=args.retries,
        timeout=args.timeout,
    )

    worst = EXIT_OK
    for spec in specs:
        if spec.get("kind", "apt") != "apt":
            continue
        rc = AptMirror(spec, fetcher, args).run()
        if rc != EXIT_OK and worst == EXIT_OK:
            worst = rc
    return worst


if __name__ == "__main__":
    sys.exit(main())

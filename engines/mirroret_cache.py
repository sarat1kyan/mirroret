#!/usr/bin/env python3
"""mirroret_cache - on-demand pull-through cache for package repositories.

The full-mirror model downloads every package a distro publishes, whether
anyone installs it or not. Ubuntu noble+jammy with main+restricted and two
architectures is ~850 GB; a fleet of 40 machines typically installs a few
thousand distinct packages, or 10-30 GB. The other 820 GB is disk rent for
files nobody will ever ask for.

This daemon inverts that. It serves the repository tree from local disk and,
on a miss, fetches that one file from upstream (through whatever proxy the
environment configures), stores it, and streams it to the client. The second
client to want that file gets it from disk at LAN speed. Disk usage
converges on "what this fleet actually installs".

Security is unchanged, and that is worth being precise about, because a
cache sitting between apt and the archive sounds like it should weaken
something:

  - InRelease/Release are passed through byte-for-byte, so the client
    verifies the upstream signature with its own keyring exactly as it
    would against archive.ubuntu.com.
  - That signed Release carries the SHA256 of every Packages index, and
    each Packages index carries the SHA256 of every .deb.
  - The client checks both chains itself.

So a corrupted or substituted cache entry is caught by the client, not
trusted by it. The cache is a transport optimisation, never a trust anchor.
This is the same reason the mirror engine refuses to re-sign anything.

Layout: cached bytes live at <cache-dir>/<route>/<path>, which is the same
shape nginx serves for a mirrored tree. That is deliberate - nginx can
`try_files $uri @cache`, serving every hit itself at full speed and handing
only misses to this process. A warm cache costs Python nothing.

Usage:
    mirroret_cache.py --config /etc/mirroret/cache.json \\
                      --cache-dir /srv/mirroret/apt \\
                      --listen 127.0.0.1:8082
"""

import argparse
import errno
import json
import os
import re
import shutil
import socketserver
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, HTTPServer

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from mirroret_fetch import (  # noqa: E402
    FetchError,
    build_opener,
    free_gb,
    human,
    log,
)

EXIT_OK = 0
EXIT_USAGE = 2
EXIT_CONFIG = 3

BUF = 256 * 1024

# How long a waiter will sit on a stalled in-flight download before giving
# up. Generous: a 400 MB package on a slow corporate link is legitimate.
INFLIGHT_TIMEOUT = 1800.0

# Poll interval while tailing a download another thread is still writing.
TAIL_SLEEP = 0.05


# -- classification -----------------------------------------------------------
#
# The single most important property of a package repository, for a cache, is
# that package files are immutable. Ubuntu never changes the bytes behind
# pool/main/c/curl/curl_8.5.0-2ubuntu10.6_amd64.deb - a rebuild gets a new
# version and therefore a new filename. So a package file, once cached, is
# correct forever and needs no revalidation.
#
# Metadata is the opposite: dists/noble/InRelease changes whenever the archive
# is republished, and serving a stale one hides security updates from every
# client. Metadata is therefore revalidated against upstream on a TTL.

_PACKAGE_SUFFIXES = (
    ".deb", ".udeb", ".ddeb",           # apt
    ".rpm", ".drpm",                    # rpm
    ".whl", ".egg",                     # python
    ".tgz",                             # npm
    ".tar.gz", ".tar.xz", ".tar.bz2", ".tar.zst", ".zip",
)

# Directories whose contents describe the repository rather than being it.
_METADATA_DIR_RE = re.compile(
    r"(^|/)(dists|repodata|repodata\.old|\.diff)(/|$)"
)


def is_immutable(rel_path: str) -> bool:
    """True when this file's bytes can never legitimately change upstream.

    Checked in this order deliberately: a metadata directory wins even when
    the filename ends in something that looks like a package, because
    dists/.../Packages.gz and repodata/.../primary.xml.gz would otherwise be
    cached forever and clients would never see a new package again.
    """
    if _METADATA_DIR_RE.search(rel_path):
        return False
    if rel_path.startswith("pool/") or "/pool/" in rel_path:
        return True
    if "/getPackage/" in rel_path or "/Packages/" in rel_path:
        return True
    return rel_path.endswith(_PACKAGE_SUFFIXES)


def guess_content_type(path: str) -> str:
    if path.endswith((".deb", ".udeb", ".ddeb")):
        return "application/vnd.debian.binary-package"
    if path.endswith(".rpm"):
        return "application/x-rpm"
    if path.endswith((".gz", ".xz", ".bz2", ".zst", ".tgz")):
        return "application/octet-stream"
    if path.endswith((".json",)):
        return "application/json"
    if path.endswith((".txt", ".list", "InRelease", "Release")):
        return "text/plain; charset=utf-8"
    return "application/octet-stream"


# -- route table --------------------------------------------------------------


class Route:
    """One URL prefix mapped to one or more upstream base URLs.

    A list rather than a single base, because a distro's security archive is
    not always reachable under the same base path as its main archive. Debian
    is the clearest case: bookworm lives at deb.debian.org/debian but
    bookworm-security lives at deb.debian.org/debian-security, while both are
    served to clients under one /debian/ prefix. Candidates are tried in
    order and the first one that does not 404 wins, so a pool request is
    answered by the main archive and a -security index by the security one.
    """

    def __init__(self, name, upstreams, kind="apt"):
        self.name = name
        self.upstreams = [u.rstrip("/") for u in upstreams]
        self.kind = kind

    @property
    def upstream(self):
        """The primary upstream, for logging and status output."""
        return self.upstreams[0]

    def candidate_urls(self, rel: str):
        quoted = urllib.parse.quote(rel)
        return ["%s/%s" % (base, quoted) for base in self.upstreams]


def load_routes(path: str) -> dict:
    try:
        with open(path, "r", encoding="utf-8") as fh:
            data = json.load(fh)
    except FileNotFoundError:
        raise SystemExit(
            "ERROR: cache config not found: %s\n"
            "       Generate it with: sudo mirroretctl upgrade" % path
        )
    except ValueError as exc:
        raise SystemExit("ERROR: %s is not valid JSON: %s" % (path, exc))

    raw = data.get("routes")
    if not isinstance(raw, dict) or not raw:
        raise SystemExit(
            "ERROR: %s has no 'routes' object - nothing to serve.\n"
            "       Expected {\"routes\": {\"ubuntu\": "
            "{\"upstream\": \"https://archive.ubuntu.com/ubuntu\"}}}" % path
        )

    routes = {}
    for name, spec in raw.items():
        if isinstance(spec, str):
            spec = {"upstream": spec}
        # "upstreams" (a list) is the general form; "upstream" (a string) is
        # the common single-archive shorthand.
        upstreams = spec.get("upstreams")
        if upstreams is None:
            single = spec.get("upstream")
            upstreams = [single] if single else []
        if isinstance(upstreams, str):
            upstreams = [upstreams]
        if not upstreams:
            raise SystemExit(
                "ERROR: route '%s' in %s has no 'upstream' URL." % (name, path)
            )
        for url in upstreams:
            if not isinstance(url, str) or not url.startswith(
                ("http://", "https://")
            ):
                raise SystemExit(
                    "ERROR: route '%s' upstream must be an http(s) URL, got %r"
                    % (name, url)
                )
        routes[name] = Route(name, upstreams, spec.get("kind", "apt"))
    return routes


# -- single-flight ------------------------------------------------------------


class _UpstreamUnavailable(Exception):
    """No candidate upstream could serve a path. Carries the last real error."""

    def __init__(self, cause, status=502):
        super().__init__(str(cause))
        self.cause = cause
        self.status = status


class Inflight:
    """One upstream download, shared by every client that wants that file.

    Without this, forty machines running the nightly `apt-get upgrade` at the
    same minute would open forty identical upstream connections for the same
    200 MB package: forty times the WAN bill, forty times the load on a
    corporate proxy that is often the actual bottleneck, and a real chance of
    them corrupting each other's partial file.

    The first caller becomes the writer. Everyone else tails the partial file
    as it grows, so a waiter that arrived one second late still starts
    receiving bytes immediately instead of blocking until the whole download
    finishes.
    """

    def __init__(self, part_path, final_path):
        self.part_path = part_path
        self.final_path = final_path
        self.header_ready = threading.Event()
        self.done = threading.Event()
        self.status = 200
        self.total = None       # int, or None when upstream omits the length
        self.headers = {}
        self.error = None       # Exception, once the fetch has failed

    def fail(self, exc: Exception) -> None:
        self.error = exc
        # Unblock anyone waiting on headers as well as anyone tailing.
        self.header_ready.set()
        self.done.set()


class CacheStats:
    def __init__(self):
        self.lock = threading.Lock()
        self.hits = 0
        self.misses = 0
        self.coalesced = 0
        self.revalidated = 0
        self.stale_served = 0
        self.errors = 0
        self.bytes_from_upstream = 0
        self.started = time.time()

    def bump(self, field: str, n: int = 1) -> None:
        with self.lock:
            setattr(self, field, getattr(self, field) + n)

    def snapshot(self) -> dict:
        with self.lock:
            return {
                "hits": self.hits,
                "misses": self.misses,
                "coalesced": self.coalesced,
                "revalidated": self.revalidated,
                "stale_served": self.stale_served,
                "errors": self.errors,
                "bytes_from_upstream": self.bytes_from_upstream,
                "uptime_seconds": int(time.time() - self.started),
            }


class Cache:
    """Cache state shared across request threads."""

    def __init__(self, args, routes: dict):
        self.args = args
        self.routes = routes
        self.cache_dir = os.path.abspath(args.cache_dir)
        self.metadata_ttl = args.metadata_ttl
        self.offline = args.offline
        self.opener = build_opener(
            ca_bundle=args.ca_bundle or None, insecure=args.insecure
        )
        self.stats = CacheStats()
        self._inflight_lock = threading.Lock()
        self._inflight = {}
        self._reval_lock = threading.Lock()
        self._reval_inflight = {}
        self._evict_lock = threading.Lock()

    # -- paths ---------------------------------------------------------------

    def resolve(self, url_path: str):
        """Map a request path onto (route, relative path, on-disk path).

        Returns None when the path does not belong to a configured route.
        Rejects traversal outside the cache directory - the daemon may be
        reachable from the LAN, so '/ubuntu/../../etc/shadow' must not
        resolve to anything.
        """
        clean = urllib.parse.unquote(url_path.split("?", 1)[0]).lstrip("/")
        if not clean:
            return None
        parts = clean.split("/", 1)
        route = self.routes.get(parts[0])
        if route is None:
            return None
        rel = parts[1] if len(parts) > 1 else ""
        if not rel or rel.endswith("/") or "\x00" in rel:
            return None
        # Reject '.'/'..' components outright instead of relying on abspath
        # normalisation: a request that normalises back to the route root
        # would otherwise be fetched upstream and then fail on os.replace.
        if any(seg in ("", ".", "..") for seg in rel.split("/")):
            return None

        disk = os.path.abspath(os.path.join(self.cache_dir, route.name, rel))
        root = os.path.join(self.cache_dir, route.name)
        if not disk.startswith(root + os.sep):
            return None
        # A path that is already a directory on disk (GET /ubuntu/dists with
        # no trailing slash) must not be fetched: upstream would answer with
        # an HTML listing, which would be stored as a regular file *named*
        # dists, and every later dists/... request would die on
        # NotADirectoryError. Likewise refuse when an ancestor is a file.
        if os.path.isdir(disk):
            return None
        probe = os.path.dirname(disk)
        while probe.startswith(root) and probe != root:
            if os.path.isfile(probe):
                return None
            probe = os.path.dirname(probe)
        return route, rel, disk

    # -- freshness -----------------------------------------------------------

    def is_fresh(self, disk_path: str, rel: str) -> bool:
        """Can we serve this cached file without asking upstream?"""
        try:
            st = os.stat(disk_path)
        except OSError:
            return False
        if is_immutable(rel):
            return True
        return (time.time() - st.st_mtime) < self.metadata_ttl

    # -- fetching ------------------------------------------------------------

    def _open_upstream(self, url, extra_headers=None):
        req = urllib.request.Request(url)
        for key, val in (extra_headers or {}).items():
            req.add_header(key, val)
        return self.opener.open(req, timeout=self.args.upstream_timeout)

    def fetch(self, route: Route, rel: str, disk_path: str) -> Inflight:
        """Start (or join) the single upstream download for this path."""
        with self._inflight_lock:
            existing = self._inflight.get(disk_path)
            if existing is not None:
                self.stats.bump("coalesced")
                return existing
            part = "%s.mirroret-part" % disk_path
            entry = Inflight(part, disk_path)
            self._inflight[disk_path] = entry

        thread = threading.Thread(
            target=self._fetch_worker,
            args=(route, rel, disk_path, entry),
            daemon=True,
        )
        try:
            thread.start()
        except RuntimeError as exc:
            # Thread exhaustion. Without this the entry stays registered with
            # no writer, and every later request for the path coalesces onto
            # it and waits the full INFLIGHT_TIMEOUT for nothing.
            entry.fail(exc)
            self._retire(disk_path)
            self.stats.bump("errors")
        return entry

    def _open_first_available(self, route: Route, rel: str):
        """Open the first candidate upstream that actually has this path.

        A 404 means "not on this archive, try the next one" rather than a
        hard failure, which is what lets one client-facing prefix span a
        main archive and a separately-hosted security archive.
        """
        last_exc = None
        last_status = 502
        for url in route.candidate_urls(rel):
            try:
                return self._open_upstream(url), url
            except urllib.error.HTTPError as exc:
                last_exc = FetchError(url, "HTTP %d" % exc.code, exc.code)
                last_status = exc.code
                if exc.code != 404:
                    break
            except Exception as exc:  # noqa: BLE001
                last_exc = exc
                break
        raise _UpstreamUnavailable(last_exc, last_status)

    def _fetch_worker(self, route: Route, rel: str, disk_path: str,
                      entry: Inflight) -> None:
        try:
            os.makedirs(os.path.dirname(disk_path), exist_ok=True)
            resp, _url = self._open_first_available(route, rel)
        except _UpstreamUnavailable as exc:
            entry.status = exc.status
            entry.fail(exc.cause or FetchError(rel, "upstream unavailable"))
            self._retire(disk_path)
            self.stats.bump("errors")
            return
        except Exception as exc:  # noqa: BLE001 - surfaced to the client as 502
            entry.fail(exc)
            self._retire(disk_path)
            self.stats.bump("errors")
            return

        try:
            length = resp.headers.get("Content-Length")
            entry.total = int(length) if length and length.isdigit() else None
            entry.headers = {
                "Content-Type": resp.headers.get(
                    "Content-Type", guess_content_type(rel)
                ),
                "Last-Modified": resp.headers.get("Last-Modified", ""),
            }
            written = 0
            # The part file must exist before waiters are released, or a
            # waiter that wakes immediately finds neither the partial nor the
            # final file and reports a spurious 404 for a download that is
            # about to succeed.
            with open(entry.part_path, "wb") as fh:
                entry.header_ready.set()
                while True:
                    chunk = resp.read(BUF)
                    if not chunk:
                        break
                    fh.write(chunk)
                    fh.flush()
                    written += len(chunk)

            if entry.total is not None and written != entry.total:
                raise OSError(
                    "short read: got %d of %d bytes" % (written, entry.total)
                )

            os.replace(entry.part_path, disk_path)
            self.stats.bump("bytes_from_upstream", written)
            entry.done.set()

            if entry.total is None and is_immutable(rel):
                # No Content-Length means a clean close and a truncated body
                # are indistinguishable. For a package - cached forever, never
                # revalidated - a silently truncated file would give every
                # client a hash mismatch for good. Serve this response (the
                # waiters hold the inode) but do not keep it; the next request
                # fetches again, hopefully with a length.
                log("cache: %s arrived without Content-Length; served but not "
                    "retained" % rel)
                try:
                    os.unlink(disk_path)
                except OSError:
                    pass
        except Exception as exc:  # noqa: BLE001
            entry.fail(exc)
            self.stats.bump("errors")
            try:
                os.unlink(entry.part_path)
            except OSError:
                pass
        finally:
            try:
                resp.close()
            except Exception:  # noqa: BLE001
                pass
            self._retire(disk_path)

    def _retire(self, disk_path: str) -> None:
        with self._inflight_lock:
            self._inflight.pop(disk_path, None)

    def revalidate(self, route: Route, rel: str, disk_path: str) -> bool:
        """Ask upstream whether stale metadata actually changed.

        A conditional GET means an unchanged InRelease costs a 304 and no
        body, which matters when every client on the network runs
        `apt-get update` on the same cron minute.
        """
        # One revalidation per path at a time. Forty clients hitting a stale
        # InRelease on the same cron minute used to start forty conditional
        # GETs that all wrote the SAME temp file with O_TRUNC from different
        # offsets - a zero-filled hole renamed live under apt's feet. The
        # first thread does the work; the rest wait, then re-check freshness.
        with self._reval_lock:
            guard = self._reval_inflight.get(disk_path)
            if guard is None:
                guard = threading.Lock()
                self._reval_inflight[disk_path] = guard
        with guard:
            try:
                if self.is_fresh(disk_path, rel):
                    return True  # someone else just revalidated it
                return self._revalidate_locked(route, rel, disk_path)
            finally:
                with self._reval_lock:
                    if self._reval_inflight.get(disk_path) is guard:
                        del self._reval_inflight[disk_path]

    def _revalidate_locked(self, route, rel, disk_path):
        try:
            st = os.stat(disk_path)
        except OSError:
            return False
        stamp = time.strftime(
            "%a, %d %b %Y %H:%M:%S GMT", time.gmtime(st.st_mtime)
        )
        resp = None
        for url in route.candidate_urls(rel):
            try:
                resp = self._open_upstream(url, {"If-Modified-Since": stamp})
                break
            except urllib.error.HTTPError as exc:
                if exc.code == 304:
                    # Unchanged upstream: bump mtime so the TTL restarts and
                    # we do not ask again on the next request.
                    os.utime(disk_path, None)
                    self.stats.bump("revalidated")
                    return True
                if exc.code == 404:
                    continue  # not on this archive; try the next candidate
                return False
            except Exception:  # noqa: BLE001
                return False
        if resp is None:
            return False

        tmp_path = None
        try:
            if resp.status == 304:
                os.utime(disk_path, None)
                self.stats.bump("revalidated")
                return True
            length = resp.headers.get("Content-Length")
            expected = int(length) if length and length.isdigit() else None
            # A unique temp name, never the shared ".mirroret-part" the miss
            # path uses, so a concurrent first-fetch of the same path (or a
            # previous crashed writer) cannot collide with us.
            fd, tmp_path = tempfile.mkstemp(
                prefix=".mirroret-reval-", dir=os.path.dirname(disk_path)
            )
            written = 0
            with os.fdopen(fd, "wb") as fh:
                while True:
                    chunk = resp.read(BUF)
                    if not chunk:
                        break
                    fh.write(chunk)
                    written += len(chunk)
            if expected is not None and written != expected:
                # A proxy-truncated 200 must not replace a good index.
                raise OSError("short read: %d of %d" % (written, expected))
            os.chmod(tmp_path, 0o644)
            os.replace(tmp_path, disk_path)
            tmp_path = None
            self.stats.bump("revalidated")
            if os.path.basename(disk_path) in ("InRelease", "Release"):
                # A new Release hashes new Packages/Translation files. On
                # archives without Acquire-By-Hash (most third-party repos)
                # those keep their names, so a still-"fresh" sibling would be
                # served against the new Release and fail apt's hash check
                # for up to metadata_ttl. Age every sibling so the next
                # request revalidates it too.
                self._expire_siblings(os.path.dirname(disk_path))
            return True
        except Exception:  # noqa: BLE001
            return False
        finally:
            if tmp_path is not None:
                try:
                    os.unlink(tmp_path)
                except OSError:
                    pass
            try:
                resp.close()
            except Exception:  # noqa: BLE001
                pass

    def _expire_siblings(self, suite_dir):
        """Set every cached index under a suite to 'stale' (mtime epoch)."""
        for dirpath, _dirs, files in os.walk(suite_dir):
            for name in files:
                full = os.path.join(dirpath, name)
                if full.endswith((".mirroret-part",)) or name.startswith(".mirroret-reval-"):
                    continue
                if name in ("InRelease", "Release", "Release.gpg"):
                    continue
                try:
                    os.utime(full, (0, 0))
                except OSError:
                    pass

    def sweep_temp_files(self, older_than=3600):
        """Delete partial/temp files left by a killed writer.

        A SIGKILL mid-download leaves *.mirroret-part or .mirroret-reval-*
        behind; nothing else ever removes them, and a cache that runs for a
        year accumulates them. Anything older than an hour cannot belong to
        a live download (INFLIGHT_TIMEOUT is 30 min).
        """
        cutoff = time.time() - older_than
        removed = 0
        for dirpath, _dirs, files in os.walk(self.cache_dir):
            for name in files:
                if not (name.endswith(".mirroret-part")
                        or name.startswith(".mirroret-reval-")):
                    continue
                full = os.path.join(dirpath, name)
                try:
                    if os.stat(full).st_mtime < cutoff:
                        os.unlink(full)
                        removed += 1
                except OSError:
                    pass
        return removed

    # -- eviction ------------------------------------------------------------

    def evict_if_needed(self) -> dict:
        """Trim the cache back under its size cap, oldest package first.

        Only package files are ever evicted. Metadata is a rounding error in
        size terms and evicting it would just force an immediate refetch on
        the next apt-get update.
        """
        cap = self.args.max_size_gb
        if cap <= 0:
            return {"evicted": 0, "freed": 0, "skipped": "no cap configured"}
        with self._evict_lock:
            entries = []
            total = 0
            for dirpath, _dirs, files in os.walk(self.cache_dir):
                for name in files:
                    if name.endswith(".mirroret-part"):
                        continue
                    full = os.path.join(dirpath, name)
                    try:
                        st = os.stat(full)
                    except OSError:
                        continue
                    total += st.st_size
                    rel = os.path.relpath(full, self.cache_dir)
                    # Strip the route component to classify on repo-relative
                    # path, so 'ubuntu/dists/...' is seen as 'dists/...'.
                    inner = rel.split("/", 1)[1] if "/" in rel else rel
                    if is_immutable(inner):
                        entries.append((st.st_atime, st.st_size, full))

            limit = int(cap * 1024 ** 3)
            if total <= limit:
                return {"evicted": 0, "freed": 0, "total_bytes": total}

            entries.sort()  # least recently accessed first
            freed = 0
            removed = 0
            for _atime, size, full in entries:
                if total - freed <= limit:
                    break
                try:
                    os.unlink(full)
                except OSError:
                    continue
                freed += size
                removed += 1
            return {"evicted": removed, "freed": freed, "total_bytes": total}


# -- HTTP ---------------------------------------------------------------------


class Handler(BaseHTTPRequestHandler):
    # HTTP/1.1 keep-alive: apt issues dozens of requests per update and a
    # fresh TCP handshake for each one is pure latency.
    protocol_version = "HTTP/1.1"
    server_version = "mirroret-cache"
    sys_version = ""

    cache: Cache  # injected by serve()

    def log_message(self, fmt: str, *args) -> None:  # noqa: A003
        if self.cache.args.verbose:
            log("%s %s" % (self.address_string(), fmt % args))

    # -- helpers -------------------------------------------------------------

    def _send_simple(self, code: int, body: bytes,
                     ctype: str = "text/plain; charset=utf-8") -> None:
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def _serve_file(self, disk_path: str, rel: str) -> None:
        # Open first, then fstat the open descriptor: the length we promise
        # and the bytes we send come from the same inode. stat-then-open
        # raced with revalidate()'s os.replace and with GC eviction, and a
        # length that does not match the body corrupts keep-alive framing
        # for that client's next request.
        try:
            fh = open(disk_path, "rb")
        except OSError:
            self._send_simple(404, b"not found\n")
            return
        with fh:
            size = os.fstat(fh.fileno()).st_size
            self.send_response(200)
            self.send_header("Content-Type", guess_content_type(rel))
            self.send_header("Content-Length", str(size))
            self.send_header("X-Mirroret-Cache", "HIT")
            self.end_headers()
            if self.command == "HEAD":
                return
            remaining = size
            while remaining > 0:
                chunk = fh.read(min(BUF, remaining))
                if not chunk:
                    break
                self.wfile.write(chunk)
                remaining -= len(chunk)
            if remaining:
                self.close_connection = True

    def _stream_inflight(self, entry: Inflight, rel: str) -> None:
        """Send a download that is still being written by another thread."""
        if not entry.header_ready.wait(timeout=INFLIGHT_TIMEOUT):
            self._send_simple(504, b"upstream timed out\n")
            return
        if entry.error is not None:
            code = entry.status if entry.status >= 400 else 502
            self._send_simple(code, b"upstream fetch failed\n")
            return

        # Without a Content-Length we cannot frame a streamed body under
        # HTTP/1.1 keep-alive, so wait for the writer and serve the finished
        # file. Upstreams that omit Content-Length are rare.
        if entry.total is None:
            if not entry.done.wait(timeout=INFLIGHT_TIMEOUT):
                self._send_simple(504, b"upstream timed out\n")
                return
            if entry.error is not None:
                self._send_simple(502, b"upstream fetch failed\n")
                return
            self._serve_file(entry.final_path, rel)
            return

        self.send_response(200)
        self.send_header("Content-Type",
                         entry.headers.get("Content-Type")
                         or guess_content_type(rel))
        self.send_header("Content-Length", str(entry.total))
        self.send_header("X-Mirroret-Cache", "MISS")
        self.end_headers()
        if self.command == "HEAD":
            return

        # Tail the partial file. Holding the fd across the writer's rename is
        # safe: rename keeps the inode, so we keep reading the same bytes.
        deadline = time.time() + INFLIGHT_TIMEOUT
        sent = 0
        try:
            fh = open(entry.part_path, "rb")
        except OSError:
            # The writer finished and renamed the partial away between our
            # header send and this open - very likely for small files, where
            # the whole download completes in microseconds. Read the finished
            # file instead. It must be a plain open here, never _serve_file:
            # the response line and headers are already on the wire, and
            # sending a second complete response would land a literal
            # "HTTP/1.1 200 OK" in the middle of the body.
            try:
                fh = open(entry.final_path, "rb")
            except OSError:
                self.close_connection = True
                return
        try:
            while sent < entry.total:
                # Never read past the length we promised. If upstream streams
                # more than its declared Content-Length the writer fails the
                # download, but a tailing reader could already have pushed the
                # surplus into a keep-alive stream, corrupting the framing of
                # that client's next request.
                chunk = fh.read(min(BUF, entry.total - sent))
                if chunk:
                    self.wfile.write(chunk)
                    sent += len(chunk)
                    continue
                if entry.done.is_set():
                    # Writer is finished and everything it wrote is flushed,
                    # so one more read sees any bytes that landed between our
                    # last read and this check.
                    chunk = fh.read(min(BUF, entry.total - sent))
                    if chunk:
                        self.wfile.write(chunk)
                        sent += len(chunk)
                        continue
                    break
                if entry.error is not None or time.time() > deadline:
                    break
                time.sleep(TAIL_SLEEP)
        finally:
            fh.close()

        if sent < entry.total:
            # We promised Content-Length bytes and cannot deliver them, because
            # the upstream fetch died mid-flight. Dropping the connection is
            # what makes the client notice: on a keep-alive connection it would
            # otherwise sit waiting for bytes that are never coming, and apt
            # would hang instead of failing over or retrying.
            self.close_connection = True

    # -- request dispatch ----------------------------------------------------

    def do_HEAD(self) -> None:  # noqa: N802
        self._handle()

    def do_GET(self) -> None:  # noqa: N802
        self._handle()

    def _handle(self) -> None:
        cache = self.cache

        if self.path.startswith("/__mirroret_cache/"):
            self._handle_control()
            return

        resolved = cache.resolve(self.path)
        if resolved is None:
            self._send_simple(
                404,
                b"no route for this path; check /etc/mirroret/cache.json\n",
            )
            return
        route, rel, disk_path = resolved

        cached = os.path.isfile(disk_path)

        if cached and cache.is_fresh(disk_path, rel):
            cache.stats.bump("hits")
            self._serve_file(disk_path, rel)
            return

        if cached and cache.offline:
            cache.stats.bump("stale_served")
            self._serve_file(disk_path, rel)
            return

        if cache.offline:
            self._send_simple(
                404, b"offline mode: not in cache and upstream disabled\n"
            )
            return

        if cached:
            # Stale metadata. A conditional GET usually comes back 304.
            if cache.revalidate(route, rel, disk_path):
                cache.stats.bump("hits")
                self._serve_file(disk_path, rel)
                return
            # Upstream unreachable or errored. A stale index beats a hard
            # failure: the client can still install from what it knows, and
            # the archive being briefly unreachable should not take the whole
            # fleet's package manager down with it.
            cache.stats.bump("stale_served")
            self._serve_file(disk_path, rel)
            return

        cache.stats.bump("misses")
        entry = cache.fetch(route, rel, disk_path)
        self._stream_inflight(entry, rel)

    def _handle_control(self) -> None:
        cache = self.cache
        what = self.path.rsplit("/", 1)[-1].split("?", 1)[0]
        if what == "status":
            body = json.dumps(
                {
                    "ok": True,
                    "routes": sorted(cache.routes),
                    "cache_dir": cache.cache_dir,
                    "offline": cache.offline,
                    "metadata_ttl": cache.metadata_ttl,
                    "free_gb": round(free_gb(cache.cache_dir), 1),
                    "stats": cache.stats.snapshot(),
                },
                indent=2,
            ).encode()
            self._send_simple(200, body, "application/json")
            return
        self._send_simple(404, b"unknown control endpoint\n")


# -- eviction thread ----------------------------------------------------------


def eviction_loop(cache: Cache, interval: int) -> None:
    while True:
        time.sleep(interval)
        try:
            swept = cache.sweep_temp_files()
            if swept:
                log("cache gc: removed %d stale temp file(s)" % swept)
            result = cache.evict_if_needed()
            if result.get("evicted"):
                log(
                    "cache gc: evicted %d files, freed %s"
                    % (result["evicted"], human(result["freed"]))
                )
        except Exception as exc:  # noqa: BLE001 - a GC failure must not kill the daemon
            log("cache gc failed: %s" % exc)


# -- entry point --------------------------------------------------------------


def parse_args(argv=None):
    p = argparse.ArgumentParser(
        prog="mirroret_cache.py",
        description="On-demand pull-through cache for package repositories.",
    )
    p.add_argument("--config", default="/etc/mirroret/cache.json",
                   help="route table (default: %(default)s)")
    p.add_argument("--cache-dir", default="/srv/mirroret/apt",
                   help="where cached files live (default: %(default)s)")
    p.add_argument("--listen", default="127.0.0.1:8082",
                   help="host:port to bind (default: %(default)s)")
    p.add_argument("--metadata-ttl", type=int, default=300,
                   help="seconds before revalidating an index (default: %(default)s)")
    p.add_argument("--max-size-gb", type=float, default=0,
                   help="evict least-recently-used packages above this size "
                        "(0 = no cap)")
    p.add_argument("--gc-interval", type=int, default=900,
                   help="seconds between eviction sweeps (default: %(default)s)")
    p.add_argument("--upstream-timeout", type=int, default=120,
                   help="seconds to wait on upstream (default: %(default)s)")
    p.add_argument("--ca-bundle", default=os.environ.get("MIRRORET_CA_BUNDLE", ""),
                   help="extra CA bundle, ADDED to the system trust store")
    p.add_argument("--insecure", action="store_true",
                   help="skip TLS verification (do not use in production)")
    p.add_argument("--offline", action="store_true",
                   help="never contact upstream; serve only what is cached")
    p.add_argument("--verbose", action="store_true", help="log every request")
    p.add_argument("--check", action="store_true",
                   help="validate config and exit without binding a port")
    return p.parse_args(argv)


def main(argv=None) -> int:
    args = parse_args(argv)

    routes = load_routes(args.config)

    if ":" not in args.listen:
        log("ERROR: --listen must be host:port, got %r" % args.listen)
        return EXIT_USAGE
    host, _, port_s = args.listen.rpartition(":")
    try:
        port = int(port_s)
    except ValueError:
        log("ERROR: --listen port is not a number: %r" % port_s)
        return EXIT_USAGE

    try:
        os.makedirs(args.cache_dir, exist_ok=True)
    except OSError as exc:
        log("ERROR: cannot create cache dir %s: %s" % (args.cache_dir, exc))
        return EXIT_CONFIG

    cache = Cache(args, routes)

    if args.check:
        log("config OK: %d route(s): %s"
            % (len(routes), ", ".join(sorted(routes))))
        for name in sorted(routes):
            log("  %-16s -> %s" % (name, routes[name].upstream))
        log("cache dir: %s (%.1f GB free)"
            % (cache.cache_dir, free_gb(cache.cache_dir)))
        return EXIT_OK

    handler = type("BoundHandler", (Handler,), {"cache": cache})

    # ThreadingHTTPServer only exists from Python 3.7; RHEL 8 ships 3.6,
    # so compose the same thing from the mixin that has always been there.
    class Server(socketserver.ThreadingMixIn, HTTPServer):
        daemon_threads = True
        allow_reuse_address = True

    try:
        httpd = Server((host, port), handler)
    except OSError as exc:
        if exc.errno == errno.EADDRINUSE:
            log("ERROR: %s is already in use.\n"
                "       Another mirroret-cache may be running: "
                "systemctl status mirroret-cache" % args.listen)
            return EXIT_CONFIG
        log("ERROR: cannot bind %s: %s" % (args.listen, exc))
        return EXIT_CONFIG

    # The GC thread always runs: even with no size cap it sweeps temp files
    # a killed writer left behind. evict_if_needed() itself is a no-op when
    # max_size_gb is 0.
    swept = cache.sweep_temp_files()
    if swept:
        log("startup: removed %d stale temp file(s) from a previous run" % swept)
    threading.Thread(
        target=eviction_loop, args=(cache, args.gc_interval), daemon=True
    ).start()

    log("mirroret cache listening on %s" % args.listen)
    log("  cache dir : %s" % cache.cache_dir)
    log("  routes    : %s" % ", ".join(sorted(routes)))
    log("  mode      : %s" % ("OFFLINE" if args.offline else "pull-through"))
    if args.max_size_gb > 0:
        log("  size cap  : %.1f GB (LRU eviction every %ds)"
            % (args.max_size_gb, args.gc_interval))
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        log("shutting down")
    return EXIT_OK


if __name__ == "__main__":
    sys.exit(main())

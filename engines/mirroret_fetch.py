#!/usr/bin/env python3
"""Shared HTTP fetch / verify / atomic-write helpers for the mirroret engines.

Stdlib only, on purpose. The mirror server is often a locked-down RHEL box
behind a proxy where `pip install` is not an option, and the whole point of
these engines is that they run on ANY host regardless of which package
manager it happens to use.

Everything here is deliberately conservative:

* Every download goes to a temp file and is renamed into place only after
  its checksum matches. A killed sync can never leave a truncated .deb or
  .rpm that a client later fails to install.
* Proxy configuration comes from the standard environment variables, so
  the generated sync scripts only have to export http_proxy/https_proxy
  (which mirroret_script_preamble already does).
* Retries are bounded and use exponential backoff. A flaky corporate
  proxy should slow a sync down, not fail it.
"""

import gzip
import hashlib
import http.client
import socket
import lzma
import os
import shutil
import ssl
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from typing import Optional

USER_AGENT = "mirroret/2 (+https://github.com/sarat1kyan/mirroret)"

# Exit codes shared by both engines so the generated shell wrappers and the
# tests can agree on what a failure means.
EXIT_OK = 0
EXIT_FAIL = 1
EXIT_USAGE = 2
EXIT_UPSTREAM = 5
EXIT_DISK = 4
EXIT_VERIFY = 6


class FetchError(Exception):
    """Raised when a URL could not be retrieved after all retries."""

    def __init__(self, url: str, reason: str, status: Optional[int] = None):
        super().__init__(f"{url}: {reason}")
        self.url = url
        self.reason = reason
        self.status = status


class VerifyError(Exception):
    """Raised when downloaded bytes do not match the advertised checksum."""


class TransferError(FetchError):
    """The connection opened fine but died mid-body. Retryable."""


# What a proxy or flaky link can throw out of resp.read() after a successful
# open. IncompleteRead (chunked truncation) is an HTTPException, not an
# OSError, which is why it has to be listed explicitly.
_TRANSFER_ERRORS = (OSError, http.client.HTTPException)

# createrepo emitted type="sha" for years to mean SHA-1; hashlib does not
# know that name and hashlib.new("sha") raises ValueError.
_ALGO_ALIASES = {"sha": "sha1", "sha-1": "sha1", "sha-256": "sha256",
                 "sha-512": "sha512", "md5sum": "md5"}


def normalize_algo(algo: Optional[str]) -> str:
    """Map repository checksum type names onto hashlib names."""
    name = (algo or "sha256").strip().lower()
    return _ALGO_ALIASES.get(name, name)


def log(msg: str) -> None:
    """Print immediately. Sync logs are tailed while the sync runs."""
    sys.stdout.write(msg + "\n")
    sys.stdout.flush()


# -- URL helpers -------------------------------------------------------------


def join_url(base: str, *parts: str) -> str:
    """Join URL fragments without collapsing or duplicating slashes.

    urllib.parse.urljoin is wrong here: it treats the base as a document
    and drops the last path segment, so joining
    ("http://h/repo/OL9/baseos", "repodata/repomd.xml") would silently
    become http://h/repo/OL9/repodata/repomd.xml.
    """
    out = base.rstrip("/")
    for part in parts:
        part = part.strip("/")
        if part:
            out = out + "/" + part
    return out


def build_opener(
    ca_bundle: Optional[str] = None,
    client_cert: Optional[str] = None,
    client_key: Optional[str] = None,
    insecure: bool = False,
):
    """Build a urllib opener honouring proxy env vars, a CA bundle and
    optional TLS client certificates (RHEL CDN entitlement certs)."""
    if insecure:
        ctx = ssl._create_unverified_context()  # noqa: SLF001 - explicit opt-in
    else:
        ctx = ssl.create_default_context()
        if ca_bundle:
            # ADD the bundle to the system trust store, do not replace it.
            # create_default_context(cafile=X) trusts ONLY X, so pointing
            # MIRRORET_CA_BUNDLE at a single corporate root - the natural
            # thing to do behind a TLS-inspecting proxy - would break every
            # upstream that is NOT re-signed by that proxy.
            try:
                ctx.load_verify_locations(cafile=ca_bundle)
            except (OSError, ssl.SSLError) as exc:
                raise SystemExit(
                    "ERROR: cannot load CA bundle %s: %s\n"
                    "       Check MIRRORET_CA_BUNDLE points at a readable "
                    "PEM file." % (ca_bundle, exc)
                )

    if client_cert:
        ctx.load_cert_chain(client_cert, client_key or client_cert)

    handlers = [
        urllib.request.HTTPSHandler(context=ctx),
        # ProxyHandler() with no argument reads http_proxy/https_proxy/no_proxy
        # from the environment, which is what the sync preamble exports.
        urllib.request.ProxyHandler(),
    ]
    opener = urllib.request.build_opener(*handlers)
    opener.addheaders = [("User-Agent", USER_AGENT)]
    return opener


class Fetcher:
    """Retrying HTTP client with checksum-verified atomic downloads."""

    def __init__(
        self,
        ca_bundle: Optional[str] = None,
        client_cert: Optional[str] = None,
        client_key: Optional[str] = None,
        insecure: bool = False,
        retries: int = 3,
        timeout: int = 60,
        backoff: float = 2.0,
    ):
        self.opener = build_opener(ca_bundle, client_cert, client_key, insecure)
        self.retries = max(1, retries)
        self.timeout = timeout
        self.backoff = backoff
        self.bytes_downloaded = 0

    # -- low level ----------------------------------------------------------

    def _open(self, url: str):
        last: Optional[Exception] = None
        for attempt in range(self.retries):
            try:
                return self.opener.open(url, timeout=self.timeout)
            except urllib.error.HTTPError as exc:
                # 4xx other than 408/429 will not get better by retrying.
                if exc.code not in (408, 429) and 400 <= exc.code < 500:
                    exc.close()
                    raise FetchError(url, f"HTTP {exc.code}", exc.code) from exc
                # A 5xx HTTPError is also a live response object; close it or
                # every retry leaks a socket until the run ends.
                exc.close()
                last = exc
            except urllib.error.URLError as exc:
                # Some failures are deterministic and retrying them only turns
                # one clear error into minutes of backoff per file: a CA the
                # bundle does not trust, or a hostname that does not resolve.
                reason = getattr(exc, "reason", None)
                if isinstance(reason, (ssl.SSLCertVerificationError, socket.gaierror)):
                    raise FetchError(url, f"{type(reason).__name__}: {reason}") from exc
                last = exc
            except ssl.SSLCertVerificationError as exc:
                raise FetchError(url, f"SSLCertVerificationError: {exc}") from exc
            except socket.gaierror as exc:
                raise FetchError(url, f"gaierror: {exc}") from exc
            except (TimeoutError, OSError) as exc:
                last = exc
            if attempt + 1 < self.retries:
                time.sleep(self.backoff * (2**attempt))
        status = getattr(last, "code", None)
        raise FetchError(url, f"{type(last).__name__}: {last}", status)

    def get_bytes(self, url: str, max_bytes: Optional[int] = None) -> bytes:
        """Retrieve a (small) URL fully into memory. For metadata only.

        The read is retried like the connect: a proxy resetting the
        connection halfway through InRelease must not take the whole run
        down with a raw ConnectionResetError.
        """
        last: Optional[Exception] = None
        for attempt in range(self.retries):
            try:
                with self._open(url) as resp:
                    data = resp.read(max_bytes) if max_bytes else resp.read()
                self.bytes_downloaded += len(data)
                return data
            except _TRANSFER_ERRORS as exc:
                last = exc
                if attempt + 1 < self.retries:
                    time.sleep(self.backoff * (2**attempt))
        raise FetchError(url, f"{type(last).__name__}: {last}")

    def exists(self, url: str) -> bool:
        try:
            self.get_bytes(url, max_bytes=1)
            return True
        except FetchError:
            return False

    def download(
        self,
        url,
        dest,
        checksum=None,
        algo="sha256",
        size=None,
        mode=0o644,
    ):
        """Download url to dest atomically, verifying checksum/size.

        Returns the number of bytes written. Raises FetchError or
        VerifyError; on either the destination is left untouched.

        A short read is retried like any other transport failure. That is
        not paranoia: a TLS-inspecting corporate proxy will happily hand
        back a truncated 135 MB primary.xml.gz with a 200 status, and
        without this a nightly sync fails the whole repository over one
        dropped connection.
        """
        os.makedirs(os.path.dirname(dest) or ".", exist_ok=True)
        last = None
        for attempt in range(self.retries):
            try:
                return self._download_once(url, dest, checksum, algo, size, mode)
            except (VerifyError, TransferError) as exc:
                # Both are "the bytes we got were wrong or incomplete": a
                # fresh attempt is the right response. A FetchError from
                # _open (404, bad certificate, DNS) has already been retried
                # where it makes sense and propagates untouched.
                last = exc
                if attempt + 1 < self.retries:
                    time.sleep(self.backoff * (2**attempt))
        raise last

    def _download_once(self, url, dest, checksum, algo, size, mode):
        tmp = "%s.mirroret-tmp.%d" % (dest, os.getpid())
        algo = normalize_algo(algo)
        try:
            digest = hashlib.new(algo) if checksum else None
        except ValueError:
            raise FetchError(
                url, "unsupported checksum algorithm %r in repository metadata" % algo
            )
        written = 0
        # When the expected size is known, stop reading once it is exceeded.
        # A server that keeps streaming past its declared Content-Length -
        # or a proxy injecting an error body into a chunked response - would
        # otherwise fill the filesystem with a single "download". The
        # oversize read is then caught by the size check below.
        limit = None if size is None else size + 1
        try:
            try:
                with self._open(url) as resp, open(tmp, "wb") as fh:
                    while True:
                        chunk = resp.read(1 << 16)
                        if not chunk:
                            break
                        fh.write(chunk)
                        written += len(chunk)
                        if digest is not None:
                            digest.update(chunk)
                        if limit is not None and written > limit:
                            raise VerifyError(
                                "%s: server sent more than the advertised %d bytes"
                                % (url, size)
                            )
            except FetchError:
                raise  # _open already classified it; do not re-wrap
            except _TRANSFER_ERRORS as exc:
                # Connection reset, read timeout, chunked truncation: the
                # transport died after a good open. Retryable, and it must
                # never surface as a raw exception - inside a worker pool
                # that would stall the whole run until every queued
                # download finished, then crash it.
                raise TransferError(url, "%s: %s" % (type(exc).__name__, exc)) from exc
            if size is not None and written != size:
                raise VerifyError(
                    "%s: size mismatch (expected %d, got %d)"
                    % (url, size, written)
                )
            if digest is not None and digest.hexdigest().lower() != checksum.lower():
                raise VerifyError(
                    "%s: %s mismatch (expected %s, got %s)"
                    % (url, algo, checksum.lower(), digest.hexdigest())
                )
            os.chmod(tmp, mode)
            os.replace(tmp, dest)
        except BaseException:
            try:
                os.unlink(tmp)
            except OSError:
                pass
            raise
        self.bytes_downloaded += written
        return written


# -- checksums ---------------------------------------------------------------


def file_digest(path: str, algo: str = "sha256") -> str:
    h = hashlib.new(normalize_algo(algo))
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def file_matches(path: str, checksum: Optional[str], algo: str, size: Optional[int]) -> bool:
    """True when path already holds exactly the wanted bytes.

    Size is checked first because it is free; the (expensive) hash is only
    computed when the size already agrees. With no checksum available the
    size alone is the best we can do, which is still enough to skip
    re-downloading a complete file.
    """
    try:
        st = os.stat(path)
    except OSError:
        return False
    if size is not None and st.st_size != size:
        return False
    if checksum:
        try:
            return file_digest(path, algo).lower() == checksum.lower()
        except (OSError, ValueError):
            # ValueError: an algorithm hashlib does not know. Treat the file
            # as not matching so it is re-fetched (and the fetch reports the
            # unsupported algorithm clearly) rather than crashing the run.
            return False
    return size is not None


def decompress(data: bytes, name: str) -> bytes:
    """Decompress by filename suffix. Plain data passes through."""
    if name.endswith(".gz"):
        return gzip.decompress(data)
    if name.endswith(".xz") or name.endswith(".lzma"):
        return lzma.decompress(data)
    if name.endswith(".bz2"):
        import bz2

        return bz2.decompress(data)
    if name.endswith(".zst") or name.endswith(".zstd"):
        # zstd has no stdlib decoder before Python 3.14; shell out if we can.
        return _zstd_decompress(data)
    return data


def _zstd_decompress(data):
    try:  # Python 3.14+
        from compression import zstd  # type: ignore[import-not-found]

        return zstd.decompress(data)
    except Exception:
        pass
    zstd_bin = shutil.which("zstd")
    if not zstd_bin:
        raise RuntimeError(
            "zstd-compressed metadata found but no zstd decoder available. "
            "Install the 'zstd' package on the mirror server."
        )
    import subprocess

    # stdout=PIPE rather than capture_output: the latter is 3.7+, and the
    # engines have to run on RHEL 8's default python3.6.
    return subprocess.run(
        [zstd_bin, "-d", "-c"], input=data,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True,
    ).stdout


# -- disk guard --------------------------------------------------------------


def free_gb(path: str) -> float:
    """Free gibibytes on the filesystem holding path (or its nearest parent)."""
    probe = os.path.abspath(path)
    while not os.path.exists(probe) and probe != "/":
        probe = os.path.dirname(probe)
    st = os.statvfs(probe)
    return (st.f_bavail * st.f_frsize) / float(1 << 30)


class DiskFloor:
    """Abort a sync before it fills the filesystem.

    reposync had no size cap, which is how a single run pulled multiple
    terabytes of source RPMs on this project's first production deploy.
    Every engine checks this between packages.
    """

    def __init__(self, path: str, min_free_gb: float):
        self.path = path
        self.min_free_gb = float(min_free_gb)

    def ok(self) -> bool:
        if self.min_free_gb <= 0:
            return True
        return free_gb(self.path) >= self.min_free_gb

    def require(self) -> None:
        if not self.ok():
            raise SystemExit(
                f"ABORT: only {free_gb(self.path):.1f} GB free on {self.path} "
                f"(floor: {self.min_free_gb} GB). Free space or raise "
                f"MIRRORET_SYNC_MIN_FREE_GB, then re-run."
            )


def human(nbytes: float) -> str:
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if abs(nbytes) < 1024 or unit == "TB":
            return f"{nbytes:.1f} {unit}" if unit != "B" else f"{int(nbytes)} B"
        nbytes /= 1024.0
    return f"{nbytes:.1f} TB"

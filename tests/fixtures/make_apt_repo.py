#!/usr/bin/env python3
"""Build a tiny but structurally real APT archive for the engine tests.

Usage: make_apt_repo.py <root> [--suite NAME] [--component C] [--arch A]
                        [--packages N] [--corrupt-pool PKG] [--drop-index]

The archive is a genuine one as far as apt's data model is concerned: a
Release listing SHA256 hashes of the indices, Packages files in both plain
and gzip form, and pool files whose recorded SHA256/Size actually match the
bytes on disk. That is what lets the tests assert real behaviour (hash
verification, publish ordering, pruning) instead of mocking it.
"""

import argparse
import gzip
import hashlib
import io
import os
import sys


def _gz(data):
    # GzipFile(mtime=0), not gzip.compress(mtime=0): the latter is 3.8+ and
    # these fixtures should run under the same interpreter range as the
    # engines they test.
    buf = io.BytesIO()
    with gzip.GzipFile(fileobj=buf, mode="wb", mtime=0) as fh:
        fh.write(data)
    return buf.getvalue()


def sha256_bytes(data):
    return hashlib.sha256(data).hexdigest()


def write(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as fh:
        fh.write(data)
    return data


def build(root, suite="testsuite", components=("main",), arches=("amd64",),
          count=3, corrupt_pool=None, drop_index=False, extra_pool=None,
          origin="Mirroret-Test"):
    root = os.path.abspath(root)
    index_entries = []  # (relpath-under-dists-suite, sha256, size)

    for comp in components:
        for arch in arches:
            paragraphs = []
            for i in range(count):
                name = "pkg%d" % i
                version = "1.%d" % i
                deb_rel = "pool/%s/%s/%s/%s_%s_%s.deb" % (
                    comp, name[0], name, name, version, arch)
                payload = ("fake deb payload for %s %s %s %s\n" % (
                    comp, arch, name, version)).encode() * 8
                write(os.path.join(root, deb_rel), payload)
                digest = sha256_bytes(payload)
                if corrupt_pool == name:
                    # Advertise a hash that does not match the bytes on disk.
                    # A correct mirror must refuse this package.
                    digest = "0" * 64
                paragraphs.append(
                    "Package: %s\n"
                    "Version: %s\n"
                    "Architecture: %s\n"
                    "Maintainer: Mirroret Tests <test@example.invalid>\n"
                    "Filename: %s\n"
                    "Size: %d\n"
                    "SHA256: %s\n"
                    "Description: fixture package %s\n"
                    % (name, version, arch, deb_rel, len(payload), digest, name)
                )
            packages = ("\n".join(paragraphs) + "\n").encode()
            base = "%s/binary-%s/Packages" % (comp, arch)
            if not drop_index:
                plain = write(os.path.join(root, "dists", suite, base), packages)
                index_entries.append((base, sha256_bytes(plain), len(plain)))
            gz = _gz(packages)
            write(os.path.join(root, "dists", suite, base + ".gz"), gz)
            index_entries.append((base + ".gz", sha256_bytes(gz), len(gz)))

            comp_release = (
                "Archive: %s\nComponent: %s\nArchitecture: %s\n"
                % (suite, comp, arch)
            ).encode()
            rel = "%s/binary-%s/Release" % (comp, arch)
            write(os.path.join(root, "dists", suite, rel), comp_release)
            index_entries.append((rel, sha256_bytes(comp_release), len(comp_release)))

        i18n = ("Package: pkg0\nDescription-md5: 0\nDescription-en: fixture\n").encode()
        rel = "%s/i18n/Translation-en" % comp
        write(os.path.join(root, "dists", suite, rel), i18n)
        index_entries.append((rel, sha256_bytes(i18n), len(i18n)))

    # A pool file that no index references - the prune test target.
    if extra_pool:
        write(os.path.join(root, extra_pool), b"orphaned payload\n")

    lines = [
        "Origin: %s" % origin,
        "Label: %s" % origin,
        "Suite: %s" % suite,
        "Codename: %s" % suite,
        "Architectures: %s" % " ".join(arches),
        "Components: %s" % " ".join(components),
        "Description: mirroret test fixture",
        "Date: Thu, 01 Jan 2026 00:00:00 UTC",
        "SHA256:",
    ]
    for path, digest, size in index_entries:
        lines.append(" %s %d %s" % (digest, size, path))
    release = ("\n".join(lines) + "\n").encode()
    write(os.path.join(root, "dists", suite, "Release"), release)
    return root


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("root")
    ap.add_argument("--suite", default="testsuite")
    ap.add_argument("--component", action="append")
    ap.add_argument("--arch", action="append")
    ap.add_argument("--packages", type=int, default=3)
    ap.add_argument("--corrupt-pool")
    ap.add_argument("--drop-index", action="store_true")
    ap.add_argument("--extra-pool")
    a = ap.parse_args()
    build(a.root, a.suite, tuple(a.component or ["main"]), tuple(a.arch or ["amd64"]),
          a.packages, a.corrupt_pool, a.drop_index, a.extra_pool)
    print(a.root)
    return 0


if __name__ == "__main__":
    sys.exit(main())

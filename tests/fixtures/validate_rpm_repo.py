#!/usr/bin/env python3
"""Assert that a mirrored yum repository is internally consistent.

This is the check that matters for a mirror: not "did the sync exit 0" but
"would a dnf client be able to resolve and download every package the
metadata advertises". It verifies

  * every file repomd.xml references exists, with matching checksum/size
    and (for XML) matching open-checksum/open-size,
  * every package primary.xml lists is on disk at exactly the advertised
    location, with the advertised sha256,
  * filelists/other describe the same package set as primary,
  * no .rpm on disk is missing from the metadata.

Exit status 0 = consistent.
"""

import bz2
import gzip
import hashlib
import lzma
import os
import sys
import xml.etree.ElementTree as ET

REPO = "{http://linux.duke.edu/metadata/repo}"
COMMON = "{http://linux.duke.edu/metadata/common}"
FILELISTS = "{http://linux.duke.edu/metadata/filelists}"
OTHER = "{http://linux.duke.edu/metadata/other}"


def uncompress(raw, href):
    if href.endswith(".gz"):
        return gzip.decompress(raw)
    if href.endswith(".bz2"):
        return bz2.decompress(raw)
    if href.endswith(".xz"):
        return lzma.decompress(raw)
    return raw


def main(repo):
    problems = []
    repodata = os.path.join(repo, "repodata")
    root = ET.parse(os.path.join(repodata, "repomd.xml")).getroot()
    types = []
    for data in root.findall(REPO + "data"):
        type_ = data.get("type")
        types.append(type_)
        href = data.find(REPO + "location").get("href")
        path = os.path.join(repo, href)
        if not os.path.exists(path):
            problems.append("repomd references a missing file: %s" % href)
            continue
        with open(path, "rb") as fh:
            raw = fh.read()
        csum = data.find(REPO + "checksum")
        if hashlib.new(csum.get("type"), raw).hexdigest() != csum.text.strip():
            problems.append("%s: checksum mismatch" % type_)
        size = data.find(REPO + "size")
        if size is not None and int(size.text) != len(raw):
            problems.append("%s: size mismatch" % type_)
        plain = uncompress(raw, href)
        ocsum = data.find(REPO + "open-checksum")
        if ocsum is not None:
            if hashlib.new(ocsum.get("type"), plain).hexdigest() != ocsum.text.strip():
                problems.append("%s: open-checksum mismatch" % type_)
        osize = data.find(REPO + "open-size")
        if osize is not None and int(osize.text) != len(plain):
            problems.append("%s: open-size mismatch" % type_)
        # sqlite variants are binary; only the XML ones are parseable.
        if ".sqlite" not in href and ".yaml" not in href and ".tar" not in href:
            try:
                ET.fromstring(plain)
            except ET.ParseError as exc:
                problems.append("%s: not valid XML (%s)" % (type_, exc))

    primary = root.find(REPO + 'data[@type="primary"]')
    if primary is None:
        problems.append("repomd has no primary metadata")
        return report(repo, types, 0, problems)

    href = primary.find(REPO + "location").get("href")
    with open(os.path.join(repo, href), "rb") as fh:
        plain = uncompress(fh.read(), href)
    tree = ET.fromstring(plain)

    listed = set()
    pkgids = set()
    count = 0
    for pkg in tree.findall(COMMON + "package"):
        count += 1
        loc = pkg.find(COMMON + "location").get("href")
        want = pkg.find(COMMON + "checksum").text.strip()
        pkgids.add(want)
        full = os.path.join(repo, loc)
        listed.add(os.path.normpath(full))
        if not os.path.exists(full):
            problems.append("primary lists a package that is not on disk: %s" % loc)
            continue
        with open(full, "rb") as fh:
            got = hashlib.sha256(fh.read()).hexdigest()
        if got != want:
            problems.append("package checksum mismatch: %s" % loc)

    for type_, ns in (("filelists", FILELISTS), ("other", OTHER)):
        node = root.find(REPO + 'data[@type="%s"]' % type_)
        if node is None:
            continue
        href = node.find(REPO + "location").get("href")
        with open(os.path.join(repo, href), "rb") as fh:
            doc = ET.fromstring(uncompress(fh.read(), href))
        ids = set(p.get("pkgid") for p in doc.findall(ns + "package"))
        if ids != pkgids:
            problems.append(
                "%s describes a different package set than primary (%d vs %d)"
                % (type_, len(ids), len(pkgids))
            )

    for dirpath, _dirs, files in os.walk(repo):
        for name in files:
            if not name.endswith(".rpm"):
                continue
            full = os.path.normpath(os.path.join(dirpath, name))
            if full not in listed:
                problems.append(
                    "rpm on disk is absent from the metadata: %s"
                    % os.path.relpath(full, repo)
                )

    return report(repo, types, count, problems)


def report(repo, types, count, problems):
    print("%s: %d packages, repodata: %s"
          % (repo, count, ",".join(sorted(types))))
    for p in problems:
        print("  PROBLEM: %s" % p)
    print("  %s" % ("CONSISTENT" if not problems else
                    "%d PROBLEM(S)" % len(problems)))
    return 1 if problems else 0


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("usage: validate_rpm_repo.py <repo-dir>", file=sys.stderr)
        sys.exit(2)
    sys.exit(main(sys.argv[1]))

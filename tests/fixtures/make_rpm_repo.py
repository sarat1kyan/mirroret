#!/usr/bin/env python3
"""Build a small but structurally real yum/dnf repository for the tests.

The repodata is the real thing: a repomd.xml whose checksums and open-sizes
match the primary/filelists/other it points at, and primary records whose
sha256 and size match the (fake) rpm payloads on disk. That is what makes
the engine tests meaningful - they exercise the same verification, arch
filtering, newest-only selection and metadata-rewrite paths that a real
Rocky or Oracle repo would.
"""

import argparse
import gzip
import hashlib
import os
import sys
import time

COMMON_NS = "http://linux.duke.edu/metadata/common"
RPM_NS = "http://linux.duke.edu/metadata/rpm"
FL_NS = "http://linux.duke.edu/metadata/filelists"
OTHER_NS = "http://linux.duke.edu/metadata/other"
REPO_NS = "http://linux.duke.edu/metadata/repo"

# (name, version, release, arch)
DEFAULT_PACKAGES = [
    ("bash", "5.1.8", "6.el9", "x86_64"),
    ("bash", "5.1.8", "9.el9", "x86_64"),          # newer release
    ("glibc", "2.34", "100.el9", "x86_64"),
    ("glibc", "2.34", "100.el9", "i686"),          # multilib
    ("tzdata", "2025a", "1.el9", "noarch"),
    ("kernel", "5.14.0", "500.el9", "x86_64"),
    ("kernel", "5.14.0", "70.el9", "x86_64"),      # older (70 < 500)
    ("oldpkg", "1.0", "1.el9", "src"),
]


def write(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as fh:
        fh.write(data)
    return data


def gz(data):
    import io
    buf = io.BytesIO()
    with gzip.GzipFile(fileobj=buf, mode="wb", mtime=0) as fh:
        fh.write(data)
    return buf.getvalue()


def build(root, packages=None, corrupt=None, epoch_map=None):
    root = os.path.abspath(root)
    packages = packages or DEFAULT_PACKAGES
    epoch_map = epoch_map or {}
    primary_pkgs, fl_pkgs, other_pkgs = [], [], []

    for name, version, release, arch in packages:
        filename = "%s-%s-%s.%s.rpm" % (name, version, release, arch)
        payload = ("fake rpm %s\n" % filename).encode() * 16
        write(os.path.join(root, "Packages", filename), payload)
        digest = hashlib.sha256(payload).hexdigest()
        advertised = "0" * 64 if corrupt == name else digest
        epoch = epoch_map.get(name, "0")
        primary_pkgs.append(
            '<package type="rpm">\n'
            '  <name>%s</name>\n'
            '  <arch>%s</arch>\n'
            '  <version epoch="%s" ver="%s" rel="%s"/>\n'
            '  <checksum type="sha256" pkgid="YES">%s</checksum>\n'
            '  <summary>fixture %s</summary>\n'
            '  <description>fixture package</description>\n'
            '  <packager></packager>\n'
            '  <url></url>\n'
            '  <time file="1700000000" build="1700000000"/>\n'
            '  <size package="%d" installed="%d" archive="%d"/>\n'
            '  <location href="Packages/%s"/>\n'
            '  <format>\n'
            '    <rpm:license>MIT</rpm:license>\n'
            '    <rpm:vendor>Mirroret Tests</rpm:vendor>\n'
            '    <rpm:group>Unspecified</rpm:group>\n'
            '    <rpm:sourcerpm>%s-%s-%s.src.rpm</rpm:sourcerpm>\n'
            '    <rpm:provides><rpm:entry name="%s"/></rpm:provides>\n'
            '  </format>\n'
            '</package>'
            % (name, arch, epoch, version, release, advertised, name,
               len(payload), len(payload), len(payload), filename,
               name, version, release, name)
        )
        fl_pkgs.append(
            '<package pkgid="%s" name="%s" arch="%s">\n'
            '  <version epoch="%s" ver="%s" rel="%s"/>\n'
            '  <file>/usr/bin/%s</file>\n'
            '</package>' % (advertised, name, arch, epoch, version, release, name)
        )
        other_pkgs.append(
            '<package pkgid="%s" name="%s" arch="%s">\n'
            '  <version epoch="%s" ver="%s" rel="%s"/>\n'
            '  <changelog author="tests" date="1700000000">fixture</changelog>\n'
            '</package>' % (advertised, name, arch, epoch, version, release)
        )

    docs = {
        "primary": (
            '<?xml version="1.0" encoding="UTF-8"?>\n'
            '<metadata xmlns="%s" xmlns:rpm="%s" packages="%d">\n%s\n</metadata>\n'
            % (COMMON_NS, RPM_NS, len(primary_pkgs), "\n".join(primary_pkgs))
        ),
        "filelists": (
            '<?xml version="1.0" encoding="UTF-8"?>\n'
            '<filelists xmlns="%s" packages="%d">\n%s\n</filelists>\n'
            % (FL_NS, len(fl_pkgs), "\n".join(fl_pkgs))
        ),
        "other": (
            '<?xml version="1.0" encoding="UTF-8"?>\n'
            '<otherdata xmlns="%s" packages="%d">\n%s\n</otherdata>\n'
            % (OTHER_NS, len(other_pkgs), "\n".join(other_pkgs))
        ),
    }

    # A package-independent metadata file, to prove it is passed through.
    comps = b'<?xml version="1.0"?><comps><group><id>core</id></group></comps>\n'
    comps_gz = gz(comps)
    write(os.path.join(root, "repodata", "comps.xml.gz"), comps_gz)

    entries = []
    for type_, text in docs.items():
        plain = text.encode()
        blob = gz(plain)
        href = "repodata/%s.xml.gz" % type_
        write(os.path.join(root, href), blob)
        entries.append(
            '  <data type="%s">\n'
            '    <checksum type="sha256">%s</checksum>\n'
            '    <open-checksum type="sha256">%s</open-checksum>\n'
            '    <location href="%s"/>\n'
            '    <timestamp>%d</timestamp>\n'
            '    <size>%d</size>\n'
            '    <open-size>%d</open-size>\n'
            '  </data>'
            % (type_, hashlib.sha256(blob).hexdigest(),
               hashlib.sha256(plain).hexdigest(), href, int(time.time()),
               len(blob), len(plain))
        )
    entries.append(
        '  <data type="group_gz">\n'
        '    <checksum type="sha256">%s</checksum>\n'
        '    <open-checksum type="sha256">%s</open-checksum>\n'
        '    <location href="repodata/comps.xml.gz"/>\n'
        '    <timestamp>%d</timestamp>\n'
        '    <size>%d</size>\n'
        '    <open-size>%d</open-size>\n'
        '  </data>'
        % (hashlib.sha256(comps_gz).hexdigest(), hashlib.sha256(comps).hexdigest(),
           int(time.time()), len(comps_gz), len(comps))
    )

    repomd = (
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<repomd xmlns="%s" xmlns:rpm="%s">\n'
        '  <revision>1700000000</revision>\n%s\n</repomd>\n'
        % (REPO_NS, RPM_NS, "\n".join(entries))
    )
    write(os.path.join(root, "repodata", "repomd.xml"), repomd.encode())
    return root


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("root")
    ap.add_argument("--corrupt", help="advertise a bad sha256 for this package")
    a = ap.parse_args()
    build(a.root, corrupt=a.corrupt)
    print(a.root)
    return 0


if __name__ == "__main__":
    sys.exit(main())

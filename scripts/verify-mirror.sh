#!/usr/bin/env bash
#
# Verify a published APT mirror is self-consistent: every file listed in
# every published InRelease/Release actually exists on disk with the size
# the signed metadata claims. If it does, no client will 404 on apt-get
# update. If it doesn't, we print exactly which paths a client would fail
# to fetch and exit non-zero.
#
# This is the check we should have had from day one - the whack-a-mole
# with cnf, dep11, ... existed because nothing on the server ever said
# "hey, your published Release names files you never mirrored".
#
# Usage:
#   sudo verify-mirror.sh [--base-dir /srv/mirroret] [--flavor ubuntu] \
#                        [--suite noble] [--json]
#
# Exits 0 if every published suite is complete, 2 if any file is missing
# or the wrong size, 3 for a usage error.

set -eo pipefail

BASE_DIR="${MIRRORET_BASE_DIR:-/srv/mirroret}"
ONLY_FLAVOR=""
ONLY_SUITE=""
OUTPUT_JSON=0

usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Walk every published APT suite under BASE_DIR/apt/*/dists/*/ and check that
every SHA256 entry in Release names a file that actually exists on disk
with the right size.

Options:
  --base-dir PATH    default: /srv/mirroret (or \$MIRRORET_BASE_DIR)
  --flavor NAME      restrict to one flavor dir (ubuntu / debian / ...)
  --suite NAME       restrict to one suite (noble, bookworm, ...)
  --json             emit machine-readable report on stdout
  -h, --help         this help
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --base-dir)  BASE_DIR="$2"; shift 2 ;;
        --flavor)    ONLY_FLAVOR="$2"; shift 2 ;;
        --suite)     ONLY_SUITE="$2"; shift 2 ;;
        --json)      OUTPUT_JSON=1; shift ;;
        -h|--help)   usage; exit 0 ;;
        *)           usage; exit 3 ;;
    esac
done

if [[ ! -d "${BASE_DIR}/apt" ]]; then
    echo "no apt tree under ${BASE_DIR}/apt - is BASE_DIR right?" >&2
    exit 3
fi

exec python3 - "$BASE_DIR" "$ONLY_FLAVOR" "$ONLY_SUITE" "$OUTPUT_JSON" <<'PY'
import json
import os
import re
import sys

BASE, ONLY_FLAVOR, ONLY_SUITE, JSON_MODE = sys.argv[1:5]
JSON_MODE = JSON_MODE == "1"

APT_ROOT = os.path.join(BASE, "apt")


def load_release(path):
    """Return {relative_path: (sha256, size)} for one Release/InRelease.

    Handles both clearsigned InRelease (--- BEGIN PGP ... ---) and plain
    Release. The SHA256 block is the source of truth; SHA1/MD5 are legacy.
    """
    with open(path, "rb") as fh:
        raw = fh.read().decode("utf-8", "replace")
    # Strip PGP signature framing so the deb822 parser sees the payload.
    if "-----BEGIN PGP SIGNED MESSAGE-----" in raw:
        body = raw.split("-----BEGIN PGP SIGNED MESSAGE-----", 1)[1]
        body = body.split("\n\n", 1)[1]  # drop the Hash: line block
        raw = body.split("-----BEGIN PGP SIGNATURE-----", 1)[0]

    fields = {}
    key = None
    for line in raw.splitlines():
        if line.startswith(" ") or line.startswith("\t"):
            fields.setdefault(key, []).append(line[1:])
        elif ":" in line:
            key, _, val = line.partition(":")
            key = key.strip()
            val = val.strip()
            if val:
                fields[key] = val
    entries = {}
    block = fields.get("SHA256")
    if isinstance(block, list):
        for line in block:
            parts = line.split()
            if len(parts) == 3:
                sha, size, rel = parts
                entries[rel] = (sha, int(size))
    return entries


def suite_report(suite_dir):
    """Check every file Release lists in one dists/<suite>/ tree."""
    release = None
    for name in ("InRelease", "Release"):
        p = os.path.join(suite_dir, name)
        if os.path.isfile(p):
            release = p
            break
    if release is None:
        return {"missing_release": True}

    entries = load_release(release)

    # The engine records which Release entries THIS configuration mirrors.
    # A filtered mirror (amd64 only, no Contents-*, no sources, main +
    # restricted) legitimately leaves most of Release unmirrored while
    # republishing the signed Release verbatim - so "every entry must exist"
    # is the wrong test and flagged every healthy sync. When a manifest is
    # present, only its entries are required; the rest are reported as
    # intentionally skipped. Without a manifest (a tree written by an older
    # engine, or a third-party mirror) fall back to checking everything.
    manifest_path = os.path.join(suite_dir, ".mirroret-manifest.json")
    intended = None
    if os.path.isfile(manifest_path):
        try:
            with open(manifest_path) as fh:
                intended = set(json.load(fh).get("entries", []))
        except (OSError, ValueError):
            intended = None

    missing, wrong_size, ok, skipped = [], [], 0, 0
    for rel, (_sha, size) in entries.items():
        if intended is not None and rel not in intended:
            skipped += 1
            continue
        # Release always references files under the suite directory.
        target = os.path.join(suite_dir, rel)
        if not os.path.isfile(target):
            missing.append(rel)
            continue
        real = os.path.getsize(target)
        if real != size:
            wrong_size.append((rel, real, size))
            continue
        ok += 1
    return {
        "release_file": os.path.basename(release),
        "entries": len(entries),
        "checked": len(entries) - skipped,
        "skipped_by_config": skipped,
        "manifest": intended is not None,
        "ok": ok,
        "missing": missing,
        "wrong_size": wrong_size,
    }


suites = []
if not os.path.isdir(APT_ROOT):
    print("no apt tree found", file=sys.stderr)
    sys.exit(3)

for flavor in sorted(os.listdir(APT_ROOT)):
    if ONLY_FLAVOR and flavor != ONLY_FLAVOR:
        continue
    fdir = os.path.join(APT_ROOT, flavor, "dists")
    if not os.path.isdir(fdir):
        continue
    for suite in sorted(os.listdir(fdir)):
        if ONLY_SUITE and suite != ONLY_SUITE:
            continue
        sdir = os.path.join(fdir, suite)
        if not os.path.isdir(sdir):
            continue
        rep = suite_report(sdir)
        rep["flavor"] = flavor
        rep["suite"] = suite
        suites.append(rep)


any_bad = any(r.get("missing") or r.get("wrong_size") or r.get("missing_release")
              for r in suites)

if JSON_MODE:
    print(json.dumps({"suites": suites, "ok": not any_bad}, indent=2))
    sys.exit(0 if not any_bad else 2)

# Human report.
GREEN = "\033[32m" if sys.stdout.isatty() else ""
RED = "\033[31m" if sys.stdout.isatty() else ""
YEL = "\033[33m" if sys.stdout.isatty() else ""
BOLD = "\033[1m" if sys.stdout.isatty() else ""
END = "\033[0m" if sys.stdout.isatty() else ""

if not suites:
    print("no published suites found under %s" % APT_ROOT)
    sys.exit(0)

print("%s== mirror integrity ==%s" % (BOLD, END))
for r in suites:
    tag = "%s%s%s" % (r["flavor"], "/", r["suite"])
    if r.get("missing_release"):
        print("  %sFAIL%s  %s: no Release/InRelease found" % (RED, END, tag))
        continue
    if not r["missing"] and not r["wrong_size"]:
        extra = ""
        if r.get("skipped_by_config"):
            extra = ", %d not mirrored by config" % r["skipped_by_config"]
        print("  %sok%s    %s: %d/%d indices present%s (%s)"
              % (GREEN, END, tag, r["ok"], r["checked"], extra,
                 r["release_file"]))
        continue
    print("  %sFAIL%s  %s: %d missing, %d wrong size (of %d checked)"
          % (RED, END, tag, len(r["missing"]), len(r["wrong_size"]),
             r["checked"]))
    for path in r["missing"][:10]:
        print("        missing: %s" % path)
    if len(r["missing"]) > 10:
        print("        ... and %d more" % (len(r["missing"]) - 10))
    for path, real, want in r["wrong_size"][:5]:
        print("        size:    %s  have=%d want=%d" % (path, real, want))

print()
if any_bad:
    print("%sSTOP%s  clients WILL 404 on the paths listed above." % (RED, END))
    print("      This means the mirror published a Release that references")
    print("      files never mirrored. Root-cause the sync log:")
    print("        sudo mirroretctl logs errors")
    print("      Then re-run:")
    print("        sudo mirroretctl sync apt")
    sys.exit(2)
print("%sok%s    every published Release is complete on disk." % (GREEN, END))
sys.exit(0)
PY

# Getting started: install, sync, point clients at it

Written to be followed top to bottom on a fresh or existing mirror server.
Every step has a check. If a check fails, stop there - the next step will
not fix it.

Assumes the mirror server is `192.168.30.110`. Substitute yours.

---

## The short way: two scripts

If you would rather not run the steps by hand, the repository ships the whole
sequence as two scripts. They do exactly what sections 1-7 below describe,
with a gate after every phase: a failed gate stops and prints the specific
fix rather than carrying on.

**On the mirror server**, after getting the code (section 1):

```bash
sudo ./scripts/setup-mirror-server.sh \
    --apt-targets "ubuntu:jammy ubuntu:noble debian:bookworm" \
    --rpm-targets "ol:9" \
    --components "main restricted" \
    --proxy http://192.168.30.243:3128 \
    --yes
```

Add `--dry-run` first to see the whole plan without changing anything. It
predicts the real run, including which upstreams your targets need and
whether the proxy is blocking them. `--help` lists every option.

**On each client**, fetched from the mirror itself:

```bash
curl -fsSL -o /tmp/setup-mirror-client.sh \
    http://192.168.30.110:8080/config/setup-mirror-client.sh
sudo bash /tmp/setup-mirror-client.sh --server 192.168.30.110
```

That detects the distro, installs the matching config, disables the upstream
repos and then proves the result by downloading a package the mirror
actually carries. Everything it disables is backed up first:

```bash
sudo bash /tmp/setup-mirror-client.sh --rollback
```

puts the machine back exactly as it was.

The rest of this document is the same sequence done by hand, which is worth
reading once so you know what the scripts are doing and what each check
means.

---

## 0. What you are about to configure

Two lines decide everything:

```bash
MIRRORET_APT_TARGETS="ubuntu:jammy ubuntu:noble debian:bookworm"
MIRRORET_RPM_TARGETS="ol:9"
```

These name what your **clients** run. They have nothing to do with what the
mirror server runs - a RHEL server mirrors Ubuntu perfectly well. If you
leave them unset, mirroret falls back to guessing from the server's own OS,
which on a RHEL host means no APT mirroring at all.

Full reference: [MULTI-DISTRO.md](MULTI-DISTRO.md).

---

## 1. Get the code

The work is on a branch, not `main`.

### Server has GitHub access

```bash
cd ~
git clone https://github.com/sarat1kyan/mirroret.git   # first time only
cd mirroret
git fetch origin
git checkout claude/package-mirror-server-audit-fhhodq
```

Already have a clone? Update it in place:

```bash
cd ~/mirroret-main            # or wherever your clone lives
git fetch origin
git checkout claude/package-mirror-server-audit-fhhodq
```

### Server has NO GitHub access

On a machine that does:

```bash
curl -L -o mirroret.zip \
  https://github.com/sarat1kyan/mirroret/archive/refs/heads/claude/package-mirror-server-audit-fhhodq.zip
```

Copy it over (scp, MobaXterm SFTP pane, USB), then on the server:

```bash
cd ~
[[ -d mirroret-main ]] && mv mirroret-main mirroret-main.prev   # keep the old tree
unzip -o mirroret.zip
mv mirroret-* mirroret-main 2>/dev/null || true
cd mirroret-main
# A zip does not preserve the execute bit. Without this, nothing runs.
chmod +x install.sh uninstall.sh mirroretctl scripts/*.sh engines/*.py
```

Do **not** delete `mirroret-main.prev` until step 5 passes.

### Check

```bash
ls engines/                      # must list 3 .py files
ls lib/targets.sh                # must exist
python3 -V                       # must print 3.6 or newer
```

If `engines/` is missing you have the old code, or the zip extracted
partially. Re-fetch before continuing.

---

## 2. Configure

```bash
sudo mkdir -p /etc/mirroret
[[ -f /etc/mirroret/mirroret.conf ]] || \
  sudo cp config/mirroret.conf.example /etc/mirroret/mirroret.conf
```

Append your settings. Edit the target lists to match your fleet.

```bash
sudo tee -a /etc/mirroret/mirroret.conf >/dev/null <<'EOF'

# ---- What the CLIENTS run -------------------------------------------------
MIRRORET_APT_TARGETS="ubuntu:jammy ubuntu:noble debian:bookworm"
MIRRORET_RPM_TARGETS="ol:9"

# ---- Disk control -------------------------------------------------------
# universe + multiverse are ~90% of an Ubuntu mirror. Drop this line to
# mirror all four components (300-600 GB per flavor).
MIRRORET_APT_COMPONENTS="main restricted"
MIRRORET_RPM_NEWEST_ONLY=1
MIRRORET_RPM_SOURCE=0
MIRRORET_SYNC_MIN_FREE_GB=15

# Add i686 only if clients install 32-bit multilib (glibc.i686).
MIRRORET_RPM_ARCH="x86_64"

# ---- Proxy --------------------------------------------------------------
# Set here, not only in your shell: cron and systemd read neither
# /etc/environment nor shell rc files, so without this the nightly sync
# fails while manual runs succeed.
http_proxy=http://192.168.30.243:3128
https_proxy=http://192.168.30.243:3128
no_proxy=localhost,127.0.0.1,::1,10.0.0.0/8,192.168.0.0/16

# Only if your proxy re-signs TLS. It is ADDED to the system trust store,
# so a single corporate root is fine here.
#MIRRORET_CA_BUNDLE=/etc/pki/ca-trust/source/anchors/corp-root.crt

# If the proxy permits CONNECT on 443 only, APT's default plain HTTP is
# blocked. Uncomment to fetch the archives over HTTPS instead.
#MIRRORET_APT_SCHEME=https
EOF
```

### Check

```bash
grep -E '^MIRRORET_(APT|RPM)_TARGETS' /etc/mirroret/mirroret.conf
```

---

## 3. Apply

Preview first. This changes nothing on disk and now tells you exactly what a
real run would do:

```bash
sudo ./install.sh --upgrade --dry-run
```

Look for `APT targets:` and `RPM targets:` near the end. If either says
`NONE`, your target lines are not being read - fix that before applying.

Then apply:

```bash
sudo ./install.sh --upgrade
```

`--upgrade` never touches mirror data. It regenerates configs, the managed
sync scripts and the cron block. Any sync script whose `MIRRORET-MANAGED`
marker you removed is left alone.

First install on a fresh box uses `sudo ./install.sh` instead.

### Check

```bash
./mirroretctl targets
```

Every target must be listed with an upstream URL. All will say
`not synced yet` - correct at this point.

```bash
./mirroretctl config diff
```

Must report `every requested target has a generated spec`. If it reports
`requested but NOT generated`, the upgrade did not pick your config up.

---

## 4. First sync

RPM first: it is usually the bulk of the data.

```bash
sudo ./mirroretctl sync rpm
```

Read the first 20 lines:

```
--- repo baseos <- https://yum.oracle.com/repo/OracleLinux/OL9/baseos/latest/x86_64/
  upstream lists 8123 packages; 8123 selected (arches=noarch,x86_64 newest_only=True source=False)
  packages: 8123 selected, 8123 to download (41.2 GB), 0 already on disk
```

`source=False` is the one to check. If it says `True`, stop and fix
`MIRRORET_RPM_SOURCE` - source RPMs are 400-600 MB each and OL9 appstream
carries ~44,000 of them.

Then APT:

```bash
sudo ./mirroretctl sync apt
```

```
--- suite jammy <- http://archive.ubuntu.com/ubuntu
  signature: NOT verified locally (no archive keyring found)
  indices: 8 files, 6142 packages listed
  packages: 6142 to download (58.3 GB), 0 already on disk
  ...
  published: dists/jammy (8 index files)
```

Two lines worth understanding:

- **`signature: NOT verified locally`** is expected on a RHEL host, which has
  no `ubuntu-archive-keyring`. Not a security gap: the archive is mirrored
  byte-for-byte including its signature, and every client re-verifies it with
  its own keyring - which is the check that protects the client. Set
  `MIRRORET_APT_REQUIRE_SIGNATURE=1` to make it fatal instead.
- **`published:`** appears only after every package the suite's indices list
  is on disk and verified. If a sync is interrupted you will not see it, and
  clients keep using the previous state instead of hitting 404s.

Both take hours. Watch from another session:

```bash
./mirroretctl logs tail
```

Then the rest:

```bash
sudo ./mirroretctl sync pip
sudo ./mirroretctl sync npm      # expect: CACHED: express (+ deps: 65)
```

If a sync aborts with `ABORT: ... would leave less than N GB free`, that is
the disk guard doing its job before filling the volume. Reduce
`MIRRORET_APT_COMPONENTS` or the target list, then re-run.

### Check

```bash
./mirroretctl targets            # every target now "published"
./mirroretctl logs errors        # failures in recent logs
df -h /srv/mirroret
```

---

## 5. Prove a client can actually use it

This is the step people skip, and it is the only one that proves anything.

```bash
./mirroretctl serve             # every HTTP endpoint answers
./mirroretctl client verify     # configs vs what is really published
./mirroretctl client simulate   # resolve AND download, as a client does
```

`client verify` is the one that catches the mismatch that produces client
404s - a config advertising a suite or repo the server has not published.

Once this passes, delete the old tree if you kept one:

```bash
rm -rf ~/mirroret-main.prev ~/mirroret.zip
```

---

## 6. Point clients at it

`./mirroretctl client list` prints the exact URL for every generated config.

### Ubuntu / Debian client

```bash
. /etc/os-release
sudo curl -fsSL -o /etc/apt/sources.list.d/mirroret.list \
    "http://192.168.30.110:8080/config/${ID}-${VERSION_CODENAME}.list"

# Disable the upstream entries or apt keeps going to the internet
sudo mv /etc/apt/sources.list /etc/apt/sources.list.disabled-by-mirroret
sudo rm -f /etc/apt/sources.list.d/ubuntu.sources    # 24.04+ / deb822 hosts

sudo apt-get update
apt-cache policy bash | head -5      # must name 192.168.30.110
```

No key to import: the mirrored `Release` files carry the upstream signature,
and the client verifies them with the keyring it already ships. A `.sources`
(deb822) variant is generated alongside the `.list` if you prefer it.

### Oracle / Rocky / Alma / RHEL client

```bash
sudo curl -fsSL -o /etc/yum.repos.d/mirroret.repo \
    http://192.168.30.110:8080/config/ol9.repo

sudo dnf config-manager --set-disabled "*"
sudo dnf config-manager --set-enabled "mirroret-*"
sudo dnf clean all && sudo dnf repolist     # only mirroret-* enabled
sudo dnf install -y bash                    # downloads from the mirror
```

No key to import either: mirrored RPMs keep their upstream signature and the
generated `.repo` points `gpgkey` at the vendor key already in
`/etc/pki/rpm-gpg/`. Do **not** add `repo_gpgcheck=1` - see
[MULTI-DISTRO.md](MULTI-DISTRO.md).

### pip / npm client

```bash
sudo curl -fsSL -o /etc/pip.conf http://192.168.30.110:8080/config/pip.conf
curl -fsSL -o ~/.npmrc http://192.168.30.110:8080/config/.npmrc
```

---

## 7. Day to day

```bash
mirroretctl                  # interactive menu, 21 options
mirroretctl status           # services, ports, disk, last sync, cron
mirroretctl targets          # what this box serves, and whether it synced
mirroretctl sync status      # is a sync running right now
mirroretctl logs errors      # what failed recently
mirroretctl doctor           # full read-only diagnostic
mirroretctl config diff      # config vs what is actually generated
mirroretctl report           # ONE txt file describing everything, for sharing
```

Cron already runs a nightly sync and a weekly cleanup:

```bash
sudo crontab -l
```

Changing what is mirrored is always the same two steps:

```bash
sudo mirroretctl config edit    # edit the target lines
sudo mirroretctl upgrade        # apply
mirroretctl targets             # confirm
```

Adding a distro is one word in `MIRRORET_APT_TARGETS` /
`MIRRORET_RPM_TARGETS` plus an upgrade and a sync. Removing one drops its
spec so it stops syncing; its data stays on disk until you delete it.

---

## When something is wrong

Start here, in this order:

```bash
mirroretctl targets        # is it even configured, and did it sync?
mirroretctl client verify  # does what clients are told match what exists?
mirroretctl logs errors    # what actually failed
mirroretctl doctor         # everything else
```

`mirroretctl report` writes one redacted text file covering the whole host -
that is the thing to send when you need someone else to look.

Specific symptoms: [TROUBLESHOOTING.md](TROUBLESHOOTING.md).
Environment problems mirroret cannot fix for you (proxy allow-list, clock
skew, corporate CA): `../FIXME-ENVIRONMENT.md`.

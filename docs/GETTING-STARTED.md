# Getting started: install, sync, verify, point clients at it

Follow top to bottom on a fresh or existing mirror server. Every step has a
check; if a check fails, stop there.

The examples use `192.168.30.110` as the mirror server. Substitute yours.

---

## The short way

Two scripts do the sequence below with a gate after each phase.

**On the mirror server:**

```bash
git clone https://github.com/sarat1kyan/mirroret.git && cd mirroret
sudo ./install.sh                     # first-run wizard, then install
sudo mirroretctl sync apt
sudo mirroretctl sync rpm
mirroretctl verify
```

or, unattended:

```bash
sudo ./scripts/setup-mirror-server.sh \
    --apt-targets "ubuntu:jammy ubuntu:noble debian:bookworm" \
    --rpm-targets "ol:9" \
    --components "main restricted" \
    --proxy http://192.168.30.243:3128 \
    --yes
```

Add `--dry-run` to see the plan without changing anything; `--help` lists
every option.

**On each client**, fetched from the mirror itself:

```bash
curl -fsSL -o /tmp/setup-mirror-client.sh \
    http://192.168.30.110:8080/config/setup-mirror-client.sh
sudo bash /tmp/setup-mirror-client.sh --server 192.168.30.110
```

It detects the distro, installs the matching config, disables the upstream
repos and proves the result by downloading a package pinned to the mirror's
own index. `--rollback` puts the machine back exactly as it was.

The rest of this document is the same sequence step by step.

---

## 0. What you are about to configure

Two lines decide what is mirrored:

```bash
MIRRORET_APT_TARGETS="ubuntu:jammy ubuntu:noble debian:bookworm"
MIRRORET_RPM_TARGETS="ol:9"
```

They name what your **clients** run, not what the server runs. Left unset,
mirroret falls back to the server's own release, which on a RHEL host means
no APT mirroring at all. Full model: [MULTI-DISTRO.md](MULTI-DISTRO.md).

One more line decides how much disk it costs:

```bash
MIRRORET_APT_MODE="hybrid"     # mirror | hybrid | cache
```

`mirror` downloads every package up front (~400 GB per Ubuntu release);
`hybrid` mirrors only the signed indices (~2 GB) and fetches packages on
first request; `cache` fetches everything on demand. See [CACHE.md](CACHE.md).

---

## 1. Get the code

```bash
cd ~
git clone https://github.com/sarat1kyan/mirroret.git
cd mirroret
```

Already have a clone: `git pull --ff-only`.

Server without GitHub access: on a machine that has it,
`git clone` then `tar czf mirroret.tgz mirroret/`, copy the tarball over and
`tar xzf` it on the server (a tarball keeps the execute bits; a zip does not).

### Check

```bash
ls engines/            # mirroret_apt.py mirroret_cache.py mirroret_fetch.py mirroret_rpm.py
python3 -V             # 3.6 or newer
```

---

## 2. Configure

### Fresh box: let the wizard do it

```bash
sudo ./install.sh
```

With a terminal, no `/etc/mirroret/mirroret.conf` and no targets in the
environment, the first-run wizard runs **before** preflight and package
installation. It asks, with defaults you can accept with Enter:

1. APT distros to serve (Ubuntu 24.04/22.04/20.04, Debian 12/11, or none)
2. Storage mode: full mirror / **hybrid (recommended)** / pure cache, and an
   optional cache size cap
3. APT architectures (amd64, i386, arm64)
4. RPM distros (Oracle 9/8, Rocky 9/8, EPEL 9, or none)
5. Whether to also provide pip, npm, Docker
6. Corporate proxy URL and, if so, whether to force HTTPS to upstream
   (`MIRRORET_APT_SCHEME=https`, for CONNECT-only proxies)
7. Free-disk floor for syncs (default 15 GB)
8. Nightly sync hour (default 2)

It writes `/etc/mirroret/mirroret.conf` and the install continues. Skip to
section 3's check.

### Existing box, or unattended: write the conf yourself

```bash
sudo mkdir -p /etc/mirroret
[[ -f /etc/mirroret/mirroret.conf ]] || \
  sudo cp config/mirroret.conf.example /etc/mirroret/mirroret.conf
sudo tee -a /etc/mirroret/mirroret.conf >/dev/null <<'EOF2'

# ---- What the CLIENTS run -------------------------------------------------
MIRRORET_APT_TARGETS="ubuntu:jammy ubuntu:noble debian:bookworm"
MIRRORET_RPM_TARGETS="ol:9"

# ---- Storage mode ---------------------------------------------------------
MIRRORET_APT_MODE="hybrid"          # indices up front, packages on demand
MIRRORET_CACHE_MAX_SIZE_GB="0"      # LRU cap for cached packages, 0 = none

# ---- Disk control (mirror mode mostly) ------------------------------------
# universe + multiverse are ~90% of a full Ubuntu mirror.
MIRRORET_APT_COMPONENTS="main restricted"
MIRRORET_RPM_NEWEST_ONLY=1
MIRRORET_RPM_SOURCE=0
MIRRORET_SYNC_MIN_FREE_GB=15        # engine default is 10; the wizard writes 15
MIRRORET_RPM_ARCH="x86_64"          # add i686 for 32-bit multilib clients

# ---- Proxy ----------------------------------------------------------------
# Set here, not only in your shell: cron and systemd read neither
# /etc/environment nor shell rc files. Every generated script and the cache
# daemon source this file and map MIRRORET_PROXY onto http_proxy/https_proxy.
MIRRORET_PROXY="http://192.168.30.243:3128"
#MIRRORET_NO_PROXY=".internal,10.0.0.0/8"
#MIRRORET_APT_SCHEME=https          # proxy permits CONNECT 443 only
#MIRRORET_CA_BUNDLE=/etc/pki/ca-trust/source/anchors/corp-root.crt
EOF2
```

Environment variables work too and beat the file, but they go **after**
`sudo`: `sudo MIRRORET_APT_MODE=hybrid ./install.sh`, never
`MIRRORET_APT_MODE=hybrid sudo ./install.sh` (sudo drops it).

### Check

```bash
grep -E '^MIRRORET_(APT|RPM)_TARGETS|^MIRRORET_APT_MODE' /etc/mirroret/mirroret.conf
```

---

## 3. Apply

Preview first. A dry run predicts the real run, including which target specs
would be written:

```bash
sudo ./install.sh --dry-run             # fresh box
sudo ./install.sh --upgrade --dry-run   # existing install
```

Look for `APT targets:` and `RPM targets:` near the end. `NONE` means the
target lines are not being read.

Then apply:

```bash
sudo ./install.sh                       # fresh box (non-interactive if the conf exists)
sudo ./install.sh --upgrade             # existing install: regenerate configs,
                                        # units, sync scripts, cron, logrotate
```

`--upgrade` never touches mirror data. It refuses to run if `/srv/mirroret`
does not exist yet.

### Check

```bash
mirroretctl targets        # every target listed with its upstream; "not synced yet"
mirroretctl config diff    # "every requested target has a generated spec"
mirroretctl cache status   # hybrid/cache: daemon running on 127.0.0.1:8082
```

`mirroretctl` is on `PATH` after the first install (`/usr/local/bin/mirroretctl`).

---

## 4. First sync

RPM first if you mirror both; it is usually the bulk.

```bash
sudo mirroretctl sync rpm
```

First lines to read:

```
--- repo baseos <- https://yum.oracle.com/repo/OracleLinux/OL9/baseos/latest/x86_64/
  upstream lists 8123 packages; 8123 selected (arches=noarch,x86_64 newest_only=True source=False)
```

`source=False` is the one to check; source RPMs are 400-600 MB each.

Then APT:

```bash
sudo mirroretctl sync apt
```

```
--- suite jammy <- http://archive.ubuntu.com/ubuntu
  signature: NOT verified locally (no archive keyring found)
  indices: 8 files, 6142 packages listed
  metadata-only: skipping 6142 package(s); pool is served on demand      # hybrid
  published: dists/jammy (8 index files)
=== integrity check ===
```

- `signature: NOT verified locally` is expected on a host without the
  archive keyring (any RHEL server). Clients verify the mirrored signature
  themselves; `MIRRORET_APT_REQUIRE_SIGNATURE=1` makes it fatal on the server.
- `metadata-only` appears in hybrid mode: no packages are downloaded ahead of
  time. In `mirror` mode you see `packages: N to download (X GB)` instead and
  the sync takes hours.
- `published:` appears only once every file the suite lists (and, in mirror
  mode, every package) is on disk. An interrupted sync leaves the previous
  state serving.
- The sync script ends with `scripts/verify-mirror.sh`, the same check as
  `mirroretctl verify`.

Watch from another shell with `mirroretctl logs tail`. Then:

```bash
sudo mirroretctl sync pip
sudo mirroretctl sync npm
```

`ABORT: ... would leave less than N GB free` is the `MIRRORET_SYNC_MIN_FREE_GB`
guard. Reduce components/targets, switch to hybrid, or add disk.

### Check

```bash
mirroretctl targets        # every target now "published"
mirroretctl verify         # every published Release complete on disk
mirroretctl logs errors
df -h /srv/mirroret
```

`verify` reads the engine's `.mirroret-manifest.json` per suite, so a
filtered mirror (main+restricted, amd64 only) passes; only files the
configuration meant to mirror are required.

---

## 5. Prove a client can use it

```bash
mirroretctl serve             # every HTTP endpoint answers
mirroretctl client verify     # configs advertise only published suites/repos
mirroretctl client simulate   # resolve AND download with a throwaway dnf config
```

`client verify` catches the mismatch that produces client 404s.

---

## 6. Point clients at it

Preferred: the published bootstrap script (top of this document). By hand,
`mirroretctl client list` prints the URL of every generated config.

### Ubuntu / Debian

```bash
. /etc/os-release
sudo curl -fsSL -o /etc/apt/sources.list.d/mirroret.list \
    "http://192.168.30.110:8080/config/${ID}-${VERSION_CODENAME}.list"
sudo mv /etc/apt/sources.list /etc/apt/sources.list.disabled-by-mirroret
sudo rm -f /etc/apt/sources.list.d/ubuntu.sources      # deb822 hosts (24.04+)
sudo apt-get update
apt-cache policy bash | head -5                        # must name 192.168.30.110
```

No key to import: the mirrored `Release` files carry the upstream signature
and the config's `signed-by=` names the stock distro keyring. In hybrid mode
the first `apt-get install` of a package fetches it through the mirror; the
next client gets it from disk.

### Oracle / Rocky / Alma / RHEL

```bash
sudo curl -fsSL -o /etc/yum.repos.d/mirroret.repo http://192.168.30.110:8080/config/ol9.repo
sudo dnf config-manager --set-disabled "*"
sudo dnf config-manager --set-enabled "mirroret-*"
sudo dnf clean all && sudo dnf repolist
sudo dnf install -y bash
```

No key to import: `gpgkey` points at the vendor key already in
`/etc/pki/rpm-gpg/`. Do not add `repo_gpgcheck=1`.

### pip / npm / Docker

```bash
sudo curl -fsSL -o /etc/pip.conf http://192.168.30.110:8080/config/pip.conf
curl -fsSL -o ~/.npmrc http://192.168.30.110:8080/config/.npmrc
sudo curl -fsSL -o /etc/docker/daemon.json http://192.168.30.110:8080/config/docker-daemon.json && sudo systemctl restart docker
```

Details: [CLIENT-CONFIGURATION-GUIDE.md](CLIENT-CONFIGURATION-GUIDE.md).

---

## 7. Day to day

```bash
mirroretctl                  # interactive menu
mirroretctl status           # services, ports, disk, last sync, cron
mirroretctl targets
mirroretctl sync status
mirroretctl cache status     # hybrid/cache: hit rate, bytes from upstream
mirroretctl logs errors
mirroretctl doctor
mirroretctl report           # one redacted txt file for support
```

Cron runs `sync-all.sh` nightly at `MIRRORET_SYNC_HOUR` and `cleanup-all.sh`
weekly (`sudo crontab -l`). Logs rotate through `/etc/logrotate.d/mirroret`.

Changing what is mirrored is always:

```bash
sudo mirroretctl config edit
sudo mirroretctl upgrade
mirroretctl targets
sudo mirroretctl sync apt      # or rpm
```

Switching storage mode is the same edit (`MIRRORET_APT_MODE`) followed by
`upgrade`; packages already on disk stay and keep being served.

---

## When something is wrong

```bash
mirroretctl targets
mirroretctl client verify
mirroretctl verify
mirroretctl logs errors
mirroretctl doctor --net
```

Symptoms and fixes: [TROUBLESHOOTING.md](TROUBLESHOOTING.md). Proxy and CA
issues: [PROXY_AND_CA.md](PROXY_AND_CA.md).

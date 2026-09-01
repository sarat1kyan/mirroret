# Mirroring several distributions from one server

The point of a central package server is that **one** box feeds every client,
whatever the clients run. This document covers how mirroret decides what to
mirror, and how to configure it.

---

## The rule

**What this server mirrors has nothing to do with what this server runs.**

A RHEL 9 host mirrors Ubuntu 22.04, Ubuntu 24.04, Debian 12, Oracle Linux 9
and Rocky 9 at the same time. A Debian 12 host does exactly the same. The
mirror server's own distribution is irrelevant.

That was not always true. Until this change, APT mirroring only ran when the
mirror server itself was Debian-based, and RPM mirroring only when it was
RHEL-based. On a RHEL mirror server the APT half silently never ran: no
error, no log line, no `.deb` on disk, because skipping was the designed
behaviour. If you are debugging an older install that "doesn't download the
Ubuntu packages", that is why.

---

## Configuration

Two settings in `/etc/mirroret/mirroret.conf`:

```bash
MIRRORET_APT_TARGETS="ubuntu:jammy ubuntu:noble debian:bookworm"
MIRRORET_RPM_TARGETS="ol:9 rocky:9 epel:9"
```

Then apply:

```bash
sudo ./install.sh --upgrade
mirroretctl targets          # confirm what is configured
sudo mirroretctl sync apt    # first APT sync
sudo mirroretctl sync rpm    # first RPM sync
```

### Target syntax

```
flavor:release[:arch,arch...]
```

* **flavor** — which upstream. See the tables below.
* **release** — codename or version number. `ubuntu:22.04` and
  `ubuntu:jammy` are the same thing; `debian:12` and `debian:bookworm` are
  the same thing. An unrecognised value is passed through unchanged, so a
  release newer than this version of mirroret still works.
* **arch** — optional per-target override. Defaults to `amd64` for APT
  (`arm64` for `ubuntu-ports`) and `MIRRORET_RPM_ARCH` for RPM.

### APT flavors

| flavor | upstream | default components |
|---|---|---|
| `ubuntu` | archive.ubuntu.com + security.ubuntu.com | main restricted universe multiverse |
| `ubuntu-ports` | ports.ubuntu.com (arm64, armhf, ppc64el, s390x) | main restricted universe multiverse |
| `debian` | deb.debian.org + deb.debian.org/debian-security | main contrib non-free non-free-firmware |

Each APT target mirrors three suites: `<release>`, `<release>-updates` and
`<release>-security`. Set `MIRRORET_APT_BACKPORTS=1` to add
`<release>-backports`.

### RPM flavors

Each target mirrors the flavor's **default** repo ids
(`rpm_flavor_default_repos` in `lib/targets.sh`). Every other id in the
catalog can be requested with `MIRRORET_RPM_REPOS` (applies when a single
RPM target is configured, or with the reposync engine).

| flavor | upstream | default repo ids | also requestable via `MIRRORET_RPM_REPOS` |
|---|---|---|---|
| `rocky` | dl.rockylinux.org | 9+: `baseos appstream crb extras`; 8: `baseos appstream powertools extras` | `devel plus highavailability resilientstorage nfv rt` |
| `almalinux` | repo.almalinux.org | same as rocky | same as rocky |
| `ol` | yum.oracle.com | `baseos appstream uek codeready epel` | `uekr6 uekr7 uekr8 addons kvm developer` |
| `centos` | mirror.stream.centos.org | `baseos appstream crb` | `highavailability nfv rt` |
| `fedora` | dl.fedoraproject.org | `everything updates` | - |
| `epel` | dl.fedoraproject.org/pub/epel | `everything` | `next` |
| `rhel` | cdn.redhat.com (needs an entitlement certificate) | `baseos appstream` | `codeready supplementary` |

An id that is not in the catalog is reported by name and skipped rather than
silently mirroring nothing; a target that resolves to zero repos warns
loudly. Legacy dnf ids are translated (`ol9_baseos_latest` -> `baseos`,
`ol9_UEKR8` -> `uekr8`, `ol9_developer_EPEL` -> `epel`,
`rhel-9-for-x86_64-appstream-rpms` -> `appstream`, `BaseOS` -> `baseos`).

`uek` resolves to UEKR8 on OL9 and UEKR7 on OL8; ask for a specific one with
`uekr6`/`uekr7`/`uekr8`.

If `MIRRORET_RPM_REPOS` names an id outside the catalog (a subscription id
such as `rhel-9-for-x86_64-baseos-rpms` that the alias table cannot map),
`MIRRORET_RPM_ENGINE=auto` falls back to `reposync`, because only the host's
own dnf knows that URL.

---

## URLs clients use

Mirroring several flavors means several URL prefixes. `mirroretctl targets`
prints the exact URL for every configured target; the pattern is:

| ecosystem | URL |
|---|---|
| Ubuntu | `http://SERVER:8080/ubuntu` |
| Ubuntu ports | `http://SERVER:8080/ubuntu-ports` |
| Debian | `http://SERVER:8080/debian` |
| RPM | `http://SERVER:8080/redhat/<flavor>/<major>/<repo>` |
| pip | `http://SERVER:8081/simple/` |
| npm | `http://SERVER:4873/` |
| Docker | `SERVER:5000` |

Ready-made client files are generated per target under
`/srv/mirroret/config/` and served at `http://SERVER:8080/config/`:

```
ubuntu-jammy.list      ubuntu-jammy.sources     # sources.list and deb822
ubuntu-noble.list      ubuntu-noble.sources
debian-bookworm.list   debian-bookworm.sources
ol9.repo  rocky9.repo  epel9.repo
pip.conf  .npmrc  docker-daemon.json
```

### On an APT client

```bash
sudo curl -fsSL -o /etc/apt/sources.list.d/mirroret.list \
    http://SERVER:8080/config/ubuntu-jammy.list

# Disable the upstream entries, or apt keeps going to the internet:
sudo mv /etc/apt/sources.list /etc/apt/sources.list.disabled-by-mirroret
sudo rm -f /etc/apt/sources.list.d/ubuntu.sources   # deb822 hosts (24.04+)

sudo apt-get update
```

No key to import: the mirrored `Release` files carry the **upstream**
signature, so the client verifies them with the `ubuntu-archive-keyring` /
`debian-archive-keyring` it already ships.

### On an RPM client

```bash
sudo curl -fsSL -o /etc/yum.repos.d/mirroret.repo \
    http://SERVER:8080/config/ol9.repo

sudo dnf config-manager --set-disabled "*"
sudo dnf config-manager --set-enabled "mirroret-*"
sudo dnf clean all && sudo dnf repolist
```

Again no key to import: mirrored RPMs keep their upstream signature, and the
generated `.repo` points `gpgkey` at the vendor key already in
`/etc/pki/rpm-gpg/`.

---

## How much disk

Rough full-mirror figures for `x86_64` with `--newest-only`, no source
packages:

| target | approximate size |
|---|---|
| `ubuntu:jammy` (4 components, 3 suites) | 400–600 GB |
| `ubuntu:jammy` (main + restricted only) | 40–70 GB |
| `debian:bookworm` (4 components) | 300–450 GB |
| `ol:9` baseos + appstream | 40–60 GB |
| `rocky:9` baseos + appstream | 40–60 GB |
| `epel:9` everything | 60–90 GB |

Two Ubuntu releases do **not** cost twice one release: all releases of a
flavor share a single `pool/`, exactly as upstream does.

These are `MIRRORET_APT_MODE=mirror` figures. In `hybrid` mode an APT target
costs roughly 2 GB of indices up front plus whatever clients actually
install; see [CACHE.md](CACHE.md).

The biggest lever is components. `universe` and `multiverse` are most of an
Ubuntu mirror:

```bash
MIRRORET_APT_COMPONENTS="main restricted"
```

Both engines estimate the download before starting and abort if it would
breach `MIRRORET_SYNC_MIN_FREE_GB`, so a target that does not fit says so in
seconds instead of filling the volume at 04:00.

---

## What the engines guarantee

Both mirroring engines are plain Python 3 using only the standard library —
no `apt-mirror`, no `debmirror`, no `reposync`, no `createrepo`, and no
requirement that the repository be configured in the mirror server's own
package manager.

**Nothing is published until it is complete.** For APT, a suite's `Release`
file is moved into place only after every index it hashes and every `.deb`
those indices list is on disk. For RPM, `repodata/` is replaced only after
every selected package has downloaded and verified. An interrupted sync
leaves the previous, consistent state serving — never metadata that promises
packages which 404.

**Every file is checksum-verified.** Downloads go to a temporary name and are
renamed into place only after the hash from the signed `Release` (APT) or
`repomd.xml`/`primary.xml` (RPM) matches. A short read — what a
TLS-inspecting proxy produces when it drops a large transfer — is retried,
not accepted.

**Metadata always matches the disk.** A full RPM mirror republishes
upstream's signed `repodata/` byte-for-byte. A filtered one (an arch subset,
or `--newest-only`) gets metadata rewritten to list exactly the packages that
were downloaded, by splicing upstream's own package records. Clients
therefore never resolve a package that is not there. This is also why a
filtered mirror cannot use `repo_gpgcheck=1`: `repomd.xml` was rebuilt
locally. Package signatures are untouched, so `gpgcheck=1` still works and
still verifies the vendor's signature.

**Signature verification is defence in depth, not the boundary.** The archive
is mirrored verbatim, so the client re-verifies the same upstream signature
with its own keyring. Mirror-side verification needs the matching archive
keyring, which a RHEL host does not have; that is a warning, not a failure.
Set `MIRRORET_APT_REQUIRE_SIGNATURE=1` to make it fatal.

---

## Checking it worked

```bash
mirroretctl targets        # configured targets + whether each has synced
mirroretctl serve          # every HTTP endpoint, from this host
mirroretctl client verify  # generated client configs, checked for breakage
mirroretctl client simulate  # resolve AND download a package as a client
mirroretctl logs errors    # failures in recent sync logs
```

`mirroretctl targets` is the one to reach for first. It answers "what does
this box actually serve?" in one screen, per target, including whether a
sync has ever completed.

---

## Migrating from a single-flavor install

Nothing to move. On upgrade:

* An existing `apt-mirror`/`debmirror` tree keeps being served and keeps
  using its existing tool — pinning `MIRRORET_APT_MIRROR_TOOL` is respected.
* An existing `reposync` tree under `redhat/mirror/<flavor>/<major>/` is the
  same layout the native engine uses, so clients see no change.
* The legacy client config names `debian-client.list` and
  `redhat-client.repo` are still generated, as copies of the first target.

To move a legacy install onto the native engines, set the targets and drop
the tool pin:

```bash
MIRRORET_APT_TARGETS="ubuntu:jammy"
MIRRORET_APT_MIRROR_TOOL=auto
MIRRORET_RPM_TARGETS="ol:9"
MIRRORET_RPM_ENGINE=auto
```

then `sudo ./install.sh --upgrade`.

# mirroret

One server that every Linux machine on your network installs packages from.

Install it on a single host and it mirrors APT (Ubuntu, Debian), RPM (Oracle
Linux, Rocky, AlmaLinux, CentOS Stream, RHEL, Fedora, EPEL), pip, npm and
Docker images. Clients point at it instead of the internet.

**The mirror server's own distribution is irrelevant.** A RHEL 9 box mirrors
Ubuntu 22.04 + 24.04 + Debian 12 + Oracle Linux 9 side by side; so does a
Debian 12 box. What gets mirrored is configuration:

```bash
# in /etc/mirroret/mirroret.conf
MIRRORET_APT_TARGETS="ubuntu:jammy ubuntu:noble debian:bookworm"
MIRRORET_RPM_TARGETS="ol:9 rocky:9 epel:9"
```

New here? [docs/GETTING-STARTED.md](docs/GETTING-STARTED.md) walks the whole
thing end to end. [docs/MULTI-DISTRO.md](docs/MULTI-DISTRO.md) is the model
behind the two lines above.

APT and RPM mirroring are done by self-contained Python 3 engines
(`engines/`) that need only the standard library: no `apt-mirror`,
`debmirror`, `reposync` or `createrepo`, and no requirement that the
repository be configured in the mirror server's own package manager. Both
publish metadata only after every package it references is on disk and
verified, so an interrupted sync never leaves clients resolving packages that
404.

---

## Quick start

### Requirements

- Linux: Ubuntu 20.04+, Debian 11+, or RHEL/CentOS/Rocky/AlmaLinux 8+
- Root on the mirror server
- `python3`
- 50 GB free by default (`MIRRORET_MIN_DISK_GB`); how much you really need
  depends on the storage mode below and the sizing table in
  [docs/MULTI-DISTRO.md](docs/MULTI-DISTRO.md)
- Outbound access to the upstream archives during install and sync
  ([docs/NETWORK_ACCESS.md](docs/NETWORK_ACCESS.md))

### Install

```bash
git clone https://github.com/sarat1kyan/mirroret.git
cd mirroret
sudo ./install.sh
```

On a fresh box with a terminal, `install.sh` runs the first-run wizard
before anything is installed. It asks which APT distros to serve, the
storage mode (full mirror / hybrid / cache), architectures, RPM distros,
whether to provide pip/npm/Docker, a proxy, the free-disk floor and the
nightly sync hour, then writes `/etc/mirroret/mirroret.conf` and continues
with preflight, packages, services and firewall. Press Enter for defaults.

The wizard is skipped with `--non-interactive`, `--upgrade`, `--dry-run`, an
existing conf, or targets already in the environment. Then the conf (or the
environment) is used as-is:

```bash
sudo MIRRORET_APT_TARGETS="ubuntu:noble debian:bookworm" \
     MIRRORET_RPM_TARGETS="ol:9" MIRRORET_APT_MODE=hybrid \
     ./install.sh --non-interactive
```

Environment variables go **after** `sudo`, never before it.

Other useful forms:

```bash
sudo ./install.sh --dry-run                       # preview, change nothing
sudo ./install.sh --apt-targets "ubuntu:jammy" --rpm-targets "rocky:9"
sudo ./install.sh --docker-mode hosted            # registry accepts docker push
sudo MIRRORET_FIREWALL_SOURCE=10.0.0.0/8 ./install.sh --no-pip --no-docker --no-npm
sudo MIRRORET_DOCKER_BACKEND=native ./install.sh  # no container runtime
sudo ./install.sh --insecure                      # lab only: no signature checks
sudo ./scripts/setup-mirror-server.sh --apt-targets "ubuntu:noble" --yes
                                                  # gated one-shot bring-up
```

### Storage modes

`MIRRORET_APT_MODE` decides how APT packages are stored:

- `mirror` - every package up front. Fully offline once synced. Roughly
  400 GB per Ubuntu release (amd64, all components).
- `hybrid` (recommended) - the signed index tree is mirrored (~2 GB),
  packages are fetched on first request and kept. `apt-get update` works
  offline; disk converges on what the fleet installs.
- `cache` - nothing up front; indices and packages both on demand.

`hybrid` and `cache` run the `mirroret-cache` daemon on `127.0.0.1:8082`;
nginx serves hits itself and hands misses to it. Signature verification is
unchanged: clients still verify the upstream `Release`. Details, sizing and
tuning: [docs/CACHE.md](docs/CACHE.md).

### After installation

```bash
mirroretctl targets              # 1. what this server is configured to mirror
sudo mirroretctl sync apt        # 2. first sync (hours in mirror mode,
sudo mirroretctl sync rpm        #    minutes in hybrid)
mirroretctl verify               # 3. every published Release is complete on disk
mirroretctl cache status         #    (hybrid/cache) daemon running, hit rate
mirroretctl client verify        # 4. client configs match what is published
```

`install.sh` links `mirroretctl` into `/usr/local/bin`. Then enrol clients
from the mirror itself:

```bash
curl -fsSL -o /tmp/setup-mirror-client.sh http://SERVER:8080/config/setup-mirror-client.sh
sudo bash /tmp/setup-mirror-client.sh --server SERVER     # --rollback undoes it
```

It detects the distro, installs the matching published config, disables the
upstream repos and proves the result by downloading a package pinned to the
mirror's own index. Or hand out the files under `/srv/mirroret/config/`
yourself ([docs/CLIENT-CONFIGURATION-GUIDE.md](docs/CLIENT-CONFIGURATION-GUIDE.md)).

A nightly `sync-all.sh` cron entry and a weekly `cleanup-all.sh` are
installed; logs rotate via `/etc/logrotate.d/mirroret`.

### Which diagnostic do I run?

| Tool | Output | Use it when |
|------|--------|-------------|
| `mirroretctl doctor` / `scripts/mirroret-debug.sh` | PASS/WARN/FAIL lines | you are at the console and want a verdict (`--net` also probes upstream) |
| `mirroretctl report` / `scripts/mirroret-collect.sh` | one redacted `.txt`, findings first | you need to hand the full picture to someone else |

`mirroret-collect.sh` is standalone (sources nothing from `lib/`), bounds
every probe with a timeout, masks passwords, tokens and proxy credentials,
and writes the report mode 600.

---

## mirroretctl

One command for everything. Interactive menu with no arguments, or a
subcommand. Read-only commands need no root.

```bash
mirroretctl status               # services, ports, disk, last sync, cron
mirroretctl targets              # configured targets and whether each synced
mirroretctl verify               # integrity of every published APT suite
mirroretctl cache status         # on-demand cache stats (hybrid/cache mode)
mirroretctl serve                # probe every HTTP endpoint locally
mirroretctl client verify        # generated client configs vs what is published
mirroretctl client simulate      # resolve AND download as a client would
mirroretctl logs errors          # failures in recent sync logs
mirroretctl config diff          # config vs what the generated scripts contain
mirroretctl approve list         # approval queue

sudo mirroretctl sync apt        # run one sync now (apt|rpm|pip|npm|docker|all)
sudo mirroretctl sync stop
sudo mirroretctl approve all rpm
sudo mirroretctl clean report    # retention dry run
sudo mirroretctl upgrade         # re-apply config, regenerate managed files
sudo mirroretctl check           # validate the installation
```

Full list: `mirroretctl help`, reproduced in
[docs/QUICK-REFERENCE.md](docs/QUICK-REFERENCE.md).

---

## Updating mirroret itself

```bash
cd mirroret
git pull --ff-only
sudo ./install.sh --upgrade      # skip package install; regenerate configs,
                                 # units, sync scripts, cron, logrotate
mirroretctl doctor
```

`--upgrade` never touches mirror data. Generated scripts whose
`mirroret-managed` marker line you removed are left alone
([docs/RETENTION.md](docs/RETENTION.md)).

---

## Supported package types

| Type | Service | Default port | Client config under `/config/` |
|------|---------|-------------|---------------|
| APT (Ubuntu, Ubuntu ports, Debian) | nginx | 8080 | `<flavor>-<codename>.list` and `.sources` |
| RPM (Oracle, Rocky, Alma, CentOS Stream, RHEL, Fedora, EPEL) | nginx | 8080 | `<flavor><major>.repo` |
| pip | pypiserver | 8081 | `pip.conf` |
| npm | Verdaccio | 4873 | `.npmrc` |
| Docker images | docker-distribution / docker-registry / registry:2 | 5000 (all interfaces) | `docker-daemon.json` |
| HTTPS (optional) | nginx TLS | 8443 | `--tls-self-signed` or your own cert |
| on-demand cache (hybrid/cache) | `mirroret-cache` | 127.0.0.1:8082 | internal; not exposed |

All ports are configurable ([docs/CONFIGURATION.md](docs/CONFIGURATION.md)).

## Supported distributions

**Server:** Ubuntu 20.04/22.04/24.04, Debian 11/12, RHEL/CentOS/Rocky/AlmaLinux 8/9.

**Clients, APT:** Ubuntu 20.04/22.04/24.04 (amd64/i386; arm64 and other ports
via the `ubuntu-ports` flavor), Debian 10-13.

**Clients, RPM:** Oracle Linux 8/9, Rocky 8/9, AlmaLinux 8/9, CentOS Stream,
RHEL 8/9 (entitlement certificate required for `cdn.redhat.com`), Fedora, EPEL.

**Clients, language ecosystems:** anything using pip, npm or Docker.

---

## Configuration

Everything is a `MIRRORET_*` variable in `/etc/mirroret/mirroret.conf`
(written by the wizard, or copied from `config/mirroret.conf.example`) or in
the environment; **environment beats the conf file**. Apply with
`sudo ./install.sh --upgrade`. The ones most installs touch:

```bash
MIRRORET_APT_TARGETS="ubuntu:jammy debian:bookworm"   # flavor:release[:arch,..]
MIRRORET_RPM_TARGETS="ol:9 rocky:9 epel:9"           # flavor:major[:arch,..]
MIRRORET_APT_MODE=hybrid                # mirror | hybrid | cache
MIRRORET_CACHE_MAX_SIZE_GB=0            # LRU cap for cached packages, 0 = none
MIRRORET_APT_COMPONENTS="main restricted"   # biggest disk lever in mirror mode
MIRRORET_PROXY=http://proxy:3128        # honoured by every sync and the cache
MIRRORET_APT_SCHEME=https               # CONNECT-only proxies
MIRRORET_SYNC_MIN_FREE_GB=15            # abort a sync below this (engine default 10)
MIRRORET_SERVER_IP=192.168.1.10         # address written into client configs
MIRRORET_FIREWALL_SOURCE=10.0.0.0/8     # restrict inbound by subnet
MIRRORET_DOCKER_MODE=cache              # cache (pull-through) | hosted (push)
MIRRORET_APPROVAL_ENABLED=1             # stage pip/npm/rpm until approved
MIRRORET_TLS_SELF_SIGNED=1              # HTTPS listener on 8443
```

Full reference with real defaults: [docs/CONFIGURATION.md](docs/CONFIGURATION.md).

---

## Security

Mirrored content keeps its **upstream** signatures. APT `Release` files are
copied byte for byte and clients verify them with the `ubuntu-` /
`debian-archive-keyring` they already have; RPMs keep their vendor signature
and the generated `.repo` points `gpgkey` at the vendor key in
`/etc/pki/rpm-gpg/`. **No key is generated or distributed for mirrored
suites**, in any storage mode. `--gpg-auto` only creates a key for packages
you publish yourself (and `MIRRORET_APT_RESIGN=1` if you re-sign; mirroret
does not).

`--insecure` writes `trusted=yes` / `gpgcheck=0` / `insecure-registries`
client configs, with a loud warning. Lab only.

[docs/SECURITY.md](docs/SECURITY.md) covers TLS (`--tls-self-signed` or your
own cert), the Docker registry exposure, nginx basic auth and the privilege
model.

---

## CLI reference

```bash
# Installer modes
sudo ./install.sh                       # install (wizard on a fresh box)
sudo ./install.sh --dry-run             # preview
sudo ./install.sh --non-interactive     # no prompts, no wizard
sudo ./install.sh --upgrade             # re-apply config on an existing install
sudo ./install.sh --check               # validate (alias --validate); regenerates nothing
sudo ./install.sh --status
sudo ./install.sh --backup-only
sudo ./install.sh --list-backups
sudo ./install.sh --rollback <id>
sudo ./install.sh --config <path>
sudo ./install.sh --network-preflight   # probe outbound HTTPS during preflight
sudo ./install.sh --debug

# What to mirror / how
sudo ./install.sh --apt-targets "ubuntu:jammy ubuntu:noble" --rpm-targets "ol:9"
sudo ./install.sh --apt-flavor debian   # legacy fallback when no targets are set
sudo ./install.sh --rpm-engine native   # auto | native | reposync
sudo ./install.sh --docker-mode hosted  # cache | hosted

# Components
sudo ./install.sh --no-apt --no-rpm --no-pip --no-docker --no-npm --no-firewall

# Security features
sudo ./install.sh --tls-self-signed
sudo ./install.sh --gpg-auto            # key for your own packages only
sudo ./install.sh --approval-mode       # MIRRORET_APPROVAL_ENABLED=1
sudo ./install.sh --insecure            # lab only

# Approval workflow (or use mirroretctl approve ...)
sudo ./install.sh --list-staging
sudo ./install.sh --approve-all-pip | --approve-all-npm | --approve-all-rpm
sudo ./install.sh --approve-package <n> | --approve-rpm <n>
sudo ./install.sh --exclude-pip <n> | --exclude-npm <n> | --exclude-rpm <n>

# Retention
sudo ./install.sh --cleanup-report      # dry run
sudo ./install.sh --cleanup             # needs MIRRORET_RETENTION_ENABLE=1

# Uninstall
sudo ./uninstall.sh --list              # preview
sudo ./uninstall.sh --docker            # one component
sudo ./uninstall.sh --all --purge --yes # everything incl. data
sudo ./install.sh --uninstall [opts]    # same, via the installer

# Development
make lint        # shellcheck + python checks
make test        # every BATS file in tests/
make format      # shfmt
make check-deps
make dry-run
```

---

## Documentation

| Document | Contents |
|----------|---------|
| [docs/GETTING-STARTED.md](docs/GETTING-STARTED.md) | **Start here** - install, storage mode, first sync, verify, enrol clients, day to day |
| [docs/MULTI-DISTRO.md](docs/MULTI-DISTRO.md) | Target syntax, upstream catalog, default repo ids, client URLs, disk sizing, engine guarantees |
| [docs/CACHE.md](docs/CACHE.md) | Storage modes: mirror / hybrid / cache, the on-demand daemon, capping disk |
| [docs/CONFIGURATION.md](docs/CONFIGURATION.md) | Every `MIRRORET_*` variable with its real default; precedence |
| [docs/CLIENT-CONFIGURATION-GUIDE.md](docs/CLIENT-CONFIGURATION-GUIDE.md) | `setup-mirror-client.sh` and the manual equivalent for APT, RPM, pip, npm, Docker |
| [docs/NETWORK_ACCESS.md](docs/NETWORK_ACCESS.md) | Inbound ports, upstream hosts per flavor, firewall commands, offline installs |
| [docs/PROXY_AND_CA.md](docs/PROXY_AND_CA.md) | `MIRRORET_PROXY`, CONNECT-only proxies, corporate CA trust |
| [docs/SECURITY.md](docs/SECURITY.md) | What protects a client, TLS, custom-repo GPG, registry exposure, basic auth |
| [docs/OPERATIONS.md](docs/OPERATIONS.md) | Sync, approval workflow, Docker backend, disk, logs, cron |
| [docs/NATIVE_MODE.md](docs/NATIVE_MODE.md) | Running without a container runtime; the units mirroret installs |
| [docs/RETENTION.md](docs/RETENTION.md) | Retention/cleanup and safe upgrades |
| [docs/ROLLBACK.md](docs/ROLLBACK.md) | Config backups and `--rollback` |
| [docs/UNINSTALL.md](docs/UNINSTALL.md) | Selective and full uninstall |
| [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) | Symptoms and fixes per component |
| [docs/QUICK-REFERENCE.md](docs/QUICK-REFERENCE.md) | `mirroretctl help` and the most-used commands |
| [docs/history/](docs/history/) | Historical review and implementation report (earlier version) |
| [docs/site/](docs/site/) | Site-specific deploy notes for one particular deployment |

---

## Repository layout

```
mirroret/
+-- install.sh              Installer (wizard, preflight, services, firewall, cron)
+-- uninstall.sh            Uninstaller entry point
+-- mirroretctl             Control surface (menu + subcommands)
+-- Makefile                lint / test / format / check-deps / dry-run / uninstall
+-- config/
|   +-- mirroret.conf.example   Documented config template
+-- engines/                stdlib-only Python
|   +-- mirroret_fetch.py   Shared retrying, checksum-verified fetcher
|   +-- mirroret_apt.py     APT mirroring engine (publishes Release last)
|   +-- mirroret_rpm.py     RPM mirroring engine
|   +-- mirroret_cache.py   On-demand pull-through cache daemon
+-- lib/
|   +-- logging.sh          section/info/warn/error/success/die
|   +-- common.sh           xrun() DRY_RUN wrapper, atomic_write, script preamble (proxy/CA)
|   +-- distro.sh           Host detection, SELinux helpers
|   +-- preflight.sh        Root, disk, commands, optional network probe
|   +-- backup.sh           Timestamped backups and rollback
|   +-- targets.sh          Upstream catalog + target specs (what to mirror)
|   +-- cache.sh            Storage modes, cache route table, mirroret-cache unit
|   +-- nginx.sh            nginx vhost (per-flavor locations, cache miss handler, TLS block)
|   +-- systemd.sh          Unit writing, enable/start
|   +-- firewall.sh         ufw / firewalld / iptables rules
|   +-- apt.sh              APT: native engine sync script, legacy apt-mirror/debmirror, client configs
|   +-- rpm.sh              RPM: native engine / reposync, client configs
|   +-- docker_registry.sh  Registry: native or container backend, client config
|   +-- pip.sh              pypiserver unit, sync script, pip.conf
|   +-- npm.sh              Verdaccio install/config, sync script, .npmrc
|   +-- tls.sh              Self-signed cert, TLS server block
|   +-- gpg.sh              Optional signing key for custom repos
|   +-- approval.sh         Staging -> approved for pip, npm, rpm
|   +-- retention.sh        Retention/cleanup
|   +-- validation.sh       --check / --status
|   +-- wizard.sh           First-run interactive wizard
|   +-- uninstall.sh        Uninstall logic
+-- scripts/
|   +-- setup-mirror-server.sh  Gated one-shot server bring-up
|   +-- setup-mirror-client.sh  Enrol a client (published under /config/; --rollback)
|   +-- verify-mirror.sh        Post-sync integrity check (mirroretctl verify)
|   +-- mirroret-debug.sh       Read-only diagnostic
|   +-- mirroret-collect.sh     One shareable report file
|   +-- mirror-apt-extra.sh     Mirror an extra third-party APT repo
|   +-- enroll-apt-extra.sh     Enrol a client in an extra APT repo
+-- tests/                  19 BATS files, 646 tests
|   +-- test_helpers.bash       Shared setup
|   +-- test_audit_fixes.bats   40   test_cache.bats          15
|   +-- test_cache_wiring.bats  17   test_cli.bats            73
|   +-- test_client_path.bats    8   test_collect.bats        44
|   +-- test_config.bats         8   test_distro.bats         11
|   +-- test_dryrun.bats        10   test_engines.bats        42
|   +-- test_fixes.bats        102   test_integration.bats    66
|   +-- test_retention.bats     31   test_rhel.bats           25
|   +-- test_security.bats      12   test_targets.bats        96
|   +-- test_uninstall.bats     27   test_verify_mirror.bats  10
|   +-- test_wizard.bats         9
|   +-- fixtures/               APT/RPM repo generators + repodata validator
+-- docs/                   See the table above
```

---

## Known limitations

- The engines are tested end to end against small local archives. The
  installer's system-level steps (systemd, SELinux, firewall) are exercised
  under `DRY_RUN` and with a mocked `/etc/os-release`. Treat the first real
  sync of a large target as a capacity test.
- A full (`mirror` mode) Ubuntu or Debian release is 300-600 GB and takes
  hours. `MIRRORET_APT_COMPONENTS="main restricted"` cuts that by roughly
  90%; `MIRRORET_APT_MODE=hybrid` makes it a few GB plus what clients use.
- `cache` storage mode needs upstream reachable for a client's first
  `apt-get update`; `hybrid` does not.
- Docker `cache` mode rejects pushes (a registry restriction). `hosted`
  accepts them and `sync-docker-images.sh` pre-seeds a list using a local
  `docker` or `podman` CLI.
- With approval mode on, Verdaccio's npmjs uplink is disabled: unapproved
  npm packages return 404 instead of being fetched live.
- A filtered RPM mirror (arch subset, or the default newest-only) has locally
  rebuilt `repomd.xml`, so clients cannot use `repo_gpgcheck=1`. `gpgcheck=1`
  still verifies the vendor package signatures.
- Mirroring RHEL from `cdn.redhat.com` needs this host's entitlement
  certificate (`/etc/pki/entitlement/*.pem`, picked up automatically).
- A TLS-inspecting proxy that re-signs the upstream archive breaks the
  client-side `Release` verification. Allow-list the archive hosts on the
  proxy; there is no re-signing in mirroret ([docs/PROXY_AND_CA.md](docs/PROXY_AND_CA.md)).
- SELinux: file contexts are set blanket-style (`httpd_sys_content_t`) and
  `httpd_can_network_connect` is enabled; no custom policy module.
- The uninstaller removes what mirroret created, not OS packages such as
  nginx, docker or podman ([docs/UNINSTALL.md](docs/UNINSTALL.md)).
- `apt-mirror` / `debmirror` remain selectable via `MIRRORET_APT_MIRROR_TOOL`
  for existing trees, Debian/Ubuntu hosts only. New installs should stay on
  the native engine.

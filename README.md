# mirroret

One server that every Linux machine on your network installs packages from.

Install it on a single host and it mirrors APT (Ubuntu, Debian), RPM (Oracle
Linux, Rocky, AlmaLinux, CentOS Stream, RHEL, Fedora, EPEL), pip, npm and
Docker images. Clients point at it instead of the internet.

**The mirror server's own distribution is irrelevant.** A RHEL 9 box mirrors
Ubuntu 22.04 + 24.04 + Debian 12 + Oracle Linux 9 side by side; so does a
Debian 12 box. What gets mirrored is configuration, not a consequence of what
the server happens to run:

```bash
# in /etc/mirroret/mirroret.conf
MIRRORET_APT_TARGETS="ubuntu:jammy ubuntu:noble debian:bookworm"
MIRRORET_RPM_TARGETS="ol:9 rocky:9 epel:9"
```

See [docs/MULTI-DISTRO.md](docs/MULTI-DISTRO.md) for the full model.

APT and RPM mirroring are done by two self-contained Python 3 engines
(`engines/`) that need only the standard library — no `apt-mirror`,
`debmirror`, `reposync` or `createrepo`, and no requirement that the
repository be configured in the mirror server's own package manager. Both
publish metadata only after every package it references is on disk and
verified, so an interrupted sync never leaves clients resolving packages that
404.

---

## Quick start

### Requirements

- Linux: Ubuntu 20.04+, Debian 11+, or RHEL/CentOS/Rocky/AlmaLinux 8+
- Root access on the mirror server
- `python3` (present by default on every supported distro)
- 50 GB free disk space minimum; see the sizing table in
  [docs/MULTI-DISTRO.md](docs/MULTI-DISTRO.md)
- Outbound internet access during installation and sync (see [docs/NETWORK_ACCESS.md](docs/NETWORK_ACCESS.md))

### Installation

```bash
git clone https://github.com/sarat1kyan/mirroret.git
cd mirroret

# Decide what your CLIENTS run - not what this server runs:
sudo ./install.sh \
    --apt-targets "ubuntu:jammy ubuntu:noble debian:bookworm" \
    --rpm-targets "ol:9 rocky:9 epel:9"

# Preview without making any changes:
sudo ./install.sh --dry-run

# Standard install (Docker as pull-through cache by default):
sudo ./install.sh

# Hosted Docker mode - accepts `docker push` for curated pre-seeding:
sudo ./install.sh --docker-mode hosted

# Standalone APT-only mirror, restricted to a corporate subnet:
sudo MIRRORET_FIREWALL_SOURCE=10.0.0.0/8 ./install.sh \
    --no-pip --no-docker --no-npm

# Force-treat the host as Debian even if /etc/os-release says otherwise:
sudo ./install.sh --apt-flavor debian

# Native mode - no Docker daemon required:
sudo MIRRORET_DOCKER_BACKEND=native ./install.sh

# Lab / air-gapped install (no GPG, no TLS - INSECURE; warning printed):
sudo ./install.sh --insecure

# Run the read-only diagnostic snapshot at any time:
sudo ./scripts/mirroret-debug.sh
sudo ./scripts/mirroret-debug.sh --net # also probe outbound HTTPS
sudo ./scripts/mirroret-debug.sh --bundle # write a /tmp tarball for support

# Collect ONE text file describing the whole host, for sending to support:
sudo ./scripts/mirroret-collect.sh
sudo ./mirroretctl report # same thing via the CLI
```

### Which diagnostic do I run?

| Tool | Output | Use it when |
|------|--------|-------------|
| `mirroret-debug.sh` | PASS/WARN/FAIL lines on the terminal | You are at the console and want a fast verdict |
| `mirroret-collect.sh` | One redacted `.txt` file, findings first | You need to hand the full picture to someone else |

`mirroret-collect.sh` is read-only and standalone: it sources nothing from
`lib/`, so it still runs when the install itself is broken. It writes 33
sections of evidence plus an auto-computed findings list, bounds every probe
with a timeout so a hung mount cannot stall the run, and masks passwords,
tokens and proxy credentials before writing. The report is created mode 600.

### After installation

```bash
# 1. Confirm what this server is configured to mirror:
mirroretctl targets

# 2. Open firewall ports for clients (if not done automatically):
# See docs/NETWORK_ACCESS.md for firewall commands.

# 3. Run the initial sync (minutes to hours depending on what you mirror):
sudo /srv/mirroret/scripts/sync-all.sh
#    ...or one ecosystem at a time:
sudo mirroretctl sync apt
sudo mirroretctl sync rpm

# 4. Validate:
sudo ./install.sh --check
mirroretctl targets            # every target should now report "published"
mirroretctl client simulate    # resolve AND download as a client would

# 5. Distribute client configs (one per target):
ls /srv/mirroret/config/
```

`mirroretctl targets` is the first command to reach for. It answers "what
does this box actually serve, and has it synced?" per target, in one screen.

---

## mirroretctl (control surface)

One command for everything. Interactive menu with no arguments, or a
subcommand.

```bash
./mirroretctl # interactive menu
./mirroretctl status # services, ports, disk, last sync, cron
./mirroretctl doctor # full read-only diagnostic
./mirroretctl serve # probe every HTTP endpoint locally
./mirroretctl client verify # check generated client configs for breakage
./mirroretctl logs errors # failures in recent sync logs
./mirroretctl config diff # config vs what the generated scripts contain

sudo ./mirroretctl sync rpm # run one sync now
sudo ./mirroretctl sync stop # stop running syncs
sudo ./mirroretctl clean report # retention dry run
sudo ./mirroretctl upgrade # re-apply config, regenerate managed scripts
```

Read-only subcommands need no root. Anything that changes state requires
root and says so. Run `./mirroretctl help` for the full list.

---

## Updating mirroret itself

Safe upgrade path - never touches your mirror data:

```bash
cd ~/mirroret-main # or wherever you cloned it
git fetch origin
git reset --hard origin/main # or `git pull --ff-only`
sudo ./install.sh --upgrade # fast path: refresh configs + services only
sudo ./scripts/mirroret-debug.sh # verify
```

`--upgrade` skips package install and directory creation (already done),
regenerates configs + managed sync scripts, and refreshes the cron block.
Your customizations are preserved: any sync script whose `MIRRORET-MANAGED`
sentinel line you removed is left alone. Full docs: [docs/RETENTION.md](docs/RETENTION.md).

---

## Supported package types

| Type | Service | Default port | Client config |
|------|---------|-------------|---------------|
| APT (Ubuntu, Ubuntu ports, Debian) | nginx | 8080 | `config/<flavor>-<release>.list` and `.sources` |
| RPM (Oracle, Rocky, Alma, CentOS Stream, RHEL, Fedora, EPEL) | nginx | 8080 | `config/<flavor><major>.repo` |
| pip (Python) | pypiserver | 8081 | `config/pip.conf` |
| Docker images | docker-distribution / registry:2 | 5000 | `config/docker-daemon.json` |
| npm | Verdaccio | 4873 | `config/.npmrc` |
| HTTPS (optional) | nginx TLS | 8443 | use `--tls-self-signed` or bring your own cert |

All ports are configurable. See [docs/CONFIGURATION.md](docs/CONFIGURATION.md).

---

## Supported distributions

**Server:** Ubuntu 20.04/22.04/24.04, Debian 11/12, RHEL/CentOS/Rocky/AlmaLinux 8/9.
Which one it is does not constrain what it can mirror.

**Clients — APT:** Ubuntu 20.04/22.04/24.04 (amd64 and, via `ubuntu-ports`,
arm64/armhf/ppc64el/s390x), Debian 11/12/13.

**Clients — RPM:** Oracle Linux 8/9, Rocky 8/9, AlmaLinux 8/9, CentOS
Stream 9/10, RHEL 8/9 (entitlement certificate required for the CDN),
Fedora, EPEL.

**Clients — language ecosystems:** anything using pip, npm or Docker.

---

## Configuration

```bash
# Copy the example config and customise it:
sudo mkdir -p /etc/mirroret
sudo cp config/mirroret.conf.example /etc/mirroret/mirroret.conf
sudo nano /etc/mirroret/mirroret.conf
sudo ./install.sh --config /etc/mirroret/mirroret.conf
```

Key settings:

```bash
MIRRORET_SERVER_IP=192.168.1.10 # IP written into client configs
MIRRORET_FIREWALL_SOURCE=10.0.0.0/8 # Restrict inbound access by subnet

# Docker
MIRRORET_DOCKER_MODE=cache # cache (default, pull-through) | hosted
MIRRORET_DOCKER_BACKEND=native # Use OS-native registry (no Docker daemon)
MIRRORET_DOCKER_UPSTREAM_URL=https://registry-1.docker.io # cache-mode upstream

# What to mirror (the setting most installs actually need)
MIRRORET_APT_TARGETS="ubuntu:jammy debian:bookworm" # flavor:release ...
MIRRORET_RPM_TARGETS="ol:9 rocky:9 epel:9"          # flavor:major ...

# APT
MIRRORET_APT_MIRROR_TOOL=auto # auto (native engine) | native | apt-mirror | debmirror
MIRRORET_APT_COMPONENTS= # biggest disk lever: "main restricted" is ~10% of full
MIRRORET_APT_BACKPORTS=0 # also mirror <release>-backports
MIRRORET_APT_UPSTREAM_HOST= # override upstream archive host
MIRRORET_APT_REQUIRE_SIGNATURE=0 # fail, not warn, if Release cannot be verified here

# RPM
MIRRORET_RPM_ENGINE=auto # auto (native engine) | native | reposync
MIRRORET_RPM_REPOS= # Space-separated repo ids to sync
MIRRORET_RPM_ARCH="x86_64 i686" # add i686 if clients install 32-bit multilib

# Other
MIRRORET_TLS_SELF_SIGNED=1 # Auto-generate a self-signed TLS cert
MIRRORET_GPG_AUTO=1 # Auto-generate a GPG signing key
MIRRORET_APPROVAL_ENABLED=1 # Require admin approval before serving pip/npm/RPM
MIRRORET_PREFLIGHT_NETWORK=1 # Probe outbound HTTPS during preflight
```

See [docs/CONFIGURATION.md](docs/CONFIGURATION.md) for the full variable reference.

---

## Security

**Secure by default:** client configs require GPG verification. APT clients will not
work until a GPG keyring is configured. Use `--gpg-auto` to have mirroret generate
and manage the key.

**Lab / insecure mode:** `--insecure` disables GPG and TLS checks. A loud warning is
printed. Only use this in isolated environments.

See [docs/SECURITY.md](docs/SECURITY.md) for:
- TLS auto-provisioning (`--tls-self-signed`) and bring-your-own-certificate setup
- GPG auto-provisioning (`--gpg-auto`) and client key distribution
- nginx basic authentication
- Restricting access by subnet

---

## CLI reference

```bash
# Installation and checks:
sudo ./install.sh # full install (all components)
sudo ./install.sh --dry-run # preview changes without applying
sudo ./install.sh --check # validate an existing installation
sudo ./install.sh --status # print service status
sudo ./install.sh --backup-only # snapshot current state

# Feature flags (can be combined):
sudo ./install.sh --tls-self-signed # enable HTTPS with auto-generated cert
sudo ./install.sh --gpg-auto # auto-generate GPG signing key
sudo ./install.sh --approval-mode # enable staging/approval workflow for pip/npm/RPM
sudo ./install.sh --insecure # disable all security checks (LAB ONLY)

# Skip components:
sudo ./install.sh --no-apt # skip APT mirror
sudo ./install.sh --no-rpm # skip RPM mirror
sudo ./install.sh --no-pip # skip pypiserver
sudo ./install.sh --no-docker # skip Docker registry
sudo ./install.sh --no-npm # skip Verdaccio / npm
sudo ./install.sh --no-firewall # skip firewall rule setup

# Approval workflow (requires MIRRORET_APPROVAL_ENABLED=1 during install):
sudo ./install.sh --list-staging # show packages awaiting approval
sudo ./install.sh --approve-all-pip # approve all staged pip packages
sudo ./install.sh --approve-all-npm # approve all staged npm packages
sudo ./install.sh --approve-package flask # approve a specific package by name fragment
sudo ./install.sh --approve-all-rpm # approve all staged RPMs (rebuilds repodata)
sudo ./install.sh --approve-rpm glibc # approve staged RPMs matching a name

# Or use the CLI, which covers all three package types:
mirroretctl approve list
sudo mirroretctl approve all rpm
sudo mirroretctl approve deny npm oldlib
sudo ./install.sh --exclude-pip badpkg # decline (remove) a staged pip package
sudo ./install.sh --exclude-npm oldlib # decline a staged npm package

# Rollback:
sudo ./install.sh --list-backups
sudo ./install.sh --rollback <backup-id>

# Uninstall (selective or full):
sudo ./uninstall.sh --list # preview, change nothing
sudo ./uninstall.sh --docker # remove only the Docker registry
sudo ./uninstall.sh --pip --npm # remove pip + npm only
sudo ./uninstall.sh --all --purge --yes # full wipe incl. data + GPG

# Development and testing:
make lint # shellcheck install.sh + lib/*.sh + scripts/*.sh
make test # run every BATS file in tests/
make format # auto-format scripts with shfmt
make check-deps # check for required tools
make dry-run # run install.sh --dry-run
```

---

## Documentation

| Document | Contents |
|----------|---------|
| [docs/MULTI-DISTRO.md](docs/MULTI-DISTRO.md) | **Mirroring several distributions from one server** - target syntax, upstream catalog, client URLs, disk sizing, what the engines guarantee |
| [docs/NETWORK_ACCESS.md](docs/NETWORK_ACCESS.md) | **Firewall rules** - inbound ports for clients, outbound ports for sync, firewall commands for ufw/firewalld/iptables |
| [docs/PROXY_AND_CA.md](docs/PROXY_AND_CA.md) | HTTP/HTTPS proxy setup and corporate TLS-inspection CA trust (sudo, apt/dnf, pip, npm, docker, podman, systemd, cron) |
| [docs/CONFIGURATION.md](docs/CONFIGURATION.md) | Full variable reference: TLS, GPG, approval, Docker mode, APT tool |
| [docs/SECURITY.md](docs/SECURITY.md) | TLS setup, GPG automation, nginx auth, privilege model |
| [docs/OPERATIONS.md](docs/OPERATIONS.md) | Daily ops: sync, approval workflow, Docker backend, disk management |
| [docs/NATIVE_MODE.md](docs/NATIVE_MODE.md) | Running without Docker: native Linux services on RHEL and Debian |
| [docs/ROLLBACK.md](docs/ROLLBACK.md) | Backup and rollback procedures |
| [DEPLOY-RUNBOOK.md](DEPLOY-RUNBOOK.md) | Step by step deploy runbook for an admin (zip transfer, verify, sync, client setup) |
| [docs/UNINSTALL.md](docs/UNINSTALL.md) | Selective and full uninstall (`./uninstall.sh`) |
| [docs/RETENTION.md](docs/RETENTION.md) | Mirror data retention/cleanup + safe upgrade workflow |
| [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) | Diagnostic steps for all components |
| [docs/QUICK-REFERENCE.md](docs/QUICK-REFERENCE.md) | One-page cheat sheet of all common commands |
| [docs/CLIENT-CONFIGURATION-GUIDE.md](docs/CLIENT-CONFIGURATION-GUIDE.md) | Complete client setup for APT, RPM, pip, npm, Docker |
| [docs/ARCHITECTURE-MANAGEMENT.md](docs/ARCHITECTURE-MANAGEMENT.md) | System architecture, workflows, management operations |
| [docs/DEPLOYMENT-CHECKLIST.md](docs/DEPLOYMENT-CHECKLIST.md) | Step-by-step deployment verification checklist |
| [docs/NETWORK-ARCHITECTURE.md](docs/NETWORK-ARCHITECTURE.md) | Network topology and advanced configurations |
| [docs/PACKAGE-CONTROL.md](docs/PACKAGE-CONTROL.md) | Advanced approval workflows and security |
| [docs/DIRECTORY-STRUCTURE.md](docs/DIRECTORY-STRUCTURE.md) | Complete directory layout and operations reference |
| [docs/TROUBLESHOOTING-GUIDE.md](docs/TROUBLESHOOTING-GUIDE.md) | Comprehensive troubleshooting for all services |

---

## Repository layout

```
mirroret/
+-- install.sh Main installer entry point
+-- Makefile lint / test / format / check-deps targets
+-- config/
| +-- mirroret.conf.example Documented config file template
+-- engines/
| +-- mirroret_fetch.py Shared retrying, checksum-verified fetcher
| +-- mirroret_apt.py APT mirroring engine (stdlib Python only)
| +-- mirroret_rpm.py RPM mirroring engine (stdlib Python only)
+-- lib/
| +-- logging.sh Logging: section/info/warn/error/success/die
| +-- common.sh xrun() DRY_RUN wrapper, atomic_write, helpers
| +-- distro.sh Distro detection (DISTRO_TYPE, PKG_MGR, etc.)
| +-- preflight.sh Pre-install checks (disk, root, commands)
| +-- backup.sh Timestamped backups and rollback
| +-- nginx.sh nginx config (HTTP + optional TLS block)
| +-- systemd.sh systemd unit writing and enable/start
| +-- firewall.sh Firewall rules (ufw / firewalld / iptables)
| +-- targets.sh Upstream catalog + target specs (which distros to mirror)
| +-- apt.sh APT mirror: native engine / apt-mirror / debmirror
| +-- rpm.sh RPM mirror: native engine / reposync + createrepo
| +-- docker_registry.sh Docker registry: native or container backend
| +-- pip.sh pypiserver: install, unit, sync script
| +-- npm.sh Verdaccio: install, config, sync script
| +-- tls.sh TLS cert provisioning and nginx block helper
| +-- gpg.sh GPG key management and client distribution
| +-- approval.sh Package staging/approval workflow
| +-- validation.sh Post-install checks and status reporting
+-- tests/
| +-- test_helpers.bash Shared BATS setup helpers
| +-- test_distro.bats 11 tests - distro detection
| +-- test_config.bats 8 tests - config loading, backup IDs
| +-- test_security.bats 11 tests - security defaults, insecure flags
| +-- test_dryrun.bats 6 tests - DRY_RUN behaviour
| +-- test_integration.bats TLS, GPG, approval, Docker backend
| +-- test_engines.bats End-to-end engine tests against a local archive
| +-- test_targets.bats Multi-distro targets, catalog, wiring
| +-- fixtures/ Archive/repo generators + a repodata validator
+-- docs/
    +-- NETWORK_ACCESS.md Firewall rules - inbound and outbound
    +-- CONFIGURATION.md Config variable reference
    +-- SECURITY.md TLS, GPG, auth, privilege
    +-- OPERATIONS.md Daily ops, sync, approval, Docker
    +-- NATIVE_MODE.md Running without Docker
    +-- ROLLBACK.md Backup and rollback guide
    +-- TROUBLESHOOTING.md Diagnostic steps
    +-- DEEP_REVIEW.md Technical security review
```

---

## Known limitations and unsupported scenarios

- The mirroring engines are tested end-to-end against real (small) archives
  served over HTTP, including checksum verification, publish ordering,
  metadata rewriting and pruning. The installer's system-level steps
  (systemd, SELinux, firewall) are still exercised under DRY_RUN and with a
  mocked `/etc/os-release` only. Treat the first real sync of a large target
  as a capacity test.
- A full Ubuntu or Debian mirror is 300-600 GB per flavor and takes hours on
  first sync. `MIRRORET_APT_COMPONENTS="main restricted"` cuts that by
  roughly 90%. Retention is available but off by default
  ([docs/RETENTION.md](docs/RETENTION.md)).
- Docker registry has two operating modes (see `MIRRORET_DOCKER_MODE`):
    - `cache` (default): pull-through proxy. Clients pull through the
      mirror and layers are cached on demand. Pushes are rejected - this
      is a registry-level restriction, not a mirroret choice.
    - `hosted`: the registry accepts `docker push`. `sync-docker-images.sh`
      pre-seeds a curated list using a local `docker` or `podman` CLI.
- npm pre-seeding warms Verdaccio's cache by installing each package
  *through* it, which needs no credentials and caches the whole dependency
  tree. `MIRRORET_NPM_ALLOW_ANON_PUBLISH` now only governs whether people may
  `npm publish` in-house packages into the registry.
- **APT signed-by:** by default, generated client configs do NOT emit
  `signed-by=mirroret.gpg`. The mirrored Release files are signed by the
  upstream archive (Ubuntu/Debian), not by mirroret. If you re-sign the
  Release files manually, set `MIRRORET_APT_RESIGN=1` to have the client
  configs reference your mirror keyring. See `docs/SECURITY.md`.
- Debian 12 removed `apt-mirror` from its repos, and neither `apt-mirror` nor
  `debmirror` is installable on a RHEL host. The default native engine needs
  only `python3`, so this is no longer a constraint; the legacy tools remain
  available via `MIRRORET_APT_MIRROR_TOOL`.
- SELinux: file contexts are set blanket-style (`httpd_sys_content_t`)
  and `httpd_can_network_connect` is enabled. A custom policy module is
  not generated.
- TLS-inspecting middleboxes that re-sign upstream archive HTTPS will
  cause apt clients to reject the mirrored Release files. There is no
  fix short of an allow-list or manual re-sign. See `docs/PROXY_AND_CA.md`.
- Clean uninstall: `./uninstall.sh` (or `./install.sh --uninstall`)
  removes services, users, configs, and optionally data + GPG. It does
  NOT remove OS packages like nginx/Docker/Podman that the operator may
  use for other things - strip those by hand if desired. See
  [docs/UNINSTALL.md](docs/UNINSTALL.md).
- Mirroring several distro families concurrently is a supported, tested
  configuration - list them in `MIRRORET_APT_TARGETS` /
  `MIRRORET_RPM_TARGETS`. Each gets its own tree, URL prefix and client
  config.
- A filtered RPM mirror (an arch subset, or the default `--newest-only`) has
  locally rebuilt `repomd.xml`, so clients cannot use `repo_gpgcheck=1` on
  it. Package signatures are untouched, so `gpgcheck=1` still verifies the
  vendor's signature. Mirror everything
  (`MIRRORET_RPM_NEWEST_ONLY=0 MIRRORET_RPM_SOURCE=1`) to keep upstream's
  signed metadata.
- Mirroring RHEL itself from `cdn.redhat.com` needs this host's entitlement
  certificate; the engine picks up `/etc/pki/entitlement/*.pem`
  automatically on a registered host.

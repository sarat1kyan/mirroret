# mirroret

Local package repository server for Linux. Mirrors APT, RPM, pip, Docker, and npm packages so air-gapped or bandwidth-constrained machines can install packages from a local server instead of the internet.

---

## Quick start

### Requirements

- Linux: Ubuntu 20.04+, Debian 11+, or RHEL/CentOS/Rocky/AlmaLinux 8+
- Root access on the mirror server
- 50 GB free disk space minimum (200–500 GB recommended for a full APT mirror)
- Outbound internet access during installation and sync (see [docs/NETWORK_ACCESS.md](docs/NETWORK_ACCESS.md))

### Installation

```bash
git clone https://github.com/sarat1kyan/mirroret.git
cd mirroret

# Preview without making any changes:
sudo ./install.sh --dry-run

# Standard install (Docker as pull-through cache by default):
sudo ./install.sh

# Hosted Docker mode — accepts `docker push` for curated pre-seeding:
sudo ./install.sh --docker-mode hosted

# Standalone APT-only mirror, restricted to a corporate subnet:
sudo MIRRORET_FIREWALL_SOURCE=10.0.0.0/8 ./install.sh \
    --no-pip --no-docker --no-npm

# Force-treat the host as Debian even if /etc/os-release says otherwise:
sudo ./install.sh --apt-flavor debian

# Native mode — no Docker daemon required:
sudo MIRRORET_DOCKER_BACKEND=native ./install.sh

# Lab / air-gapped install (no GPG, no TLS — INSECURE; warning printed):
sudo ./install.sh --insecure

# Run the read-only diagnostic snapshot at any time:
sudo ./scripts/mirroret-debug.sh
sudo ./scripts/mirroret-debug.sh --net      # also probe outbound HTTPS
sudo ./scripts/mirroret-debug.sh --bundle   # write a /tmp tarball for support
```

### After installation

```bash
# 1. Open firewall ports for clients (if not done automatically):
#    See docs/NETWORK_ACCESS.md for firewall commands.

# 2. Run the initial sync (takes minutes to hours depending on what you mirror):
sudo /srv/mirroret/scripts/sync-all.sh

# 3. Validate the installation:
sudo ./install.sh --check

# 4. Distribute client configs to your machines:
ls /srv/mirroret/config/
```

---

## Supported package types

| Type | Service | Default port | Client config |
|------|---------|-------------|---------------|
| APT (Debian/Ubuntu) | nginx | 8080 | `config/debian-client.list` |
| RPM (RHEL/CentOS/Rocky) | nginx | 8080 | `config/redhat-client.repo` |
| pip (Python) | pypiserver | 8081 | `config/pip.conf` |
| Docker images | docker-distribution / registry:2 | 5000 | `config/docker-daemon.json` |
| npm | Verdaccio | 4873 | `config/.npmrc` |
| HTTPS (optional) | nginx TLS | 8443 | use `--tls-self-signed` or bring your own cert |

All ports are configurable. See [docs/CONFIGURATION.md](docs/CONFIGURATION.md).

---

## Supported distributions

**Server:** Ubuntu 20.04/22.04/24.04, Debian 11/12, RHEL/CentOS/Rocky/AlmaLinux 8/9

**Clients:** Any Linux distribution that uses APT, yum/dnf, pip, Docker, or npm.

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
MIRRORET_SERVER_IP=192.168.1.10        # IP written into client configs
MIRRORET_FIREWALL_SOURCE=10.0.0.0/8    # Restrict inbound access by subnet

# Docker
MIRRORET_DOCKER_MODE=cache             # cache (default, pull-through) | hosted
MIRRORET_DOCKER_BACKEND=native         # Use OS-native registry (no Docker daemon)
MIRRORET_DOCKER_UPSTREAM_URL=https://registry-1.docker.io   # cache-mode upstream

# APT
MIRRORET_APT_FLAVOR=auto               # auto | ubuntu | debian
MIRRORET_APT_UPSTREAM_HOST=            # override upstream archive host
MIRRORET_APT_MIRROR_TOOL=debmirror     # Required on Debian 12 (apt-mirror removed)
MIRRORET_APT_RESIGN=0                  # See docs/SECURITY.md before enabling

# RPM
MIRRORET_RPM_FLAVOR=                   # Override OS_ID-based directory name
MIRRORET_RPM_REPOS=                    # Space-separated repo names to sync

# Other
MIRRORET_TLS_SELF_SIGNED=1             # Auto-generate a self-signed TLS cert
MIRRORET_GPG_AUTO=1                    # Auto-generate a GPG signing key
MIRRORET_APPROVAL_ENABLED=1            # Require admin approval before serving pip/npm
MIRRORET_PREFLIGHT_NETWORK=1           # Probe outbound HTTPS during preflight
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
sudo ./install.sh                          # full install (all components)
sudo ./install.sh --dry-run                # preview changes without applying
sudo ./install.sh --check                  # validate an existing installation
sudo ./install.sh --status                 # print service status
sudo ./install.sh --backup-only            # snapshot current state

# Feature flags (can be combined):
sudo ./install.sh --tls-self-signed        # enable HTTPS with auto-generated cert
sudo ./install.sh --gpg-auto               # auto-generate GPG signing key
sudo ./install.sh --approval-mode          # enable staging/approval workflow for pip/npm
sudo ./install.sh --insecure               # disable all security checks (LAB ONLY)

# Skip components:
sudo ./install.sh --no-apt                 # skip APT mirror
sudo ./install.sh --no-rpm                 # skip RPM mirror
sudo ./install.sh --no-pip                 # skip pypiserver
sudo ./install.sh --no-docker              # skip Docker registry
sudo ./install.sh --no-npm                 # skip Verdaccio / npm
sudo ./install.sh --no-firewall            # skip firewall rule setup

# Approval workflow (requires MIRRORET_APPROVAL_ENABLED=1 during install):
sudo ./install.sh --list-staging           # show packages awaiting approval
sudo ./install.sh --approve-all-pip        # approve all staged pip packages
sudo ./install.sh --approve-all-npm        # approve all staged npm packages
sudo ./install.sh --approve-package flask  # approve a specific package by name fragment
sudo ./install.sh --exclude-pip badpkg     # decline (remove) a staged pip package
sudo ./install.sh --exclude-npm oldlib     # decline a staged npm package

# Rollback:
sudo ./install.sh --list-backups
sudo ./install.sh --rollback <backup-id>

# Uninstall (selective or full):
sudo ./uninstall.sh --list                # preview, change nothing
sudo ./uninstall.sh --docker              # remove only the Docker registry
sudo ./uninstall.sh --pip --npm           # remove pip + npm only
sudo ./uninstall.sh --all --purge --yes   # full wipe incl. data + GPG

# Development and testing:
make lint                            # shellcheck install.sh + lib/*.sh + scripts/*.sh
make test                            # run every BATS file in tests/
make format                          # auto-format scripts with shfmt
make check-deps                      # check for required tools
make dry-run                         # run install.sh --dry-run
```

---

## Documentation

| Document | Contents |
|----------|---------|
| [docs/NETWORK_ACCESS.md](docs/NETWORK_ACCESS.md) | **Firewall rules** — inbound ports for clients, outbound ports for sync, firewall commands for ufw/firewalld/iptables |
| [docs/PROXY_AND_CA.md](docs/PROXY_AND_CA.md) | HTTP/HTTPS proxy setup and corporate TLS-inspection CA trust (sudo, apt/dnf, pip, npm, docker, podman, systemd, cron) |
| [docs/CONFIGURATION.md](docs/CONFIGURATION.md) | Full variable reference: TLS, GPG, approval, Docker mode, APT tool |
| [docs/SECURITY.md](docs/SECURITY.md) | TLS setup, GPG automation, nginx auth, privilege model |
| [docs/OPERATIONS.md](docs/OPERATIONS.md) | Daily ops: sync, approval workflow, Docker backend, disk management |
| [docs/NATIVE_MODE.md](docs/NATIVE_MODE.md) | Running without Docker: native Linux services on RHEL and Debian |
| [docs/ROLLBACK.md](docs/ROLLBACK.md) | Backup and rollback procedures |
| [docs/UNINSTALL.md](docs/UNINSTALL.md) | Selective and full uninstall (`./uninstall.sh`) |
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
├── install.sh                  Main installer entry point
├── Makefile                    lint / test / format / check-deps targets
├── config/
│   └── mirroret.conf.example   Documented config file template
├── lib/
│   ├── logging.sh              Logging: section/info/warn/error/success/die
│   ├── common.sh               xrun() DRY_RUN wrapper, atomic_write, helpers
│   ├── distro.sh               Distro detection (DISTRO_TYPE, PKG_MGR, etc.)
│   ├── preflight.sh            Pre-install checks (disk, root, commands)
│   ├── backup.sh               Timestamped backups and rollback
│   ├── nginx.sh                nginx config (HTTP + optional TLS block)
│   ├── systemd.sh              systemd unit writing and enable/start
│   ├── firewall.sh             Firewall rules (ufw / firewalld / iptables)
│   ├── apt.sh                  APT mirror: apt-mirror / apt-mirror2 / debmirror
│   ├── rpm.sh                  RPM mirror: createrepo, reposync
│   ├── docker_registry.sh      Docker registry: native or container backend
│   ├── pip.sh                  pypiserver: install, unit, sync script
│   ├── npm.sh                  Verdaccio: install, config, sync script
│   ├── tls.sh                  TLS cert provisioning and nginx block helper
│   ├── gpg.sh                  GPG key management and client distribution
│   ├── approval.sh             Package staging/approval workflow
│   └── validation.sh           Post-install checks and status reporting
├── tests/
│   ├── test_helpers.bash       Shared BATS setup helpers
│   ├── test_distro.bats        11 tests — distro detection
│   ├── test_config.bats        8 tests  — config loading, backup IDs
│   ├── test_security.bats      11 tests — security defaults, insecure flags
│   ├── test_dryrun.bats        6 tests  — DRY_RUN behaviour
│   └── test_integration.bats  TLS, GPG, approval, Docker backend
└── docs/
    ├── NETWORK_ACCESS.md       Firewall rules — inbound and outbound
    ├── CONFIGURATION.md        Config variable reference
    ├── SECURITY.md             TLS, GPG, auth, privilege
    ├── OPERATIONS.md           Daily ops, sync, approval, Docker
    ├── NATIVE_MODE.md          Running without Docker
    ├── ROLLBACK.md             Backup and rollback guide
    ├── TROUBLESHOOTING.md      Diagnostic steps
    └── DEEP_REVIEW.md          Technical security review
```

---

## Known limitations and unsupported scenarios

- Mirroret has not been end-to-end validated against every real upstream;
  installs are tested under DRY_RUN and with mocked `/etc/os-release` only.
  Treat the first real sync as a smoke test, not a guarantee.
- Full APT mirror requires 200–500 GB and several hours on first sync.
  Sizes grow over time — there is no automatic retention/cleanup.
- Docker registry has two operating modes (see `MIRRORET_DOCKER_MODE`):
    - `cache` (default): pull-through proxy. Clients pull through the
      mirror and layers are cached on demand. Pushes are rejected — this
      is a registry-level restriction, not a mirroret choice.
    - `hosted`: the registry accepts `docker push`. `sync-docker-images.sh`
      pre-seeds a curated list using a local `docker` or `podman` CLI.
- npm auto-publish to Verdaccio requires `npm login` unless you set
  `MIRRORET_NPM_ALLOW_ANON_PUBLISH=1`.
- **APT signed-by:** by default, generated client configs do NOT emit
  `signed-by=mirroret.gpg`. The mirrored Release files are signed by the
  upstream archive (Ubuntu/Debian), not by mirroret. If you re-sign the
  Release files manually, set `MIRRORET_APT_RESIGN=1` to have the client
  configs reference your mirror keyring. See `docs/SECURITY.md`.
- Debian 12 (Bookworm) removed `apt-mirror` from its repos. Set
  `MIRRORET_APT_MIRROR_TOOL=debmirror` or let mirroret fall back automatically.
- SELinux: file contexts are set blanket-style (`httpd_sys_content_t`)
  and `httpd_can_network_connect` is enabled. A custom policy module is
  not generated.
- TLS-inspecting middleboxes that re-sign upstream archive HTTPS will
  cause apt clients to reject the mirrored Release files. There is no
  fix short of an allow-list or manual re-sign. See `docs/PROXY_AND_CA.md`.
- Clean uninstall: `./uninstall.sh` (or `./install.sh --uninstall`)
  removes services, users, configs, and optionally data + GPG. It does
  NOT remove OS packages like nginx/Docker/Podman that the operator may
  use for other things — strip those by hand if desired. See
  [docs/UNINSTALL.md](docs/UNINSTALL.md).
- Mirroring more than one distro family on a single host concurrently
  (e.g. Rocky AND AlmaLinux) is possible but largely untested — set
  `MIRRORET_RPM_FLAVOR` explicitly per install.

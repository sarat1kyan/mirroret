# mirroret

Local package repository server for Linux environments. Mirrors APT, RPM, pip, Docker, and npm packages so air-gapped or bandwidth-constrained machines can install packages from a local server.

**Status: functional for lab and production use. TLS and GPG can be auto-provisioned. See [docs/SECURITY.md](docs/SECURITY.md).**

---

## Quick start

### Requirements

- Linux (Ubuntu 20.04+, Debian 11+, RHEL/CentOS/Rocky 8+)
- Root access
- Sufficient disk space (50 GB minimum, 200–500 GB recommended for full APT mirror)

### Installation

```bash
git clone https://github.com/sarat1kyan/mirroret.git
cd mirroret

# Standard install (secure defaults — requires GPG setup before clients work):
sudo ./install.sh

# With TLS and GPG auto-provisioned:
sudo ./install.sh --tls-self-signed --gpg-auto

# With staging/approval workflow for pip and npm:
sudo ./install.sh --approval-mode

# Lab / air-gapped install (insecure mode — no GPG, no TLS):
sudo ./install.sh --insecure

# Preview what will happen without making changes:
sudo ./install.sh --dry-run

# Install only APT mirror, restrict to specific subnet:
sudo MIRRORET_FIREWALL_SOURCE=10.0.0.0/8 ./install.sh --no-pip --no-docker --no-npm

# Native mode (no Docker daemon required):
sudo MIRRORET_DOCKER_BACKEND=native ./install.sh
```

### After installation

```bash
# 1. Run initial sync (takes minutes to hours depending on what you mirror):
sudo /srv/mirroret/scripts/sync-all.sh

# 2. Validate the installation:
sudo ./install.sh --check

# 3. Distribute client configs:
ls /srv/mirroret/config/
```

---

## Supported package types

| Type | Service | Port | Client config |
|------|---------|------|---------------|
| APT (Debian/Ubuntu) | nginx | 8080 | `config/debian-client.list` |
| RPM (RHEL/CentOS/Rocky) | nginx | 8080 | `config/redhat-client.repo` |
| pip (Python) | pypiserver | 8081 | `config/pip.conf` |
| Docker images | docker-distribution / registry:2 | 5000 | `config/docker-daemon.json` |
| npm | Verdaccio | 4873 | `config/.npmrc` |
| HTTPS | nginx TLS | 8443 | (cert distribution via GPG/TLS scripts) |

All ports are configurable. See [docs/CONFIGURATION.md](docs/CONFIGURATION.md).

---

## Supported distributions

**Server:** Ubuntu 20.04/22.04/24.04, Debian 11/12, RHEL/CentOS/Rocky/AlmaLinux 8/9

**Clients:** Any Linux distribution that uses APT, yum/dnf, pip, Docker, or npm.

---

## Configuration

See [docs/CONFIGURATION.md](docs/CONFIGURATION.md) for full variable reference.

```bash
# Copy the example config:
sudo mkdir -p /etc/mirroret
sudo cp config/mirroret.conf.example /etc/mirroret/mirroret.conf
sudo ./install.sh --config /etc/mirroret/mirroret.conf
```

Key settings:

```bash
MIRRORET_SERVER_IP=192.168.1.10       # IP for client configs
MIRRORET_FIREWALL_SOURCE=10.0.0.0/8  # Restrict access by subnet
MIRRORET_APT_KEYRING=/etc/apt/keyrings/mirroret.gpg  # GPG keyring

# New in production release:
MIRRORET_TLS_SELF_SIGNED=1           # Auto TLS cert generation
MIRRORET_GPG_AUTO=1                  # Auto GPG key generation
MIRRORET_APPROVAL_ENABLED=1          # Package staging/approval workflow
MIRRORET_DOCKER_BACKEND=native       # Native OS registry (no container runtime)
MIRRORET_APT_MIRROR_TOOL=debmirror   # Use debmirror (required on Debian 12)
```

---

## Security

**Default behaviour (secure):** Client configs are generated with GPG verification enabled. APT clients will not work until you configure a GPG keyring or use `--gpg-auto`. RPM clients will not work until you set `MIRRORET_RPM_GPGKEY_URL`.

**Lab/insecure mode:** Use `--insecure` to disable GPG and TLS checks. A loud warning is printed. Only use this in isolated environments.

See [docs/SECURITY.md](docs/SECURITY.md) for:
- TLS auto-provisioning (`--tls-self-signed`) and BYOC setup
- GPG auto-provisioning (`--gpg-auto`) and key distribution
- nginx authentication
- Firewall scoping

---

## Commands

```bash
# Installation and modes:
sudo ./install.sh                          # full install
sudo ./install.sh --dry-run                # preview changes
sudo ./install.sh --check                  # validate installation
sudo ./install.sh --status                 # service status
sudo ./install.sh --backup-only            # backup current state
sudo ./install.sh --tls-self-signed        # enable HTTPS with auto cert
sudo ./install.sh --gpg-auto               # auto GPG key generation
sudo ./install.sh --approval-mode          # enable staging/approval workflow

# Approval workflow:
sudo ./install.sh --list-staging           # show packages awaiting approval
sudo ./install.sh --approve-all-pip        # approve all staged pip packages
sudo ./install.sh --approve-all-npm        # approve all staged npm packages
sudo ./install.sh --approve-package flask  # approve a specific package
sudo ./install.sh --exclude-pip badpkg     # decline a staged pip package

# Rollback:
sudo ./install.sh --list-backups
sudo ./install.sh --rollback <backup-id>

# Development:
make lint                            # shellcheck all scripts
make test                            # run unit tests (36 tests)
make test-integration                # run integration tests (52 tests)
make test-all                        # run all tests
make format                          # auto-format with shfmt
make check-deps                      # check tool availability
```

---

## Documentation

| Document | Contents |
|----------|---------|
| [docs/CONFIGURATION.md](docs/CONFIGURATION.md) | All config variables including TLS, GPG, approval, Docker backend |
| [docs/SECURITY.md](docs/SECURITY.md) | TLS setup, GPG automation, auth, privilege |
| [docs/OPERATIONS.md](docs/OPERATIONS.md) | Daily operations, sync, approval workflow, Docker backend |
| [docs/NATIVE_MODE.md](docs/NATIVE_MODE.md) | Running without Docker: native Linux services |
| [docs/ROLLBACK.md](docs/ROLLBACK.md) | Backup and rollback procedures |
| [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) | Diagnostic steps including TLS, GPG, debmirror, approval |
| [docs/NETWORK_ACCESS.md](docs/NETWORK_ACCESS.md) | Outbound and inbound port reference |
| [docs/DEEP_REVIEW.md](docs/DEEP_REVIEW.md) | Technical security review |

---

## Structure

```
mirroret/
├── install.sh                  Main entry point
├── mirroret.sh                 Original basic installer (APT/RPM only)
├── mirroret-unified.sh         Original unified installer (all types)
├── config/
│   └── mirroret.conf.example   Config file template
├── lib/
│   ├── logging.sh              Logging functions
│   ├── common.sh               DRY_RUN, xrun(), helpers
│   ├── distro.sh               Distribution detection
│   ├── preflight.sh            Pre-install checks
│   ├── backup.sh               Backup and rollback
│   ├── nginx.sh                nginx config management (HTTP + TLS blocks)
│   ├── systemd.sh              systemd unit management
│   ├── firewall.sh             Firewall rule management
│   ├── apt.sh                  APT mirror (apt-mirror / apt-mirror2 / debmirror)
│   ├── rpm.sh                  RPM mirror configuration
│   ├── docker_registry.sh      Docker registry (native or container backend)
│   ├── pip.sh                  pypiserver setup + staging/approval support
│   ├── npm.sh                  Verdaccio setup + auto-publish + staging support
│   ├── tls.sh                  TLS cert provisioning and nginx block helper
│   ├── gpg.sh                  GPG key management and client distribution
│   ├── approval.sh             Package staging/approval workflow
│   └── validation.sh           Status and validation checks
├── tests/
│   ├── test_distro.bats        Distro detection tests
│   ├── test_config.bats        Config and backup tests
│   ├── test_security.bats      Security defaults tests
│   ├── test_dryrun.bats        Dry-run behaviour tests
│   ├── test_integration.bats   Integration tests (TLS, GPG, approval, etc.)
│   └── test_helpers.bash       BATS helper functions
├── docs/
│   ├── SECURITY.md             TLS, GPG, auth, privilege
│   ├── CONFIGURATION.md        Config variable reference
│   ├── OPERATIONS.md           Daily ops, sync, approval, Docker backend
│   ├── NATIVE_MODE.md          Running without Docker
│   ├── ROLLBACK.md             Backup and rollback guide
│   ├── TROUBLESHOOTING.md      Troubleshooting guide
│   ├── NETWORK_ACCESS.md       Port reference
│   └── DEEP_REVIEW.md          Technical security review
└── Makefile                    lint/test/format targets
```

---

## Known limitations

- Full APT mirror requires 200–500 GB and several hours on first sync.
- The original `mirroret.sh` and `mirroret-unified.sh` are preserved as-is for reference.
- SELinux context changes are best-effort on RHEL-based systems.
- Docker image pre-seed (`sync-docker-images.sh`) requires `docker` or `podman` CLI installed even with the native registry backend.
- npm auto-publish to Verdaccio requires `npm login` first when `MIRRORET_NPM_ALLOW_ANON_PUBLISH=0` (the default).
- Verdaccio does not serve downloaded tarballs as static files; it proxies npm install requests. The staging/approval workflow stores tarballs for admin review before they are published to Verdaccio.
- debmirror requires the Ubuntu archive keyring on Debian hosts. See [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md#debmirror-gpg).

See [docs/DEEP_REVIEW.md](docs/DEEP_REVIEW.md) for the full technical security review.

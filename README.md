# mirroret

Local package repository server for Linux environments. Mirrors APT, RPM, pip, Docker, and npm packages so air-gapped or bandwidth-constrained machines can install packages from a local server.

**Status: functional, suitable for lab use after review. Production deployments require GPG signing configuration. See [docs/SECURITY.md](docs/SECURITY.md).**

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

# Lab / air-gapped install (insecure mode — no GPG, no TLS):
sudo ./install.sh --insecure

# Preview what will happen without making changes:
sudo ./install.sh --dry-run

# Install only APT mirror, restrict to specific subnet:
sudo MIRRORET_FIREWALL_SOURCE=10.0.0.0/8 ./install.sh --no-pip --no-docker --no-npm
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
| Docker images | registry:2 | 5000 | `config/docker-daemon.json` |
| npm | Verdaccio | 4873 | `config/.npmrc` |

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
```

---

## Security

**Default behaviour (secure):** Client configs are generated with GPG verification enabled. APT clients will not work until you configure a GPG keyring. RPM clients will not work until you set `MIRRORET_RPM_GPGKEY_URL`.

**Lab/insecure mode:** Use `--insecure` to disable GPG and TLS checks. A loud warning is printed. Only use this in isolated environments.

See [docs/SECURITY.md](docs/SECURITY.md) for:
- GPG signing setup for APT and RPM
- TLS configuration for Docker and pip
- nginx authentication
- Firewall scoping

---

## Commands

```bash
# Installation and modes:
sudo ./install.sh                    # full install
sudo ./install.sh --dry-run          # preview changes
sudo ./install.sh --check            # validate installation
sudo ./install.sh --status           # service status
sudo ./install.sh --backup-only      # backup current state

# Rollback:
sudo ./install.sh --list-backups
sudo ./install.sh --rollback <backup-id>

# Development:
make lint                            # shellcheck all scripts
make test                            # run bats tests
make format                          # auto-format with shfmt
make check-deps                      # check tool availability
```

---

## Documentation

| Document | Contents |
|----------|---------|
| [docs/CONFIGURATION.md](docs/CONFIGURATION.md) | All config variables |
| [docs/SECURITY.md](docs/SECURITY.md) | GPG signing, TLS, auth, privilege |
| [docs/OPERATIONS.md](docs/OPERATIONS.md) | Daily operations, sync, disk management |
| [docs/ROLLBACK.md](docs/ROLLBACK.md) | Backup and rollback procedures |
| [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) | Diagnostic steps for common failures |
| [docs/DEEP_REVIEW.md](docs/DEEP_REVIEW.md) | Technical security review |
| [docs/IMPLEMENTATION_REPORT.md](docs/IMPLEMENTATION_REPORT.md) | What was changed and why |

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
│   ├── common.sh               DRY_RUN, run(), helpers
│   ├── distro.sh               Distribution detection
│   ├── preflight.sh            Pre-install checks
│   ├── backup.sh               Backup and rollback
│   ├── nginx.sh                nginx config management
│   ├── systemd.sh              systemd unit management
│   ├── firewall.sh             Firewall rule management
│   ├── apt.sh                  APT mirror configuration
│   ├── rpm.sh                  RPM mirror configuration
│   ├── docker_registry.sh      Docker registry setup
│   ├── pip.sh                  pypiserver setup
│   ├── npm.sh                  Verdaccio setup
│   └── validation.sh           Status and validation checks
├── tests/
│   ├── test_distro.bats        Distro detection tests
│   ├── test_config.bats        Config and backup tests
│   ├── test_security.bats      Security defaults tests
│   ├── test_dryrun.bats        Dry-run behaviour tests
│   └── test_helpers.bash       BATS helper functions
├── docs/
│   ├── DEEP_REVIEW.md          Technical security review
│   ├── SECURITY.md             Security configuration guide
│   ├── CONFIGURATION.md        Config variable reference
│   ├── OPERATIONS.md           Daily operations guide
│   ├── ROLLBACK.md             Backup and rollback guide
│   ├── TROUBLESHOOTING.md      Troubleshooting guide
│   └── IMPLEMENTATION_REPORT.md Change summary
└── Makefile                    lint/test/format targets
```

---

## Known limitations

- No built-in TLS termination (use a reverse proxy for production)
- Docker registry does not include TLS by default (configure TLS before production use)
- Full APT mirror requires 200–500 GB and several hours on first sync
- The original `mirroret.sh` and `mirroret-unified.sh` are preserved as-is for reference
- SELinux context changes are best-effort on RHEL-based systems

See [docs/DEEP_REVIEW.md](docs/DEEP_REVIEW.md) for the full list of known issues.

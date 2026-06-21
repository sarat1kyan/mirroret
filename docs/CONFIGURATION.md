# Configuration Reference

All configuration is done through environment variables or a config file.

## Config file

Copy the example config and edit it:

```bash
sudo mkdir -p /etc/mirroret
sudo cp config/mirroret.conf.example /etc/mirroret/mirroret.conf
sudo nano /etc/mirroret/mirroret.conf

# Load during installation:
sudo ./install.sh --config /etc/mirroret/mirroret.conf
```

Variables in the config file are plain shell assignments. Environment variables take precedence over the config file.

---

## Variable reference

### Paths

| Variable | Default | Description |
|---|---|---|
| `MIRRORET_BASE_DIR` | `/srv/mirroret` | Base directory for all repository data |
| `MIRRORET_BACKUP_BASE` | `/var/backups/mirroret` | Backup directory |
| `MIRRORET_LOG_FILE` | `/var/log/mirroret-install.log` | Installation log |

### Network

| Variable | Default | Description |
|---|---|---|
| `MIRRORET_SERVER_IP` | auto-detected | IP address used in client configs |
| `MIRRORET_WEB_PORT` | `8080` | nginx HTTP port |
| `MIRRORET_PIP_PORT` | `8081` | pypiserver port |
| `MIRRORET_DOCKER_REGISTRY_PORT` | `5000` | Docker registry port |
| `MIRRORET_NPM_PORT` | `4873` | Verdaccio npm port |
| `MIRRORET_FIREWALL_SOURCE` | *(empty)* | Source CIDR for firewall rules (empty = any) |

### Distribution detection

| Variable | Default | Description |
|---|---|---|
| `MIRRORET_UBUNTU_CODENAME` | auto-detected | Ubuntu codename to mirror (jammy, noble, etc.) |
| `MIRRORET_RHEL_VERSION` | auto-detected | RHEL major version (8, 9, etc.) |
| `MIRRORET_APT_ARCH` | `amd64` | APT mirror architecture |
| `MIRRORET_APT_THREADS` | `10` | apt-mirror download threads |

### TLS

| Variable | Default | Description |
|---|---|---|
| `MIRRORET_TLS_SELF_SIGNED` | `0` | Generate a self-signed cert during install |
| `MIRRORET_TLS_CERT` | *(empty)* | Path to an existing PEM certificate |
| `MIRRORET_TLS_KEY` | *(empty)* | Path to the matching private key |
| `MIRRORET_TLS_PORT` | `8443` | nginx HTTPS listener port |
| `MIRRORET_TLS_DIR` | `/etc/mirroret/tls` | Directory for generated cert/key files |

### GPG signing

| Variable | Default | Description |
|---|---|---|
| `MIRRORET_GPG_AUTO` | `0` | Auto-generate a GPG key if none exists |
| `MIRRORET_GPG_NAME` | `mirroret` | Real Name field for the generated key |
| `MIRRORET_GPG_EMAIL` | `mirroret@localhost` | Email field for the generated key |
| `MIRRORET_GPG_HOMEDIR` | `/etc/mirroret/gnupg` | GPG home directory (isolated keyring) |
| `MIRRORET_GPG_KEYID` | *(empty)* | Fingerprint of an existing key to use |

### Package approval workflow

| Variable | Default | Description |
|---|---|---|
| `MIRRORET_APPROVAL_ENABLED` | `0` | Enable staging→approved workflow for pip/npm |

When enabled, sync scripts download to `BASE_DIR/staging/{pip,npm}/`. Use
`--approve-all-pip`, `--approve-all-npm`, `--approve-package`, `--exclude-pip`,
or `--exclude-npm` to manage the queue.

### Docker registry backend

| Variable | Default | Description |
|---|---|---|
| `MIRRORET_DOCKER_BACKEND` | `auto` | `auto`, `native`, or `container` |
| `MIRRORET_DOCKER_IMAGES_FILE` | *(empty)* | Path to image list file (one per line) |

`auto`: use OS package if available, fall back to container.
`native`: `docker-distribution` (RHEL) or `docker-registry` (Debian).
`container`: `registry:2` via Docker or Podman.

### APT mirror tool

| Variable | Default | Description |
|---|---|---|
| `MIRRORET_APT_MIRROR_TOOL` | `auto` | `auto`, `apt-mirror`, or `debmirror` |

`auto`: tries apt-mirror, then apt-mirror2 (pip), then debmirror.
Debian 12 removed apt-mirror from its repos; use `debmirror` or `apt-mirror` with apt-mirror2.
See [TROUBLESHOOTING.md](TROUBLESHOOTING.md) for debmirror GPG issues.

### npm extras

| Variable | Default | Description |
|---|---|---|
| `MIRRORET_NPM_PACKAGES_FILE` | *(empty)* | Path to npm package list (one per line) |
| `MIRRORET_NPM_ALLOW_ANON_PUBLISH` | `0` | Allow unauthenticated publish to Verdaccio |

### Security

| Variable | Default | Description |
|---|---|---|
| `MIRRORET_APT_KEYRING` | *(empty)* | Path to GPG keyring for APT clients |
| `MIRRORET_APT_INSECURE` | `0` | Enable `trusted=yes` in APT configs (LAB ONLY) |
| `MIRRORET_RPM_GPGKEY_URL` | *(empty)* | URL to RPM GPG key |
| `MIRRORET_RPM_INSECURE` | `0` | Enable `gpgcheck=0` in RPM configs (LAB ONLY) |
| `MIRRORET_DOCKER_INSECURE` | `0` | Enable insecure Docker registry (LAB ONLY) |
| `MIRRORET_PIP_INSECURE` | `0` | Enable `trusted-host` in pip.conf (LAB ONLY) |

### Component toggles

| Variable | Default | Description |
|---|---|---|
| `MIRRORET_ENABLE_APT` | `1` | Enable APT mirror setup |
| `MIRRORET_ENABLE_RPM` | `1` | Enable RPM mirror setup |
| `MIRRORET_ENABLE_PIP` | `1` | Enable pypiserver setup |
| `MIRRORET_ENABLE_DOCKER` | `1` | Enable Docker registry setup |
| `MIRRORET_ENABLE_NPM` | `1` | Enable Verdaccio npm setup |

### Behaviour

| Variable | Default | Description |
|---|---|---|
| `MIRRORET_MIN_DISK_GB` | `50` | Minimum free disk space (GB) before install |
| `MIRRORET_NON_INTERACTIVE` | `0` | Suppress all prompts |
| `MIRRORET_SYNC_HOUR` | `2` | Hour for daily cron sync (0-23) |
| `LOG_LEVEL` | `INFO` | Log verbosity (`DEBUG` or `INFO`) |
| `DRY_RUN` | `0` | Dry-run mode (equivalent to `--dry-run`) |

---

## Common configurations

### APT-only mirror

```bash
MIRRORET_ENABLE_RPM=0
MIRRORET_ENABLE_PIP=0
MIRRORET_ENABLE_DOCKER=0
MIRRORET_ENABLE_NPM=0
```

### Restricted network access

```bash
MIRRORET_FIREWALL_SOURCE=192.168.10.0/24
MIRRORET_SERVER_IP=192.168.10.5
```

### Secure production setup

```bash
MIRRORET_APT_KEYRING=/etc/apt/keyrings/mirroret.gpg
MIRRORET_RPM_GPGKEY_URL=http://192.168.10.5:8080/config/RPM-GPG-KEY-mirroret
MIRRORET_APT_INSECURE=0
MIRRORET_RPM_INSECURE=0
MIRRORET_DOCKER_INSECURE=0
MIRRORET_PIP_INSECURE=0
MIRRORET_FIREWALL_SOURCE=192.168.10.0/24
```

### Lab/air-gapped setup

```bash
MIRRORET_APT_INSECURE=1
MIRRORET_RPM_INSECURE=1
MIRRORET_DOCKER_INSECURE=1
MIRRORET_PIP_INSECURE=1
```

Or use the `--insecure` flag:

```bash
sudo ./install.sh --insecure
```

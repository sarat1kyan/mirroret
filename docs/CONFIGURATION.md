# Configuration Reference

All configuration is done through environment variables or a config file.

## Config file

```bash
# Copy the example and customise it:
sudo mkdir -p /etc/mirroret
sudo cp config/mirroret.conf.example /etc/mirroret/mirroret.conf
sudo nano /etc/mirroret/mirroret.conf

# Load during installation:
sudo ./install.sh --config /etc/mirroret/mirroret.conf
```

The config file contains plain shell variable assignments. Environment variables
set in the shell take precedence over values in the config file.

---

## Variable reference

### Paths

| Variable | Default | Description |
|---|---|---|
| `MIRRORET_BASE_DIR` | `/srv/mirroret` | Root directory for all repository data and scripts |
| `MIRRORET_BACKUP_BASE` | `/var/backups/mirroret` | Directory for timestamped config backups |
| `MIRRORET_LOG_FILE` | `/var/log/mirroret-install.log` | Installation log file path |

### Network

| Variable | Default | Description |
|---|---|---|
| `MIRRORET_SERVER_IP` | auto-detected | IP address written into client config files. Set explicitly when auto-detection picks the wrong interface. |
| `MIRRORET_WEB_PORT` | `8080` | nginx HTTP listener port |
| `MIRRORET_PIP_PORT` | `8081` | pypiserver port |
| `MIRRORET_DOCKER_REGISTRY_PORT` | `5000` | Docker registry port |
| `MIRRORET_NPM_PORT` | `4873` | Verdaccio npm port |
| `MIRRORET_FIREWALL_SOURCE` | *(empty)* | Source CIDR to restrict inbound firewall rules (empty = allow from anywhere) |

### Distribution detection

| Variable | Default | Description |
|---|---|---|
| `MIRRORET_UBUNTU_CODENAME` | auto-detected | Ubuntu codename to mirror: `focal`, `jammy`, `noble`, etc. |
| `MIRRORET_RHEL_VERSION` | auto-detected | RHEL major version: `8` or `9` |
| `MIRRORET_APT_ARCH` | `amd64` | CPU architecture for the APT mirror |
| `MIRRORET_APT_THREADS` | `10` | Number of parallel download threads for apt-mirror |

### TLS

| Variable | Default | Description |
|---|---|---|
| `MIRRORET_TLS_SELF_SIGNED` | `0` | Set to `1` to auto-generate a self-signed cert during install |
| `MIRRORET_TLS_CERT` | *(empty)* | Path to an existing PEM-encoded certificate |
| `MIRRORET_TLS_KEY` | *(empty)* | Path to the matching PEM-encoded private key |
| `MIRRORET_TLS_PORT` | `8443` | nginx HTTPS listener port |
| `MIRRORET_TLS_DIR` | `/etc/mirroret/tls` | Directory where self-signed cert/key are stored |

Set either `MIRRORET_TLS_SELF_SIGNED=1` **or** both `MIRRORET_TLS_CERT` + `MIRRORET_TLS_KEY`.
Both options enable the TLS listener. Without at least one, TLS is off (HTTP only).

### GPG signing

| Variable | Default | Description |
|---|---|---|
| `MIRRORET_GPG_AUTO` | `0` | Set to `1` to auto-generate a 4096-bit RSA key if none exists |
| `MIRRORET_GPG_NAME` | `mirroret` | Real Name field used when generating a key |
| `MIRRORET_GPG_EMAIL` | `mirroret@localhost` | Email field used when generating a key |
| `MIRRORET_GPG_HOMEDIR` | `/etc/mirroret/gnupg` | Isolated GPG keyring directory (separate from system keyring) |
| `MIRRORET_GPG_KEYID` | *(empty)* | Fingerprint of an existing key to use; auto-detected from the homedir when empty |

After `setup_gpg()` runs, `MIRRORET_APT_KEYRING` is set to the exported binary keyring path
and `MIRRORET_GPG_KEYID` is set to the key fingerprint in use.

### Package approval workflow

| Variable | Default | Description |
|---|---|---|
| `MIRRORET_APPROVAL_ENABLED` | `0` | Set to `1` to enable the staging → approved workflow for pip and npm |

When enabled:
- Sync scripts download packages to `BASE_DIR/staging/{pip,npm}/` instead of serving them directly.
- Nothing is served until an admin promotes packages to `BASE_DIR/approved/{pip,npm}/`.
- Use `--list-staging`, `--approve-all-pip`, `--approve-all-npm`, `--approve-package`,
  `--exclude-pip`, `--exclude-npm` to manage the queue.

Directory layout with approval enabled:

```
/srv/mirroret/
├── staging/
│   ├── pip/    ← sync downloads pip packages here
│   └── npm/    ← sync downloads npm tarballs here
└── approved/
    ├── pip/    ← pypiserver serves from here
    └── npm/    ← nginx serves as static files from here
```

### Docker registry backend

| Variable | Default | Description |
|---|---|---|
| `MIRRORET_DOCKER_BACKEND` | `auto` | `auto`, `native`, or `container` |
| `MIRRORET_DOCKER_IMAGES_FILE` | *(empty)* | Path to a file listing images to pre-seed (one per line, `#` for comments) |

- `auto` — use the OS-native registry package if available; fall back to the `registry:2` container.
- `native` — install `docker-distribution` (RHEL) or `docker-registry` (Debian/Ubuntu) as a systemd service.
- `container` — run `registry:2` via Docker or Podman. Podman is detected automatically (podman-docker shim).

### APT mirror tool

| Variable | Default | Description |
|---|---|---|
| `MIRRORET_APT_MIRROR_TOOL` | `auto` | `auto`, `apt-mirror`, or `debmirror` |

- `auto` — try `apt-mirror`, then `apt-mirror2` (pip), then `debmirror`.
- `apt-mirror` — use `apt-mirror`. Falls back to `apt-mirror2` (pip) if not installed.
- `debmirror` — use `debmirror`. Required on Debian 12+ where `apt-mirror` was removed from the repos.

After `configure_apt_mirror()` runs, `MIRRORET_APT_RESOLVED_TOOL` is exported with the
actual tool selected, and `MIRRORET_APT_DATA_PATH` is exported with the path nginx serves
as `/ubuntu`.

### npm extras

| Variable | Default | Description |
|---|---|---|
| `MIRRORET_NPM_PACKAGES_FILE` | *(empty)* | Path to a plain-text file listing npm packages to sync (one per line, `#` for comments) |
| `MIRRORET_NPM_ALLOW_ANON_PUBLISH` | `0` | Set to `1` to allow unauthenticated publish to Verdaccio |

When `MIRRORET_NPM_ALLOW_ANON_PUBLISH=0` (default), `npm login` must be run against the
Verdaccio URL before the sync script can publish packages. Set to `1` for networks where
authentication is not required.

### Security / insecure mode

| Variable | Default | Description |
|---|---|---|
| `MIRRORET_APT_KEYRING` | *(empty)* | Path to binary GPG keyring for APT `signed-by` field. Set automatically by `--gpg-auto`. |
| `MIRRORET_APT_INSECURE` | `0` | Set to `1` to add `trusted=yes` to APT client configs (LAB ONLY — disables GPG check) |
| `MIRRORET_RPM_GPGKEY_URL` | *(empty)* | URL to the GPG key for RPM client configs (`gpgkey=` field) |
| `MIRRORET_RPM_INSECURE` | `0` | Set to `1` to add `gpgcheck=0` to RPM client configs (LAB ONLY) |
| `MIRRORET_DOCKER_INSECURE` | `0` | Set to `1` to add `insecure-registries` to Docker client config (LAB ONLY) |
| `MIRRORET_PIP_INSECURE` | `0` | Set to `1` to add `trusted-host` to pip.conf (LAB ONLY) |

Use `--insecure` on the command line to set all four insecure flags at once.

### Component toggles

| Variable | Default | Description |
|---|---|---|
| `MIRRORET_ENABLE_APT` | `1` | `0` to skip APT mirror setup (same as `--no-apt`) |
| `MIRRORET_ENABLE_RPM` | `1` | `0` to skip RPM mirror setup (`--no-rpm`) |
| `MIRRORET_ENABLE_PIP` | `1` | `0` to skip pypiserver setup (`--no-pip`) |
| `MIRRORET_ENABLE_DOCKER` | `1` | `0` to skip Docker registry setup (`--no-docker`) |
| `MIRRORET_ENABLE_NPM` | `1` | `0` to skip Verdaccio setup (`--no-npm`) |

### Behaviour

| Variable | Default | Description |
|---|---|---|
| `MIRRORET_MIN_DISK_GB` | `50` | Minimum free disk space in GB required before install proceeds |
| `MIRRORET_NON_INTERACTIVE` | `0` | Set to `1` to suppress all interactive prompts (auto-decline) |
| `MIRRORET_SYNC_HOUR` | `2` | Hour (0–23) for the daily cron sync |
| `LOG_LEVEL` | `INFO` | Log verbosity: `DEBUG` or `INFO` |
| `DRY_RUN` | `0` | Set to `1` for dry-run mode (no changes made). Same as `--dry-run`. |

### Service users

These users are created automatically during installation. You can override them if needed.

| Variable | Default | Description |
|---|---|---|
| `MIRRORET_PYPI_USER` | `mirroret-pip` | System user that runs pypiserver |
| `MIRRORET_NPM_USER` | `mirroret-npm` | System user that runs Verdaccio |

---

## Common configurations

### Recommended production setup

```bash
# /etc/mirroret/mirroret.conf
MIRRORET_SERVER_IP=192.168.10.5
MIRRORET_FIREWALL_SOURCE=192.168.10.0/24
MIRRORET_TLS_SELF_SIGNED=1
MIRRORET_GPG_AUTO=1
MIRRORET_APPROVAL_ENABLED=1
MIRRORET_DOCKER_BACKEND=native
MIRRORET_UBUNTU_CODENAME=jammy
```

```bash
sudo ./install.sh --config /etc/mirroret/mirroret.conf
```

### Minimal — APT mirror only, subnet-restricted

```bash
sudo MIRRORET_SERVER_IP=10.0.1.5 \
     MIRRORET_FIREWALL_SOURCE=10.0.0.0/8 \
     ./install.sh --no-rpm --no-pip --no-docker --no-npm --gpg-auto
```

### Lab / air-gapped, all components, no security checks

```bash
sudo ./install.sh --insecure
```

### Debian 12 server (apt-mirror not in repos)

```bash
sudo MIRRORET_APT_MIRROR_TOOL=debmirror ./install.sh --gpg-auto
```

### RHEL 9 server, native Docker registry, no container runtime

```bash
sudo MIRRORET_DOCKER_BACKEND=native \
     MIRRORET_SERVER_IP=10.1.0.10 \
     ./install.sh --gpg-auto --tls-self-signed
```

### Custom package lists — persist across reinstalls

```bash
# Docker images to pre-seed:
cat > /etc/mirroret/images.txt <<'EOF'
ubuntu:22.04
debian:12
nginx:stable
python:3.11-slim
node:20-slim
EOF

# npm packages:
cat > /etc/mirroret/npm-packages.txt <<'EOF'
express
lodash
typescript
webpack
EOF

sudo MIRRORET_DOCKER_IMAGES_FILE=/etc/mirroret/images.txt \
     MIRRORET_NPM_PACKAGES_FILE=/etc/mirroret/npm-packages.txt \
     ./install.sh
```

### Use an existing TLS certificate

```bash
sudo MIRRORET_TLS_CERT=/etc/ssl/certs/server.crt \
     MIRRORET_TLS_KEY=/etc/ssl/private/server.key \
     ./install.sh
```

---

## Runtime-only variables

These variables are set internally by `install.sh` during a run. They are not
user-configurable in the config file, but they are exported and can be read by
shell scripts that source the lib modules.

| Variable | Set by | Description |
|---|---|---|
| `MIRRORET_TLS_ENABLED` | `lib/tls.sh` | `1` when TLS cert and key are provisioned |
| `MIRRORET_APT_KEYRING` | `lib/gpg.sh` | Path to the binary GPG keyring for APT clients |
| `MIRRORET_GPG_KEYID` | `lib/gpg.sh` | Fingerprint of the GPG key in use |
| `MIRRORET_APT_DATA_PATH` | `lib/apt.sh` | Directory nginx serves as `/ubuntu` (tool-agnostic) |
| `MIRRORET_APT_RESOLVED_TOOL` | `lib/apt.sh` | Actual APT mirror tool used: `apt-mirror`, `apt-mirror2`, or `debmirror` |
| `DISTRO_TYPE` | `lib/distro.sh` | `debian` or `rhel` |
| `PKG_MGR` | `lib/distro.sh` | `apt-get` or `dnf` |
| `PKG_MGR_INSTALL` | `lib/distro.sh` | Full install command with flags |
| `CONTAINER_CMD` | `lib/docker_registry.sh` | `docker` or `podman` (set after runtime detection) |

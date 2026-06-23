# Native Linux Services Mode

mirroret can run entirely without Docker or Podman by using OS-native packages
and systemd services. This is called **native mode**.

---

## Why native mode

- No container runtime required on the mirror server.
- Simpler dependency chain on locked-down or minimal servers.
- All services managed by standard `systemctl` — no container lifecycle.
- Works on a fresh minimal RHEL/Rocky/AlmaLinux/CentOS or Debian/Ubuntu install.

---

## What always runs natively

These components always use native OS services regardless of the Docker registry backend:

| Component | How installed | Systemd unit |
|---|---|---|
| nginx | distro package (`nginx`) | `nginx` |
| pypiserver | distro package or pip venv | `pypiserver` |
| Verdaccio | `npm install -g verdaccio` | `verdaccio` |

---

## Docker registry backend

The Docker registry can run as a native systemd service or as a container.
`MIRRORET_DOCKER_BACKEND` controls which is used.

### RHEL / Rocky / AlmaLinux / CentOS 8/9

```bash
sudo MIRRORET_DOCKER_BACKEND=native ./install.sh
```

Installs `docker-distribution` and manages the `docker-distribution` systemd service.

| Item | Value |
|---|---|
| Package | `docker-distribution` |
| Service | `docker-distribution` |
| Config | `/etc/docker-distribution/registry/config.yml` |
| Storage | `/srv/mirroret/docker/registry/` |

```bash
# Status:
systemctl status docker-distribution

# Logs:
journalctl -u docker-distribution -n 50 --no-pager

# Restart after config changes:
systemctl restart docker-distribution
```

### Debian / Ubuntu

```bash
sudo MIRRORET_DOCKER_BACKEND=native ./install.sh
```

Installs `docker-registry` and manages the `docker-registry` systemd service.

| Item | Value |
|---|---|
| Package | `docker-registry` |
| Service | `docker-registry` |
| Config | `/etc/docker/registry/config.yml` |
| Storage | `/srv/mirroret/docker/registry/` |

```bash
# Status:
systemctl status docker-registry

# Logs:
journalctl -u docker-registry -n 50 --no-pager

# Restart after config changes:
systemctl restart docker-registry
```

### Auto selection (default)

`MIRRORET_DOCKER_BACKEND=auto` (the default) tries the native OS package first.
If the package is not in the repos or not installed, it falls back to the
`registry:2` container.

---

## APT mirror: native tools on Debian 12+

`apt-mirror` was removed from Debian 12 (Bookworm). mirroret supports two alternatives:

### debmirror

```bash
sudo MIRRORET_APT_MIRROR_TOOL=debmirror ./install.sh
```

Installs `debmirror` via `apt-get` and generates a sync script at
`/srv/mirroret/scripts/sync-apt-debmirror.sh`.

debmirror requires the Ubuntu archive keyring to verify package signatures:

```bash
sudo apt-get install -y ubuntu-keyring
```

Run the initial sync manually after install:

```bash
sudo /srv/mirroret/scripts/sync-apt-debmirror.sh
```

See [TROUBLESHOOTING.md](TROUBLESHOOTING.md#debmirror-gpg) for GPG key issues.

### apt-mirror2 (Python drop-in replacement)

`apt-mirror2` is config-file-compatible with `apt-mirror` and installable via pip.

```bash
sudo MIRRORET_APT_MIRROR_TOOL=apt-mirror sudo ./install.sh
```

If `apt-mirror` is not found in the distro repos, mirroret automatically installs
`apt-mirror2` into `/opt/mirroret-apt-mirror2/` and symlinks it to
`/usr/local/bin/apt-mirror2`. The same `mirror.list` config is used.

---

## Full native-only examples

### RHEL 9 / Rocky 9 — no Docker or Podman

```bash
sudo MIRRORET_DOCKER_BACKEND=native \
     MIRRORET_GPG_AUTO=1 \
     MIRRORET_TLS_SELF_SIGNED=1 \
     ./install.sh
```

### Debian 12 — apt-mirror not in repos

```bash
sudo MIRRORET_DOCKER_BACKEND=native \
     MIRRORET_APT_MIRROR_TOOL=debmirror \
     MIRRORET_GPG_AUTO=1 \
     MIRRORET_TLS_SELF_SIGNED=1 \
     ./install.sh
```

### Ubuntu 22.04 — APT and pip only, no Docker or npm

```bash
sudo MIRRORET_SERVER_IP=10.0.1.5 \
     MIRRORET_FIREWALL_SOURCE=10.0.0.0/8 \
     MIRRORET_GPG_AUTO=1 \
     ./install.sh --no-docker --no-npm
```

### Using a config file

```bash
# /etc/mirroret/mirroret.conf
MIRRORET_SERVER_IP=192.168.10.10
MIRRORET_DOCKER_BACKEND=native
MIRRORET_APT_MIRROR_TOOL=debmirror
MIRRORET_GPG_AUTO=1
MIRRORET_TLS_SELF_SIGNED=1
MIRRORET_APPROVAL_ENABLED=1
MIRRORET_FIREWALL_SOURCE=192.168.10.0/24
```

```bash
sudo ./install.sh --config /etc/mirroret/mirroret.conf
```

---

## Service management summary

After a native install, all services are managed by systemd:

```bash
# Status of all mirroret services:
systemctl status nginx pypiserver verdaccio

# Native Docker registry (RHEL/Rocky):
systemctl status docker-distribution

# Native Docker registry (Debian/Ubuntu):
systemctl status docker-registry

# Enable auto-start after reboot (done automatically by install.sh):
systemctl enable nginx pypiserver verdaccio docker-distribution

# Restart all:
systemctl restart nginx pypiserver verdaccio

# Combined log view:
journalctl -u nginx -u pypiserver -u verdaccio -u docker-distribution -n 100 --no-pager
```

---

## Limitations in native mode

- **Docker image pre-seeding:** `sync-docker-images.sh` still requires `docker` or
  `podman` CLI installed on the mirror server to pull images from Docker Hub and push
  them to the local registry. The registry service itself does not need a container
  runtime — only the CLI tool for the pull/push operations.

- **Verdaccio:** always installed as a native Node.js process via
  `npm install -g verdaccio`. Not a container.

- **pypiserver:** installed from the distro package (`python3-pypiserver`) or via
  pip into `/opt/mirroret-pypiserver/`. Neither path requires containers.

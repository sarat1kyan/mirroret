# Native Linux Services Mode

mirroret can run entirely without Docker or Podman by using OS-native packages
and systemd services. This is called **native mode**.

---

## Why native mode

- No container runtime required on the mirror server.
- Simpler dependency chain on locked-down or minimal servers.
- All services managed by standard `systemctl` - no container lifecycle.
- Works on a fresh minimal RHEL/Rocky/AlmaLinux/CentOS or Debian/Ubuntu install.

---

## What always runs natively

These components always use native OS services regardless of the Docker registry backend:

| Component | How installed | Systemd unit |
|---|---|---|
| nginx | distro package (`nginx`) | `nginx` |
| pypiserver | distro package or pip venv (`/opt/mirroret-pypiserver`) | `pypiserver` |
| Verdaccio | `npm install -g verdaccio` | `verdaccio` |
| APT / RPM mirroring | `engines/*.py`, stdlib Python only, copied to `/srv/mirroret/engines/` | none (cron-driven `sync-*.sh`) |
| on-demand cache (`MIRRORET_APT_MODE=hybrid\|cache`) | `engines/mirroret_cache.py` via `/srv/mirroret/scripts/run-cache.sh` | `mirroret-cache` (127.0.0.1:8082) |

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

## APT mirroring

The default (`MIRRORET_APT_MIRROR_TOOL=auto`) is the native engine,
`engines/mirroret_apt.py`: plain Python 3, no `apt-mirror`, no `debmirror`,
works on any host including RHEL, and mirrors several flavors side by side.
Nothing in this section is needed for it.

### Legacy tools: apt-mirror / debmirror

`MIRRORET_APT_MIRROR_TOOL=apt-mirror` or `=debmirror` remain available for
existing single-flavor trees on Debian/Ubuntu hosts. They publish metadata
before packages and cannot mirror more than one flavor. `apt-mirror` was
removed from Debian 12; when it is missing mirroret installs `apt-mirror2`
into `/opt/mirroret-apt-mirror2/` (symlinked as `/usr/local/bin/apt-mirror2`).
`debmirror` needs the archive keyring on the server
(`ubuntu-keyring` / `debian-archive-keyring`) and generates
`/srv/mirroret/scripts/sync-apt-debmirror.sh`. To move to the native engine,
set `MIRRORET_APT_MIRROR_TOOL=auto` plus `MIRRORET_APT_TARGETS` and run
`sudo ./install.sh --upgrade`; see [MULTI-DISTRO.md](MULTI-DISTRO.md#migrating-from-a-single-flavor-install).

---

## Full native-only examples

### RHEL 9 / Rocky 9 - no Docker or Podman

```bash
sudo MIRRORET_DOCKER_BACKEND=native \
     MIRRORET_RPM_TARGETS="rocky:9 epel:9" \
     MIRRORET_TLS_SELF_SIGNED=1 \
     ./install.sh
```

### Debian 12 - hybrid APT mirror, no container runtime

```bash
sudo MIRRORET_DOCKER_BACKEND=native \
     MIRRORET_APT_TARGETS="debian:bookworm ubuntu:noble" \
     MIRRORET_APT_MODE=hybrid \
     MIRRORET_TLS_SELF_SIGNED=1 \
     ./install.sh
```

### Ubuntu 22.04 - APT and pip only, no Docker or npm

```bash
sudo MIRRORET_SERVER_IP=10.0.1.5 \
     MIRRORET_FIREWALL_SOURCE=10.0.0.0/8 \
     MIRRORET_APT_TARGETS="ubuntu:jammy ubuntu:noble" \
     ./install.sh --no-rpm --no-docker --no-npm
```

### Using a config file

```bash
# /etc/mirroret/mirroret.conf
MIRRORET_SERVER_IP=192.168.10.10
MIRRORET_APT_TARGETS="ubuntu:noble debian:bookworm"
MIRRORET_RPM_TARGETS="ol:9"
MIRRORET_APT_MODE=hybrid
MIRRORET_DOCKER_BACKEND=native
MIRRORET_TLS_SELF_SIGNED=1
MIRRORET_APPROVAL_ENABLED=1
MIRRORET_FIREWALL_SOURCE=192.168.10.0/24
```

```bash
sudo ./install.sh          # /etc/mirroret/mirroret.conf is loaded automatically
```

---

## Service management summary

After a native install, all services are managed by systemd:

```bash
# Status of all mirroret services (mirroret-cache exists in hybrid/cache mode):
systemctl status nginx pypiserver verdaccio mirroret-cache
mirroretctl service list

# Native Docker registry (RHEL/Rocky):
systemctl status docker-distribution

# Native Docker registry (Debian/Ubuntu):
systemctl status docker-registry

# Enable auto-start after reboot (done automatically by install.sh):
systemctl enable nginx pypiserver verdaccio mirroret-cache docker-distribution

# Restart all:
systemctl restart nginx pypiserver verdaccio mirroret-cache

# Combined log view:
journalctl -u nginx -u pypiserver -u verdaccio -u mirroret-cache -u docker-distribution -n 100 --no-pager
```

---

## Limitations in native mode

- **Docker image pre-seeding:** `sync-docker-images.sh` still requires `docker` or
  `podman` CLI installed on the mirror server to pull images from Docker Hub and push
  them to the local registry. The registry service itself does not need a container
  runtime - only the CLI tool for the pull/push operations.

- **Verdaccio:** always installed as a native Node.js process via
  `npm install -g verdaccio`. Not a container.

- **pypiserver:** installed from the distro package (`python3-pypiserver`) or via
  pip into `/opt/mirroret-pypiserver/`. Neither path requires containers.

- **mirroret-cache:** a plain Python process under systemd, root, bound to
  loopback, sandboxed with `ProtectSystem=full` and `ReadWritePaths` limited
  to the mirror tree. No container.

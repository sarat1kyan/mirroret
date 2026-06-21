# Native Linux Services Mode

mirroret can run entirely without Docker or Podman by using OS-native packages
and systemd services. This is called **native mode**.

---

## Why native mode

- No container runtime required.
- Simpler dependency chain on locked-down servers.
- Services managed directly by systemd — standard `systemctl` operations.
- Works on fresh minimal RHEL/Rocky/Alma/CentOS or Debian/Ubuntu installs.

---

## What runs natively (always)

These components always use native OS services regardless of the Docker backend:

| Component | Package | Systemd unit |
|-----------|---------|--------------|
| nginx (HTTP/S server) | `nginx` | `nginx` |
| pypiserver (pip) | `python3-pypiserver` or venv | `pypiserver` |
| Verdaccio (npm) | npm global install | `verdaccio` |

---

## Docker registry backend

The Docker registry can run as a native service or a container. Use
`MIRRORET_DOCKER_BACKEND` to control this.

### RHEL / Rocky / Alma / CentOS

```bash
MIRRORET_DOCKER_BACKEND=native sudo ./install.sh
```

Installs the `docker-distribution` package and manages the `docker-distribution`
systemd service. Config file: `/etc/docker-distribution/registry/config.yml`.

```bash
# Check status:
systemctl status docker-distribution

# View logs:
journalctl -u docker-distribution -n 50 --no-pager

# Restart after config changes:
systemctl restart docker-distribution
```

### Debian / Ubuntu

```bash
MIRRORET_DOCKER_BACKEND=native sudo ./install.sh
```

Installs the `docker-registry` package and manages the `docker-registry`
systemd service. Config file: `/etc/docker/registry/config.yml`.

```bash
# Check status:
systemctl status docker-registry

# View logs:
journalctl -u docker-registry -n 50 --no-pager

# Restart after config changes:
systemctl restart docker-registry
```

### Auto selection (default)

`MIRRORET_DOCKER_BACKEND=auto` (the default) tries the native package first;
if not available it falls back to the `registry:2` container.

---

## APT mirror: native tools on Debian 12+

`apt-mirror` was removed from Debian 12 (Bookworm). mirroret can use two
alternatives:

### debmirror

```bash
MIRRORET_APT_MIRROR_TOOL=debmirror sudo ./install.sh
```

installs `debmirror` via `apt-get` and generates a sync script at
`BASE_DIR/scripts/sync-apt-debmirror.sh`. debmirror requires the Ubuntu
archive keyring:

```bash
sudo apt-get install -y ubuntu-keyring
```

Run the sync manually after install:

```bash
sudo /srv/mirroret/scripts/sync-apt-debmirror.sh
```

### apt-mirror2 (pip)

`apt-mirror2` is a Python drop-in replacement for apt-mirror, installable via pip.

```bash
MIRRORET_APT_MIRROR_TOOL=apt-mirror sudo ./install.sh
```

If `apt-mirror` is not found in the repos, mirroret automatically tries
`apt-mirror2` from pip. It is installed into `/opt/mirroret-apt-mirror2/` and
symlinked into `/usr/local/bin/apt-mirror2`.

---

## Full native-only example (no Docker)

```bash
# RHEL/Rocky (no Docker or Podman installed):
sudo ./install.sh \
    MIRRORET_DOCKER_BACKEND=native \
    MIRRORET_APT_MIRROR_TOOL=auto \
    MIRRORET_GPG_AUTO=1 \
    MIRRORET_TLS_SELF_SIGNED=1

# Debian 12 (apt-mirror removed from repos):
sudo ./install.sh \
    MIRRORET_DOCKER_BACKEND=native \
    MIRRORET_APT_MIRROR_TOOL=debmirror \
    MIRRORET_GPG_AUTO=1 \
    MIRRORET_TLS_SELF_SIGNED=1
```

---

## Service management summary

After a native install, all services are managed by systemd:

```bash
# Status of all mirroret services:
systemctl status nginx pypiserver verdaccio docker-distribution docker-registry

# Enable auto-start after boot (done by install.sh):
systemctl enable nginx pypiserver verdaccio

# Restart all:
systemctl restart nginx pypiserver verdaccio

# View combined logs:
journalctl -u nginx -u pypiserver -u verdaccio -u docker-distribution -n 100
```

---

## Limitations

- Docker image pre-seed (`sync-docker-images.sh`) still requires either
  `docker` or `podman` CLI tools installed on the mirror server to pull images
  and push them to the local registry. The registry itself does not need a
  container runtime.
- Verdaccio is always installed via `npm install -g verdaccio` and run as a
  native Node.js process (not a container).
- pypiserver is either installed from the distro package or via pip into a venv.
  Neither path requires containers.

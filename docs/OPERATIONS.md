# Operations Guide

## Daily operations

### Check system status

```bash
sudo ./install.sh --status
```

### Check service health

```bash
systemctl status nginx pypiserver verdaccio
docker ps --filter name=mirroret-registry
```

### View recent logs

```bash
# nginx access log
tail -f /var/log/nginx/mirroret-unified-access.log

# pypiserver
journalctl -u pypiserver -n 50 --no-pager

# verdaccio
journalctl -u verdaccio -n 50 --no-pager

# sync logs
ls -lth /srv/mirroret/logs/ | head -20
```

---

## Sync operations

### Manual sync (all repositories)

```bash
sudo /srv/mirroret/scripts/sync-all.sh
```

### Sync individual repositories

```bash
# APT (Ubuntu/Debian)
sudo /usr/bin/apt-mirror

# RHEL/CentOS
sudo /srv/mirroret/scripts/sync-redhat-repos.sh

# pip packages
sudo /srv/mirroret/scripts/sync-pip-packages.sh

# Docker images
sudo /srv/mirroret/scripts/sync-docker-images.sh

# npm packages
sudo /srv/mirroret/scripts/sync-npm-packages.sh
```

### Modify the package list

**Option A: edit the generated sync script directly.**

```bash
sudo nano /srv/mirroret/scripts/sync-pip-packages.sh
# Edit the PACKAGES array.

sudo nano /srv/mirroret/scripts/sync-docker-images.sh
# Edit the IMAGES array.

sudo nano /srv/mirroret/scripts/sync-npm-packages.sh
# Edit the PACKAGES array.
```

**Option B: supply a package list file (persists across reinstalls).**

```bash
# Docker images:
cat > /etc/mirroret/docker-images.txt <<'EOF'
ubuntu:22.04
debian:12
nginx:stable
# my org images:
myregistry.example/app:latest
EOF
MIRRORET_DOCKER_IMAGES_FILE=/etc/mirroret/docker-images.txt sudo ./install.sh

# npm packages:
echo "express\nlodash\ntypescript" > /etc/mirroret/npm-packages.txt
MIRRORET_NPM_PACKAGES_FILE=/etc/mirroret/npm-packages.txt sudo ./install.sh
```

---

## APT repository management

### Regenerate APT index after manual changes

```bash
cd /srv/mirroret/debian/approved
dpkg-scanpackages . /dev/null | gzip -9c > Packages.gz
dpkg-scanpackages . /dev/null > Packages
```

### Clean old packages

```bash
# apt-mirror generates a clean script:
bash /srv/mirroret/debian/mirror/var/clean.sh
```

---

## RPM repository management

### Update RPM metadata after changes

```bash
createrepo --update /srv/mirroret/redhat/approved/rocky/9/baseos
createrepo --update /srv/mirroret/redhat/approved/rocky/9/appstream
```

---

## Docker registry management

### List images in registry

```bash
curl http://localhost:5000/v2/_catalog
```

### Delete an image from registry

```bash
# Get digest:
curl -H "Accept: application/vnd.docker.distribution.manifest.v2+json" \
     http://localhost:5000/v2/<image>/manifests/<tag>

# Delete:
curl -X DELETE http://localhost:5000/v2/<image>/manifests/<digest>
```

### Run garbage collection

```bash
docker exec mirroret-registry registry garbage-collect /etc/docker/registry/config.yml
```

---

## Disk space management

### Check usage

```bash
du -sh /srv/mirroret/*
df -h /srv/mirroret
```

### Identify large packages

```bash
# Largest .deb files:
find /srv/mirroret/debian -name "*.deb" -printf "%s %p\n" | sort -rn | head -20

# Largest .rpm files:
find /srv/mirroret/redhat -name "*.rpm" -printf "%s %p\n" | sort -rn | head -20
```

### Log rotation

Sync logs grow indefinitely. To add log rotation:

```bash
cat > /etc/logrotate.d/mirroret <<'EOF'
/srv/mirroret/logs/*.log {
    weekly
    rotate 8
    compress
    missingok
    notifempty
}
EOF
```

---

## Cron management

### View scheduled sync

```bash
crontab -l | grep mirroret
```

### Change sync time

```bash
# Edit the crontab:
crontab -e
# Or reinstall with a different hour:
MIRRORET_SYNC_HOUR=4 sudo ./install.sh
```

---

## Service restarts

```bash
# nginx
sudo systemctl reload nginx      # graceful reload (preferred)
sudo systemctl restart nginx     # full restart

# pypiserver
sudo systemctl restart pypiserver

# verdaccio
sudo systemctl restart verdaccio

# Docker registry
docker restart mirroret-registry
```

---

## Validation

Run a full installation validation:

```bash
sudo ./install.sh --check
```

Or via make:

```bash
sudo make validate
```

---

## Package approval workflow

When `MIRRORET_APPROVAL_ENABLED=1` is set, sync scripts download to
`BASE_DIR/staging/{pip,npm}/` and nothing is served until an admin promotes
packages to `BASE_DIR/approved/{pip,npm}/`.

```bash
# See what is waiting:
sudo ./install.sh --list-staging

# Approve everything:
sudo ./install.sh --approve-all-pip
sudo ./install.sh --approve-all-npm

# Approve a specific package (name fragment):
sudo ./install.sh --approve-package requests

# Decline (remove) a specific package:
sudo ./install.sh --exclude-pip badpkg
sudo ./install.sh --exclude-npm oldlib
```

nginx serves packages from `approved/` when approval mode is on.
When approval mode is off, sync scripts write directly to the served directory.

---

## APT sync tool selection

On Debian 12+ where `apt-mirror` is no longer in the repos, mirroret
automatically falls back to `apt-mirror2` (pip) or `debmirror`.

To force a specific tool:

```bash
MIRRORET_APT_MIRROR_TOOL=debmirror sudo ./install.sh
```

When using `debmirror`, the generated sync script is at:
`/srv/mirroret/scripts/sync-apt-debmirror.sh`

Run it manually after install to populate the mirror:

```bash
sudo /srv/mirroret/scripts/sync-apt-debmirror.sh
```

See [TROUBLESHOOTING.md](TROUBLESHOOTING.md) for debmirror GPG key issues.

---

## Docker registry backend

```bash
# Native OS package (no Docker daemon needed):
MIRRORET_DOCKER_BACKEND=native sudo ./install.sh

# Container via Docker or Podman:
MIRRORET_DOCKER_BACKEND=container sudo ./install.sh

# Auto (default): native if available, else container:
MIRRORET_DOCKER_BACKEND=auto sudo ./install.sh
```

The native backend uses:
- RHEL/Rocky/Alma: `docker-distribution` package, service `docker-distribution`
- Debian/Ubuntu: `docker-registry` package, service `docker-registry`

For the container backend, Podman on RHEL is detected automatically.
A systemd unit is generated when Podman is used (`podman generate systemd`).

---

## Port reference

| Port | Service | Protocol |
|------|---------|----------|
| 8080 | nginx HTTP (APT/RPM browser) | TCP |
| 8443 | nginx HTTPS (when TLS enabled) | TCP |
| 8081 | pypiserver (pip) | TCP |
| 5000 | Docker registry | TCP |
| 4873 | Verdaccio (npm) | TCP |

All ports are configurable. See [CONFIGURATION.md](CONFIGURATION.md).

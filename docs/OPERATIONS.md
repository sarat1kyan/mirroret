# Operations Guide

## Daily operations

### Check system status

```bash
sudo ./install.sh --status
```

### Check individual service health

```bash
# All services at once:
systemctl status nginx pypiserver verdaccio

# Native Docker registry (RHEL):
systemctl status docker-distribution

# Native Docker registry (Debian):
systemctl status docker-registry

# Container-based registry:
docker ps --filter name=mirroret-registry
```

### View recent logs

```bash
# nginx access log:
tail -f /var/log/nginx/mirroret-unified-access.log

# nginx TLS access log (when TLS is enabled):
tail -f /var/log/nginx/mirroret-unified-tls-access.log

# pypiserver:
journalctl -u pypiserver -n 50 --no-pager

# Verdaccio:
journalctl -u verdaccio -n 50 --no-pager

# Sync logs:
ls -lth /srv/mirroret/logs/ | head -20
tail -f /srv/mirroret/logs/sync-pip-*.log
```

---

## Sync operations

### Sync all repositories (cron also runs this daily)

```bash
sudo /srv/mirroret/scripts/sync-all.sh
```

`sync-all.sh` calls the correct per-tool script for each component. The APT
sync command inside `sync-all.sh` is automatically set to the right binary when
`install.sh` runs:

- `apt-mirror` selected -> calls `/usr/bin/apt-mirror`
- `apt-mirror2` selected -> calls `/usr/local/bin/apt-mirror2`
- `debmirror` selected -> calls `/srv/mirroret/scripts/sync-apt-debmirror.sh`

To see which tool was selected, check the first line of the APT section:

```bash
grep "_run_step.*apt" /srv/mirroret/scripts/sync-all.sh
```

### Sync individual repositories

```bash
# APT (Ubuntu/Debian) - the correct tool is called by sync-all.sh.
# To run manually, check which tool is configured:
grep "_run_step.*apt" /srv/mirroret/scripts/sync-all.sh | awk '{print $2}'
# Then call that script or binary directly.

# With debmirror:
sudo /srv/mirroret/scripts/sync-apt-debmirror.sh

# With apt-mirror or apt-mirror2:
sudo /usr/bin/apt-mirror
# or:
sudo /usr/local/bin/apt-mirror2

# RHEL/CentOS RPM:
sudo /srv/mirroret/scripts/sync-redhat-repos.sh

# pip packages:
sudo /srv/mirroret/scripts/sync-pip-packages.sh

# Docker images:
sudo /srv/mirroret/scripts/sync-docker-images.sh

# npm packages:
sudo /srv/mirroret/scripts/sync-npm-packages.sh
```

### Customise the package list

**Option A - edit the generated sync script directly (changes may be overwritten on reinstall):**

```bash
sudo nano /srv/mirroret/scripts/sync-pip-packages.sh
# Edit the PACKAGES array.

sudo nano /srv/mirroret/scripts/sync-docker-images.sh
# Edit the IMAGES array.

sudo nano /srv/mirroret/scripts/sync-npm-packages.sh
# Edit the PACKAGES array.
```

**Option B - supply a package list file that persists across reinstalls:**

```bash
# Docker images:
cat > /etc/mirroret/docker-images.txt <<'EOF'
ubuntu:22.04
debian:12
nginx:stable
# comment lines start with #
myregistry.example/app:latest
EOF
sudo MIRRORET_DOCKER_IMAGES_FILE=/etc/mirroret/docker-images.txt ./install.sh

# npm packages:
cat > /etc/mirroret/npm-packages.txt <<'EOF'
express
lodash
typescript
EOF
sudo MIRRORET_NPM_PACKAGES_FILE=/etc/mirroret/npm-packages.txt ./install.sh
```

---

## APT repository management

### Force re-sync of APT mirror

```bash
# apt-mirror / apt-mirror2:
sudo /usr/bin/apt-mirror # or /usr/local/bin/apt-mirror2

# debmirror:
sudo /srv/mirroret/scripts/sync-apt-debmirror.sh
```

### Regenerate APT index after adding custom packages

```bash
cd /srv/mirroret/debian/approved
dpkg-scanpackages . /dev/null | gzip -9c > Packages.gz
dpkg-scanpackages . /dev/null > Packages
```

### Clean removed packages (apt-mirror only)

```bash
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

### List images in the registry

```bash
curl http://localhost:5000/v2/_catalog
```

### Delete an image

```bash
# Get the digest:
curl -H "Accept: application/vnd.docker.distribution.manifest.v2+json" \
     http://localhost:5000/v2/<image>/manifests/<tag>

# Delete by digest:
curl -X DELETE http://localhost:5000/v2/<image>/manifests/<digest>
```

### Run garbage collection

**Container backend:**

```bash
docker exec mirroret-registry \
    registry garbage-collect /etc/docker/registry/config.yml
```

**Native backend - RHEL (`docker-distribution`):**

```bash
sudo registry garbage-collect \
    /etc/docker-distribution/registry/config.yml
```

**Native backend - Debian (`docker-registry`):**

```bash
sudo registry garbage-collect \
    /etc/docker/registry/config.yml
```

After garbage collection, restart the registry service:

```bash
# Container:
docker restart mirroret-registry

# Native RHEL:
sudo systemctl restart docker-distribution

# Native Debian:
sudo systemctl restart docker-registry
```

---

## Disk space management

### Check usage by component

```bash
du -sh /srv/mirroret/*
df -h /srv/mirroret
```

### Find the largest packages

```bash
# Largest .deb files:
find /srv/mirroret/debian -name "*.deb" -printf "%s %p\n" | sort -rn | head -20

# Largest .rpm files:
find /srv/mirroret/redhat -name "*.rpm" -printf "%s %p\n" | sort -rn | head -20

# Largest Docker image layers:
du -sh /srv/mirroret/docker/registry/docker/registry/v2/blobs/sha256/*/*
```

### Set up log rotation

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

### View the scheduled sync

```bash
crontab -l | grep mirroret
```

### Change sync time

```bash
# Edit directly:
crontab -e

# Or reinstall with a different hour:
MIRRORET_SYNC_HOUR=4 sudo ./install.sh
```

---

## Service restarts

```bash
# nginx (graceful reload is preferred - no dropped connections):
sudo systemctl reload nginx

# Full restart:
sudo systemctl restart nginx

# pypiserver:
sudo systemctl restart pypiserver

# Verdaccio:
sudo systemctl restart verdaccio

# Docker registry - container backend:
docker restart mirroret-registry

# Docker registry - native RHEL:
sudo systemctl restart docker-distribution

# Docker registry - native Debian:
sudo systemctl restart docker-registry
```

---

## Validation

```bash
# Full post-install validation:
sudo ./install.sh --check

# Via make:
sudo make validate
```

---

## Package approval workflow

When `MIRRORET_APPROVAL_ENABLED=1`, sync downloads to a staging area and
nothing reaches a client until an operator promotes it. Covers pip, npm and RPM.

```bash
# See everything waiting for approval:
mirroretctl approve list

# Full staged RPM file list (can be thousands of lines):
mirroretctl approve list rpm

# Promote everything of one kind:
sudo mirroretctl approve all rpm
sudo mirroretctl approve all pip
sudo mirroretctl approve all npm

# Promote by name fragment:
sudo mirroretctl approve rpm glibc
sudo mirroretctl approve pip requests

# Decline (delete from staging):
sudo mirroretctl approve deny rpm telnet
sudo mirroretctl approve deny npm oldlib
```

The same operations exist as `install.sh` flags (`--list-staging`,
`--approve-all-pip`, `--approve-all-npm`, `--approve-all-rpm`,
`--approve-package`, `--approve-rpm`, `--exclude-pip`, `--exclude-npm`,
`--exclude-rpm`) for scripted use.

Directory layout:

```
/srv/mirroret/
+-- staging/
| +-- pip/            <- sync writes here; admin reviews
| +-- npm/            <- sync writes here; admin reviews
+-- approved/
| +-- pip/            <- pypiserver serves from here
| +-- npm/            <- promoted AND published into Verdaccio
+-- redhat/
    +-- staging/      <- reposync writes here in approval mode
    +-- mirror/       <- promoted RPMs land here; clients read this
```

### What promotion actually does

Moving a file is not enough to make it installable. Each kind needs a
different final step, and approval performs it:

| Kind | Move | Additional step |
|------|------|-----------------|
| pip  | `staging/pip` -> `approved/pip` | none; pypiserver reads the directory |
| npm  | `staging/npm` -> `approved/npm` | `npm publish` into Verdaccio |
| rpm  | `redhat/staging` -> `redhat/mirror` | `createrepo_c` rebuild of each touched repo |

For RPM this matters: a `.rpm` sitting in the tree that repodata does not list
does not exist as far as `dnf` is concerned. If `createrepo_c` is missing, the
approval warns loudly and the packages stay invisible until you install it and
re-run.

### npm approval turns off the npmjs proxy

Verdaccio normally proxies `registry.npmjs.org`, so a client can pull any
package on demand. That silently defeats approval: the approved set is never
consulted. With `MIRRORET_APPROVAL_ENABLED=1` the generated Verdaccio config
omits the uplink entirely.

Consequence: a package nobody approved returns 404 instead of being fetched
live. That is the intended trade and the reason to think before enabling this
on a busy developer network.

Publishing needs credentials. Either run
`npm login --registry=http://localhost:4873/` once, or set
`MIRRORET_NPM_ALLOW_ANON_PUBLISH=1`. Without one of those, promotion reports
`authentication required` and the package is moved but not installable.

### RPM syncs still report download failures

In approval mode the RPM sync exits before metadata generation, but it still
returns non-zero if any `reposync` failed or the disk floor aborted the run,
so a cron failure is not masked by the early exit.

When approval mode is off, sync scripts write directly to the served
directories and packages are available immediately.

---

## APT sync tool selection

On Debian 12+ where `apt-mirror` is no longer in the repos, mirroret falls back
automatically to `apt-mirror2` (pip) or `debmirror`.

To force a specific tool:

```bash
MIRRORET_APT_MIRROR_TOOL=debmirror sudo ./install.sh
```

When `debmirror` is selected the sync script is generated at:
`/srv/mirroret/scripts/sync-apt-debmirror.sh`

Run it manually after install to populate the mirror:

```bash
sudo /srv/mirroret/scripts/sync-apt-debmirror.sh
```

debmirror requires the Ubuntu archive keyring:

```bash
sudo apt-get install -y ubuntu-keyring
```

See [TROUBLESHOOTING.md](TROUBLESHOOTING.md#debmirror-gpg) for GPG key issues.

---

## Docker registry backend

```bash
# Native OS package (no Docker daemon needed on the mirror server):
MIRRORET_DOCKER_BACKEND=native sudo ./install.sh

# Container via Docker or Podman:
MIRRORET_DOCKER_BACKEND=container sudo ./install.sh

# Auto (default): native if available, else container:
MIRRORET_DOCKER_BACKEND=auto sudo ./install.sh
```

Native backend services:

| Distro | Package | Service | Config file |
|---|---|---|---|
| RHEL/Rocky/Alma/CentOS | `docker-distribution` | `docker-distribution` | `/etc/docker-distribution/registry/config.yml` |
| Debian/Ubuntu | `docker-registry` | `docker-registry` | `/etc/docker/registry/config.yml` |

For the container backend, Podman on RHEL is detected automatically (podman-docker shim).
A systemd unit is generated when Podman is used (`podman generate systemd`).

> **Note:** Docker image pre-seeding (`sync-docker-images.sh`) still requires `docker`
> or `podman` CLI installed on the mirror server regardless of the registry backend.
> The CLI is used to `pull` images from Docker Hub and `push` them to the local registry.

---

## Port reference

| Port | Variable | Service | Protocol |
|---|---|---|---|
| 8080 | `MIRRORET_WEB_PORT` | nginx HTTP | TCP |
| 8443 | `MIRRORET_TLS_PORT` | nginx HTTPS (when TLS enabled) | TCP |
| 8081 | `MIRRORET_PIP_PORT` | pypiserver | TCP |
| 5000 | `MIRRORET_DOCKER_REGISTRY_PORT` | Docker registry | TCP |
| 4873 | `MIRRORET_NPM_PORT` | Verdaccio | TCP |

All ports are configurable. See [CONFIGURATION.md](CONFIGURATION.md).
For firewall setup commands see [NETWORK_ACCESS.md](NETWORK_ACCESS.md).

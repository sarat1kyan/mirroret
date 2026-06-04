# Troubleshooting Guide

## Quick diagnosis

```bash
# Full validation:
sudo ./install.sh --check

# Service status:
sudo ./install.sh --status

# nginx config test:
sudo nginx -t

# Check service logs:
journalctl -u nginx -n 50 --no-pager
journalctl -u pypiserver -n 50 --no-pager
journalctl -u verdaccio -n 50 --no-pager
```

---

## nginx

### nginx fails to start

```bash
sudo nginx -t          # check config syntax
sudo journalctl -u nginx -n 100 --no-pager
```

Common causes:
- Port conflict: another process is using port 8080
  ```bash
  ss -tlnp | grep 8080
  ```
- Config syntax error: check the output of `nginx -t`
- Missing directory: the `root` or `alias` path doesn't exist
  ```bash
  ls -la /srv/mirroret/debian/approved
  ```

### nginx returns 403

Check directory permissions and SELinux (RHEL):
```bash
ls -la /srv/mirroret/
# Fix permissions:
chmod 755 /srv/mirroret /srv/mirroret/debian /srv/mirroret/debian/approved

# SELinux (RHEL only):
semanage fcontext -a -t httpd_sys_content_t '/srv/mirroret(/.*)?'
restorecon -Rv /srv/mirroret
```

---

## APT mirror

### apt-mirror sync fails

```bash
# Check the log:
ls -lt /srv/mirroret/logs/
tail -100 /srv/mirroret/logs/sync-debian-*.log

# Common causes:
# - No internet access from the mirror server
curl -I http://archive.ubuntu.com/ubuntu/

# - Insufficient disk space
df -h /srv/mirroret

# - Wrong base_path in mirror.list
cat /etc/apt/mirror.list
```

### Clients get "NO_PUBKEY" errors

The repository is not signed or the keyring is not distributed to clients.

```bash
# Option 1: configure GPG signing (production)
# See docs/SECURITY.md

# Option 2: use insecure mode (lab only)
MIRRORET_APT_INSECURE=1 sudo ./install.sh
```

### apt update fails on clients

```bash
# On the client:
sudo apt update 2>&1 | head -20

# Check the mirror is accessible:
curl http://<mirror-ip>:8080/debian/mirror/dists/jammy/Release

# Verify the client sources.list:
cat /etc/apt/sources.list.d/mirroret.list
```

---

## RPM / yum / dnf

### reposync fails

```bash
# Check log:
tail -100 /srv/mirroret/logs/sync-redhat-*.log

# Verify reposync is installed:
which reposync || dnf install yum-utils

# Check repo configuration:
dnf repolist
```

### Clients report GPG key errors

```bash
# Option 1: configure gpgkey URL (production)
MIRRORET_RPM_GPGKEY_URL=http://<mirror-ip>:8080/config/RPM-GPG-KEY-mirroret \
    sudo ./install.sh

# Option 2: insecure mode (lab only)
MIRRORET_RPM_INSECURE=1 sudo ./install.sh
```

---

## pypiserver / pip

### pypiserver fails to start

```bash
journalctl -u pypiserver -n 50 --no-pager

# Check if port is in use:
ss -tlnp | grep 8081

# Check the mirroret-pip user exists:
id mirroret-pip

# Check permissions on pip directory:
ls -la /srv/mirroret/pip/
```

### pip install fails on clients

```bash
# Test the index directly:
curl http://<mirror-ip>:8081/simple/

# Verify pip.conf on client:
cat ~/.pip/pip.conf
# or
cat /etc/pip.conf

# Test with explicit index:
pip install requests --index-url http://<mirror-ip>:8081/simple/ --trusted-host <mirror-ip>
```

---

## Docker registry

### Registry container not starting

```bash
docker ps -a --filter name=mirroret-registry
docker logs mirroret-registry

# Recreate if necessary:
docker rm mirroret-registry
# Then re-run install.sh or manually:
docker run -d \
    --name mirroret-registry \
    --restart=always \
    -p 5000:5000 \
    -v /srv/mirroret/docker/registry:/var/lib/registry \
    -v /etc/docker/registry/config.yml:/etc/docker/registry/config.yml:ro \
    registry:2
```

### Clients get TLS errors when pulling images

```bash
# Option 1: configure TLS (production)
# See docs/SECURITY.md for TLS certificate setup.

# Option 2: insecure mode (lab only)
MIRRORET_DOCKER_INSECURE=1 sudo ./install.sh
# Then on clients, add to /etc/docker/daemon.json:
# {"insecure-registries": ["<mirror-ip>:5000"]}
# sudo systemctl restart docker
```

### Image push to registry fails

```bash
# Verify registry is running:
curl http://localhost:5000/v2/

# Check storage permissions:
ls -la /srv/mirroret/docker/registry/

# View detailed registry logs:
docker logs -f mirroret-registry
```

---

## Verdaccio / npm

### Verdaccio fails to start

```bash
journalctl -u verdaccio -n 50 --no-pager

# Check if the mirroret-npm user exists:
id mirroret-npm

# Check the htpasswd file exists (must be present even if empty):
ls -la /etc/verdaccio/htpasswd

# Check config:
verdaccio --config /etc/verdaccio/config.yaml --dry-run 2>&1 || true
```

### npm install fails on clients

```bash
# Test registry directly:
curl http://<mirror-ip>:4873/

# Check .npmrc on client:
cat ~/.npmrc

# Test with explicit registry:
npm install express --registry http://<mirror-ip>:4873/
```

---

## Installation rollback

If the installation left the system in a bad state:

```bash
# List available backups:
sudo ./install.sh --list-backups

# Roll back:
sudo ./install.sh --rollback <backup-id>

# After rollback, verify:
sudo nginx -t
sudo systemctl status nginx pypiserver verdaccio
```

---

## Common errors

| Error | Likely cause | Fix |
|-------|-------------|-----|
| `Permission denied` | Not running as root | `sudo ./install.sh` |
| `nginx: [emerg] bind() failed` | Port in use | `ss -tlnp \| grep <port>` |
| `NO_PUBKEY` on clients | Missing GPG key | See docs/SECURITY.md |
| `No space left on device` | Disk full | Free space or expand volume |
| `Could not connect to server` | nginx not running | `systemctl start nginx` |
| `Container already exists` | Re-run after partial failure | `docker rm mirroret-registry` |

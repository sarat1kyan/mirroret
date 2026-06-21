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

## TLS

### nginx HTTPS listener returns SSL handshake error

```bash
# Verify the cert and key match:
openssl x509 -noout -modulus -in /etc/mirroret/tls/cert.pem | md5sum
openssl rsa  -noout -modulus -in /etc/mirroret/tls/key.pem  | md5sum
# Both hashes must be identical.

# Check the nginx TLS block was appended:
grep -n "ssl_certificate" /etc/nginx/sites-available/mirroret-unified \
  || grep -n "ssl_certificate" /etc/nginx/conf.d/mirroret-unified.conf

# Verify the port is open:
ss -tlnp | grep 8443
```

### Clients show "certificate verify failed" for self-signed cert

The self-signed CA must be imported on clients. See [SECURITY.md](SECURITY.md).

```bash
# Check cert details:
openssl x509 -text -noout -in /etc/mirroret/tls/cert.pem | grep -E "Subject|SAN|Not"
```

---

## GPG

### GPG key generation fails

```bash
# Ensure gpg is installed:
gpg --version

# Check the GPG homedir is accessible:
ls -la /etc/mirroret/gnupg

# Run with DEBUG for detailed output:
LOG_LEVEL=DEBUG MIRRORET_GPG_AUTO=1 sudo ./install.sh
```

### APT clients get "NO_PUBKEY" after GPG auto-provision

The key was generated but not distributed to clients.

```bash
# Run the distribution script on each client:
bash <(curl -fsSL http://<mirror-ip>:8080/config/import-mirroret-gpg-key.sh)

# Or manually copy the binary keyring:
sudo wget http://<mirror-ip>:8080/config/mirroret.gpg \
    -O /etc/apt/keyrings/mirroret.gpg
```

---

## Approval workflow

### `--list-staging` shows nothing but sync ran

Check the staging directory for the correct location:

```bash
ls /srv/mirroret/staging/pip/
ls /srv/mirroret/staging/npm/
```

If empty, verify the sync script was regenerated with approval mode enabled:

```bash
grep -i "staging" /srv/mirroret/scripts/sync-pip-packages.sh
```

If the script points to `pip/approved` instead of `staging/pip`, re-run install with `MIRRORET_APPROVAL_ENABLED=1`.

### Packages approved but pypiserver returns 404

pypiserver serves from `approved/pip/` when approval is enabled. Verify the
unit file points to the correct directory:

```bash
systemctl cat pypiserver | grep ExecStart
# Should contain: .../approved/pip
```

---

## APT mirror / debmirror

### <a name="debmirror-gpg"></a>debmirror fails with GPG errors

```
GPG error: ... NO_PUBKEY ...
```

debmirror requires the Ubuntu archive keyring to verify downloaded packages.

```bash
# Install the keyring:
sudo apt-get install -y ubuntu-keyring

# Verify the keyring file exists:
ls /usr/share/keyrings/ubuntu-archive-keyring.gpg

# Re-run the debmirror sync script:
sudo /srv/mirroret/scripts/sync-apt-debmirror.sh
```

If the keyring file is in a different path on your system, update the
`KEYRING_FILE` variable in the generated sync script.

### apt-mirror not available on Debian 12

Debian 12 (Bookworm) removed `apt-mirror` from its repos. mirroret will
automatically fall back to `apt-mirror2` (pip) or `debmirror`.

Force a specific tool if needed:

```bash
MIRRORET_APT_MIRROR_TOOL=debmirror sudo ./install.sh
```

---

## Native Docker registry

### docker-distribution service fails on RHEL

```bash
# Check service logs:
journalctl -u docker-distribution -n 50 --no-pager

# Check the config file:
cat /etc/docker-distribution/registry/config.yml

# Verify storage directory:
ls -la /srv/mirroret/docker/registry/
```

### docker-registry service fails on Debian

```bash
journalctl -u docker-registry -n 50 --no-pager
cat /etc/docker/registry/config.yml
```

---

## Common errors

| Error | Likely cause | Fix |
|-------|-------------|-----|
| `Permission denied` | Not running as root | `sudo ./install.sh` |
| `nginx: [emerg] bind() failed` | Port in use | `ss -tlnp \| grep <port>` |
| `NO_PUBKEY` on clients | Missing GPG key | See SECURITY.md |
| `No space left on device` | Disk full | Free space or expand volume |
| `Could not connect to server` | nginx not running | `systemctl start nginx` |
| `Container already exists` | Re-run after partial failure | `docker rm mirroret-registry` |
| `SSL handshake failed` | Missing/wrong cert | See TLS section above |
| `debmirror: GPG error` | Missing Ubuntu keyring | `apt-get install ubuntu-keyring` |
| Staging shows packages but approval says none | Wrong path in sync script | Reinstall with `MIRRORET_APPROVAL_ENABLED=1` |

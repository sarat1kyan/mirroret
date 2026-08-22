# Troubleshooting Guide

## Quick diagnosis

```bash
# Full validation:
sudo ./install.sh --check

# Service status:
sudo ./install.sh --status

# nginx config test:
sudo nginx -t

# Recent logs:
journalctl -u nginx -n 50 --no-pager
journalctl -u pypiserver -n 50 --no-pager
journalctl -u verdaccio -n 50 --no-pager

# Sync logs:
ls -lth /srv/mirroret/logs/
```

---

## nginx

### nginx fails to start

```bash
sudo nginx -t # check config syntax
sudo journalctl -u nginx -n 100 --no-pager
```

Common causes:

- **Port conflict:** another process is already using port 8080.
  ```bash
  ss -tlnp | grep 8080
  kill -9 $(ss -tlnp | grep :8080 | awk '{print $6}' | cut -d= -f2 | cut -d, -f1)
  ```
- **Config syntax error:** check `nginx -t` output.
- **Missing directory:** the `root` or `alias` path doesn't exist yet (run the sync first).
  ```bash
  ls -la /srv/mirroret/debian/
  ```

### nginx returns 403 Forbidden

```bash
ls -la /srv/mirroret/
chmod 755 /srv/mirroret /srv/mirroret/debian /srv/mirroret/debian/mirror

# SELinux (RHEL only):
semanage fcontext -a -t httpd_sys_content_t '/srv/mirroret(/.*)?'
restorecon -Rv /srv/mirroret
```

### nginx returns 502 Bad Gateway for /pip/ or /npm/

The backend service (pypiserver on 8081 or Verdaccio on 4873) is not running.

```bash
systemctl status pypiserver
systemctl status verdaccio
systemctl restart pypiserver
systemctl restart verdaccio
```

---

## APT mirror

### No .deb is ever downloaded, and nothing reports an error

The single most common cause: **no APT target is configured.**

```bash
mirroretctl targets
```

If that prints no APT target, or install.sh warned "APT mirroring is enabled
but no target resolved", the server has nothing to mirror. What a server
mirrors is configuration, not a consequence of what it runs, so a RHEL or
CentOS mirror server has nothing to guess from:

```bash
sudo tee -a /etc/mirroret/mirroret.conf >/dev/null <<'EOF'
MIRRORET_APT_TARGETS="ubuntu:jammy ubuntu:noble debian:bookworm"
EOF
sudo ./install.sh --upgrade
mirroretctl targets            # each target should now be listed
sudo mirroretctl sync apt
```

On installs older than the multi-distro change, APT setup was gated on the
mirror server being Debian-based and simply skipped on any other host - no
error, because skipping was the designed behaviour. See
[MULTI-DISTRO.md](MULTI-DISTRO.md).

### A suite exists but clients get 404 on every package

```bash
# Are there packages at all?
find /srv/mirroret/apt -name '*.deb' | wc -l

# Does the tree have indices but no pool?
ls /srv/mirroret/apt/ubuntu/
```

`dists/` with no `pool/` means indices were published without packages. The
native engine cannot produce that state (it publishes `Release` last, only
after every listed package is on disk), so this indicates a legacy
apt-mirror/debmirror tree or a manual edit. Re-run the sync:

```bash
sudo mirroretctl sync apt
```

### The sync says "signature: NOT verified locally"

Expected on a mirror server that is not Debian/Ubuntu: verifying a suite's
`Release` needs the matching archive keyring, and a RHEL host has no
`ubuntu-archive-keyring`.

It is not a security hole. The archive is mirrored byte-for-byte including
its signature, so every client re-verifies it with its own keyring - which is
the check that actually protects the client. To make it fatal instead of a
warning, install the keyring on the mirror server (or point
`--keyring` at a copy) and set:

```bash
MIRRORET_APT_REQUIRE_SIGNATURE=1
```

### The sync fails with "sha256 mismatch" on one package

The upstream archive was mid-publish, or a proxy truncated the transfer. The
engine retries each download, so a persistent mismatch means the bytes really
do differ. It refuses to publish the suite, leaving the previous state
serving. Re-run the sync; if it persists for the same package, the upstream
mirror is inconsistent - try a different `MIRRORET_APT_UPSTREAM_HOST`.

### apt-mirror sync fails

```bash
# Check the sync log:
ls -lt /srv/mirroret/logs/
tail -100 /srv/mirroret/logs/sync-apt-*.log

# Test internet connectivity from the mirror server:
curl -I http://archive.ubuntu.com/ubuntu/

# Insufficient disk space:
df -h /srv/mirroret

# Wrong base_path in mirror.list:
cat /etc/apt/mirror.list
```

### Clients get "NO_PUBKEY" errors

The repository is not signed or the keyring has not been distributed to clients.

```bash
# Option 1: configure GPG signing (production):
sudo ./install.sh --gpg-auto
# Then distribute the key - see docs/SECURITY.md.

# Option 2: insecure mode (lab only):
sudo MIRRORET_APT_INSECURE=1 ./install.sh
```

### apt update fails on clients

```bash
# On the client, check the error:
sudo apt update 2>&1 | head -30

# Verify the mirror is reachable from the client:
curl http://<mirror-ip>:8080/ubuntu/dists/jammy/Release

# Check the sources.list entry:
cat /etc/apt/sources.list.d/mirroret.list

# The path must match the nginx /ubuntu alias.
# If the path is wrong, regenerate client configs:
sudo ./install.sh --check
```

---

## RPM / yum / dnf

### Clients resolve a package, then get 404 downloading it

The metadata lists packages that are not on disk. This happens when a
FILTERED mirror (an arch subset, or the default `--newest-only`) is served
with upstream's metadata, which advertises everything upstream has.

The native engine cannot produce this: it rewrites metadata to list exactly
what it downloaded, and publishes `repodata/` only after every selected
package has verified. If you are seeing it:

```bash
# 1. Are you keeping upstream metadata on a filtered mirror?
grep MIRRORET_RPM_KEEP_UPSTREAM_METADATA /etc/mirroret/mirroret.conf

# 2. Re-sync so metadata matches disk:
sudo mirroretctl sync rpm

# 3. Prove a client can resolve AND download:
mirroretctl client simulate
```

`mirroretctl client simulate` is the check that matters - it queries the
mirror over HTTP exactly as a client does and then fetches the package the
metadata points at.

### "dnf install glibc.i686" fails with "No match for argument"

The i686 subpackages were never mirrored. Add the architecture and re-sync:

```bash
sudo sed -i 's/^#\?MIRRORET_RPM_ARCH=.*/MIRRORET_RPM_ARCH="x86_64 i686"/' \
    /etc/mirroret/mirroret.conf
sudo ./install.sh --upgrade
sudo mirroretctl sync rpm
```

Cost: roughly 10-15% more disk on baseos/appstream.

### Clients fail with a repomd.xml signature error

A filtered mirror rebuilds `repomd.xml` locally, so upstream's detached
signature no longer applies and is deliberately not published. Remove
`repo_gpgcheck=1` from the client's `.repo` file - the generated configs do
not set it.

Package signatures are untouched by mirroring, so `gpgcheck=1` still works
and still verifies the vendor's signature. To keep upstream's signed
metadata you must mirror everything:

```bash
MIRRORET_RPM_NEWEST_ONLY=0
MIRRORET_RPM_SOURCE=1
MIRRORET_RPM_ARCH=""     # every architecture upstream publishes
```

That is terabytes on most repos. Read
[MULTI-DISTRO.md](MULTI-DISTRO.md) first.

### "did not return repository metadata" / "not <repomd>"

The upstream URL answered, but with something that is not repository
metadata - almost always a proxy block page. The engine prints the first
bytes of the response so you can see what it got:

```bash
# Confirm from the mirror server:
curl -sS -o /dev/null -w '%{http_code}\n' \
    https://yum.oracle.com/repo/OracleLinux/OL9/baseos/latest/x86_64/repodata/repomd.xml
```

A 403 here is a proxy policy decision, not a mirroret problem. See
[PROXY_AND_CA.md](PROXY_AND_CA.md) and FIXME-ENVIRONMENT.md BLOCKER 1.

### reposync fails

```bash
# Check the sync log:
tail -100 /srv/mirroret/logs/sync-redhat-*.log

# Verify reposync is installed:
which reposync || dnf install -y yum-utils

# Check what repos are configured:
dnf repolist -v
```

### Clients report GPG key errors

```bash
# Option 1: set the key URL in the repo config:
sudo MIRRORET_RPM_GPGKEY_URL=http://<mirror-ip>:8080/config/GPG-KEY.asc \
    ./install.sh --gpg-auto

# Option 2: insecure mode (lab only):
sudo MIRRORET_RPM_INSECURE=1 ./install.sh
```

---

## pypiserver / pip

### pypiserver fails to start

```bash
journalctl -u pypiserver -n 100 --no-pager

# Port in use:
ss -tlnp | grep 8081

# User does not exist:
id mirroret-pip

# Permissions on pip directory:
ls -la /srv/mirroret/pip/

# Check the ExecStart path points to a valid binary:
systemctl cat pypiserver | grep ExecStart
which pypi-server
```

### pip install fails on clients

```bash
# Test the index endpoint:
curl http://<mirror-ip>:8081/simple/

# Check pip config on client:
cat ~/.pip/pip.conf
# or:
cat /etc/pip.conf

# Test with explicit flags:
pip install requests \
    --index-url http://<mirror-ip>:8081/simple/ \
    --trusted-host <mirror-ip>
```

---

## Docker registry

### Container-based registry not starting

```bash
docker ps -a --filter name=mirroret-registry
docker logs mirroret-registry

# Recreate if needed:
docker rm mirroret-registry
docker run -d \
    --name mirroret-registry \
    --restart=always \
    -p 5000:5000 \
    -v /srv/mirroret/docker/registry:/var/lib/registry \
    -v /etc/docker/registry/config.yml:/etc/docker/registry/config.yml:ro \
    registry:2
```

### Native registry (docker-distribution) fails on RHEL

```bash
journalctl -u docker-distribution -n 100 --no-pager
cat /etc/docker-distribution/registry/config.yml
ls -la /srv/mirroret/docker/registry/
systemctl restart docker-distribution
```

### Native registry (docker-registry) fails on Debian

```bash
journalctl -u docker-registry -n 100 --no-pager
cat /etc/docker/registry/config.yml
systemctl restart docker-registry
```

### Clients get TLS errors pulling images

```bash
# Option 1: configure TLS on nginx (preferred):
sudo ./install.sh --tls-self-signed
# Then distribute the cert - see docs/SECURITY.md.

# Option 2: insecure registry (lab only):
sudo MIRRORET_DOCKER_INSECURE=1 ./install.sh
# On each client, add to /etc/docker/daemon.json:
# {"insecure-registries": ["<mirror-ip>:5000"]}
# Then: sudo systemctl restart docker
```

### Image push to registry fails

```bash
# Verify registry is running:
curl http://localhost:5000/v2/

# Check storage permissions:
ls -la /srv/mirroret/docker/registry/

# Container logs:
docker logs -f mirroret-registry

# Native RHEL logs:
journalctl -u docker-distribution -f

# Native Debian logs:
journalctl -u docker-registry -f
```

---

## Verdaccio / npm

### Verdaccio fails to start

```bash
journalctl -u verdaccio -n 100 --no-pager

# User does not exist:
id mirroret-npm

# htpasswd file must exist (even if empty):
ls -la /etc/verdaccio/htpasswd
touch /etc/verdaccio/htpasswd
chown mirroret-npm: /etc/verdaccio/htpasswd

# Config syntax check:
verdaccio --config /etc/verdaccio/config.yaml 2>&1 | head -20

# Check the ExecStart binary:
systemctl cat verdaccio | grep ExecStart
which verdaccio
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

## TLS

### nginx HTTPS listener: SSL handshake error

```bash
# Verify the cert and key are a matched pair:
openssl x509 -noout -modulus -in /etc/mirroret/tls/cert.pem | md5sum
openssl rsa -noout -modulus -in /etc/mirroret/tls/key.pem | md5sum
# Both hashes must match.

# Check the TLS server block was appended to the nginx config:
grep -n "ssl_certificate" /etc/nginx/sites-available/mirroret-unified \
  2>/dev/null || \
grep -n "ssl_certificate" /etc/nginx/conf.d/mirroret-unified.conf

# Verify the port is open:
ss -tlnp | grep 8443
```

### Clients show "certificate verify failed" for a self-signed cert

The cert's CA must be imported on the client. See [SECURITY.md](SECURITY.md).

```bash
# Check what the cert says:
openssl x509 -text -noout -in /etc/mirroret/tls/cert.pem \
    | grep -E "Subject|DNS:|IP:|Not "
```

---

## GPG

### GPG key generation fails

```bash
# Check gpg is installed:
gpg --version

# Check the homedir is accessible:
ls -la /etc/mirroret/gnupg/

# Run with DEBUG for detailed output:
LOG_LEVEL=DEBUG MIRRORET_GPG_AUTO=1 sudo ./install.sh --dry-run
```

### APT clients get "NO_PUBKEY" after GPG auto-provision

The key was generated but not distributed to clients.

```bash
# Run the distribution script on each client:
bash <(curl -fsSL http://<mirror-ip>:8080/config/import-mirroret-gpg-key.sh)

# Or manually:
sudo curl -fsSL http://<mirror-ip>:8080/config/mirroret.gpg \
    -o /etc/apt/keyrings/mirroret.gpg
sudo chmod 644 /etc/apt/keyrings/mirroret.gpg
```

---

## Approval workflow

### `--list-staging` shows nothing but the sync ran

Check the staging directory:

```bash
ls /srv/mirroret/staging/pip/
ls /srv/mirroret/staging/npm/
```

If both are empty, verify the sync script targets staging:

```bash
grep -i "staging" /srv/mirroret/scripts/sync-pip-packages.sh
# Should see: DEST_DIR=".../staging/pip"
```

If the script targets `pip/approved` instead of `staging/pip`, the install was
run without approval mode. Re-run:

```bash
sudo MIRRORET_APPROVAL_ENABLED=1 ./install.sh
```

### Packages approved but pypiserver returns 404

pypiserver serves from `approved/pip/` when approval is enabled.
Verify the unit file:

```bash
systemctl cat pypiserver | grep ExecStart
# Should contain: .../approved/pip
```

If it points to the wrong path, re-run install with `MIRRORET_APPROVAL_ENABLED=1`.

---

## <a name="debmirror-gpg"></a>APT / debmirror

### debmirror fails with GPG errors

```
GPG error: ... NO_PUBKEY ...
```

debmirror requires the Ubuntu archive keyring to verify packages.

```bash
# Install the keyring:
sudo apt-get install -y ubuntu-keyring

# Verify the file exists:
ls /usr/share/keyrings/ubuntu-archive-keyring.gpg

# Re-run the sync:
sudo /srv/mirroret/scripts/sync-apt-debmirror.sh
```

If the keyring is at a different path, edit the `KEYRING_FILE` variable in the sync script.

### apt-mirror not available on Debian 12

Debian 12 removed `apt-mirror` from its repos. mirroret falls back automatically.
Force a specific tool if needed:

```bash
MIRRORET_APT_MIRROR_TOOL=debmirror sudo ./install.sh
```

### Unsure which APT tool is in use

```bash
grep "_run_step.*apt" /srv/mirroret/scripts/sync-all.sh
```

The second argument is the tool or script that will be called.

---

## Installation rollback

```bash
# List available backups:
sudo ./install.sh --list-backups

# Roll back:
sudo ./install.sh --rollback <backup-id>

# Verify after rollback:
sudo nginx -t
sudo systemctl status nginx pypiserver verdaccio
sudo ./install.sh --check
```

---

## Common error table

| Error | Likely cause | Fix |
|---|---|---|
| `Permission denied` | Not running as root | `sudo ./install.sh` |
| `nginx: [emerg] bind() failed` | Port already in use | `ss -tlnp \| grep <port>` |
| `NO_PUBKEY` on APT clients | Missing GPG key distribution | See [SECURITY.md](SECURITY.md) |
| `No space left on device` | Disk full | `df -h /srv/mirroret` - free space or expand volume |
| `Could not connect to server` | nginx not running | `systemctl start nginx` |
| `Container already exists` | Re-run after partial failure | `docker rm mirroret-registry` |
| `SSL: CERTIFICATE_VERIFY_FAILED` | Self-signed cert not imported | See TLS section above |
| `debmirror: GPG error` | Missing Ubuntu keyring | `apt-get install ubuntu-keyring` |
| `pypiserver 404` after approval | Wrong serve dir in unit | Reinstall with `MIRRORET_APPROVAL_ENABLED=1` |
| `npm: E401 Unauthorized` | Verdaccio auth required | `npm login --registry http://<ip>:4873/` or set `MIRRORET_NPM_ALLOW_ANON_PUBLISH=1` |
| `docker-distribution: failed to start` | Config or permissions issue | `journalctl -u docker-distribution -n 50` |

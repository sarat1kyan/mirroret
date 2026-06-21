# Security Guide

## Overview

By default, mirroret generates client configurations that **require** package signature verification. Insecure modes exist for isolated/air-gapped lab environments and must be explicitly opted into.

---

## APT / Debian-Ubuntu

### Secure mode (default) — with GPG auto-provision

The simplest path: let mirroret generate and manage the GPG key.

```bash
sudo ./install.sh --gpg-auto
```

This generates a key, exports the public key, and sets `MIRRORET_APT_KEYRING` automatically.
Client configs will use `signed-by=<keyring>`. Distribute the key with the generated script.

### Secure mode — manual GPG key

If you already have a key:

```bash
# Export it into the mirroret gnupg homedir:
gpg --export-secret-keys <FINGERPRINT> \
    | gpg --homedir /etc/mirroret/gnupg --import

MIRRORET_GPG_KEYID=<FINGERPRINT> sudo ./install.sh
```

Manual repository signing (if serving custom packages via apt-ftparchive):

```bash
GPG="gpg --homedir /etc/mirroret/gnupg"
${GPG} -abs -o /srv/mirroret/debian/approved/Release.gpg \
    /srv/mirroret/debian/approved/Release
${GPG} --clearsign -o /srv/mirroret/debian/approved/InRelease \
    /srv/mirroret/debian/approved/Release
```

**Distribute the keyring to clients:**

```bash
# On each client:
sudo mkdir -p /etc/apt/keyrings
sudo wget http://<mirror-ip>:8080/config/mirroret.gpg \
    -O /etc/apt/keyrings/mirroret.gpg
sudo chmod 644 /etc/apt/keyrings/mirroret.gpg
```

### Lab mode (insecure, opt-in)

Only for air-gapped/isolated environments with no external network access.

```bash
sudo ./install.sh --insecure
# Or selectively:
MIRRORET_APT_INSECURE=1 sudo ./install.sh
```

This generates `trusted=yes` in client configs. A security warning is printed during install.

---

## RPM / RHEL-CentOS

### Secure mode (default)

```bash
# Generate a GPG key for RPM signing (if you don't have one):
gpg --batch --gen-key <<EOF
%no-protection
Key-Type: RSA
Key-Length: 4096
Name-Real: Mirroret RPM Repository
Name-Email: mirroret@$(hostname -f)
Expire-Date: 2y
EOF

# Export the public key:
gpg --export --armor 'Mirroret RPM Repository' > /srv/mirroret/config/RPM-GPG-KEY-mirroret

# Configure the key URL:
MIRRORET_RPM_GPGKEY_URL=http://<mirror-ip>:8080/config/RPM-GPG-KEY-mirroret
```

### Lab mode (insecure, opt-in)

```bash
MIRRORET_RPM_INSECURE=1 sudo ./install.sh
```

Generates `gpgcheck=0`. A security warning is printed.

---

## TLS (nginx HTTPS listener)

mirroret can configure nginx with an HTTPS listener in addition to the HTTP one.

### Option A: auto-generated self-signed certificate

```bash
sudo ./install.sh --tls-self-signed
# or:
MIRRORET_TLS_SELF_SIGNED=1 sudo ./install.sh
```

- Generates a 4096-bit RSA cert valid for 10 years in `/etc/mirroret/tls/`.
- HTTPS listens on port 8443 by default (`MIRRORET_TLS_PORT=8443`).
- Clients will see an untrusted-CA warning until they import the cert.

**Distribute the cert to clients:**

```bash
# Copy cert to each client:
sudo mkdir -p /etc/ssl/certs/
sudo wget -q http://<mirror-ip>:8080/config/cert.pem -O /etc/ssl/certs/mirroret.crt
# Or via SCP from the server:
sudo scp root@<mirror-ip>:/etc/mirroret/tls/cert.pem /usr/local/share/ca-certificates/mirroret.crt
sudo update-ca-certificates   # Debian/Ubuntu
sudo update-ca-trust extract  # RHEL/Rocky
```

### Option B: bring-your-own certificate (internal CA or public cert)

```bash
MIRRORET_TLS_CERT=/etc/ssl/certs/server.crt
MIRRORET_TLS_KEY=/etc/ssl/private/server.key
sudo ./install.sh
```

The cert must be PEM-encoded. `MIRRORET_TLS_CERT` and `MIRRORET_TLS_KEY` are validated at install time.

### Option C: no TLS (lab default)

By default mirroret uses HTTP only. TLS is opt-in.

---

## GPG automation

### Auto-generate a signing key

```bash
sudo ./install.sh --gpg-auto
# or:
MIRRORET_GPG_AUTO=1 sudo ./install.sh
```

- Generates a 4096-bit RSA GPG key stored in `/etc/mirroret/gnupg/` (isolated from the system keyring).
- Exports the public key to `BASE_DIR/config/GPG-KEY.asc` (armored) and `BASE_DIR/config/mirroret.gpg` (binary).
- Writes `BASE_DIR/config/import-mirroret-gpg-key.sh` — a client-side script for importing the key.

### Use an existing key

```bash
MIRRORET_GPG_KEYID=FINGERPRINT sudo ./install.sh
```

The key must exist in `MIRRORET_GPG_HOMEDIR` (default `/etc/mirroret/gnupg`).

### Customise key identity

```bash
MIRRORET_GPG_NAME="My Org Mirror"
MIRRORET_GPG_EMAIL="mirror@myorg.example"
MIRRORET_GPG_AUTO=1 sudo ./install.sh
```

### Distribute the key to clients

A convenience script is generated at `BASE_DIR/config/import-mirroret-gpg-key.sh`.
Clients can run it directly (requires `curl`):

```bash
# On each client:
bash <(curl -fsSL http://<mirror-ip>:8080/config/import-mirroret-gpg-key.sh)
```

Or manually:

```bash
# APT clients:
curl -fsSL http://<mirror-ip>:8080/config/GPG-KEY.asc \
    | sudo gpg --dearmor -o /etc/apt/keyrings/mirroret.gpg
# RPM clients:
sudo rpm --import http://<mirror-ip>:8080/config/GPG-KEY.asc
```

---

## Docker Registry

### TLS mode

Use the mirroret nginx TLS listener (`--tls-self-signed` or `MIRRORET_TLS_CERT`) to terminate TLS. The Docker registry itself listens on localhost:5000 and is fronted by nginx.

**Distribute the cert to Docker clients:**

```bash
# On each Docker client:
sudo mkdir -p /etc/docker/certs.d/<mirror-ip>:5000
sudo wget -q http://<mirror-ip>:8080/config/cert.pem \
    -O /etc/docker/certs.d/<mirror-ip>:5000/ca.crt
sudo systemctl restart docker
```

### Lab mode (insecure, opt-in)

```bash
MIRRORET_DOCKER_INSECURE=1 sudo ./install.sh
```

This adds the registry to `insecure-registries` in the generated client `daemon.json`. A security warning is printed.

---

## pip / pypiserver

### TLS mode (default)

Configure a TLS certificate for pypiserver (via nginx reverse proxy).

```bash
# nginx handles TLS termination on port 8081 or 8080/pip/.
# Configure Let's Encrypt or a self-signed cert in the nginx vhost.
```

### Lab mode (insecure, opt-in)

```bash
MIRRORET_PIP_INSECURE=1 sudo ./install.sh
```

Adds `trusted-host` to pip.conf. A security warning is printed.

---

## Network hardening

### Restrict repository access to known clients

```bash
# Only allow access from 10.0.0.0/8:
MIRRORET_FIREWALL_SOURCE=10.0.0.0/8 sudo ./install.sh
```

### nginx basic authentication

Add to the nginx server block to restrict package downloads:

```nginx
location /debian {
    auth_basic "Repository Access";
    auth_basic_user_file /etc/nginx/.htpasswd;
    alias /srv/mirroret/debian/approved;
    autoindex on;
}
```

Create password file:

```bash
htpasswd -c /etc/nginx/.htpasswd repouser
```

---

## Privilege reduction

All services (pypiserver, verdaccio) run as dedicated unprivileged system users:
- `mirroret-pip` — owns `/srv/mirroret/pip/`
- `mirroret-npm` — owns `/srv/mirroret/npm/`

nginx runs as `www-data` (Debian) or `nginx` (RHEL).

The Docker registry container should be secured separately. See [Docker security docs](https://docs.docker.com/registry/deploying/).

---

## Audit trail

All package installations are logged via nginx access logs:

```
/var/log/nginx/mirroret-unified-access.log
```

For pip and npm, service logs are accessible via:

```bash
journalctl -u pypiserver -f
journalctl -u verdaccio -f
```

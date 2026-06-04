# Security Guide

## Overview

By default, mirroret generates client configurations that **require** package signature verification. Insecure modes exist for isolated/air-gapped lab environments and must be explicitly opted into.

---

## APT / Debian-Ubuntu

### Secure mode (default)

Client packages are verified against a GPG keyring. You must sign your repository.

**Step 1: Generate a signing key pair**

```bash
gpg --batch --gen-key <<EOF
%no-protection
Key-Type: RSA
Key-Length: 4096
Subkey-Type: RSA
Subkey-Length: 4096
Name-Real: Mirroret Repository
Name-Email: mirroret@$(hostname -f)
Expire-Date: 2y
EOF
```

**Step 2: Export the public key**

```bash
gpg --export --armor 'Mirroret Repository' > /srv/mirroret/config/mirroret.gpg.asc
# Also export in binary for apt
gpg --export 'Mirroret Repository' > /srv/mirroret/config/mirroret.gpg
```

**Step 3: Sign the repository**

```bash
# Re-generate APT metadata with signing.
# After dpkg-scanpackages, sign the Release file:
apt-ftparchive release /srv/mirroret/debian/approved > /srv/mirroret/debian/approved/Release
gpg --default-key 'Mirroret Repository' \
    -abs -o /srv/mirroret/debian/approved/Release.gpg \
    /srv/mirroret/debian/approved/Release
gpg --default-key 'Mirroret Repository' \
    --clearsign -o /srv/mirroret/debian/approved/InRelease \
    /srv/mirroret/debian/approved/Release
```

**Step 4: Configure mirroret**

```bash
# In /etc/mirroret/mirroret.conf or as environment variable:
MIRRORET_APT_KEYRING=/etc/apt/keyrings/mirroret.gpg
```

**Step 5: Distribute the keyring to clients**

```bash
# On each client:
sudo mkdir -p /etc/apt/keyrings
sudo wget http://<mirror-ip>:8080/config/mirroret.gpg -O /etc/apt/keyrings/mirroret.gpg
sudo chmod 644 /etc/apt/keyrings/mirroret.gpg
```

### Lab mode (insecure, opt-in)

Only for air-gapped/isolated environments with no external network access.

```bash
# Install with insecure APT mode:
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

## Docker Registry

### TLS mode (default)

The Docker registry does not include TLS by default — you must configure it.

**Using a self-signed certificate:**

```bash
mkdir -p /etc/docker/registry/certs
openssl req -newkey rsa:4096 -nodes -sha256 \
    -keyout /etc/docker/registry/certs/domain.key \
    -x509 -days 365 \
    -out /etc/docker/registry/certs/domain.crt \
    -subj "/CN=<mirror-ip>"

# Update /etc/docker/registry/config.yml:
# http:
#   tls:
#     certificate: /etc/docker/registry/certs/domain.crt
#     key: /etc/docker/registry/certs/domain.key
```

**Distribute the cert to clients:**

```bash
# On each client:
sudo mkdir -p /etc/docker/certs.d/<mirror-ip>:5000
sudo cp domain.crt /etc/docker/certs.d/<mirror-ip>:5000/ca.crt
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

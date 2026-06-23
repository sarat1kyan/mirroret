# Security Guide

## Overview

By default mirroret generates client configs that **require** package signature
verification. Insecure modes exist only for isolated/air-gapped lab environments
and must be explicitly opted into.

---

## APT / Debian-Ubuntu

### Auto-provision GPG (recommended)

The simplest path: let mirroret generate and manage the signing key.

```bash
sudo ./install.sh --gpg-auto
```

- Generates a 4096-bit RSA key in `/etc/mirroret/gnupg/` (isolated from the system keyring).
- Exports the public key to `/srv/mirroret/config/GPG-KEY.asc` (armored) and
  `/srv/mirroret/config/mirroret.gpg` (binary).
- Writes a client import helper: `/srv/mirroret/config/import-mirroret-gpg-key.sh`.
- Sets `MIRRORET_APT_KEYRING` automatically so client configs use `signed-by=`.

Customise the key identity:

```bash
sudo MIRRORET_GPG_NAME="My Org Mirror" \
     MIRRORET_GPG_EMAIL="mirror@myorg.example" \
     ./install.sh --gpg-auto
```

**Distribute the key to APT clients:**

```bash
# Option A — run the generated helper script on each client (requires curl):
bash <(curl -fsSL http://<mirror-ip>:8080/config/import-mirroret-gpg-key.sh)

# Option B — manually import the binary keyring:
sudo mkdir -p /etc/apt/keyrings
sudo curl -fsSL http://<mirror-ip>:8080/config/mirroret.gpg \
    -o /etc/apt/keyrings/mirroret.gpg
sudo chmod 644 /etc/apt/keyrings/mirroret.gpg
```

### Bring your own GPG key

```bash
# Import your key into the mirroret keyring:
gpg --export-secret-keys <FINGERPRINT> \
    | gpg --homedir /etc/mirroret/gnupg --import

# Tell mirroret which key to use:
sudo MIRRORET_GPG_KEYID=<FINGERPRINT> ./install.sh
```

### Manual repository signing (custom .deb packages)

mirroret mirrors upstream packages which are already signed by Ubuntu/Debian.
If you add your own custom `.deb` packages to the `approved/` tree:

```bash
GPG="gpg --homedir /etc/mirroret/gnupg"
cd /srv/mirroret/debian/approved

dpkg-scanpackages . /dev/null > Packages
gzip -9c Packages > Packages.gz
apt-ftparchive release . > Release

# Sign the Release file:
${GPG} -abs -o Release.gpg Release
${GPG} --clearsign -o InRelease Release
```

### Lab mode (insecure — opt in explicitly)

```bash
sudo ./install.sh --insecure
# or selectively:
sudo MIRRORET_APT_INSECURE=1 ./install.sh
```

Generates `trusted=yes` in client configs. A security warning is printed.
**Only use this in isolated environments.**

---

## RPM / RHEL-CentOS

### Auto-provision GPG (recommended)

`--gpg-auto` also exports the key in a format usable by RPM clients:

```bash
sudo ./install.sh --gpg-auto
```

The armored public key is at `/srv/mirroret/config/GPG-KEY.asc` and is served
via nginx at `http://<mirror-ip>:8080/config/GPG-KEY.asc`.

Set the key URL so RPM client configs are correct:

```bash
sudo MIRRORET_RPM_GPGKEY_URL=http://<mirror-ip>:8080/config/GPG-KEY.asc \
     ./install.sh --gpg-auto
```

**Import the key on RPM clients:**

```bash
sudo rpm --import http://<mirror-ip>:8080/config/GPG-KEY.asc
```

### Bring your own RPM GPG key

```bash
# Export your key:
gpg --export --armor 'My Mirror Key' > /srv/mirroret/config/GPM-GPG-KEY-mirror

# Set the URL in the client repo file:
sudo MIRRORET_RPM_GPGKEY_URL=http://<mirror-ip>:8080/config/RPM-GPG-KEY-mirror \
     ./install.sh
```

### Lab mode (insecure — opt in explicitly)

```bash
sudo MIRRORET_RPM_INSECURE=1 ./install.sh
```

Generates `gpgcheck=0` in client repo files. A security warning is printed.

---

## TLS (nginx HTTPS listener)

mirroret configures an nginx HTTPS listener in addition to the HTTP listener.
TLS is opt-in; without it only HTTP is served.

### Option A — auto-generate a self-signed certificate

```bash
sudo ./install.sh --tls-self-signed
# or:
sudo MIRRORET_TLS_SELF_SIGNED=1 ./install.sh
```

- Generates a 4096-bit RSA cert valid for 10 years.
- Cert stored at `/etc/mirroret/tls/cert.pem`, key at `/etc/mirroret/tls/key.pem`.
- HTTPS listens on port 8443 by default (`MIRRORET_TLS_PORT=8443`).
- Clients will see an "untrusted CA" warning until they import the cert.

**Distribute the cert to clients:**

```bash
# Debian/Ubuntu clients — trust the cert system-wide:
sudo curl -fsSL http://<mirror-ip>:8080/config/cert.pem \
    -o /usr/local/share/ca-certificates/mirroret.crt
sudo update-ca-certificates

# RHEL/Rocky clients:
sudo curl -fsSL http://<mirror-ip>:8080/config/cert.pem \
    -o /etc/pki/ca-trust/source/anchors/mirroret.crt
sudo update-ca-trust extract

# Docker clients — trust per-registry:
sudo mkdir -p /etc/docker/certs.d/<mirror-ip>:5000
sudo curl -fsSL http://<mirror-ip>:8080/config/cert.pem \
    -o /etc/docker/certs.d/<mirror-ip>:5000/ca.crt
sudo systemctl restart docker
```

> **Note:** The cert is served over plain HTTP so clients can retrieve it without
> already having TLS configured. This is acceptable because it is a public
> certificate, not a secret.

### Option B — bring your own certificate

```bash
sudo MIRRORET_TLS_CERT=/etc/ssl/certs/server.crt \
     MIRRORET_TLS_KEY=/etc/ssl/private/server.key \
     ./install.sh
```

Both files must be PEM-encoded. They are validated with `openssl x509` at install time.
Use a cert from your internal CA or a public CA (e.g., Let's Encrypt).

### Custom TLS port

```bash
sudo MIRRORET_TLS_PORT=443 MIRRORET_TLS_SELF_SIGNED=1 ./install.sh
```

Remember to open the custom port in the firewall (see [NETWORK_ACCESS.md](NETWORK_ACCESS.md)).

### No TLS (HTTP only — default)

Do not pass `--tls-self-signed` or set `MIRRORET_TLS_CERT`/`MIRRORET_TLS_KEY`.
The HTTP listener on port 8080 is always active.

---

## Docker Registry

### TLS via nginx (recommended)

The Docker registry itself always listens on `localhost:5000` (HTTP). nginx terminates
TLS and proxies `/v2/` to the registry.

Enable TLS on the nginx side:

```bash
sudo ./install.sh --tls-self-signed
```

Docker clients must be configured to use the HTTPS endpoint:

```bash
# On each Docker client, add to /etc/docker/daemon.json:
{
  "registry-mirrors": ["https://<mirror-ip>:8443"]
}
# Then restart Docker:
sudo systemctl restart docker
```

Import the mirror's TLS cert into Docker (see cert distribution above).

### Lab mode — insecure registry (opt in)

```bash
sudo MIRRORET_DOCKER_INSECURE=1 ./install.sh
```

The generated `config/docker-daemon.json` adds `insecure-registries`.
On each Docker client, apply the file and restart Docker.

---

## pip / pypiserver

pypiserver listens on port 8081 over plain HTTP. The TLS nginx listener at 8443
includes a reverse proxy for `/pip/` which provides HTTPS access to pypiserver.

### Lab mode (trusted-host)

```bash
sudo MIRRORET_PIP_INSECURE=1 ./install.sh
```

Adds `trusted-host = <mirror-ip>` to the generated `pip.conf`.
A security warning is printed.

---

## Network access restriction

Restrict which client IPs can reach the mirror server:

```bash
# Allow only 10.0.0.0/8 to reach all ports:
sudo MIRRORET_FIREWALL_SOURCE=10.0.0.0/8 ./install.sh
```

See [NETWORK_ACCESS.md](NETWORK_ACCESS.md) for per-tool firewall commands
(ufw, firewalld, iptables).

### nginx basic authentication

To require a username/password for repository access:

```bash
# Create the password file:
sudo apt-get install -y apache2-utils   # Debian/Ubuntu
sudo dnf install -y httpd-tools         # RHEL/Rocky
sudo htpasswd -c /etc/nginx/.htpasswd repouser

# Add to the relevant location block in the nginx config:
# /etc/nginx/sites-available/mirroret-unified   (Debian/Ubuntu)
# /etc/nginx/conf.d/mirroret-unified.conf       (RHEL/Rocky)
```

```nginx
location /ubuntu {
    auth_basic "Repository Access";
    auth_basic_user_file /etc/nginx/.htpasswd;
    alias /srv/mirroret/debian/mirror/mirror/archive.ubuntu.com/ubuntu;
    autoindex on;
}
```

After editing the config, reload nginx:

```bash
sudo nginx -t && sudo systemctl reload nginx
```

---

## Privilege model

All long-running services run as dedicated unprivileged users:

| Service | User | Owns |
|---|---|---|
| pypiserver | `mirroret-pip` | `/srv/mirroret/pip/`, `/srv/mirroret/staging/pip/`, `/srv/mirroret/approved/pip/` |
| Verdaccio | `mirroret-npm` | `/srv/mirroret/npm/`, `/etc/verdaccio/` |
| nginx | `www-data` (Debian) / `nginx` (RHEL) | reads repository directories |

`install.sh` must be run as root. After installation, the services drop privileges.

---

## Audit trail

All package download requests are logged in nginx access logs:

```
/var/log/nginx/mirroret-unified-access.log
/var/log/nginx/mirroret-unified-tls-access.log   (when TLS is enabled)
```

pypiserver and Verdaccio logs:

```bash
journalctl -u pypiserver -f
journalctl -u verdaccio -f
```

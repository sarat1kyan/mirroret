# Network Access Requirements

This document covers every network connection mirroret makes or listens on.

- **The mirror server** needs outbound internet access during installation and sync.
- **Client machines** only need to reach the mirror server - not the internet.

---

## 1. Inbound ports: what clients need to reach on the mirror server

Open these on the mirror server's firewall. All ports are configurable via environment variables.

| Default port | Variable | Service | Required |
|---|---|---|---|
| 8080 | `MIRRORET_WEB_PORT` | nginx HTTP - APT, RPM, static files | Always |
| 8443 | `MIRRORET_TLS_PORT` | nginx HTTPS - TLS listener | Only if TLS enabled |
| 8081 | `MIRRORET_PIP_PORT` | pypiserver (pip/PyPI) | If pip enabled |
| 5000 | `MIRRORET_DOCKER_REGISTRY_PORT` | Docker registry | If Docker enabled |
| 4873 | `MIRRORET_NPM_PORT` | Verdaccio (npm) | If npm enabled |

The TLS port (8443) is only opened in the firewall automatically when `--tls-self-signed`
or `MIRRORET_TLS_CERT`/`MIRRORET_TLS_KEY` are set.

### Firewall commands - inbound (run on the mirror server)

**UFW (Ubuntu/Debian):**

```bash
sudo ufw allow 8080/tcp # nginx HTTP
sudo ufw allow 8443/tcp # nginx HTTPS (only if TLS is enabled)
sudo ufw allow 8081/tcp # pypiserver / pip
sudo ufw allow 5000/tcp # Docker registry
sudo ufw allow 4873/tcp # Verdaccio / npm

# Optional: restrict to a specific subnet only
sudo ufw allow from 192.168.10.0/24 to any port 8080 proto tcp
sudo ufw allow from 192.168.10.0/24 to any port 8081 proto tcp
sudo ufw allow from 192.168.10.0/24 to any port 5000 proto tcp
sudo ufw allow from 192.168.10.0/24 to any port 4873 proto tcp
```

**firewalld (RHEL / Rocky / AlmaLinux):**

```bash
# Open ports permanently in the default zone:
sudo firewall-cmd --permanent --add-port=8080/tcp # nginx HTTP
sudo firewall-cmd --permanent --add-port=8443/tcp # nginx HTTPS (only if TLS)
sudo firewall-cmd --permanent --add-port=8081/tcp # pypiserver
sudo firewall-cmd --permanent --add-port=5000/tcp # Docker registry
sudo firewall-cmd --permanent --add-port=4873/tcp # Verdaccio

# Reload to apply:
sudo firewall-cmd --reload

# Verify:
sudo firewall-cmd --list-ports

# Optional: restrict to a specific subnet (source zone method):
sudo firewall-cmd --permanent --new-zone=mirroret
sudo firewall-cmd --permanent --zone=mirroret --add-source=192.168.10.0/24
sudo firewall-cmd --permanent --zone=mirroret --add-port=8080/tcp
sudo firewall-cmd --permanent --zone=mirroret --add-port=8081/tcp
sudo firewall-cmd --permanent --zone=mirroret --add-port=5000/tcp
sudo firewall-cmd --permanent --zone=mirroret --add-port=4873/tcp
sudo firewall-cmd --reload
```

**iptables (direct):**

```bash
# Allow inbound from anywhere (replace with your client subnet if desired):
sudo iptables -A INPUT -p tcp --dport 8080 -j ACCEPT # nginx HTTP
sudo iptables -A INPUT -p tcp --dport 8443 -j ACCEPT # nginx HTTPS
sudo iptables -A INPUT -p tcp --dport 8081 -j ACCEPT # pypiserver
sudo iptables -A INPUT -p tcp --dport 5000 -j ACCEPT # Docker registry
sudo iptables -A INPUT -p tcp --dport 4873 -j ACCEPT # Verdaccio

# Persist rules (choose one):
sudo iptables-save > /etc/iptables/rules.v4 # Debian/Ubuntu
sudo service iptables save # RHEL/Rocky
```

> `install.sh` calls `configure_firewall()` which automatically adds inbound rules via
> whichever tool is detected (ufw > firewalld > iptables). Use `--no-firewall` to skip
> this step if you manage firewall rules separately.

---

## 2. Outbound ports: what the mirror server needs to reach the internet

### 2a. During `install.sh` (one-time setup)

These hosts are contacted **only during installation** to install OS packages and
tools. After installation they are not needed unless you reinstall.

#### Debian / Ubuntu

| Destination | Port | Protocol | Purpose |
|---|---|---|---|
| `archive.ubuntu.com` | 80 | HTTP | `apt-get install nginx, python3, nodejs...` |
| `security.ubuntu.com` | 80 | HTTP | Ubuntu security package index update |
| `deb.debian.org` | 80 | HTTP | Same role on Debian (replaces archive.ubuntu.com) |

#### RHEL / Rocky Linux / AlmaLinux / CentOS Stream

The exact hostnames depend on which distribution you run. All use HTTPS/443.

**Rocky Linux 8 / 9:**

| Destination | Port | Protocol | Purpose |
|---|---|---|---|
| `dl.rockylinux.org` | 443 | HTTPS | `dnf install nginx, createrepo_c, nodejs, podman...` |
| `mirrors.rockylinux.org` | 443 | HTTPS | Mirror-list resolution (dnf uses this to find the fastest mirror) |

**AlmaLinux 8 / 9:**

| Destination | Port | Protocol | Purpose |
|---|---|---|---|
| `repo.almalinux.org` | 443 | HTTPS | AlmaLinux BaseOS, AppStream, Extras packages |
| `mirrors.almalinux.org` | 443 | HTTPS | Mirror-list resolution |

**RHEL 8 / 9 (Red Hat subscription):**

| Destination | Port | Protocol | Purpose |
|---|---|---|---|
| `cdn.redhat.com` | 443 | HTTPS | All Red Hat package downloads (subscription-based CDN) |
| `subscription.rhsm.redhat.com` | 443 | HTTPS | Subscription Manager registration and entitlement |

> If the RHEL system is already registered (`subscription-manager status` shows `Current`),
> only `cdn.redhat.com` is needed during the install.

**CentOS Stream 8 / 9:**

| Destination | Port | Protocol | Purpose |
|---|---|---|---|
| `mirror.stream.centos.org` | 443 | HTTPS | CentOS Stream package downloads |
| `mirrors.centos.org` | 443 | HTTPS | Mirror-list resolution |

#### All distributions - tools installed from the internet

| Destination | Port | Protocol | Purpose |
|---|---|---|---|
| `registry-1.docker.io` | 443 | HTTPS | `docker/podman pull registry:2` (container backend) |
| `auth.docker.io` | 443 | HTTPS | Docker Hub token authentication for the pull above |
| `registry.npmjs.org` | 443 | HTTPS | `npm install -g verdaccio` |
| `pypi.org` | 443 | HTTPS | `pip install pypiserver passlib` (venv fallback) |
| `files.pythonhosted.org` | 443 | HTTPS | pip package tarballs for pypiserver install |

> **When is the container pull needed?**
> Only when the Docker registry backend resolves to `container` mode.
> On RHEL/Rocky 8 with `docker-distribution` available: native mode - no Docker Hub pull.
> On RHEL/Rocky 9 where `docker-distribution` is absent: Podman pulls `registry:2` from Docker Hub.
> On Debian/Ubuntu with `docker-registry` package available: native mode - no Docker Hub pull.

> **Air-gapped install:** If you pre-install all OS packages manually (`nginx`, `python3`,
> `nodejs`, `npm`, `podman` or `docker-distribution`, etc.) none of the above are needed.
> See section 5 for full offline instructions.

### 2b. During sync (recurring - runs via cron daily)

These hosts are contacted every time the mirror syncs packages.

**APT mirror:**

| Hostname | Port | Protocol | Purpose |
|---|---|---|---|
| `archive.ubuntu.com` | 80 | HTTP | Ubuntu package downloads |
| `security.ubuntu.com` | 80 | HTTP | Ubuntu security updates |
| `deb.debian.org` | 80 | HTTP | Debian packages (if mirroring Debian) |
| `security.debian.org` | 80 | HTTP | Debian security updates |

> If you override the upstream mirror (e.g., a regional mirror), allow that host instead.

**RPM mirror:**

| Hostname | Port | Protocol | Purpose |
|---|---|---|---|
| `dl.rockylinux.org` | 443 | HTTPS | Rocky Linux packages |
| `mirrors.rockylinux.org` | 443 | HTTPS | Rocky Linux mirror list |
| `dl.fedoraproject.org` | 443 | HTTPS | Fedora EPEL packages |
| `mirror.centos.org` | 80/443 | HTTP/S | CentOS packages |
| `vault.centos.org` | 443 | HTTPS | CentOS archived releases |

> The exact URLs depend on what is configured in `/etc/yum.repos.d/` on the mirror server.
> Run `dnf repolist -v` to see the current upstream URLs.

**Docker registry (pull-through cache):**

| Hostname | Port | Protocol | Purpose |
|---|---|---|---|
| `registry-1.docker.io` | 443 | HTTPS | Docker image layers |
| `auth.docker.io` | 443 | HTTPS | Docker Hub authentication tokens |
| `index.docker.io` | 443 | HTTPS | Docker Hub manifest API |
| `production.cloudflare.docker.com` | 443 | HTTPS | Docker CDN (image layer delivery) |

> The registry operates as a pull-through cache. Images are fetched from Docker Hub
> on first client request, then cached locally. `sync-docker-images.sh` pre-seeds
> a configurable list of images.

**pip (PyPI):**

| Hostname | Port | Protocol | Purpose |
|---|---|---|---|
| `pypi.org` | 443 | HTTPS | Package metadata and index |
| `files.pythonhosted.org` | 443 | HTTPS | Package tarball downloads |

**npm:**

| Hostname | Port | Protocol | Purpose |
|---|---|---|---|
| `registry.npmjs.org` | 443 | HTTPS | npm package metadata and tarballs |

---

## 3. Firewall rules: outbound (on the mirror server)

Most Linux distributions allow all outbound traffic by default. If your security
policy requires explicit outbound rules, add these.

**UFW - allow outbound:**

```bash
# Usually outbound is allowed by default. To be explicit:
sudo ufw allow out to any port 80 proto tcp # apt-get (HTTP)
sudo ufw allow out to any port 443 proto tcp # all HTTPS destinations
sudo ufw allow out to any port 53 proto udp # DNS (required for hostname resolution)
```

**firewalld - outbound is permitted by default in standard zones.**
If using a `drop` or custom zone, add outbound rules explicitly:

```bash
sudo firewall-cmd --permanent --direct --add-rule ipv4 filter OUTPUT 0 -p tcp --dport 80 -j ACCEPT
sudo firewall-cmd --permanent --direct --add-rule ipv4 filter OUTPUT 0 -p tcp --dport 443 -j ACCEPT
sudo firewall-cmd --permanent --direct --add-rule ipv4 filter OUTPUT 0 -p udp --dport 53 -j ACCEPT
sudo firewall-cmd --reload
```

---

## 4. Summary table - all rules at a glance

### Inbound (clients -> mirror server)

| Port | Proto | Direction | Service | When |
|---|---|---|---|---|
| 8080 | TCP | IN | nginx HTTP | Always |
| 8443 | TCP | IN | nginx HTTPS | TLS enabled only |
| 8081 | TCP | IN | pypiserver | pip enabled |
| 5000 | TCP | IN | Docker registry | Docker enabled |
| 4873 | TCP | IN | Verdaccio | npm enabled |

### Outbound (mirror server -> internet)

| Port | Proto | Direction | Destination | When |
|---|---|---|---|---|
| 80 | TCP | OUT | `archive.ubuntu.com`, `security.ubuntu.com`, `deb.debian.org` | APT sync + Debian install |
| 80/443 | TCP | OUT | `mirror.stream.centos.org`, `mirrors.centos.org` | RPM CentOS Stream sync/install |
| 443 | TCP | OUT | `dl.rockylinux.org`, `mirrors.rockylinux.org` | RPM Rocky sync + Rocky install |
| 443 | TCP | OUT | `repo.almalinux.org`, `mirrors.almalinux.org` | AlmaLinux sync + AlmaLinux install |
| 443 | TCP | OUT | `cdn.redhat.com` | RHEL subscription sync + install |
| 443 | TCP | OUT | `dl.fedoraproject.org` | RPM Fedora/EPEL sync |
| 443 | TCP | OUT | `registry-1.docker.io`, `auth.docker.io`, `index.docker.io`, `production.cloudflare.docker.com` | Docker sync |
| 443 | TCP | OUT | `pypi.org`, `files.pythonhosted.org` | pip sync |
| 443 | TCP | OUT | `registry.npmjs.org` | npm sync |
| 443 | TCP | OUT | `registry-1.docker.io`, `auth.docker.io` | Install: `docker/podman pull registry:2` (container backend) |
| 443 | TCP | OUT | `registry.npmjs.org` | Install: `npm install -g verdaccio` |
| 443 | TCP | OUT | `pypi.org`, `files.pythonhosted.org` | Install: `pip install pypiserver` |
| 53 | UDP | OUT | DNS server | All hostname resolution |

---

## 5. Air-gapped / offline installation

If the mirror server has no internet access at all:

1. Pre-install all OS packages before running `install.sh`:

   ```bash
   # Debian/Ubuntu (on a connected machine, then copy .deb files):
   apt-get download nginx python3-venv nodejs npm gnupg wget curl rsync cron dpkg-dev
   # Then on the air-gapped server: dpkg -i *.deb

   # RHEL/Rocky (on a connected machine):
   dnf download --resolve nginx createrepo_c yum-utils python3 python3-pip wget curl rsync cronie \
       policycoreutils-python-utils nodejs npm podman docker-distribution
   # Then on the air-gapped server: dnf localinstall *.rpm
   # Note: docker-distribution may not exist on RHEL 9 - skip it; podman will be the container backend.
   ```

2. Install `verdaccio`, `pypiserver`, and `registry:2` from offline sources:

   ```bash
   # Verdaccio: bundle it as a tarball on a connected machine
   npm pack verdaccio
   # Copy and install offline:
   npm install -g verdaccio-*.tgz

   # pypiserver: download wheel on connected machine
   pip download pypiserver passlib -d ./pypiserver-offline/
   # Copy and install offline:
   pip install --no-index --find-links ./pypiserver-offline/ pypiserver passlib

   # Docker registry image: save on connected machine
   docker pull registry:2
   docker save registry:2 | gzip > registry2.tar.gz
   # Copy and load on air-gapped server:
   docker load < registry2.tar.gz
   ```

3. Run install with `--no-docker` if no container runtime is available, or
   use `MIRRORET_DOCKER_BACKEND=native` to install the OS-native registry package
   from your pre-loaded offline repo.

4. All subsequent syncs will fail (no internet). Schedule syncs on a connected
   machine and transfer the package data to the air-gapped server manually (rsync
   over a DMZ hop, USB transfer, etc.).

# Network Access Requirements

This document covers every network connection mirroret makes or listens on.

- **The mirror server** needs outbound internet access during installation and sync.
- **Client machines** only need to reach the mirror server - not the internet.

---

## 1. Inbound ports: what clients need to reach on the mirror server

Open these on the mirror server's firewall. All ports are configurable via environment variables.

| Default port | Variable | Service | Required |
|---|---|---|---|
| 8080 | `MIRRORET_WEB_PORT` | nginx HTTP - APT, RPM, `/config/`, proxies for `/pip/`, `/npm/`, `/v2/` | Always |
| 8443 | `MIRRORET_TLS_PORT` | nginx HTTPS - TLS listener | Only if TLS configured |
| 8081 | `MIRRORET_PIP_PORT` | pypiserver (pip/PyPI) | If pip enabled |
| 5000 | `MIRRORET_DOCKER_REGISTRY_PORT` | Docker registry (listens on all interfaces) | If Docker enabled |
| 4873 | `MIRRORET_NPM_PORT` | Verdaccio (npm) | If npm enabled |

`install.sh` opens these itself unless `--no-firewall`: always the web port,
plus the pip/Docker/npm ports for enabled components, plus the TLS port
**when TLS is ready** at that point of the run (`--tls-self-signed` or
`MIRRORET_TLS_CERT`+`MIRRORET_TLS_KEY`, cert and key in place). Rules go to
whichever firewall is **running** (ufw, then firewalld, then iptables); an
installed-but-stopped firewall gets no rules and a warning.

The on-demand cache daemon (`mirroret-cache`, `MIRRORET_CACHE_PORT` 8082)
binds 127.0.0.1 only and is never opened; nginx is its only client.

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

### 2b. During sync (recurring - cron, nightly) and on cache misses

These hosts are derived from `lib/targets.sh` (`apt_suites`, `rpm_repo_url`)
for the flavors you configure. Only the rows for your targets apply. In
hybrid/cache storage mode the same hosts are also contacted by
`mirroret-cache` whenever a client asks for a file not yet on disk.

**APT mirror** - port **80** by default; **443** when `MIRRORET_APT_SCHEME=https`
(needed behind a CONNECT-only proxy):

| Flavor | Hostname | Path | Override |
|---|---|---|---|
| `ubuntu` | `archive.ubuntu.com` | `/ubuntu` (release, -updates, -backports) | `MIRRORET_APT_UPSTREAM_HOST` |
| `ubuntu` | `security.ubuntu.com` | `/ubuntu` (-security) | `MIRRORET_APT_SECURITY_HOST` |
| `ubuntu-ports` | `ports.ubuntu.com` | `/ubuntu-ports` (all suites) | `MIRRORET_APT_PORTS_HOST` |
| `debian` | `deb.debian.org` | `/debian` (release, -updates, -backports) | `MIRRORET_APT_UPSTREAM_HOST` |
| `debian` | `deb.debian.org` | `/debian-security` (-security) | `MIRRORET_APT_SECURITY_HOST` |

> Debian security lives at `deb.debian.org/debian-security`, not
> `security.debian.org`. If you point an override at a regional mirror,
> allow that host instead.

**RPM mirror** - port **443** for every flavor:

| Flavor | Hostname | Base path | Override |
|---|---|---|---|
| `rocky` | `dl.rockylinux.org` | `/pub/rocky/<major>/<Repo>/<arch>/os/` | `MIRRORET_RPM_ROCKY_BASE` |
| `almalinux` | `repo.almalinux.org` | `/almalinux/<major>/<Repo>/<arch>/os/` | `MIRRORET_RPM_ALMA_BASE` |
| `ol` | `yum.oracle.com` | `/repo/OracleLinux/OL<major>/<repo>/<arch>/` | `MIRRORET_RPM_ORACLE_BASE` |
| `centos` | `mirror.stream.centos.org` | `/<major>-stream/<Repo>/<arch>/os/` | `MIRRORET_RPM_CENTOS_BASE` |
| `fedora` | `dl.fedoraproject.org` | `/pub/fedora/linux/{releases,updates}/<major>/Everything/<arch>/` | `MIRRORET_RPM_FEDORA_BASE` |
| `epel` | `dl.fedoraproject.org` | `/pub/epel/<major>/Everything/<arch>/` (`next/` for `epel:next`) | `MIRRORET_RPM_EPEL_BASE` |
| `rhel` | `cdn.redhat.com` | `/content/dist/rhel<major>/<major>/<arch>/<repo>/os` (TLS client cert from `/etc/pki/entitlement/`) | `MIRRORET_RPM_RHEL_CDN` |

> The native engine fetches these URLs directly; no mirror-list hosts are
> involved. Only the legacy `reposync` engine uses whatever
> `/etc/yum.repos.d/` on the server points at (`dnf repolist -v`).

**Docker registry (pull-through cache):**

| Hostname | Port | Protocol | Purpose |
|---|---|---|---|
| `registry-1.docker.io` | 443 | HTTPS | Docker image layers |
| `auth.docker.io` | 443 | HTTPS | Docker Hub authentication tokens |
| `index.docker.io` | 443 | HTTPS | Docker Hub manifest API |
| `production.cloudflare.docker.com` | 443 | HTTPS | Docker CDN (image layer delivery) |

> In `cache` mode the registry proxies `MIRRORET_DOCKER_UPSTREAM_URL`
> (default `https://registry-1.docker.io`); Docker Hub then redirects layer
> downloads to the other hosts above. In `hosted` mode `sync-docker-images.sh`
> pulls a configurable list with the local `docker`/`podman` CLI.

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

| Port | Proto | Destination | When |
|---|---|---|---|
| 80 (443 with `MIRRORET_APT_SCHEME=https`) | TCP | `archive.ubuntu.com`, `security.ubuntu.com` | `ubuntu` targets |
| 80 (443 with `MIRRORET_APT_SCHEME=https`) | TCP | `ports.ubuntu.com` | `ubuntu-ports` targets |
| 80 (443 with `MIRRORET_APT_SCHEME=https`) | TCP | `deb.debian.org` | `debian` targets |
| 443 | TCP | `dl.rockylinux.org` | `rocky` targets |
| 443 | TCP | `repo.almalinux.org` | `almalinux` targets |
| 443 | TCP | `yum.oracle.com` | `ol` targets |
| 443 | TCP | `mirror.stream.centos.org` | `centos` targets |
| 443 | TCP | `dl.fedoraproject.org` | `fedora` / `epel` targets |
| 443 | TCP | `cdn.redhat.com` | `rhel` targets |
| 443 | TCP | `registry-1.docker.io`, `auth.docker.io`, `index.docker.io`, `production.cloudflare.docker.com` | Docker cache mode / pre-seed; install (`registry:2` pull, container backend) |
| 443 | TCP | `pypi.org`, `files.pythonhosted.org` | pip sync; install (`pip install pypiserver` venv fallback) |
| 443 | TCP | `registry.npmjs.org` | npm sync (Verdaccio uplink); install (`npm install -g verdaccio`) |
| 80/443 | TCP | the server's own distro repos | install (`apt-get` / `dnf install nginx ...`) |
| 53 | UDP | DNS | hostname resolution |

Behind a proxy all of the above go to the proxy instead; set
`MIRRORET_PROXY` in `/etc/mirroret/mirroret.conf` ([PROXY_AND_CA.md](PROXY_AND_CA.md)).

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

4. Syncs need upstream, so on a fully air-gapped host they fail. Use
   `MIRRORET_APT_MODE=mirror` on a connected machine and transfer
   `/srv/mirroret/apt/` and `/srv/mirroret/redhat/mirror/` (rsync over a DMZ
   hop, removable media). `hybrid` and `cache` modes are not suitable for an
   air-gapped server: they fetch packages on demand.

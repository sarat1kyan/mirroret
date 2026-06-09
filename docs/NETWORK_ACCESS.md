# Network Access Requirements

This document lists all external hostnames and ports that the mirroret server
needs outbound network access to. Use this to configure firewall rules or proxy
allowlists on the mirror host.

Client machines only need to reach **the mirror server itself** — they do not
need direct internet access once the mirror is running.

---

## APT mirror (`apt-mirror`)

| Hostname | Port | Protocol | Purpose |
|---|---|---|---|
| `archive.ubuntu.com` | 80 | HTTP | Ubuntu package downloads |
| `security.ubuntu.com` | 80 | HTTP | Ubuntu security updates |
| `deb.debian.org` | 80 | HTTP | Debian packages (optional) |
| `security.debian.org` | 80 | HTTP | Debian security updates (optional) |

> If you override `MIRRORET_APT_UPSTREAM` to use a regional mirror, allow that
> hostname instead of the defaults above.

---

## RPM mirror (`reposync` / `dnf`)

| Hostname | Port | Protocol | Purpose |
|---|---|---|---|
| `dl.rockylinux.org` | 443 | HTTPS | Rocky Linux packages |
| `mirrors.rockylinux.org` | 443 | HTTPS | Rocky Linux mirror list |
| `dl.fedoraproject.org` | 443 | HTTPS | Fedora packages |
| `mirror.centos.org` | 80/443 | HTTP/S | CentOS packages |
| `vault.centos.org` | 443 | HTTPS | CentOS archived versions |

> The actual upstream URLs depend on what is configured in `/etc/yum.repos.d/`
> on the mirror server. Run `dnf repolist -v` to see current upstream URLs.

---

## Docker registry (pull-through cache)

| Hostname | Port | Protocol | Purpose |
|---|---|---|---|
| `registry-1.docker.io` | 443 | HTTPS | Docker image layers |
| `auth.docker.io` | 443 | HTTPS | Docker Hub authentication tokens |
| `index.docker.io` | 443 | HTTPS | Docker Hub manifest API |
| `production.cloudflare.docker.com` | 443 | HTTPS | Docker CDN (image layer delivery) |

---

## pip mirror (`pypiserver`)

| Hostname | Port | Protocol | Purpose |
|---|---|---|---|
| `pypi.org` | 443 | HTTPS | Package metadata / index |
| `files.pythonhosted.org` | 443 | HTTPS | Package tarball downloads |

---

## npm mirror (`verdaccio`)

| Hostname | Port | Protocol | Purpose |
|---|---|---|---|
| `registry.npmjs.org` | 443 | HTTPS | npm package metadata and tarballs |

---

## Installer (one-time, during `install.sh` run)

These are contacted only during initial setup to install system dependencies.

| Hostname | Port | Protocol | Purpose |
|---|---|---|---|
| `archive.ubuntu.com` | 80 | HTTP | `apt-get install` of nginx, python3, etc. |
| `dl.rockylinux.org` | 443 | HTTPS | `dnf install` of nginx, createrepo, etc. |
| `registry-1.docker.io` | 443 | HTTPS | `docker pull registry:2` (registry image) |
| `registry.npmjs.org` | 443 | HTTPS | `npm install -g verdaccio` |
| `pypi.org` | 443 | HTTPS | `pip install pypiserver passlib` |

---

## Quick-reference firewall rule summary

| Destination | Port | Proto | Component |
|---|---|---|---|
| `archive.ubuntu.com` | 80 | TCP | APT Ubuntu |
| `security.ubuntu.com` | 80 | TCP | APT Ubuntu security |
| `deb.debian.org` | 80 | TCP | APT Debian (optional) |
| `security.debian.org` | 80 | TCP | APT Debian security (optional) |
| `dl.rockylinux.org` | 443 | TCP | RPM Rocky Linux |
| `mirrors.rockylinux.org` | 443 | TCP | RPM Rocky Linux mirror list |
| `dl.fedoraproject.org` | 443 | TCP | RPM Fedora |
| `mirror.centos.org` | 80/443 | TCP | RPM CentOS |
| `vault.centos.org` | 443 | TCP | RPM CentOS archived |
| `registry-1.docker.io` | 443 | TCP | Docker Hub layers |
| `auth.docker.io` | 443 | TCP | Docker Hub auth |
| `index.docker.io` | 443 | TCP | Docker Hub manifest |
| `production.cloudflare.docker.com` | 443 | TCP | Docker CDN |
| `pypi.org` | 443 | TCP | pip / PyPI |
| `files.pythonhosted.org` | 443 | TCP | pip package files |
| `registry.npmjs.org` | 443 | TCP | npm |

---

## Inbound ports (mirror server → clients)

These are the ports clients need to reach on the mirror server itself.
All are configurable via environment variables.

| Default port | Variable | Service |
|---|---|---|
| 8080 | `MIRRORET_WEB_PORT` | nginx (APT + RPM HTTP) |
| 8081 | `MIRRORET_PIP_PORT` | pypiserver (pip) |
| 5000 | `MIRRORET_DOCKER_REGISTRY_PORT` | Docker registry |
| 4873 | `MIRRORET_NPM_PORT` | Verdaccio (npm) |

# Unified Repository Server - Architecture & Management Guide

## System Architecture

### Overview
```
+-----------------------------------------------------------------+
| UNIFIED LOCAL REPOSITORY SERVER |
| |
| +----------------------------------------------------------+ |
| | Nginx Web Server (Port 8080) | |
| | +- /debian/ -> Debian/Ubuntu packages | |
| | +- /redhat/ -> RHEL/CentOS packages | |
| | +- /pip/ (proxy) -> Python packages (8081) | |
| | +- /npm/ (proxy) -> Node.js packages (4873) | |
| | +- /v2/ (proxy) -> Docker registry (5000) | |
| +----------------------------------------------------------+ |
| |
| +----------------------------------------------------------+ |
| | PyPI Server (pypiserver) - Port 8081 | |
| | Storage: /srv/localrepo/pip/approved | |
| +----------------------------------------------------------+ |
| |
| +----------------------------------------------------------+ |
| | Docker Registry - Port 5000 | |
| | Storage: /srv/localrepo/docker/registry | |
| +----------------------------------------------------------+ |
| |
| +----------------------------------------------------------+ |
| | Verdaccio (npm) - Port 4873 | |
| | Storage: /srv/localrepo/npm/approved | |
| +----------------------------------------------------------+ |
| |
| +----------------------------------------------------------+ |
| | Cron Jobs - Automated Sync | |
| | Daily at 2:00 AM - sync-all-repos.sh | |
| +----------------------------------------------------------+ |
+-----------------------------------------------------------------+
                              |
                   Network (LAN/WAN)
                              |
        +---------------------+---------------------+
        | | |
        v v v
   +---------+ +---------+ +---------+
   | Ubuntu | | CentOS | | Debian |
   | Client | | Client | | Client |
   +---------| +---------| +---------|
   | apt | | dnf | | apt |
   | pip | | pip | | pip |
   | docker | | docker | | docker |
   | npm | | npm | | npm |
   +---------+ +---------+ +---------+
```

## Port Allocation

| Port | Service | Purpose | Protocol |
|------|---------|---------|----------|
| 8080 | Nginx | Main web interface & APT/YUM repos | HTTP |
| 8081 | pypiserver | Python pip index | HTTP |
| 5000 | Docker Registry | Container image storage | HTTP |
| 4873 | Verdaccio | npm package registry | HTTP |
| 22 | SSH | Server management | SSH |

## Directory Structure

```
/srv/localrepo/
|
+-- debian/ # Debian/Ubuntu packages
| +-- mirror/ # Downloaded from official repos
| | +-- mirror/ # apt-mirror structure
| | | +-- archive.ubuntu.com/
| | | +-- ubuntu/
| | | +-- dists/
| | | +-- pool/
| | +-- var/ # apt-mirror working directory
| | +-- skel/
| +-- approved/ # Packages approved for client use
| +-- Packages.gz # Package index
| +-- [.deb files]
|
+-- redhat/ # RHEL/CentOS/Fedora packages
| +-- mirror/ # Downloaded from official repos
| | +-- rocky/
| | | +-- 9/
| | | +-- baseos/
| | | +-- appstream/
| | | +-- extras/
| | +-- centos/
| | +-- fedora/
| +-- approved/ # Packages approved for client use
| +-- rocky/
| +-- 9/
| +-- baseos/
| | +-- repodata/ # Repository metadata
| +-- appstream/
|
+-- pip/ # Python packages
| +-- mirror/ # Downloaded .whl and .tar.gz files
| +-- approved/ # Approved packages (served by pypiserver)
| +-- cache/ # pip cache directory
|
+-- docker/ # Docker images
| +-- registry/ # Docker registry storage
| | +-- docker/
| | +-- registry/
| | +-- v2/
| +-- mirror/ # Images downloaded from Docker Hub
| +-- approved/ # Approved images
|
+-- npm/ # Node.js packages
| +-- mirror/ # Downloaded packages
| +-- approved/ # Approved packages (Verdaccio storage)
| +-- cache/ # npm cache
|
+-- staging/ # Temporary area for package review
| +-- debian/
| +-- redhat/
| +-- pip/
| +-- docker/
| +-- npm/
|
+-- approved/ # Central approved packages
| +-- debian/
| +-- redhat/
| +-- pip/
| +-- docker/
| +-- npm/
|
+-- logs/ # All system logs
| +-- sync-debian-YYYYMMDD-HHMMSS.log
| +-- sync-redhat-YYYYMMDD-HHMMSS.log
| +-- sync-pip-YYYYMMDD-HHMMSS.log
| +-- sync-docker-YYYYMMDD-HHMMSS.log
| +-- sync-npm-YYYYMMDD-HHMMSS.log
|
+-- scripts/ # Management scripts
| +-- sync-all-repos.sh # Master sync script
| +-- sync-redhat-repos.sh # RHEL-specific sync
| +-- sync-pip-packages.sh # pip packages sync
| +-- sync-docker-images.sh # Docker images sync
| +-- sync-npm-packages.sh # npm packages sync
| +-- approve-all-packages.sh # Approval script
|
+-- config/ # Client configuration files
| +-- debian-client.list # APT sources for clients
| +-- redhat-client.repo # YUM/DNF repo for clients
| +-- pip.conf # pip configuration
| +-- .npmrc # npm configuration
| +-- docker-daemon.json # Docker daemon config
|
+-- README.md # Server documentation
```

## Package Workflow

### 1. Debian/Ubuntu Packages (.deb)

```
Official Ubuntu Repos
        v
   [apt-mirror sync]
        v
/srv/localrepo/debian/mirror/
        v
   [Manual Review]
        v
/srv/localrepo/debian/approved/
        v
[dpkg-scanpackages to generate index]
        v
   Served via Nginx
        v
    Client APT
```

### 2. RHEL/CentOS Packages (.rpm)

```
Official Rocky/CentOS Repos
        v
   [reposync]
        v
/srv/localrepo/redhat/mirror/
        v
   [Manual Review]
        v
/srv/localrepo/redhat/approved/
        v
[createrepo to generate metadata]
        v
   Served via Nginx
        v
   Client DNF/YUM
```

### 3. Python pip Packages

```
    PyPI.org
        v
  [pip download]
        v
/srv/localrepo/pip/mirror/
        v
   [Manual Review]
        v
/srv/localrepo/pip/approved/
        v
  [pypiserver serves]
        v
    Client pip
```

### 4. Docker Images

```
  Docker Hub
        v
  [docker pull]
        v
/srv/localrepo/docker/mirror/
        v
   [Manual Review]
        v
  [docker push to local registry]
        v
/srv/localrepo/docker/registry/
        v
   Docker Registry (port 5000)
        v
    Client docker
```

### 5. npm Packages

```
   npmjs.org
        v
[Verdaccio proxy/cache]
        v
/srv/localrepo/npm/approved/
        v
   Verdaccio serves
        v
    Client npm
```

## Management Operations

### Daily Operations

#### Morning Checklist (5 minutes)
```bash
# 1. Check sync logs from last night
tail -50 /srv/localrepo/logs/sync-*.log | grep -i error

# 2. Check all services
systemctl status nginx
systemctl status pypiserver
systemctl status verdaccio
docker ps | grep registry

# 3. Check disk usage
df -h /srv/localrepo

# 4. Quick package counts
echo "Debian packages: $(find /srv/localrepo/debian/approved -name '*.deb' | wc -l)"
echo "RHEL packages: $(find /srv/localrepo/redhat/approved -name '*.rpm' | wc -l)"
echo "pip packages: $(ls /srv/localrepo/pip/approved | wc -l)"
echo "Docker images: $(curl -s http://localhost:5000/v2/_catalog | jq -r '.repositories | length')"
```

### Manual Sync Operations

#### Sync All Repositories
```bash
# Full sync (takes hours)
/srv/localrepo/scripts/sync-all-repos.sh

# Monitor progress
tail -f /srv/localrepo/logs/sync-*.log
```

#### Sync Individual Repository Types
```bash
# Debian/Ubuntu only
apt-mirror

# RHEL/CentOS only
/srv/localrepo/scripts/sync-redhat-repos.sh

# pip packages only
/srv/localrepo/scripts/sync-pip-packages.sh

# Docker images only
/srv/localrepo/scripts/sync-docker-images.sh

# npm packages only
/srv/localrepo/scripts/sync-npm-packages.sh
```

### Package Approval

#### Auto-Approve All Packages
```bash
/srv/localrepo/scripts/approve-all-packages.sh
```

#### Manual Selective Approval

**Debian/Ubuntu:**
```bash
# View new packages
find /srv/localrepo/debian/mirror/mirror -name "*.deb" -newer /srv/localrepo/debian/approved

# Approve specific package
cp /srv/localrepo/debian/mirror/mirror/path/to/package.deb /srv/localrepo/debian/approved/

# Regenerate index
cd /srv/localrepo/debian/approved
dpkg-scanpackages . /dev/null | gzip -9c > Packages.gz
```

**RHEL/CentOS:**
```bash
# View new packages
find /srv/localrepo/redhat/mirror -name "*.rpm" -newer /srv/localrepo/redhat/approved

# Approve specific package
cp /srv/localrepo/redhat/mirror/rocky/9/baseos/package.rpm /srv/localrepo/redhat/approved/rocky/9/baseos/

# Regenerate metadata
createrepo --update /srv/localrepo/redhat/approved/rocky/9/baseos
```

**pip Packages:**
```bash
# View new packages
ls /srv/localrepo/pip/mirror/

# Approve package
cp /srv/localrepo/pip/mirror/package.whl /srv/localrepo/pip/approved/

# pypiserver auto-detects new packages
```

**Docker Images:**
```bash
# View downloaded images
docker images

# Tag for local registry
docker tag ubuntu:22.04 localhost:5000/ubuntu:22.04

# Push to local registry (approval)
docker push localhost:5000/ubuntu:22.04
```

**npm Packages:**
```bash
# Verdaccio automatically caches packages when requested
# Manual approval through Verdaccio web interface at http://SERVER:4873
```

## Monitoring & Maintenance

### Service Health Checks

```bash
#!/bin/bash
# health-check.sh

echo "Service Status:"
echo "+- Nginx: $(systemctl is-active nginx)"
echo "+- pypiserver: $(systemctl is-active pypiserver)"
echo "+- Verdaccio: $(systemctl is-active verdaccio)"
echo "+- Docker Registry: $(docker inspect -f '{{.State.Running}}' local-docker-registry)"

echo ""
echo "Port Availability:"
netstat -tuln | grep -E ':(8080|8081|5000|4873) '

echo ""
echo "Disk Usage:"
df -h /srv/localrepo | tail -1

echo ""
echo "Package Counts:"
echo " Debian: $(find /srv/localrepo/debian/approved -name '*.deb' 2>/dev/null | wc -l)"
echo " RHEL: $(find /srv/localrepo/redhat/approved -name '*.rpm' 2>/dev/null | wc -l)"
echo " pip: $(ls /srv/localrepo/pip/approved 2>/dev/null | wc -l)"
echo " Docker: $(curl -s http://localhost:5000/v2/_catalog 2>/dev/null | jq -r '.repositories | length' || echo 'N/A')"
```

### Log Management

```bash
# View recent errors across all logs
grep -i error /srv/localrepo/logs/*.log | tail -50

# Clean old logs (keep last 30 days)
find /srv/localrepo/logs -name "*.log" -mtime +30 -delete

# Monitor live sync
tail -f /srv/localrepo/logs/sync-*.log
```

### Disk Space Management

```bash
# Check usage by repository type
du -sh /srv/localrepo/*

# Clean Docker unused images
docker image prune -a

# Clean pip cache
rm -rf /srv/localrepo/pip/cache/*

# Clean npm cache
npm cache clean --force
```

## Customization & Configuration

### Adding More Debian/Ubuntu Versions

Edit `/etc/apt/mirror.list`:
```bash
# Add Debian 11 (Bullseye)
deb http://deb.debian.org/debian bullseye main contrib non-free
deb http://deb.debian.org/debian bullseye-updates main contrib non-free

# Add Ubuntu 20.04 (Focal)
deb http://archive.ubuntu.com/ubuntu focal main restricted universe multiverse
deb http://archive.ubuntu.com/ubuntu focal-updates main restricted universe multiverse
```

### Adding More RHEL Variants

Edit `/srv/localrepo/scripts/sync-redhat-repos.sh`:
```bash
# Add Fedora 38
reposync -p "$REPO_BASE/fedora/38" \
    --download-metadata \
    --repo fedora \
    --repo updates

createrepo --update "$REPO_BASE/fedora/38/fedora"
```

### Customizing pip Package List

Edit `/srv/localrepo/scripts/sync-pip-packages.sh`:
```bash
PACKAGES=(
    "requests"
    "flask"
    "django"
    "numpy"
    "pandas"
    # Add your packages here
    "your-package-name"
)
```

### Customizing Docker Images List

Edit `/srv/localrepo/scripts/sync-docker-images.sh`:
```bash
IMAGES=(
    "ubuntu:22.04"
    "nginx:latest"
    # Add your images here
    "your-image:tag"
)
```

## Security Hardening

### Enable HTTPS

```bash
# Generate self-signed certificate
sudo openssl req -x509 -nodes -days 365 -newkey rsa:4096 \
    -keyout /etc/nginx/ssl/repo.key \
    -out /etc/nginx/ssl/repo.crt

# Update nginx configuration
# Edit /etc/nginx/sites-available/unified-repo
# Change: listen 8080;
# To: listen 8443 ssl;
# Add:
# ssl_certificate /etc/nginx/ssl/repo.crt;
# ssl_certificate_key /etc/nginx/ssl/repo.key;

sudo nginx -t
sudo systemctl restart nginx
```

### Add Authentication

```bash
# Create password file
sudo htpasswd -c /etc/nginx/.htpasswd repouser

# Add to nginx config
# location / {
# auth_basic "Restricted Repository";
# auth_basic_user_file /etc/nginx/.htpasswd;
# }
```

### Network Restrictions

```bash
# Restrict to local network only
# Add to nginx server block:
# allow 192.168.1.0/24;
# deny all;

# Firewall configuration
sudo ufw allow from 192.168.1.0/24 to any port 8080
sudo ufw allow from 192.168.1.0/24 to any port 5000
```

## Performance Optimization

### Nginx Tuning

```nginx
# Edit /etc/nginx/nginx.conf
worker_processes auto;
worker_rlimit_nofile 65535;

events {
    worker_connections 4096;
    use epoll;
}

http {
    # Caching
    open_file_cache max=10000 inactive=30s;
    open_file_cache_valid 60s;
    
    # Keep-alive
    keepalive_timeout 65;
    keepalive_requests 100;
    
    # Compression
    gzip on;
    gzip_vary on;
    gzip_comp_level 6;
}
```

### Docker Registry Optimization

```yaml
# Edit /etc/docker/registry/config.yml
storage:
  cache:
    blobdescriptor: inmemory
  delete:
    enabled: true
```

### pypiserver Performance

```bash
# Edit /etc/systemd/system/pypiserver.service
# Add: --cache-control 3600
ExecStart=/usr/local/bin/pypi-server run -p 8081 --overwrite --cache-control 3600 /srv/localrepo/pip/approved
```

This completes the architecture and management guide!

# Network Architecture & Client Setup Guide

## Network Topology

```
┌────────────────────────────────────────────────────────────────┐
│                    Local Repository Server                     │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │  Nginx Web Server (Port 8080)                            │  │
│  │  ├── /mirror/     (Downloaded packages)                  │  │
│  │  └── /approved/   (Approved packages for clients)        │  │
│  └──────────────────────────────────────────────────────────┘  │
│                                                                │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │  Automatic Sync Service (Cron)                           │  │
│  │  ├── Daily sync at 2 AM                                  │  │
│  │  ├── Package approval workflow                           │  │
│  │  └── Repository metadata generation                      │  │
│  └──────────────────────────────────────────────────────────┘  │
│                                                                │
│  Directory Structure: /var/mirroret/                           │
│  ├── mirror/       # Official repo downloads                   │
│  ├── approved/     # Packages ready for client use             │
│  ├── staging/      # Temporary area for review                 │
│  ├── logs/         # Sync and operation logs                   │
│  ├── scripts/      # Management automation                     │
│  └── config/       # Client configuration files                │
└────────────────────────────────────────────────────────────────┘
                              │
                    HTTP Port 8080
                              │
        ┌─────────────────────┼─────────────────────┐
        │                     │                     │
        ▼                     ▼                     ▼
┌───────────────┐    ┌───────────────┐    ┌───────────────┐
│ Client 1      │    │ Client 2      │    │ Client 3      │
│ Ubuntu 22.04  │    │ CentOS 9      │    │ Debian 12     │
├───────────────┤    ├───────────────┤    ├───────────────┤
│ apt client    │    │ dnf/yum       │    │ apt client    │
│               │    │               │    │               │
│ Sources:      │    │ Repos:        │    │ Sources:      │
│ localrepo     │    │ localrepo     │    │ localrepo     │
└───────────────┘    └───────────────┘    └───────────────┘
```

## Port Configuration

| Port | Protocol | Service | Purpose | Security |
|------|----------|---------|---------|----------|
| 8080 | TCP | Nginx HTTP | Repository access | Firewall restricted |
| 22 | TCP | SSH | Management | Key-based auth |

## Client Configuration - Detailed Steps

### For Debian/Ubuntu Clients

#### Step 1: Backup Existing Configuration
```bash
# Backup current sources
sudo cp /etc/apt/sources.list /etc/apt/sources.list.original.backup
sudo mkdir -p /etc/apt/sources.list.d/backup
sudo mv /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/backup/ 2>/dev/null || true
```

#### Step 2: Disable Official Repositories (Optional but Recommended)
```bash
# Comment out all lines in original sources.list
sudo sed -i 's/^deb/# deb/g' /etc/apt/sources.list
```

#### Step 3: Add Local Repository
```bash
# Download the configuration from repo server
REPO_SERVER="192.168.1.100"  # Replace with your server IP
REPO_PORT="8080"

wget http://${REPO_SERVER}:${REPO_PORT}/config/localrepo.list -O /tmp/localrepo.list
sudo mv /tmp/localrepo.list /etc/apt/sources.list.d/

# Or manually create the file:
sudo tee /etc/apt/sources.list.d/localrepo.list << EOF
# Local Repository Server
deb [trusted=yes] http://${REPO_SERVER}:${REPO_PORT}/approved/mirror jammy main restricted universe multiverse
deb [trusted=yes] http://${REPO_SERVER}:${REPO_PORT}/approved/mirror jammy-updates main restricted universe multiverse
deb [trusted=yes] http://${REPO_SERVER}:${REPO_PORT}/approved/mirror jammy-security main restricted universe multiverse
EOF
```

#### Step 4: Update Package Cache
```bash
sudo apt clean
sudo apt update
```

#### Step 5: Verify Configuration
```bash
# Check repository sources
apt-cache policy

# Test package availability
apt-cache search nginx

# Try installing a package
sudo apt install htop
```

#### Step 6: Lock to Local Repository Only (Optional)
```bash
# Create apt preferences to prevent external repos
sudo tee /etc/apt/preferences.d/mirroret-only << EOF
Package: *
Pin: origin "${REPO_SERVER}"
Pin-Priority: 1000

Package: *
Pin: origin *
Pin-Priority: -1
EOF
```

### For RHEL/CentOS/Fedora Clients

#### Step 1: Backup Existing Configuration
```bash
# Backup current repos
sudo mkdir -p /etc/yum.repos.d/backup
sudo cp /etc/yum.repos.d/*.repo /etc/yum.repos.d/backup/
```

#### Step 2: Disable Official Repositories
```bash
# Move all existing repos to backup
sudo mv /etc/yum.repos.d/*.repo /etc/yum.repos.d/backup/

# Or disable them
sudo yum-config-manager --disable \*
```

#### Step 3: Add Local Repository
```bash
# Download the configuration
REPO_SERVER="192.168.1.100"  # Replace with your server IP
REPO_PORT="8080"

wget http://${REPO_SERVER}:${REPO_PORT}/config/localrepo.repo -O /tmp/localrepo.repo
sudo mv /tmp/localrepo.repo /etc/yum.repos.d/

# Or manually create:
sudo tee /etc/yum.repos.d/localrepo.repo << EOF
[localrepo-baseos]
name=Local Repository - BaseOS
baseurl=http://${REPO_SERVER}:${REPO_PORT}/approved/centos/9/baseos
enabled=1
gpgcheck=0
priority=1

[localrepo-appstream]
name=Local Repository - AppStream
baseurl=http://${REPO_SERVER}:${REPO_PORT}/approved/centos/9/appstream
enabled=1
gpgcheck=0
priority=1

[localrepo-extras]
name=Local Repository - Extras
baseurl=http://${REPO_SERVER}:${REPO_PORT}/approved/centos/9/extras
enabled=1
gpgcheck=0
priority=1
EOF
```

#### Step 4: Clear Cache and Update
```bash
# For DNF (Fedora/CentOS 8+/RHEL 8+)
sudo dnf clean all
sudo dnf makecache
sudo dnf repolist

# For YUM (CentOS 7/RHEL 7)
sudo yum clean all
sudo yum makecache
sudo yum repolist
```

#### Step 5: Verify Configuration
```bash
# Check repository list
sudo dnf repolist -v

# Test package search
sudo dnf search nginx

# Try installing a package
sudo dnf install htop
```

## Client-Side Scripts

### Automatic Client Configuration Script (Debian/Ubuntu)
```bash
#!/bin/bash
# save as: configure-mirroret-debian.sh

REPO_SERVER="192.168.1.100"  # CHANGE THIS
REPO_PORT="8080"

echo "Configuring local repository client..."

# Backup
sudo cp /etc/apt/sources.list /etc/apt/sources.list.backup.$(date +%Y%m%d)

# Disable official repos
sudo sed -i 's/^deb/# deb/g' /etc/apt/sources.list

# Add local repo
sudo tee /etc/apt/sources.list.d/localrepo.list << EOF
deb [trusted=yes] http://${REPO_SERVER}:${REPO_PORT}/approved/mirror jammy main restricted universe multiverse
deb [trusted=yes] http://${REPO_SERVER}:${REPO_PORT}/approved/mirror jammy-updates main restricted universe multiverse
deb [trusted=yes] http://${REPO_SERVER}:${REPO_PORT}/approved/mirror jammy-security main restricted universe multiverse
EOF

# Update
sudo apt clean
sudo apt update

echo "Configuration complete!"
```

### Automatic Client Configuration Script (RHEL/CentOS/Fedora)
```bash
#!/bin/bash
# save as: configure-mirroret-rhel.sh

REPO_SERVER="192.168.1.100"  # CHANGE THIS
REPO_PORT="8080"

echo "Configuring local repository client..."

# Backup
sudo mkdir -p /etc/yum.repos.d/backup
sudo cp /etc/yum.repos.d/*.repo /etc/yum.repos.d/backup/ 2>/dev/null || true

# Disable official repos
sudo mv /etc/yum.repos.d/*.repo /etc/yum.repos.d/backup/ 2>/dev/null || true

# Add local repo
sudo tee /etc/yum.repos.d/localrepo.repo << EOF
[localrepo-baseos]
name=Local Repository - BaseOS
baseurl=http://${REPO_SERVER}:${REPO_PORT}/approved/centos/9/baseos
enabled=1
gpgcheck=0

[localrepo-appstream]
name=Local Repository - AppStream
baseurl=http://${REPO_SERVER}:${REPO_PORT}/approved/centos/9/appstream
enabled=1
gpgcheck=0

[localrepo-extras]
name=Local Repository - Extras
baseurl=http://${REPO_SERVER}:${REPO_PORT}/approved/centos/9/extras
enabled=1
gpgcheck=0
EOF

# Update
if command -v dnf &> /dev/null; then
    sudo dnf clean all
    sudo dnf makecache
else
    sudo yum clean all
    sudo yum makecache
fi

echo "Configuration complete!"
```

## Network Security Recommendations

### Firewall Configuration on Server

#### Using UFW (Ubuntu/Debian)
```bash
# Allow SSH
sudo ufw allow 22/tcp

# Allow repo port from specific network
sudo ufw allow from 192.168.1.0/24 to any port 8080

# Enable firewall
sudo ufw enable
```

#### Using firewalld (RHEL/CentOS/Fedora)
```bash
# Allow repo port from specific network
sudo firewall-cmd --permanent --add-rich-rule='rule family="ipv4" source address="192.168.1.0/24" port port="8080" protocol="tcp" accept'

# Reload
sudo firewall-cmd --reload
```

### Optional: Enable HTTPS

#### Generate Self-Signed Certificate
```bash
sudo mkdir -p /etc/nginx/ssl
sudo openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
    -keyout /etc/nginx/ssl/localrepo.key \
    -out /etc/nginx/ssl/localrepo.crt
```

#### Update Nginx Configuration
```nginx
server {
    listen 8443 ssl;
    server_name _;
    
    ssl_certificate /etc/nginx/ssl/localrepo.crt;
    ssl_certificate_key /etc/nginx/ssl/localrepo.key;
    
    root /var/mirroret;
    autoindex on;
    
    # ... rest of configuration
}
```

## Monitoring & Maintenance

### Check Repository Server Status
```bash
# Nginx status
sudo systemctl status nginx

# Check disk usage
df -h /var/mirroret

# View recent sync logs
tail -f /var/mirroret/logs/sync-*.log

# Check web server access
curl http://localhost:8080/
```

### Client Health Check Script
```bash
#!/bin/bash
# Run on clients to verify repo connectivity

REPO_SERVER="192.168.1.100"
REPO_PORT="8080"

echo "Testing connection to repository server..."

# Test HTTP connectivity
if curl -s --connect-timeout 5 http://${REPO_SERVER}:${REPO_PORT}/ > /dev/null; then
    echo "✓ Repository server is reachable"
else
    echo "✗ Cannot reach repository server"
    exit 1
fi

# Test package manager
if [ -f /etc/debian_version ]; then
    sudo apt update 2>&1 | grep -q "mirroret" && echo "✓ APT configured correctly"
elif [ -f /etc/redhat-release ]; then
    sudo dnf repolist 2>&1 | grep -q "localrepo" && echo "✓ DNF configured correctly"
fi
```

## Troubleshooting

### Common Issues

#### Issue 1: Clients Cannot Connect
```bash
# On server, check nginx
sudo nginx -t
sudo systemctl status nginx

# Check firewall
sudo ufw status
# or
sudo firewall-cmd --list-all

# Test from client
telnet <SERVER_IP> 8080
curl http://<SERVER_IP>:8080/
```

#### Issue 2: No Packages Available
```bash
# On server, check if packages exist
ls -lah /var/mirroret/approved/

# Re-run approval script
/var/mirroret/scripts/approve-packages.sh --auto-approve

# Regenerate metadata (Debian)
cd /var/mirroret/approved/mirror
dpkg-scanpackages . /dev/null | gzip -9c > Packages.gz

# Regenerate metadata (RHEL)
createrepo --update /var/mirroret/approved/
```

#### Issue 3: GPG Key Errors (Debian/Ubuntu)
```bash
# On clients, use [trusted=yes] in sources.list
# Or import keys from server
wget http://<SERVER_IP>:8080/mirror/mirror/archive.ubuntu.com/ubuntu/project/ubuntu-archive-keyring.gpg
sudo apt-key add ubuntu-archive-keyring.gpg
```

## Mass Deployment

### Using Ansible (Example Playbook)
```yaml
---
- name: Configure Local Repository Clients
  hosts: all
  become: yes
  vars:
    repo_server: "192.168.1.100"
    repo_port: "8080"
  
  tasks:
    - name: Backup existing sources (Debian/Ubuntu)
      copy:
        src: /etc/apt/sources.list
        dest: /etc/apt/sources.list.backup
        remote_src: yes
      when: ansible_os_family == "Debian"
    
    - name: Configure local repository (Debian/Ubuntu)
      copy:
        content: |
          deb [trusted=yes] http://{{ repo_server }}:{{ repo_port }}/approved/mirror jammy main restricted universe multiverse
        dest: /etc/apt/sources.list.d/localrepo.list
      when: ansible_os_family == "Debian"
    
    - name: Update apt cache
      apt:
        update_cache: yes
      when: ansible_os_family == "Debian"
    
    - name: Configure local repository (RHEL/CentOS)
      copy:
        content: |
          [localrepo-baseos]
          name=Local Repository - BaseOS
          baseurl=http://{{ repo_server }}:{{ repo_port }}/approved/centos/9/baseos
          enabled=1
          gpgcheck=0
        dest: /etc/yum.repos.d/localrepo.repo
      when: ansible_os_family == "RedHat"
    
    - name: Update yum cache
      yum:
        update_cache: yes
      when: ansible_os_family == "RedHat"
```

## Performance Tuning

### Nginx Optimization
```nginx
# Add to nginx configuration
worker_processes auto;
worker_rlimit_nofile 65535;

events {
    worker_connections 4096;
    use epoll;
}

http {
    # Caching
    proxy_cache_path /var/cache/nginx levels=1:2 keys_zone=repo_cache:10m max_size=10g inactive=60m;
    
    # File descriptor cache
    open_file_cache max=1000 inactive=20s;
    open_file_cache_valid 30s;
    open_file_cache_min_uses 2;
    
    # Compression
    gzip on;
    gzip_vary on;
    gzip_types text/plain application/x-debian-package;
}
```

### Sync Performance
```bash
# Parallel downloads for apt-mirror
# Edit /etc/apt/mirror.list
set nthreads 20

# For reposync (RHEL)
reposync --download-metadata --newest-only --delete -p /var/mirroret/mirror
```

This comprehensive network architecture ensures reliable package management with full control!

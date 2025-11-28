# Directory Structure & Quick Start Guide

## Complete Directory Structure

```
/var/local-repo/                              # Main repository base
│
├── mirror/                                    # Downloaded packages from official repos
│   ├── mirror/                               # (Debian/Ubuntu) Mirror structure
│   │   └── archive.ubuntu.com/
│   │       └── ubuntu/
│   │           ├── dists/
│   │           │   ├── jammy/
│   │           │   ├── jammy-updates/
│   │           │   └── jammy-security/
│   │           └── pool/
│   │               ├── main/
│   │               ├── restricted/
│   │               ├── universe/
│   │               └── multiverse/
│   │
│   ├── centos/                               # (RHEL/CentOS) Mirror structure
│   │   └── 9/
│   │       ├── baseos/
│   │       ├── appstream/
│   │       └── extras/
│   │
│   ├── var/                                  # apt-mirror working directory
│   │   ├── clean.sh                          # Cleanup script
│   │   └── postmirror.sh                     # Post-sync hook
│   │
│   └── skel/                                 # Skeleton structure
│
├── approved/                                  # Approved packages for client use
│   ├── mirror/                               # (Debian/Ubuntu) Approved packages
│   │   ├── Packages                          # Package index (plain text)
│   │   ├── Packages.gz                       # Package index (compressed)
│   │   ├── Release                           # Release information
│   │   └── [.deb files]                      # Individual package files
│   │
│   ├── ubuntu/                               # Ubuntu-specific packages
│   ├── debian/                               # Debian-specific packages
│   ├── centos/                               # (RHEL/CentOS) Approved packages
│   │   └── 9/
│   │       ├── baseos/
│   │       │   └── repodata/                 # Repository metadata
│   │       ├── appstream/
│   │       └── extras/
│   │
│   └── rhel/                                 # RHEL-specific packages
│
├── staging/                                   # Temporary staging area for testing
│   ├── test-packages/                        # Packages under review
│   └── quarantine/                           # Suspicious packages
│
├── archive/                                   # Historical package versions
│   ├── 2024-01/                              # Monthly archives
│   ├── 2024-02/
│   └── rollback-20240115/                    # Rollback snapshots
│
├── logs/                                      # All system logs
│   ├── sync-20240115-020000.log              # Sync operation logs
│   ├── approval-20240115.log                 # Approval activity
│   ├── security-updates-20240115.log         # Security update tracking
│   ├── manual-review-queue.txt               # Queue for manual review
│   └── client-access.log                     # Client access logs (from nginx)
│
├── scripts/                                   # Management automation scripts
│   ├── sync-mirror.sh                        # Main sync script (auto via cron)
│   ├── approve-packages.sh                   # Package approval script
│   ├── check-updates.sh                      # Show available updates
│   ├── list-packages.sh                      # List all packages
│   ├── exclude-package.sh                    # Add to blacklist
│   ├── show-updates.sh                       # Compare mirror vs approved
│   ├── package-info.sh                       # Detailed package information
│   ├── detect-security-updates.sh            # Security update detection
│   ├── check-cve.sh                          # CVE vulnerability check
│   ├── test-package-docker.sh                # Isolated testing with Docker
│   ├── auto-approve-rules.sh                 # Rule-based auto-approval
│   ├── rollback-package.sh                   # Version rollback
│   └── manage-blacklist.sh                   # Blacklist management
│
└── config/                                    # Configuration files
    ├── localrepo.list                        # Debian/Ubuntu client config
    ├── localrepo.repo                        # RHEL/CentOS/Fedora client config
    ├── approved-packages.txt                 # Whitelist
    ├── blacklist-packages.txt                # Blacklist
    ├── excluded-packages.txt                 # Exclusion list
    └── approval-rules.conf                   # Auto-approval rules

```

## System Files Modified/Created

### Nginx Configuration
```
/etc/nginx/sites-available/local-repo         # (Debian/Ubuntu)
/etc/nginx/sites-enabled/local-repo           # Symlink
/etc/nginx/conf.d/local-repo.conf             # (RHEL/CentOS)
```

### Repository Configuration
```
/etc/apt/mirror.list                          # apt-mirror config (Debian/Ubuntu)
```

### Cron Jobs
```
/var/spool/cron/root                          # Root user crontab
# Contains: 0 2 * * * /var/local-repo/scripts/sync-mirror.sh
```

### Logs
```
/var/log/nginx/local-repo-access.log          # Nginx access log
/var/log/nginx/local-repo-error.log           # Nginx error log
/var/log/local-repo-setup.log                 # Installation log
```

## Disk Space Requirements

### Initial Setup (Minimal)
- Base system: ~500 MB
- Scripts and configs: ~10 MB
- **Total**: ~510 MB

### After First Sync

#### Debian/Ubuntu (Full Mirror)
- Ubuntu 22.04 LTS (jammy) - Main only: ~80 GB
- Ubuntu 22.04 LTS (jammy) - All components: ~220 GB
- Ubuntu 22.04 LTS + Updates + Security: ~280 GB

#### RHEL/CentOS (Full Mirror)
- CentOS 9 - BaseOS: ~15 GB
- CentOS 9 - AppStream: ~25 GB
- CentOS 9 - All repos: ~50 GB

### Recommended Disk Space
- **Production (Debian/Ubuntu)**: 500 GB - 1 TB
- **Production (RHEL/CentOS)**: 200 GB - 500 GB
- **Testing environment**: 100 GB - 200 GB

### Space Monitoring
```bash
# Check current usage
df -h /var/local-repo

# Check breakdown by directory
du -sh /var/local-repo/*

# Monitor growth over time
du -sh /var/local-repo >> /var/local-repo/logs/disk-usage.log
```

## Quick Start Guide

### Step 1: Run Installation Script
```bash
# Download or copy the installation script
chmod +x local-repo-server-install.sh

# Run as root
sudo ./local-repo-server-install.sh

# Installation will take 5-10 minutes
```

### Step 2: Verify Installation
```bash
# Check nginx is running
sudo systemctl status nginx

# Check cron job
crontab -l | grep sync-mirror

# Test web server
curl http://localhost:8080/

# View directory structure
tree -L 2 /var/local-repo
```

### Step 3: Perform Initial Sync
```bash
# Manual first sync (takes 2-8 hours depending on connection)
sudo /var/local-repo/scripts/sync-mirror.sh

# Monitor progress
tail -f /var/local-repo/logs/sync-*.log

# Check disk usage during sync
watch -n 60 'df -h /var/local-repo'
```

### Step 4: Approve Packages
```bash
# Check what's available
sudo /var/local-repo/scripts/check-updates.sh

# Auto-approve all (for initial setup)
sudo /var/local-repo/scripts/approve-packages.sh --auto-approve

# Or selective approval
sudo /var/local-repo/scripts/show-updates.sh
# Review and manually approve specific packages
```

### Step 5: Configure First Client

#### For Debian/Ubuntu Client:
```bash
# On the client machine
REPO_SERVER="192.168.1.100"  # Replace with your server IP

# Backup original sources
sudo cp /etc/apt/sources.list /etc/apt/sources.list.backup

# Add local repository
sudo tee /etc/apt/sources.list.d/localrepo.list << EOF
deb [trusted=yes] http://${REPO_SERVER}:8080/approved/mirror jammy main restricted universe multiverse
deb [trusted=yes] http://${REPO_SERVER}:8080/approved/mirror jammy-updates main restricted universe multiverse
deb [trusted=yes] http://${REPO_SERVER}:8080/approved/mirror jammy-security main restricted universe multiverse
EOF

# Disable official repositories (optional)
sudo sed -i 's/^deb/# deb/g' /etc/apt/sources.list

# Update
sudo apt update

# Test installation
sudo apt install htop
```

#### For RHEL/CentOS Client:
```bash
# On the client machine
REPO_SERVER="192.168.1.100"  # Replace with your server IP

# Backup original repos
sudo mkdir -p /etc/yum.repos.d/backup
sudo mv /etc/yum.repos.d/*.repo /etc/yum.repos.d/backup/

# Add local repository
sudo tee /etc/yum.repos.d/localrepo.repo << EOF
[localrepo-baseos]
name=Local Repository - BaseOS
baseurl=http://${REPO_SERVER}:8080/approved/centos/9/baseos
enabled=1
gpgcheck=0

[localrepo-appstream]
name=Local Repository - AppStream
baseurl=http://${REPO_SERVER}:8080/approved/centos/9/appstream
enabled=1
gpgcheck=0
EOF

# Update
sudo dnf clean all
sudo dnf makecache

# Test installation
sudo dnf install htop
```

## Daily Operations

### Morning Routine (5 minutes)
```bash
# 1. Check sync logs from last night
tail -50 /var/local-repo/logs/sync-$(date +%Y%m%d)*.log

# 2. Check for security updates
/var/local-repo/scripts/detect-security-updates.sh

# 3. Review manual approval queue
cat /var/local-repo/logs/manual-review-queue.txt

# 4. Check disk space
df -h /var/local-repo
```

### Weekly Maintenance (30 minutes)
```bash
# 1. Review and approve pending packages
/var/local-repo/scripts/show-updates.sh
/var/local-repo/scripts/approve-packages.sh

# 2. Clean old logs (keep last 30 days)
find /var/local-repo/logs -name "*.log" -mtime +30 -delete

# 3. Archive old package versions
/var/local-repo/scripts/archive-old-versions.sh  # Create this script

# 4. Review blacklist effectiveness
/var/local-repo/scripts/manage-blacklist.sh

# 5. Test client connectivity
# Pick 2-3 random clients and verify they can update
```

### Monthly Tasks (1-2 hours)
```bash
# 1. Full system audit
/var/local-repo/scripts/audit-repository.sh  # Create comprehensive audit script

# 2. Review and update approval rules
vim /var/local-repo/config/approval-rules.conf

# 3. Test disaster recovery
# Simulate package rollback
/var/local-repo/scripts/rollback-package.sh nginx <previous-version>

# 4. Update documentation
vim /var/local-repo/README.md

# 5. Review client logs
# Check nginx access logs for unusual patterns
tail -1000 /var/log/nginx/local-repo-access.log | sort | uniq -c

# 6. Backup configuration
tar -czf /backup/local-repo-config-$(date +%Y%m%d).tar.gz \
    /var/local-repo/config \
    /var/local-repo/scripts \
    /etc/nginx/sites-available/local-repo \
    /etc/apt/mirror.list
```

## Performance Optimization Tips

### 1. Mirror Sync Optimization
```bash
# Edit /etc/apt/mirror.list
set nthreads 20  # Increase parallel downloads (default: 20)

# For faster syncing, use closest mirror
# Example: Use local country mirror instead of main
deb http://us.archive.ubuntu.com/ubuntu jammy main
# Instead of:
deb http://archive.ubuntu.com/ubuntu jammy main
```

### 2. Nginx Performance Tuning
```nginx
# Edit /etc/nginx/nginx.conf or site config
worker_processes auto;
worker_rlimit_nofile 65535;

events {
    worker_connections 4096;
    use epoll;
    multi_accept on;
}

http {
    # Caching
    open_file_cache max=10000 inactive=30s;
    open_file_cache_valid 60s;
    open_file_cache_min_uses 2;
    open_file_cache_errors on;
    
    # Keep-alive
    keepalive_timeout 65;
    keepalive_requests 100;
    
    # Compression
    gzip on;
    gzip_vary on;
    gzip_comp_level 6;
    gzip_types application/x-debian-package;
}
```

### 3. Filesystem Optimization
```bash
# Use XFS or ext4 with large_file option
mkfs.ext4 -T largefile /dev/sdb1

# Mount with optimal options
/dev/sdb1 /var/local-repo ext4 noatime,nodiratime,data=writeback 0 2

# Or XFS (recommended for large repos)
mkfs.xfs /dev/sdb1
/dev/sdb1 /var/local-repo xfs noatime,nodiratime 0 2
```

### 4. Network Optimization (Server)
```bash
# Edit /etc/sysctl.conf
net.core.rmem_max = 134217728
net.core.wmem_max = 134217728
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864
net.ipv4.tcp_congestion_control = bbr

# Apply
sysctl -p
```

## Troubleshooting Guide

### Issue 1: Sync Taking Too Long
```bash
# Check mirror speed
time wget http://archive.ubuntu.com/ubuntu/README -O /dev/null

# Switch to faster mirror
# Edit /etc/apt/mirror.list and change mirror URL

# Reduce scope (sync only main, not universe/multiverse)
```

### Issue 2: Disk Space Full
```bash
# Find largest directories
du -sh /var/local-repo/* | sort -h

# Clean old packages
/var/local-repo/mirror/var/clean.sh  # For apt-mirror

# Remove old logs
find /var/local-repo/logs -mtime +30 -delete

# Archive to external storage
rsync -av /var/local-repo/archive/ /mnt/backup/
rm -rf /var/local-repo/archive/*
```

### Issue 3: Clients Can't Connect
```bash
# On server
sudo systemctl status nginx
sudo nginx -t
sudo netstat -tlnp | grep 8080

# Check firewall
sudo ufw status
sudo iptables -L -n | grep 8080

# On client
telnet <SERVER_IP> 8080
curl -v http://<SERVER_IP>:8080/
```

### Issue 4: Packages Not Updating
```bash
# Regenerate repository metadata

# Debian/Ubuntu
cd /var/local-repo/approved/mirror
dpkg-scanpackages . /dev/null | gzip -9c > Packages.gz
dpkg-scanpackages . /dev/null > Packages

# RHEL/CentOS
createrepo --update /var/local-repo/approved/centos/9/baseos
createrepo --update /var/local-repo/approved/centos/9/appstream

# Restart nginx
sudo systemctl restart nginx
```

## Security Hardening

### 1. Enable HTTPS
```bash
# Generate SSL certificate
sudo openssl req -x509 -nodes -days 365 -newkey rsa:4096 \
    -keyout /etc/nginx/ssl/localrepo.key \
    -out /etc/nginx/ssl/localrepo.crt

# Update nginx config to use port 443
```

### 2. Add Authentication
```nginx
# In nginx config
location / {
    auth_basic "Restricted Repository";
    auth_basic_user_file /etc/nginx/.htpasswd;
}

# Create password file
sudo htpasswd -c /etc/nginx/.htpasswd repouser
```

### 3. IP Whitelisting
```nginx
# In nginx config
location / {
    allow 192.168.1.0/24;
    deny all;
}
```

### 4. Regular Security Audits
```bash
# Check for suspicious activity
tail -1000 /var/log/nginx/local-repo-access.log | \
    awk '{print $1}' | sort | uniq -c | sort -rn | head -20

# Monitor failed requests
grep " 404 " /var/log/nginx/local-repo-access.log | tail -50

# Check for vulnerability in approved packages
/var/local-repo/scripts/detect-security-updates.sh
```

This comprehensive guide covers everything from installation to daily operations!

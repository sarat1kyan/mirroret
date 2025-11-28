# Local Repository Server - Complete Solution

## 🎯 Project Overview

This is a **production-ready local repository server** that gives you **100% manual control** over package management across your entire Linux infrastructure. It supports both Debian-based (Ubuntu, Debian) and RHEL-based (CentOS, Fedora, RHEL) systems.

### Key Features
✅ **Full Manual Control** - Approve every package before deployment  
✅ **Multi-Distribution Support** - Debian, Ubuntu, CentOS, Fedora, RHEL  
✅ **Security-First** - Review security updates, track CVEs  
✅ **Automated Syncing** - Daily automatic sync from official repos  
✅ **Web-Based Access** - Nginx serving packages on port 8080  
✅ **Package Approval Workflow** - Mirror → Review → Approve → Deploy  
✅ **Blacklist/Whitelist** - Control exactly what can be installed  
✅ **Rollback Support** - Revert to previous package versions  
✅ **Testing Environment** - Isolated testing before approval  

## 📋 Files Included

| File | Purpose |
|------|---------|
| `local-repo-server-install.sh` | Main installation script (run this first) |
| `NETWORK-ARCHITECTURE.md` | Network topology, ports, client configs |
| `PACKAGE-CONTROL.md` | Advanced approval workflows, security |
| `DIRECTORY-STRUCTURE.md` | Complete directory layout, quick start guide |
| `README.md` | This file - overview and getting started |

## 🚀 Quick Start (5 Steps)

### Step 1: Install Repository Server
```bash
# Download the script
wget https://your-server.com/local-repo-server-install.sh
chmod +x local-repo-server-install.sh

# Run as root
sudo ./local-repo-server-install.sh

# Wait 5-10 minutes for installation
```

### Step 2: Initial Package Sync
```bash
# Start first sync (takes 2-8 hours)
sudo /var/local-repo/scripts/sync-mirror.sh

# Monitor progress
tail -f /var/local-repo/logs/sync-*.log
```

### Step 3: Approve Packages
```bash
# Auto-approve all packages (initial setup)
sudo /var/local-repo/scripts/approve-packages.sh --auto-approve

# Or review first
sudo /var/local-repo/scripts/show-updates.sh
```

### Step 4: Configure Clients

**Ubuntu/Debian Clients:**
```bash
REPO_SERVER="192.168.1.100"  # Your server IP
wget http://${REPO_SERVER}:8080/config/localrepo.list
sudo mv localrepo.list /etc/apt/sources.list.d/
sudo apt update
```

**RHEL/CentOS Clients:**
```bash
REPO_SERVER="192.168.1.100"  # Your server IP
wget http://${REPO_SERVER}:8080/config/localrepo.repo
sudo mv localrepo.repo /etc/yum.repos.d/
sudo dnf clean all && sudo dnf makecache
```

### Step 5: Test Installation
```bash
# On client machine
sudo apt install htop    # Debian/Ubuntu
# or
sudo dnf install htop    # RHEL/CentOS
```

## 📊 System Architecture

```
                    LOCAL REPOSITORY SERVER
                    
┌─────────────────────────────────────────────────────────┐
│  Nginx Web Server (Port 8080)                           │
│  ├─ /mirror/     - Downloaded from official repos       │
│  └─ /approved/   - Approved packages for clients        │
└─────────────────────────────────────────────────────────┘
                          │
                    HTTP (Port 8080)
                          │
        ┌─────────────────┼─────────────────┐
        │                 │                 │
        ▼                 ▼                 ▼
    ┌────────┐        ┌────────┐      ┌────────┐
    │ Client │        │ Client │      │ Client │
    │ Ubuntu │        │ CentOS │      │ Debian │
    └────────┘        └────────┘      └────────┘
```

## 🔧 Management Commands

### Daily Operations
```bash
# Check for new updates
/var/local-repo/scripts/check-updates.sh

# Approve packages
/var/local-repo/scripts/approve-packages.sh

# List available packages
/var/local-repo/scripts/list-packages.sh

# Sync manually (instead of waiting for cron)
/var/local-repo/scripts/sync-mirror.sh
```

### Package Control
```bash
# View package details
/var/local-repo/scripts/package-info.sh nginx

# Exclude unwanted package
/var/local-repo/scripts/exclude-package.sh telnet

# Check security updates
/var/local-repo/scripts/detect-security-updates.sh

# Rollback to previous version
/var/local-repo/scripts/rollback-package.sh nginx 1.18.0
```

### System Monitoring
```bash
# Check nginx status
sudo systemctl status nginx

# View sync logs
tail -f /var/local-repo/logs/sync-*.log

# Check disk usage
df -h /var/local-repo

# Monitor client access
tail -f /var/log/nginx/local-repo-access.log
```

## 📁 Directory Structure

```
/var/local-repo/
├── mirror/          # Downloaded packages (not for clients)
├── approved/        # Approved packages (served to clients)
├── staging/         # Testing area
├── archive/         # Historical versions
├── logs/           # All system logs
├── scripts/        # Management scripts
└── config/         # Configuration files
```

## 🔐 Security Features

### 1. Package Approval Workflow
```
Official Repos → Mirror → Manual Review → Approved → Clients
```
Nothing reaches clients without your approval.

### 2. Security Update Detection
```bash
# Automatically detect security updates
/var/local-repo/scripts/detect-security-updates.sh

# Check for CVEs
/var/local-repo/scripts/check-cve.sh package-name
```

### 3. Blacklist/Whitelist System
```bash
# Whitelist: Only these packages allowed
echo "nginx curl wget git" > /var/local-repo/config/approved-packages.txt

# Blacklist: Never allow these
echo "telnet rsh-server" > /var/local-repo/config/blacklist-packages.txt
```

### 4. Testing Before Deployment
```bash
# Test package in isolated Docker container
/var/local-repo/scripts/test-package-docker.sh package-name
```

## 🌐 Network Configuration

### Ports Used
| Port | Service | Purpose |
|------|---------|---------|
| 8080 | Nginx HTTP | Repository access (clients download packages) |
| 22 | SSH | Server management |

### Firewall Rules
```bash
# Ubuntu/Debian (UFW)
sudo ufw allow from 192.168.1.0/24 to any port 8080

# RHEL/CentOS (firewalld)
sudo firewall-cmd --permanent --add-rich-rule='rule family="ipv4" source address="192.168.1.0/24" port port="8080" protocol="tcp" accept'
sudo firewall-cmd --reload
```

## 💾 Disk Space Requirements

### Debian/Ubuntu
- **Minimal** (main only): 80 GB
- **Standard** (main + updates + security): 280 GB
- **Full** (all components): 500 GB

### RHEL/CentOS
- **Minimal** (baseos only): 15 GB
- **Standard** (baseos + appstream): 50 GB
- **Full** (all repos): 100 GB

### Recommended
- **Production**: 500 GB - 1 TB
- **Testing**: 100 GB - 200 GB

## 🔄 Automatic Sync Schedule

By default, the system syncs daily at 2:00 AM:

```bash
# View cron schedule
crontab -l | grep sync-mirror

# Modify sync time (edit crontab)
crontab -e
# Change: 0 2 * * * to your preferred time
```

## 📖 Documentation Files

### Detailed Guides
1. **NETWORK-ARCHITECTURE.md** - Complete network setup, client configuration, security hardening
2. **PACKAGE-CONTROL.md** - Advanced approval workflows, security features, rollback procedures  
3. **DIRECTORY-STRUCTURE.md** - Full directory layout, quick start, troubleshooting

### Generated on Server
- `/var/local-repo/README.md` - Server-specific documentation with actual IPs and paths

## 🛠️ Typical Workflows

### Workflow 1: Daily Package Approval
```bash
# Morning routine (5 minutes)
1. Check logs: tail -50 /var/local-repo/logs/sync-*.log
2. Security check: /var/local-repo/scripts/detect-security-updates.sh
3. Approve updates: /var/local-repo/scripts/approve-packages.sh
```

### Workflow 2: New Client Setup
```bash
# On new client (2 minutes)
1. Download config: wget http://REPO_IP:8080/config/localrepo.list
2. Install config: sudo mv localrepo.list /etc/apt/sources.list.d/
3. Update cache: sudo apt update
4. Test install: sudo apt install htop
```

### Workflow 3: Emergency Rollback
```bash
# If bad package deployed (5 minutes)
1. Identify issue: Check client reports
2. Find old version: ls /var/local-repo/archive/
3. Rollback: /var/local-repo/scripts/rollback-package.sh nginx 1.18.0
4. Notify clients: "Update available - run apt/dnf update"
```

### Workflow 4: Security Update Deployment
```bash
# Critical security update (10 minutes)
1. Detect: /var/local-repo/scripts/detect-security-updates.sh
2. Review: /var/local-repo/scripts/package-info.sh package-name
3. Fast-track approve: cp mirror/package.deb approved/
4. Update metadata: dpkg-scanpackages approved/ | gzip > Packages.gz
5. Notify clients: Email blast "Critical update available"
```

## 🎓 Advanced Features

### Rule-Based Auto-Approval
```bash
# Configure approval rules
vim /var/local-repo/config/approval-rules.conf

# Example rules:
SECURITY:*:security      # Auto-approve security updates
MANUAL:kernel:*          # Always require manual review for kernel
DENY:telnet:*            # Never approve telnet
```

### Version Pinning
```bash
# Pin specific versions for clients
# Client-side: /etc/apt/preferences.d/pins
Package: nginx
Pin: version 1.18.0-*
Pin-Priority: 1001
```

### Custom Mirrors
```bash
# Use faster/closer mirrors
# Edit /etc/apt/mirror.list
deb http://us.archive.ubuntu.com/ubuntu jammy main
```

## 📊 Monitoring & Alerts

### Email Notifications
```bash
# Configure for sync completion
# Add to /var/local-repo/scripts/sync-mirror.sh:
echo "Sync completed" | mail -s "Repo Sync Complete" admin@example.com

# For security updates
# Add to cron:
0 8 * * * /var/local-repo/scripts/detect-security-updates.sh | mail -s "Security Updates" admin@example.com
```

### Disk Space Alerts
```bash
# Add to cron (daily check)
0 6 * * * [ $(df /var/local-repo | awk 'NR==2 {print $5}' | sed 's/%//') -gt 80 ] && echo "Disk usage over 80%" | mail -s "Disk Alert" admin@example.com
```

## 🚨 Troubleshooting

### Problem: Sync Fails
```bash
# Check logs
tail -100 /var/local-repo/logs/sync-*.log

# Test mirror connectivity
wget -O /dev/null http://archive.ubuntu.com/ubuntu/README

# Switch to different mirror
vim /etc/apt/mirror.list
```

### Problem: Clients Can't Connect
```bash
# On server
sudo systemctl status nginx
sudo netstat -tlnp | grep 8080
sudo ufw status

# On client
telnet REPO_IP 8080
curl -v http://REPO_IP:8080/
```

### Problem: Out of Disk Space
```bash
# Clean old logs
find /var/local-repo/logs -mtime +30 -delete

# Run cleanup script
/var/local-repo/mirror/var/clean.sh

# Archive old packages
mv /var/local-repo/archive/* /external/backup/
```

## 📞 Support & Resources

### Log Locations
- Installation: `/var/log/local-repo-setup.log`
- Sync operations: `/var/local-repo/logs/sync-*.log`
- Nginx access: `/var/log/nginx/local-repo-access.log`
- Nginx errors: `/var/log/nginx/local-repo-error.log`

### Configuration Files
- Nginx: `/etc/nginx/sites-available/local-repo`
- apt-mirror: `/etc/apt/mirror.list`
- Cron: `crontab -l`

### Web Interface
Access repository browser: `http://YOUR_SERVER_IP:8080/`

## 📝 Best Practices

1. **Daily**: Check security updates and approve critical patches
2. **Weekly**: Review approval queue, clean old logs
3. **Monthly**: Full audit, test rollback procedures, backup configs
4. **Quarterly**: Review and update approval rules, test disaster recovery

## ⚡ Performance Tips

1. **Use local mirrors** for faster sync
2. **Increase nginx workers** for more clients
3. **Use XFS filesystem** for better large-file performance
4. **Schedule sync during off-hours** (2 AM default)
5. **Monitor bandwidth** to avoid network saturation

## 🔧 Customization

All scripts are fully customizable:
- Located in `/var/local-repo/scripts/`
- Well-commented Python/Bash code
- Modify sync schedules, approval rules, exclusions
- Add custom notifications, integrations

## 🎯 Project Goals Achieved

✅ **Full manual control** over package deployment  
✅ **Multi-distribution** support (Debian, Ubuntu, RHEL, CentOS, Fedora)  
✅ **Automatic syncing** with manual approval workflow  
✅ **Security-first** approach with CVE tracking  
✅ **Easy client setup** with pre-configured files  
✅ **Complete documentation** for all scenarios  
✅ **Production-ready** with monitoring and alerts  

## 📜 License & Credits

This is a professional DevOps solution for enterprise package management.

**Author**: Professional Linux DevOps & System Architect  
**Version**: 1.0.0  
**Last Updated**: 2024

## 🚀 Next Steps

1. Run the installation script
2. Perform initial sync
3. Configure your first client
4. Set up monitoring and alerts
5. Document your organization's approval procedures
6. Train team on daily operations

**Need help?** Check the detailed guides:
- Network setup → `NETWORK-ARCHITECTURE.md`
- Package control → `PACKAGE-CONTROL.md`  
- Directory layout → `DIRECTORY-STRUCTURE.md`

---

**Ready to take control of your infrastructure? Start with:**
```bash
sudo ./local-repo-server-install.sh
```

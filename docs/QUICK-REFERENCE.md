# Quick Reference Card - Local Repository Server

## 🚀 Installation (One Command)
```bash
sudo ./mirroret-server-install.sh
```

## 📍 Important Locations

| Location | Purpose |
|----------|---------|
| `/var/mirroret/` | Base directory |
| `/var/mirroret/mirror/` | Downloaded packages (not for clients) |
| `/var/mirroret/approved/` | Approved packages (served to clients) |
| `/var/mirroret/scripts/` | All management scripts |
| `/var/mirroret/config/` | Client configuration files |
| `/var/mirroret/logs/` | All system logs |

## 🔧 Essential Commands

### Server Management
```bash
# Check nginx status
sudo systemctl status nginx

# Restart nginx
sudo systemctl restart nginx

# View active connections
sudo netstat -tlnp | grep 8080

# Check disk usage
df -h /var/mirroret
```

### Package Operations
```bash
# Manual sync packages
/var/mirroret/scripts/sync-mirror.sh

# Check available updates
/var/mirroret/scripts/check-updates.sh

# Show update comparison
/var/mirroret/scripts/show-updates.sh

# Auto-approve all packages
/var/mirroret/scripts/approve-packages.sh --auto-approve

# Manual approval (review first)
/var/mirroret/scripts/approve-packages.sh

# List all packages
/var/mirroret/scripts/list-packages.sh

# Get package details
/var/mirroret/scripts/package-info.sh <package-name>
```

### Security Operations
```bash
# Detect security updates
/var/mirroret/scripts/detect-security-updates.sh

# Check CVEs for package
/var/mirroret/scripts/check-cve.sh <package-name>

# Exclude unwanted package
/var/mirroret/scripts/exclude-package.sh <package-name>
```

### Maintenance
```bash
# View sync logs
tail -f /var/mirroret/logs/sync-*.log

# View nginx access logs
tail -f /var/log/nginx/mirroret-access.log

# Clean old logs (older than 30 days)
find /var/mirroret/logs -mtime +30 -delete

# Check cron schedule
crontab -l | grep sync-mirror
```

## 🖥️ Client Setup Commands

### Ubuntu/Debian Clients
```bash
# Quick setup (replace IP)
REPO_IP="192.168.1.100"
wget http://${REPO_IP}:8080/config/localrepo.list
sudo mv localrepo.list /etc/apt/sources.list.d/
sudo apt update

# Disable official repos (optional)
sudo sed -i 's/^deb/# deb/g' /etc/apt/sources.list

# Test installation
sudo apt install htop
```

### RHEL/CentOS/Fedora Clients
```bash
# Quick setup (replace IP)
REPO_IP="192.168.1.100"
wget http://${REPO_IP}:8080/config/localrepo.repo
sudo mv localrepo.repo /etc/yum.repos.d/
sudo dnf clean all && sudo dnf makecache

# Disable official repos (optional)
sudo mkdir /etc/yum.repos.d/backup
sudo mv /etc/yum.repos.d/*.repo /etc/yum.repos.d/backup/

# Test installation
sudo dnf install htop
```

## 🌐 Network Information

### Ports
- **8080** - HTTP (Repository Access)
- **22** - SSH (Management)

### URLs
- Repository Browser: `http://SERVER_IP:8080/`
- Mirror Packages: `http://SERVER_IP:8080/mirror/`
- Approved Packages: `http://SERVER_IP:8080/approved/`
- Client Configs: `http://SERVER_IP:8080/config/`

### Firewall Commands
```bash
# Ubuntu/Debian (UFW)
sudo ufw allow from 192.168.1.0/24 to any port 8080

# RHEL/CentOS (firewalld)
sudo firewall-cmd --permanent --add-rich-rule='rule family="ipv4" source address="192.168.1.0/24" port port="8080" protocol="tcp" accept'
sudo firewall-cmd --reload
```

## 📊 Workflow Cheat Sheet

### Daily Routine (5 min)
```bash
# 1. Check last night's sync
tail -50 /var/mirroret/logs/sync-$(date +%Y%m%d)*.log

# 2. Security check
/var/mirroret/scripts/detect-security-updates.sh

# 3. Approve if safe
/var/mirroret/scripts/approve-packages.sh
```

### Emergency Rollback
```bash
# Find package in archive
ls /var/mirroret/archive/

# Rollback to specific version
/var/mirroret/scripts/rollback-package.sh <package> <version>

# Example:
/var/mirroret/scripts/rollback-package.sh nginx 1.18.0
```

### Add New Client
```bash
# Copy config to client
scp /var/mirroret/config/localrepo.list user@client:/tmp/

# Or download directly on client
wget http://SERVER_IP:8080/config/localrepo.list
```

## 🔍 Troubleshooting Quick Fixes

### Nginx Not Working
```bash
sudo nginx -t                    # Test config
sudo systemctl restart nginx     # Restart
sudo systemctl status nginx      # Check status
sudo journalctl -u nginx -f      # View logs
```

### Sync Failed
```bash
# Check logs
tail -100 /var/mirroret/logs/sync-*.log

# Test connectivity
wget -O /dev/null http://archive.ubuntu.com/ubuntu/README

# Run manual sync
/var/mirroret/scripts/sync-mirror.sh
```

### Clients Can't Connect
```bash
# On server - check nginx
sudo netstat -tlnp | grep 8080

# On server - check firewall
sudo ufw status

# On client - test connection
telnet SERVER_IP 8080
curl -v http://SERVER_IP:8080/
```

### Out of Space
```bash
# Check usage
du -sh /var/mirroret/*

# Clean old logs
find /var/mirroret/logs -mtime +30 -delete

# Run cleanup (Debian/Ubuntu)
/var/mirroret/mirror/var/clean.sh

# Archive old packages
mv /var/mirroret/archive/* /backup/
```

### Packages Not Updating
```bash
# Debian/Ubuntu - regenerate metadata
cd /var/mirroret/approved/mirror
dpkg-scanpackages . /dev/null | gzip -9c > Packages.gz

# RHEL/CentOS - regenerate metadata
createrepo --update /var/mirroret/approved/centos/9/baseos

# Restart nginx
sudo systemctl restart nginx
```

## 📝 Configuration File Locations

| File | Purpose |
|------|---------|
| `/etc/nginx/sites-available/mirroret` | Nginx config (Debian/Ubuntu) |
| `/etc/nginx/conf.d/mirroret.conf` | Nginx config (RHEL/CentOS) |
| `/etc/apt/mirror.list` | apt-mirror config (Debian/Ubuntu) |
| `/var/mirroret/config/blacklist-packages.txt` | Package blacklist |
| `/var/mirroret/config/approved-packages.txt` | Package whitelist |
| `/var/mirroret/config/approval-rules.conf` | Auto-approval rules |

## ⚡ Performance Tuning

### Increase Sync Speed
```bash
# Edit /etc/apt/mirror.list
set nthreads 20  # More parallel downloads
```

### Optimize Nginx
```bash
# Edit /etc/nginx/nginx.conf
worker_processes auto;
worker_connections 4096;
```

### Use Local Mirror
```bash
# Edit /etc/apt/mirror.list
# Replace: http://archive.ubuntu.com
# With: http://us.archive.ubuntu.com (or closest)
```

## 🔐 Security Quick Tips

### Enable HTTPS
```bash
# Generate certificate
sudo openssl req -x509 -nodes -days 365 -newkey rsa:4096 \
    -keyout /etc/nginx/ssl/repo.key \
    -out /etc/nginx/ssl/repo.crt

# Update nginx config to use SSL
# Change listen 8080 to listen 8443 ssl
```

### Add Authentication
```bash
# Create password file
sudo htpasswd -c /etc/nginx/.htpasswd repouser

# Add to nginx config
auth_basic "Restricted";
auth_basic_user_file /etc/nginx/.htpasswd;
```

### IP Whitelist
```bash
# Edit nginx config, add:
allow 192.168.1.0/24;
deny all;
```

## 📅 Scheduled Tasks

### Current Cron Jobs
```bash
# View cron schedule
crontab -l

# Default schedule:
# 0 2 * * * /var/mirroret/scripts/sync-mirror.sh
# (Daily at 2:00 AM)
```

### Modify Sync Time
```bash
crontab -e
# Change hour: 0 2 * * * (2 AM) to 0 4 * * * (4 AM)
```

## 📞 Emergency Contacts & Info

| Item | Value |
|------|-------|
| Installation Log | `/var/log/mirroret-setup.log` |
| Sync Logs | `/var/mirroret/logs/sync-*.log` |
| Nginx Access | `/var/log/nginx/mirroret-access.log` |
| Nginx Errors | `/var/log/nginx/mirroret-error.log` |
| Documentation | `/var/mirroret/README.md` |

## 🎯 One-Liners for Common Tasks

```bash
# Quick status check
echo "Nginx: $(systemctl is-active nginx) | Disk: $(df -h /var/mirroret | awk 'NR==2 {print $5}') | Last sync: $(ls -lt /var/mirroret/logs/sync-*.log | head -1 | awk '{print $6,$7,$8}')"

# Count packages
echo "Mirror: $(find /var/mirroret/mirror -name '*.deb' -o -name '*.rpm' 2>/dev/null | wc -l) | Approved: $(find /var/mirroret/approved -name '*.deb' -o -name '*.rpm' 2>/dev/null | wc -l)"

# Recent client IPs
tail -1000 /var/log/nginx/mirroret-access.log | awk '{print $1}' | sort -u

# Top accessed packages
tail -1000 /var/log/nginx/mirroret-access.log | grep -oP '/[^/]+\.(deb|rpm)' | sort | uniq -c | sort -rn | head -10
```

## 🆘 Getting Help

1. Check logs first: `tail -f /var/mirroret/logs/*.log`
2. Review documentation: `cat /var/mirroret/README.md`
3. Test connectivity: `curl http://localhost:8080/`
4. Check processes: `ps aux | grep nginx`

---

**Print this card and keep it handy for quick reference!**

**Server IP**: _______________  
**Port**: 8080  
**First Install Date**: _______________  
**Admin Contact**: _______________

# Unified Repository Server - Comprehensive Troubleshooting Guide

## 🔍 General Diagnostics

### Quick Health Check Script
```bash
#!/bin/bash
# repo-health-check.sh

echo "═══════════════════════════════════════════════════════"
echo "  UNIFIED REPOSITORY SERVER - HEALTH CHECK"
echo "═══════════════════════════════════════════════════════"
echo ""

# Check services
echo "[1] Service Status:"
for service in nginx pypiserver verdaccio docker; do
    if systemctl is-active --quiet $service 2>/dev/null; then
        echo "  ✓ $service: RUNNING"
    else
        echo "  ✗ $service: NOT RUNNING"
    fi
done

# Check Docker registry container
if docker ps | grep -q local-docker-registry; then
    echo "  ✓ Docker Registry: RUNNING"
else
    echo "  ✗ Docker Registry: NOT RUNNING"
fi

echo ""
echo "[2] Port Availability:"
for port in 8080 8081 5000 4873; do
    if netstat -tuln | grep -q ":$port "; then
        echo "  ✓ Port $port: LISTENING"
    else
        echo "  ✗ Port $port: NOT LISTENING"
    fi
done

echo ""
echo "[3] Disk Space:"
df -h /srv/localrepo | tail -1

echo ""
echo "[4] Recent Errors:"
grep -i error /srv/localrepo/logs/*.log 2>/dev/null | tail -5

echo ""
echo "═══════════════════════════════════════════════════════"
```

---

## 🚨 Common Issues & Solutions

### Issue 1: Nginx Won't Start

**Symptoms:**
```bash
$ systemctl status nginx
● nginx.service - A high performance web server
   Active: failed (Result: exit-code)
```

**Diagnosis:**
```bash
# Test nginx configuration
sudo nginx -t

# Check error log
sudo tail -50 /var/log/nginx/error.log

# Check if port is already in use
sudo netstat -tuln | grep :8080
```

**Solutions:**

**A. Configuration Error**
```bash
# Common: syntax error in config
sudo nginx -t
# Fix the error shown

# Reload
sudo systemctl restart nginx
```

**B. Port Already in Use**
```bash
# Find process using port 8080
sudo lsof -i :8080

# Kill the process or change nginx port
# Edit /etc/nginx/sites-available/unified-repo
# Change: listen 8080;
# To: listen 8081;

sudo nginx -t
sudo systemctl restart nginx
```

**C. Permission Issues**
```bash
# Fix permissions
sudo chown -R www-data:www-data /srv/localrepo  # Debian/Ubuntu
# or
sudo chown -R nginx:nginx /srv/localrepo        # RHEL/CentOS

sudo chmod -R 755 /srv/localrepo

sudo systemctl restart nginx
```

---

### Issue 2: apt-mirror Sync Fails

**Symptoms:**
```bash
$ apt-mirror
Downloading /ubuntu/pool/main/...
ERROR: Connection timed out
```

**Diagnosis:**
```bash
# Check network connectivity
ping -c 3 archive.ubuntu.com

# Test mirror URL
wget -O /dev/null http://archive.ubuntu.com/ubuntu/README

# Check logs
tail -100 /srv/localrepo/debian/mirror/var/cron.log
```

**Solutions:**

**A. Network Issues**
```bash
# Use a different mirror
sudo vim /etc/apt/mirror.list

# Change from:
deb http://archive.ubuntu.com/ubuntu jammy main
# To:
deb http://us.archive.ubuntu.com/ubuntu jammy main
# Or your country's mirror

# Retry sync
apt-mirror
```

**B. Disk Full**
```bash
# Check disk space
df -h /srv/localrepo

# Clean old packages
bash /srv/localrepo/debian/mirror/var/clean.sh

# Or reduce mirror scope
# Edit /etc/apt/mirror.list
# Remove universe/multiverse if not needed
```

**C. Timeout Issues**
```bash
# Increase timeout in apt-mirror
# Edit /usr/bin/apt-mirror
# Find: $ENV{mirror_timeout} = 300;
# Change to: $ENV{mirror_timeout} = 600;

# Retry
apt-mirror
```

---

### Issue 3: pypiserver Not Starting

**Symptoms:**
```bash
$ systemctl status pypiserver
● pypiserver.service - PyPI Server
   Active: failed
```

**Diagnosis:**
```bash
# Check service logs
sudo journalctl -u pypiserver -n 50

# Test pypiserver manually
/usr/local/bin/pypi-server run -p 8081 /srv/localrepo/pip/approved
```

**Solutions:**

**A. pypiserver Not Installed**
```bash
# Install pypiserver
sudo python3 -m pip install pypiserver passlib --break-system-packages

# Verify installation
which pypi-server

# Restart service
sudo systemctl restart pypiserver
```

**B. Port Already in Use**
```bash
# Check what's using port 8081
sudo lsof -i :8081

# Change port in service file
sudo vim /etc/systemd/system/pypiserver.service
# Change -p 8081 to -p 8082

sudo systemctl daemon-reload
sudo systemctl restart pypiserver
```

**C. Permission Issues**
```bash
# Fix permissions
sudo chmod -R 755 /srv/localrepo/pip

# Restart
sudo systemctl restart pypiserver
```

---

### Issue 4: Docker Registry Not Accessible

**Symptoms:**
```bash
$ docker pull localhost:5000/ubuntu:22.04
Error response from daemon: Get "https://localhost:5000/v2/": http: server gave HTTP response to HTTPS client
```

**Diagnosis:**
```bash
# Check registry container
docker ps | grep registry

# Check registry logs
docker logs local-docker-registry

# Test registry API
curl http://localhost:5000/v2/
# Should return: {}
```

**Solutions:**

**A. Registry Container Not Running**
```bash
# Start registry
docker start local-docker-registry

# Or recreate if missing
docker run -d \
    --name local-docker-registry \
    --restart=always \
    -p 5000:5000 \
    -v /srv/localrepo/docker/registry:/var/lib/registry \
    registry:2
```

**B. Insecure Registry Not Configured**
```bash
# Edit Docker daemon config
sudo vim /etc/docker/daemon.json
# Add:
{
  "insecure-registries": ["localhost:5000", "SERVER_IP:5000"]
}

# Restart Docker
sudo systemctl restart docker

# Restart registry
docker restart local-docker-registry
```

**C. Firewall Blocking**
```bash
# Allow port 5000
sudo ufw allow 5000/tcp
# or
sudo firewall-cmd --permanent --add-port=5000/tcp
sudo firewall-cmd --reload
```

---

### Issue 5: Verdaccio npm Registry Issues

**Symptoms:**
```bash
$ npm install express
npm ERR! code ECONNREFUSED
npm ERR! errno ECONNREFUSED
```

**Diagnosis:**
```bash
# Check Verdaccio status
systemctl status verdaccio

# Check logs
sudo journalctl -u verdaccio -n 50

# Test manually
curl http://localhost:4873/
```

**Solutions:**

**A. Verdaccio Not Running**
```bash
# Start Verdaccio
sudo systemctl start verdaccio

# Check status
systemctl status verdaccio

# Enable auto-start
sudo systemctl enable verdaccio
```

**B. Configuration Issues**
```bash
# Check Verdaccio config
cat /etc/verdaccio/config.yaml

# Common issue: port conflict
# Edit config
sudo vim /etc/verdaccio/config.yaml
# Ensure correct port is set

# Restart
sudo systemctl restart verdaccio
```

**C. Permission Issues**
```bash
# Fix storage permissions
sudo chmod -R 755 /srv/localrepo/npm

# Restart
sudo systemctl restart verdaccio
```

---

### Issue 6: Client Can't Connect to Repository

**Symptoms:**
```bash
# On client:
$ sudo apt update
Err:1 http://REPO_SERVER:8080/debian jammy InRelease
  Could not connect to REPO_SERVER:8080
```

**Diagnosis:**
```bash
# On CLIENT - Test connectivity
ping REPO_SERVER
telnet REPO_SERVER 8080
curl http://REPO_SERVER:8080/

# On SERVER - Check if port is listening
sudo netstat -tuln | grep :8080

# On SERVER - Check firewall
sudo ufw status
# or
sudo firewall-cmd --list-all
```

**Solutions:**

**A. Firewall Blocking**
```bash
# On SERVER - Allow client network
sudo ufw allow from CLIENT_IP to any port 8080
sudo ufw allow from 192.168.1.0/24 to any port 8080

# or for firewalld
sudo firewall-cmd --permanent --add-rich-rule='rule family="ipv4" source address="192.168.1.0/24" port port="8080" protocol="tcp" accept'
sudo firewall-cmd --reload
```

**B. Nginx Not Listening on External Interface**
```bash
# Check nginx listen directive
grep listen /etc/nginx/sites-available/unified-repo

# Should be:
# listen 8080;  (all interfaces)
# NOT:
# listen 127.0.0.1:8080;  (localhost only)

# Fix and restart
sudo vim /etc/nginx/sites-available/unified-repo
sudo nginx -t
sudo systemctl restart nginx
```

**C. Network/Routing Issues**
```bash
# On CLIENT - Check routing
traceroute REPO_SERVER

# On SERVER - Check if listening
sudo ss -tlnp | grep :8080
```

---

### Issue 7: Packages Not Found After Sync

**Symptoms:**
```bash
# On client:
$ sudo apt install nginx
Reading package lists... Done
E: Unable to locate package nginx
```

**Diagnosis:**
```bash
# On SERVER - Check if packages exist
find /srv/localrepo/debian/approved -name "nginx*.deb"

# Check if index is generated
ls -lh /srv/localrepo/debian/approved/Packages.gz

# On CLIENT - Check sources.list
cat /etc/apt/sources.list.d/local-repo.list
```

**Solutions:**

**A. Package Index Not Generated**
```bash
# On SERVER - Regenerate index
cd /srv/localrepo/debian/approved
dpkg-scanpackages . /dev/null | gzip -9c > Packages.gz
dpkg-scanpackages . /dev/null > Packages

# Restart nginx
sudo systemctl restart nginx
```

**B. Packages Not Approved**
```bash
# On SERVER - Copy from mirror to approved
rsync -av /srv/localrepo/debian/mirror/mirror/ /srv/localrepo/debian/approved/

# Regenerate index
cd /srv/localrepo/debian/approved
dpkg-scanpackages . /dev/null | gzip -9c > Packages.gz
```

**C. Wrong Repository URL**
```bash
# On CLIENT - Verify URL in sources.list
cat /etc/apt/sources.list.d/local-repo.list

# Should match server structure
# Test URL manually
curl http://REPO_SERVER:8080/debian/approved/Packages.gz

# Fix if needed
sudo vim /etc/apt/sources.list.d/local-repo.list
sudo apt update
```

---

### Issue 8: Disk Space Full

**Symptoms:**
```bash
$ df -h
Filesystem      Size  Used Avail Use% Mounted on
/dev/sda1       500G  500G     0 100% /srv
```

**Diagnosis:**
```bash
# Check space usage by directory
du -sh /srv/localrepo/*

# Find largest files
find /srv/localrepo -type f -size +100M -exec ls -lh {} \; | sort -k5 -hr | head -20
```

**Solutions:**

**A. Clean Old Packages**
```bash
# For Debian/Ubuntu
bash /srv/localrepo/debian/mirror/var/clean.sh

# For RHEL - remove old versions
# (requires custom script)
```

**B. Clean Logs**
```bash
# Remove old logs
find /srv/localrepo/logs -name "*.log" -mtime +30 -delete

# Compress old logs
find /srv/localrepo/logs -name "*.log" -mtime +7 -exec gzip {} \;
```

**C. Clean Docker Images**
```bash
# Remove unused Docker images
docker image prune -a

# Clean Docker registry (garbage collection)
docker exec local-docker-registry bin/registry garbage-collect /etc/docker/registry/config.yml
```

**D. Reduce Mirror Scope**
```bash
# Edit apt-mirror to sync less
sudo vim /etc/apt/mirror.list
# Remove universe/multiverse if not needed

# For RHEL, sync only essential repos
# Edit sync script to skip extras
```

---

### Issue 9: Slow Package Downloads

**Symptoms:**
```bash
# Clients downloading at < 1 MB/s from local server
```

**Diagnosis:**
```bash
# Test network speed
iperf3 -s  # On server
iperf3 -c SERVER_IP  # On client

# Check nginx connections
sudo ss -ant | grep :8080 | wc -l

# Check server load
top
```

**Solutions:**

**A. Nginx Performance Tuning**
```bash
# Edit /etc/nginx/nginx.conf
sudo vim /etc/nginx/nginx.conf

# Add/modify:
worker_processes auto;
worker_connections 4096;
sendfile on;
tcp_nopush on;
tcp_nodelay on;

# Restart
sudo nginx -t
sudo systemctl restart nginx
```

**B. Network Issues**
```bash
# Check MTU settings
ip link show

# Test with different MTU
sudo ip link set eth0 mtu 9000  # Jumbo frames if supported

# Check for packet loss
ping -c 100 -f REPO_SERVER
```

**C. Disk I/O Bottleneck**
```bash
# Check disk I/O
iostat -x 1

# If high I/O wait, consider:
# - Move to faster disk (SSD)
# - Use different filesystem (XFS)
# - Enable caching in nginx
```

---

## 🔧 Service-Specific Troubleshooting

### Nginx Troubleshooting

```bash
# Test configuration
sudo nginx -t

# Reload configuration
sudo nginx -s reload

# Check error log
sudo tail -f /var/log/nginx/error.log

# Check access log for client IPs
sudo tail -f /var/log/nginx/unified-repo-access.log

# Verbose mode (debug)
# Edit nginx.conf:
error_log /var/log/nginx/error.log debug;
```

### pypiserver Troubleshooting

```bash
# Check if running
systemctl status pypiserver

# View logs
sudo journalctl -u pypiserver -f

# Test manually
/usr/local/bin/pypi-server run -p 8081 --verbose /srv/localrepo/pip/approved

# List packages
curl http://localhost:8081/packages/

# Check permissions
ls -la /srv/localrepo/pip/approved
```

### Docker Registry Troubleshooting

```bash
# Check container status
docker ps -a | grep registry

# View logs
docker logs -f local-docker-registry

# Check catalog
curl http://localhost:5000/v2/_catalog

# Test push
docker pull alpine
docker tag alpine localhost:5000/test-alpine
docker push localhost:5000/test-alpine

# Registry configuration
docker exec local-docker-registry cat /etc/docker/registry/config.yml
```

### Verdaccio Troubleshooting

```bash
# Check status
systemctl status verdaccio

# View logs
sudo journalctl -u verdaccio -f

# Test API
curl http://localhost:4873/

# Check config
cat /etc/verdaccio/config.yaml

# Clear cache
rm -rf /srv/localrepo/npm/cache/*
systemctl restart verdaccio
```

---

## 📊 Performance Monitoring

### Real-Time Monitoring Script
```bash
#!/bin/bash
# monitor-repo.sh

watch -n 2 '
echo "=== Service Status ==="
systemctl is-active nginx pypiserver verdaccio docker

echo ""
echo "=== Active Connections ==="
ss -ant | grep -E ":(8080|8081|5000|4873)" | wc -l

echo ""
echo "=== Disk Usage ==="
df -h /srv/localrepo | tail -1

echo ""
echo "=== Network Traffic ==="
ifstat 1 1

echo ""
echo "=== CPU & Memory ==="
top -bn1 | head -5
'
```

### Log Analysis
```bash
# Find most accessed packages
awk '{print $7}' /var/log/nginx/unified-repo-access.log | sort | uniq -c | sort -rn | head -20

# Find slow requests (> 1 second)
awk '$NF > 1.0' /var/log/nginx/unified-repo-access.log

# Count requests per hour
awk '{print $4}' /var/log/nginx/unified-repo-access.log | cut -d: -f2 | sort | uniq -c
```

---

## 🆘 Emergency Recovery

### Complete Service Restart
```bash
#!/bin/bash
# emergency-restart.sh

echo "Stopping all services..."
systemctl stop verdaccio
systemctl stop pypiserver
docker stop local-docker-registry
systemctl stop nginx

sleep 5

echo "Starting all services..."
systemctl start nginx
docker start local-docker-registry
systemctl start pypiserver
systemctl start verdaccio

sleep 3

echo "Checking status..."
systemctl status nginx | grep Active
docker ps | grep registry
systemctl status pypiserver | grep Active
systemctl status verdaccio | grep Active
```

### Rebuild Package Indices
```bash
#!/bin/bash
# rebuild-indices.sh

echo "Rebuilding all package indices..."

# Debian/Ubuntu
cd /srv/localrepo/debian/approved
dpkg-scanpackages . /dev/null | gzip -9c > Packages.gz
dpkg-scanpackages . /dev/null > Packages

# RHEL/CentOS
for repo in /srv/localrepo/redhat/approved/*/*; do
    [ -d "$repo" ] && createrepo --update "$repo"
done

echo "Indices rebuilt. Restarting nginx..."
systemctl restart nginx
```

This comprehensive troubleshooting guide covers most common issues you'll encounter!

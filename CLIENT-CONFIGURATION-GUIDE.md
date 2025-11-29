# Complete Client Configuration Guide - All Package Types

## Overview

This guide covers configuring clients to use your unified local repository for:
- **APT** (Debian/Ubuntu)
- **YUM/DNF** (RHEL/CentOS/Fedora)
- **pip** (Python packages)
- **Docker** (Container images)
- **npm** (Node.js packages)

---

## 🔧 Prerequisites

**Replace these values with your actual server details:**
```bash
REPO_SERVER="192.168.1.100"  # Your repository server IP
WEB_PORT="8080"
DOCKER_PORT="5000"
PIP_PORT="8081"
NPM_PORT="4873"
```

---

## 1️⃣ Debian/Ubuntu Clients (APT)

### Complete Configuration Script
```bash
#!/bin/bash
# Configure Debian/Ubuntu client to use local repository

REPO_SERVER="192.168.1.100"
WEB_PORT="8080"

echo "Configuring APT to use local repository..."

# Backup original sources
sudo cp /etc/apt/sources.list /etc/apt/sources.list.backup.$(date +%Y%m%d)
sudo mkdir -p /etc/apt/sources.list.d/backup
sudo mv /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/backup/ 2>/dev/null || true

# Disable official repositories
sudo sed -i 's/^deb/# deb/g' /etc/apt/sources.list

# Add local repository
sudo tee /etc/apt/sources.list.d/mirroret.list << EOF
# Unified Local Repository
deb [trusted=yes] http://${REPO_SERVER}:${WEB_PORT}/debian/approved/mirror jammy main restricted universe multiverse
deb [trusted=yes] http://${REPO_SERVER}:${WEB_PORT}/debian/approved/mirror jammy-updates main restricted universe multiverse
deb [trusted=yes] http://${REPO_SERVER}:${WEB_PORT}/debian/approved/mirror jammy-security main restricted universe multiverse
EOF

# Update package cache
sudo apt clean
sudo apt update

echo "✓ APT configured successfully!"
echo "Test with: sudo apt install htop"
```

### Manual Steps
```bash
# 1. Backup current configuration
sudo cp /etc/apt/sources.list /etc/apt/sources.list.backup

# 2. Download repository configuration
wget http://REPO_SERVER:8080/config/debian-client.list
sudo mv debian-client.list /etc/apt/sources.list.d/mirroret.list

# 3. Disable official repos (optional but recommended)
sudo sed -i 's/^deb/# deb/g' /etc/apt/sources.list

# 4. Update
sudo apt update

# 5. Verify
apt-cache policy
```

### Restore Original Configuration
```bash
# If you need to revert
sudo mv /etc/apt/sources.list.backup /etc/apt/sources.list
sudo rm /etc/apt/sources.list.d/mirroret.list
sudo apt update
```

---

## 2️⃣ RHEL/CentOS/Fedora Clients (YUM/DNF)

### Complete Configuration Script
```bash
#!/bin/bash
# Configure RHEL/CentOS/Fedora client to use local repository

REPO_SERVER="192.168.1.100"
WEB_PORT="8080"

echo "Configuring YUM/DNF to use local repository..."

# Backup original repositories
sudo mkdir -p /etc/yum.repos.d/backup
sudo cp /etc/yum.repos.d/*.repo /etc/yum.repos.d/backup/ 2>/dev/null || true

# Disable all official repositories
sudo mv /etc/yum.repos.d/*.repo /etc/yum.repos.d/backup/ 2>/dev/null || true

# Add local repository
sudo tee /etc/yum.repos.d/mirroret.repo << EOF
# Unified Local Repository

[localrepo-baseos]
name=Local Repository - BaseOS
baseurl=http://${REPO_SERVER}:${WEB_PORT}/redhat/approved/rocky/9/baseos
enabled=1
gpgcheck=0
priority=1

[localrepo-appstream]
name=Local Repository - AppStream
baseurl=http://${REPO_SERVER}:${WEB_PORT}/redhat/approved/rocky/9/appstream
enabled=1
gpgcheck=0
priority=1

[localrepo-extras]
name=Local Repository - Extras
baseurl=http://${REPO_SERVER}:${WEB_PORT}/redhat/approved/rocky/9/extras
enabled=1
gpgcheck=0
priority=1
EOF

# Clear cache and update
if command -v dnf &> /dev/null; then
    sudo dnf clean all
    sudo dnf makecache
    sudo dnf repolist
else
    sudo yum clean all
    sudo yum makecache
    sudo yum repolist
fi

echo "✓ YUM/DNF configured successfully!"
echo "Test with: sudo dnf install htop"
```

### Manual Steps
```bash
# 1. Backup current repos
sudo mkdir -p /etc/yum.repos.d/backup
sudo cp /etc/yum.repos.d/*.repo /etc/yum.repos.d/backup/

# 2. Download repository configuration
wget http://REPO_SERVER:8080/config/redhat-client.repo
sudo mv redhat-client.repo /etc/yum.repos.d/mirroret.repo

# 3. Disable official repos
sudo mv /etc/yum.repos.d/backup/*.repo /etc/yum.repos.d/backup/disabled/

# 4. Update
sudo dnf clean all && sudo dnf makecache

# 5. Verify
sudo dnf repolist
```

### Restore Original Configuration
```bash
# If you need to revert
sudo mv /etc/yum.repos.d/backup/*.repo /etc/yum.repos.d/
sudo rm /etc/yum.repos.d/mirroret.repo
sudo dnf clean all && sudo dnf makecache
```

---

## 3️⃣ Python pip Configuration

### Method 1: Global Configuration (Recommended)
```bash
#!/bin/bash
# Configure pip to use local repository

REPO_SERVER="192.168.1.100"
PIP_PORT="8081"

echo "Configuring pip to use local repository..."

# Create pip config directory
mkdir -p ~/.pip

# Create pip configuration
cat > ~/.pip/pip.conf << EOF
[global]
index-url = http://${REPO_SERVER}:${PIP_PORT}/simple/
trusted-host = ${REPO_SERVER}

[install]
trusted-host = ${REPO_SERVER}
EOF

# System-wide configuration (optional, requires sudo)
sudo mkdir -p /etc/pip
sudo tee /etc/pip/pip.conf << EOF
[global]
index-url = http://${REPO_SERVER}:${PIP_PORT}/simple/
trusted-host = ${REPO_SERVER}
EOF

echo "✓ pip configured successfully!"
echo "Test with: pip install requests"
```

### Method 2: Per-Command Usage
```bash
# Install package using local repository
pip install --index-url http://REPO_SERVER:8081/simple/ \
    --trusted-host REPO_SERVER \
    requests

# Install with requirements file
pip install -r requirements.txt \
    --index-url http://REPO_SERVER:8081/simple/ \
    --trusted-host REPO_SERVER
```

### Method 3: Environment Variable
```bash
# Add to ~/.bashrc or ~/.profile
export PIP_INDEX_URL=http://REPO_SERVER:8081/simple/
export PIP_TRUSTED_HOST=REPO_SERVER

# Reload
source ~/.bashrc

# Now pip will automatically use local repo
pip install flask
```

### Verify Configuration
```bash
# Show pip configuration
pip config list

# Test search (if supported by pypiserver)
pip search requests

# Install test package
pip install requests
```

---

## 4️⃣ Docker Registry Configuration

### Method 1: Daemon Configuration (Recommended)
```bash
#!/bin/bash
# Configure Docker to use local registry

REPO_SERVER="192.168.1.100"
DOCKER_PORT="5000"

echo "Configuring Docker to use local registry..."

# Backup existing daemon.json
if [ -f /etc/docker/daemon.json ]; then
    sudo cp /etc/docker/daemon.json /etc/docker/daemon.json.backup
fi

# Create/update daemon.json
sudo tee /etc/docker/daemon.json << EOF
{
  "insecure-registries": ["${REPO_SERVER}:${DOCKER_PORT}"],
  "registry-mirrors": ["http://${REPO_SERVER}:${DOCKER_PORT}"]
}
EOF

# Restart Docker
sudo systemctl restart docker

# Wait for Docker to start
sleep 3

echo "✓ Docker configured successfully!"
echo "Test with: docker pull ${REPO_SERVER}:${DOCKER_PORT}/ubuntu:22.04"
```

### Pulling Images from Local Registry
```bash
# Pull from local registry
docker pull REPO_SERVER:5000/ubuntu:22.04
docker pull REPO_SERVER:5000/nginx:latest
docker pull REPO_SERVER:5000/python:3.11

# Tag and push your own images
docker tag my-app:latest REPO_SERVER:5000/my-app:latest
docker push REPO_SERVER:5000/my-app:latest

# List images in registry
curl -X GET http://REPO_SERVER:5000/v2/_catalog

# List tags for an image
curl -X GET http://REPO_SERVER:5000/v2/ubuntu/tags/list
```

### Docker Compose Configuration
```yaml
version: '3.8'

services:
  app:
    image: REPO_SERVER:5000/ubuntu:22.04
    # ... rest of configuration
```

### Verify Docker Registry
```bash
# Check registry is accessible
curl http://REPO_SERVER:5000/v2/

# Should return: {}

# List all images
curl http://REPO_SERVER:5000/v2/_catalog
```

---

## 5️⃣ npm Registry Configuration

### Method 1: Global Configuration (Recommended)
```bash
#!/bin/bash
# Configure npm to use local registry

REPO_SERVER="192.168.1.100"
NPM_PORT="4873"

echo "Configuring npm to use local registry..."

# Set registry globally
npm set registry http://${REPO_SERVER}:${NPM_PORT}/

# Create .npmrc in home directory
cat > ~/.npmrc << EOF
registry=http://${REPO_SERVER}:${NPM_PORT}/
EOF

# Verify configuration
npm config get registry

echo "✓ npm configured successfully!"
echo "Test with: npm install express"
```

### Method 2: Project-Specific Configuration
```bash
# Create .npmrc in project directory
cd /path/to/your/project

cat > .npmrc << EOF
registry=http://REPO_SERVER:4873/
EOF

# Now npm install will use local registry
npm install
```

### Method 3: Per-Command Usage
```bash
# Install package using local registry
npm install --registry http://REPO_SERVER:4873/ express

# Install all dependencies
npm install --registry http://REPO_SERVER:4873/
```

### Publishing to Local Registry
```bash
# Create user (first time only)
npm adduser --registry http://REPO_SERVER:4873/

# Publish package
npm publish --registry http://REPO_SERVER:4873/
```

### Verify npm Registry
```bash
# Check current registry
npm config get registry

# Search for package
npm search express --registry http://REPO_SERVER:4873/

# View package info
npm view express --registry http://REPO_SERVER:4873/
```

---

## 📋 Complete Client Setup Script (All Package Types)

```bash
#!/bin/bash
#######################################################################
# Complete Client Configuration Script
# Configures ALL package managers to use local repository
#######################################################################

REPO_SERVER="192.168.1.100"  # CHANGE THIS
WEB_PORT="8080"
DOCKER_PORT="5000"
PIP_PORT="8081"
NPM_PORT="4873"

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

echo "════════════════════════════════════════════════════════"
echo "  Unified Repository Client Configuration"
echo "════════════════════════════════════════════════════════"
echo ""

# Detect OS
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$ID
fi

# Configure APT (Debian/Ubuntu)
if [[ "$OS" == "ubuntu" || "$OS" == "debian" ]]; then
    echo -e "${BLUE}[1/5] Configuring APT...${NC}"
    sudo cp /etc/apt/sources.list /etc/apt/sources.list.backup 2>/dev/null || true
    sudo sed -i 's/^deb/# deb/g' /etc/apt/sources.list
    sudo tee /etc/apt/sources.list.d/mirroret.list << EOF
deb [trusted=yes] http://${REPO_SERVER}:${WEB_PORT}/debian/approved/mirror jammy main restricted universe multiverse
deb [trusted=yes] http://${REPO_SERVER}:${WEB_PORT}/debian/approved/mirror jammy-updates main restricted universe multiverse
deb [trusted=yes] http://${REPO_SERVER}:${WEB_PORT}/debian/approved/mirror jammy-security main restricted universe multiverse
EOF
    sudo apt update
    echo -e "${GREEN}✓ APT configured${NC}"
fi

# Configure YUM/DNF (RHEL/CentOS/Fedora)
if [[ "$OS" == "centos" || "$OS" == "rhel" || "$OS" == "fedora" || "$OS" == "rocky" ]]; then
    echo -e "${BLUE}[1/5] Configuring YUM/DNF...${NC}"
    sudo mkdir -p /etc/yum.repos.d/backup
    sudo mv /etc/yum.repos.d/*.repo /etc/yum.repos.d/backup/ 2>/dev/null || true
    sudo tee /etc/yum.repos.d/mirroret.repo << EOF
[localrepo-baseos]
name=Local Repository - BaseOS
baseurl=http://${REPO_SERVER}:${WEB_PORT}/redhat/approved/rocky/9/baseos
enabled=1
gpgcheck=0

[localrepo-appstream]
name=Local Repository - AppStream
baseurl=http://${REPO_SERVER}:${WEB_PORT}/redhat/approved/rocky/9/appstream
enabled=1
gpgcheck=0
EOF
    if command -v dnf &> /dev/null; then
        sudo dnf clean all && sudo dnf makecache
    else
        sudo yum clean all && sudo yum makecache
    fi
    echo -e "${GREEN}✓ YUM/DNF configured${NC}"
fi

# Configure pip
echo -e "${BLUE}[2/5] Configuring pip...${NC}"
mkdir -p ~/.pip
cat > ~/.pip/pip.conf << EOF
[global]
index-url = http://${REPO_SERVER}:${PIP_PORT}/simple/
trusted-host = ${REPO_SERVER}
EOF
echo -e "${GREEN}✓ pip configured${NC}"

# Configure Docker
echo -e "${BLUE}[3/5] Configuring Docker...${NC}"
if command -v docker &> /dev/null; then
    sudo tee /etc/docker/daemon.json << EOF
{
  "insecure-registries": ["${REPO_SERVER}:${DOCKER_PORT}"],
  "registry-mirrors": ["http://${REPO_SERVER}:${DOCKER_PORT}"]
}
EOF
    sudo systemctl restart docker 2>/dev/null || true
    echo -e "${GREEN}✓ Docker configured${NC}"
else
    echo -e "${GREEN}⊘ Docker not installed, skipping${NC}"
fi

# Configure npm
echo -e "${BLUE}[4/5] Configuring npm...${NC}"
if command -v npm &> /dev/null; then
    npm set registry http://${REPO_SERVER}:${NPM_PORT}/
    echo -e "${GREEN}✓ npm configured${NC}"
else
    echo -e "${GREEN}⊘ npm not installed, skipping${NC}"
fi

# Verify configuration
echo -e "${BLUE}[5/5] Verifying configuration...${NC}"
echo ""
echo "Package Manager Configurations:"
echo "  • APT/YUM: Configured to use ${REPO_SERVER}:${WEB_PORT}"
echo "  • pip: http://${REPO_SERVER}:${PIP_PORT}"
echo "  • Docker: ${REPO_SERVER}:${DOCKER_PORT}"
echo "  • npm: http://${REPO_SERVER}:${NPM_PORT}"
echo ""
echo "════════════════════════════════════════════════════════"
echo -e "${GREEN}  Configuration Complete!${NC}"
echo "════════════════════════════════════════════════════════"
```

---

## 🔍 Verification & Testing

### Test APT (Debian/Ubuntu)
```bash
# Check configured sources
apt-cache policy

# Search for package
apt-cache search nginx

# Install test package
sudo apt install htop

# Verify package came from local repo
apt-cache madison htop
```

### Test YUM/DNF (RHEL/CentOS)
```bash
# List configured repos
sudo dnf repolist

# Search for package
sudo dnf search nginx

# Install test package
sudo dnf install htop

# Verify package source
sudo dnf info htop
```

### Test pip
```bash
# Show configuration
pip config list

# Install test package
pip install requests

# Show package info
pip show requests
```

### Test Docker
```bash
# Check daemon configuration
docker info | grep -A 5 "Registry"

# Pull from local registry
docker pull ${REPO_SERVER}:5000/ubuntu:22.04

# List local images
docker images
```

### Test npm
```bash
# Show configuration
npm config get registry

# Install test package
npm install express

# Show package info
npm view express
```

---

## 🔄 Switching Back to Official Repositories

### APT (Debian/Ubuntu)
```bash
sudo mv /etc/apt/sources.list.backup /etc/apt/sources.list
sudo rm /etc/apt/sources.list.d/mirroret.list
sudo apt update
```

### YUM/DNF (RHEL/CentOS)
```bash
sudo mv /etc/yum.repos.d/backup/*.repo /etc/yum.repos.d/
sudo rm /etc/yum.repos.d/mirroret.repo
sudo dnf clean all && sudo dnf makecache
```

### pip
```bash
rm ~/.pip/pip.conf
# pip will now use default PyPI
```

### Docker
```bash
sudo mv /etc/docker/daemon.json.backup /etc/docker/daemon.json
sudo systemctl restart docker
```

### npm
```bash
npm config delete registry
# npm will now use default registry
```

---

## 🆘 Troubleshooting

### APT Issues
```bash
# Clear cache
sudo apt clean

# Update with verbose output
sudo apt update -o Debug::Acquire::http=true

# Check repo accessibility
curl http://REPO_SERVER:8080/debian/approved/mirror/
```

### YUM/DNF Issues
```bash
# Clear cache
sudo dnf clean all

# Verbose update
sudo dnf makecache --verbose

# Check repo accessibility
curl http://REPO_SERVER:8080/redhat/approved/rocky/9/baseos/
```

### pip Issues
```bash
# Verbose install
pip install -v requests

# Check index
curl http://REPO_SERVER:8081/simple/

# Test connectivity
pip install --index-url http://REPO_SERVER:8081/simple/ --trusted-host REPO_SERVER requests
```

### Docker Issues
```bash
# Check daemon
sudo systemctl status docker

# Check registry
curl http://REPO_SERVER:5000/v2/

# Restart Docker
sudo systemctl restart docker
```

### npm Issues
```bash
# Clear cache
npm cache clean --force

# Check registry
curl http://REPO_SERVER:4873/

# Verbose install
npm install express --verbose
```

This completes the client configuration guide for all package types!

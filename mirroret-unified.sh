#!/bin/bash

#######################################################################
# UNIFIED MIRRORET SERVER - Complete Installation Script
# Supports: deb, rpm, pip, Docker, npm packages
# Purpose: Central package repository for all Linux distributions
# Author: Mher Saratikyan
#######################################################################

set -e  # Exit on error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Configuration
REPO_BASE_DIR="/srv/localrepo"
WEB_PORT=8080
DOCKER_REGISTRY_PORT=5000
PIP_PORT=8081
NPM_PORT=4873
SYNC_HOUR=2  # Hour for daily sync (2 AM)
SERVER_IP=$(hostname -I | awk '{print $1}')
DOMAIN_NAME="${SERVER_IP}"  # Can be changed to actual domain

# Logging
LOG_FILE="/var/log/unified-repo-setup.log"
exec > >(tee -a "$LOG_FILE") 2>&1

#######################################################################
# Helper Functions
#######################################################################

print_header() {
    echo -e "${BLUE}"
    echo "═══════════════════════════════════════════════════════════"
    echo "  $1"
    echo "═══════════════════════════════════════════════════════════"
    echo -e "${NC}"
}

print_success() {
    echo -e "${GREEN}✓ $1${NC}"
}

print_error() {
    echo -e "${RED}✗ $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}⚠ $1${NC}"
}

print_info() {
    echo -e "${CYAN}ℹ $1${NC}"
}

#######################################################################
# Distro Detection
#######################################################################

detect_distro() {
    print_header "Detecting Linux Distribution"
    
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
        VER=$VERSION_ID
        
        case "$OS" in
            ubuntu|debian)
                DISTRO_TYPE="debian"
                PKG_MGR="apt-get"
                print_success "Detected: $OS $VER (Debian-based)"
                ;;
            centos|rhel|fedora|rocky|alma)
                DISTRO_TYPE="rhel"
                if command -v dnf &> /dev/null; then
                    PKG_MGR="dnf"
                else
                    PKG_MGR="yum"
                fi
                print_success "Detected: $OS $VER (RHEL-based)"
                ;;
            *)
                print_error "Unsupported distribution: $OS"
                exit 1
                ;;
        esac
    else
        print_error "Cannot detect distribution"
        exit 1
    fi
}

#######################################################################
# Install Base Packages
#######################################################################

install_base_packages() {
    print_header "Installing Base System Packages"
    
    if [ "$DISTRO_TYPE" = "debian" ]; then
        $PKG_MGR update
        $PKG_MGR install -y \
            apt-mirror \
            dpkg-dev \
            nginx \
            python3 \
            python3-pip \
            python3-venv \
            docker.io \
            nodejs \
            npm \
            wget \
            curl \
            rsync \
            cron \
            git \
            gnupg \
            apache2-utils
    else
        $PKG_MGR install -y \
            createrepo \
            yum-utils \
            nginx \
            python3 \
            python3-pip \
            docker \
            nodejs \
            npm \
            wget \
            curl \
            rsync \
            cronie \
            git \
            httpd-tools
        
        systemctl enable crond
        systemctl start crond
        systemctl enable docker
        systemctl start docker
    fi
    
    # Install Docker if not present (Debian)
    if [ "$DISTRO_TYPE" = "debian" ]; then
        systemctl enable docker
        systemctl start docker
    fi
    
    print_success "Base packages installed"
}

#######################################################################
# Create Directory Structure
#######################################################################

create_directory_structure() {
    print_header "Creating Unified Repository Directory Structure"
    
    # Main directories
    mkdir -p "$REPO_BASE_DIR"/{debian,redhat,pip,docker,npm}
    mkdir -p "$REPO_BASE_DIR"/{staging,approved,logs,scripts,config}
    
    # Debian/Ubuntu structure
    mkdir -p "$REPO_BASE_DIR/debian"/{mirror,approved}
    mkdir -p "$REPO_BASE_DIR/debian/mirror"/{ubuntu,debian}
    
    # RHEL/CentOS structure
    mkdir -p "$REPO_BASE_DIR/redhat"/{mirror,approved}
    mkdir -p "$REPO_BASE_DIR/redhat/mirror"/{centos,fedora,rhel}
    
    # Python pip structure
    mkdir -p "$REPO_BASE_DIR/pip"/{mirror,approved,cache}
    
    # Docker registry structure
    mkdir -p "$REPO_BASE_DIR/docker"/{registry,mirror,approved}
    
    # npm structure
    mkdir -p "$REPO_BASE_DIR/npm"/{mirror,approved,cache}
    
    # Common directories
    mkdir -p "$REPO_BASE_DIR/staging"/{debian,redhat,pip,docker,npm}
    mkdir -p "$REPO_BASE_DIR/approved"/{debian,redhat,pip,docker,npm}
    
    print_success "Directory structure created at $REPO_BASE_DIR"
    
    # Display structure
    print_info "Repository structure:"
    tree -L 2 "$REPO_BASE_DIR" 2>/dev/null || ls -R "$REPO_BASE_DIR" | head -50
}

#######################################################################
# Configure apt-mirror (Debian/Ubuntu)
#######################################################################

configure_apt_mirror() {
    print_header "Configuring apt-mirror for Debian/Ubuntu"
    
    cat > /etc/apt/mirror.list << 'EOF'
############# config ##################
set base_path    /srv/localrepo/debian/mirror
set mirror_path  $base_path/mirror
set skel_path    $base_path/skel
set var_path     $base_path/var
set cleanscript  $var_path/clean.sh
set defaultarch  amd64
set postmirror_script $var_path/postmirror.sh
set run_postmirror 0
set nthreads     20
set _tilde 0
#
############# end config ##############

# Ubuntu 22.04 LTS (Jammy)
deb http://archive.ubuntu.com/ubuntu jammy main restricted universe multiverse
deb http://archive.ubuntu.com/ubuntu jammy-updates main restricted universe multiverse
deb http://archive.ubuntu.com/ubuntu jammy-security main restricted universe multiverse

# Ubuntu 20.04 LTS (Focal) - Optional
# deb http://archive.ubuntu.com/ubuntu focal main restricted universe multiverse
# deb http://archive.ubuntu.com/ubuntu focal-updates main restricted universe multiverse
# deb http://archive.ubuntu.com/ubuntu focal-security main restricted universe multiverse

# Debian 12 (Bookworm) - Optional
# deb http://deb.debian.org/debian bookworm main contrib non-free non-free-firmware
# deb http://deb.debian.org/debian bookworm-updates main contrib non-free non-free-firmware
# deb http://security.debian.org/debian-security bookworm-security main contrib non-free non-free-firmware

clean http://archive.ubuntu.com/ubuntu
EOF
    
    print_success "apt-mirror configured"
}

#######################################################################
# Configure createrepo (RHEL/CentOS)
#######################################################################

configure_createrepo() {
    print_header "Configuring Repository Sync for RHEL-based systems"
    
    cat > "$REPO_BASE_DIR/scripts/sync-redhat-repos.sh" << 'EOF'
#!/bin/bash

REPO_BASE="/srv/localrepo/redhat/mirror"
LOG_FILE="/srv/localrepo/logs/sync-redhat-$(date +%Y%m%d-%H%M%S).log"

echo "Starting RHEL repository sync: $(date)" | tee -a "$LOG_FILE"

# Rocky Linux 9 (free alternative to RHEL)
reposync -p "$REPO_BASE/rocky/9" \
    --download-metadata \
    --repo baseos \
    --repo appstream \
    --repo extras 2>&1 | tee -a "$LOG_FILE"

# Create repository metadata
for repo in baseos appstream extras; do
    if [ -d "$REPO_BASE/rocky/9/$repo" ]; then
        createrepo --update "$REPO_BASE/rocky/9/$repo" 2>&1 | tee -a "$LOG_FILE"
    fi
done

echo "RHEL sync completed: $(date)" | tee -a "$LOG_FILE"
EOF
    
    chmod +x "$REPO_BASE_DIR/scripts/sync-redhat-repos.sh"
    print_success "RHEL repository sync script created"
}

#######################################################################
# Setup Python pip Repository (using pypiserver)
#######################################################################

setup_pip_repository() {
    print_header "Setting Up Python pip Repository"
    
    # Install pypiserver
    python3 -m pip install pypiserver passlib --break-system-packages 2>/dev/null || \
    python3 -m pip install pypiserver passlib
    
    # Create pypiserver service
    cat > /etc/systemd/system/pypiserver.service << EOF
[Unit]
Description=PyPI Server
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=$REPO_BASE_DIR/pip
ExecStart=/usr/local/bin/pypi-server run -p $PIP_PORT --overwrite $REPO_BASE_DIR/pip/approved
Restart=always

[Install]
WantedBy=multi-user.target
EOF
    
    # Create pip sync script
    cat > "$REPO_BASE_DIR/scripts/sync-pip-packages.sh" << 'EOF'
#!/bin/bash

MIRROR_DIR="/srv/localrepo/pip/mirror"
APPROVED_DIR="/srv/localrepo/pip/approved"
LOG_FILE="/srv/localrepo/logs/sync-pip-$(date +%Y%m%d-%H%M%S).log"

echo "Starting pip packages sync: $(date)" | tee -a "$LOG_FILE"

# List of common packages to mirror
PACKAGES=(
    "requests"
    "flask"
    "django"
    "numpy"
    "pandas"
    "pytest"
    "black"
    "pylint"
    "ansible"
    "boto3"
)

mkdir -p "$MIRROR_DIR"

for package in "${PACKAGES[@]}"; do
    echo "Downloading $package..." | tee -a "$LOG_FILE"
    pip download "$package" -d "$MIRROR_DIR" 2>&1 | tee -a "$LOG_FILE"
done

echo "pip sync completed: $(date)" | tee -a "$LOG_FILE"
EOF
    
    chmod +x "$REPO_BASE_DIR/scripts/sync-pip-packages.sh"
    
    # Start pypiserver
    systemctl daemon-reload
    systemctl enable pypiserver
    systemctl start pypiserver
    
    print_success "pip repository configured on port $PIP_PORT"
}

#######################################################################
# Setup Docker Registry
#######################################################################

setup_docker_registry() {
    print_header "Setting Up Docker Registry"
    
    # Create Docker registry configuration
    mkdir -p /etc/docker/registry
    
    cat > /etc/docker/registry/config.yml << EOF
version: 0.1
log:
  fields:
    service: registry
storage:
  cache:
    blobdescriptor: inmemory
  filesystem:
    rootdirectory: $REPO_BASE_DIR/docker/registry
http:
  addr: :$DOCKER_REGISTRY_PORT
  headers:
    X-Content-Type-Options: [nosniff]
health:
  storagedriver:
    enabled: true
    interval: 10s
    threshold: 3
EOF
    
    # Run Docker registry as container
    docker run -d \
        --name local-docker-registry \
        --restart=always \
        -p $DOCKER_REGISTRY_PORT:5000 \
        -v $REPO_BASE_DIR/docker/registry:/var/lib/registry \
        -v /etc/docker/registry/config.yml:/etc/docker/registry/config.yml \
        registry:2
    
    # Create Docker sync script
    cat > "$REPO_BASE_DIR/scripts/sync-docker-images.sh" << 'EOF'
#!/bin/bash

LOCAL_REGISTRY="localhost:5000"
LOG_FILE="/srv/localrepo/logs/sync-docker-$(date +%Y%m%d-%H%M%S).log"

echo "Starting Docker images sync: $(date)" | tee -a "$LOG_FILE"

# List of common images to mirror
IMAGES=(
    "ubuntu:22.04"
    "ubuntu:20.04"
    "debian:12"
    "nginx:latest"
    "python:3.11"
    "node:18"
    "redis:latest"
    "postgres:15"
)

for image in "${IMAGES[@]}"; do
    echo "Pulling $image..." | tee -a "$LOG_FILE"
    docker pull "$image" 2>&1 | tee -a "$LOG_FILE"
    
    # Tag for local registry
    local_image=$(echo "$image" | sed 's/:/-/g')
    docker tag "$image" "$LOCAL_REGISTRY/$image"
    
    echo "Image synced: $image" | tee -a "$LOG_FILE"
done

echo "Docker sync completed: $(date)" | tee -a "$LOG_FILE"
EOF
    
    chmod +x "$REPO_BASE_DIR/scripts/sync-docker-images.sh"
    
    print_success "Docker registry configured on port $DOCKER_REGISTRY_PORT"
}

#######################################################################
# Setup npm Registry (using Verdaccio)
#######################################################################

setup_npm_registry() {
    print_header "Setting Up npm Registry"
    
    # Install Verdaccio globally
    npm install -g verdaccio
    
    # Create Verdaccio configuration
    mkdir -p /etc/verdaccio
    
    cat > /etc/verdaccio/config.yaml << EOF
storage: $REPO_BASE_DIR/npm/approved
auth:
  htpasswd:
    file: ./htpasswd
uplinks:
  npmjs:
    url: https://registry.npmjs.org/
packages:
  '@*/*':
    access: \$all
    publish: \$authenticated
    unpublish: \$authenticated
    proxy: npmjs
  '**':
    access: \$all
    publish: \$authenticated
    unpublish: \$authenticated
    proxy: npmjs
server:
  keepAliveTimeout: 60
middlewares:
  audit:
    enabled: true
logs: { type: stdout, format: pretty, level: http }
EOF
    
    # Create Verdaccio service
    cat > /etc/systemd/system/verdaccio.service << EOF
[Unit]
Description=Verdaccio npm Registry
After=network.target

[Service]
Type=simple
User=root
ExecStart=/usr/bin/verdaccio --config /etc/verdaccio/config.yaml --listen $NPM_PORT
Restart=always

[Install]
WantedBy=multi-user.target
EOF
    
    # Create npm sync script
    cat > "$REPO_BASE_DIR/scripts/sync-npm-packages.sh" << 'EOF'
#!/bin/bash

LOG_FILE="/srv/localrepo/logs/sync-npm-$(date +%Y%m%d-%H%M%S).log"

echo "Starting npm packages sync: $(date)" | tee -a "$LOG_FILE"

# Common packages to cache
PACKAGES=(
    "express"
    "react"
    "vue"
    "angular"
    "lodash"
    "axios"
    "webpack"
)

for package in "${PACKAGES[@]}"; do
    echo "Caching $package..." | tee -a "$LOG_FILE"
    npm view "$package" | tee -a "$LOG_FILE"
done

echo "npm sync completed: $(date)" | tee -a "$LOG_FILE"
EOF
    
    chmod +x "$REPO_BASE_DIR/scripts/sync-npm-packages.sh"
    
    # Start Verdaccio
    systemctl daemon-reload
    systemctl enable verdaccio
    systemctl start verdaccio
    
    print_success "npm registry (Verdaccio) configured on port $NPM_PORT"
}

#######################################################################
# Configure Nginx as Frontend
#######################################################################

configure_nginx() {
    print_header "Configuring Nginx Web Server"
    
    cat > /etc/nginx/sites-available/unified-repo << EOF
server {
    listen $WEB_PORT;
    server_name $DOMAIN_NAME;
    
    root $REPO_BASE_DIR;
    autoindex on;
    
    # Main repository browser
    location / {
        try_files \$uri \$uri/ =404;
    }
    
    # Debian/Ubuntu repositories
    location /debian {
        alias $REPO_BASE_DIR/debian/approved;
        autoindex on;
    }
    
    # RHEL/CentOS repositories
    location /redhat {
        alias $REPO_BASE_DIR/redhat/approved;
        autoindex on;
    }
    
    # PyPI proxy
    location /pip/ {
        proxy_pass http://127.0.0.1:$PIP_PORT/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
    }
    
    # npm proxy
    location /npm/ {
        proxy_pass http://127.0.0.1:$NPM_PORT/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
    }
    
    # Docker registry proxy
    location /v2/ {
        proxy_pass http://127.0.0.1:$DOCKER_REGISTRY_PORT/v2/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        client_max_body_size 0;
        chunked_transfer_encoding on;
    }
    
    # Large file support
    client_max_body_size 0;
    
    # Logging
    access_log /var/log/nginx/unified-repo-access.log;
    error_log /var/log/nginx/unified-repo-error.log;
}
EOF
    
    # Enable site
    if [ -d /etc/nginx/sites-enabled ]; then
        ln -sf /etc/nginx/sites-available/unified-repo /etc/nginx/sites-enabled/
    else
        # RHEL-based
        cp /etc/nginx/sites-available/unified-repo /etc/nginx/conf.d/unified-repo.conf
    fi
    
    # Test and restart nginx
    nginx -t
    systemctl enable nginx
    systemctl restart nginx
    
    print_success "Nginx configured on port $WEB_PORT"
}

#######################################################################
# Create Master Sync Script
#######################################################################

create_master_sync_script() {
    print_header "Creating Master Sync Script"
    
    cat > "$REPO_BASE_DIR/scripts/sync-all-repos.sh" << 'EOF'
#!/bin/bash

LOG_DIR="/srv/localrepo/logs"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)

echo "════════════════════════════════════════════════════════"
echo "  UNIFIED REPOSITORY SYNC - $(date)"
echo "════════════════════════════════════════════════════════"

# Sync Debian/Ubuntu
echo "[1/5] Syncing Debian/Ubuntu repositories..."
/usr/bin/apt-mirror 2>&1 | tee "$LOG_DIR/sync-debian-$TIMESTAMP.log"

# Sync RHEL/CentOS
echo "[2/5] Syncing RHEL/CentOS repositories..."
/srv/localrepo/scripts/sync-redhat-repos.sh

# Sync pip packages
echo "[3/5] Syncing Python pip packages..."
/srv/localrepo/scripts/sync-pip-packages.sh

# Sync Docker images
echo "[4/5] Syncing Docker images..."
/srv/localrepo/scripts/sync-docker-images.sh

# Sync npm packages
echo "[5/5] Syncing npm packages..."
/srv/localrepo/scripts/sync-npm-packages.sh

echo ""
echo "════════════════════════════════════════════════════════"
echo "  SYNC COMPLETED - $(date)"
echo "════════════════════════════════════════════════════════"
EOF
    
    chmod +x "$REPO_BASE_DIR/scripts/sync-all-repos.sh"
    print_success "Master sync script created"
}

#######################################################################
# Create Approval Scripts
#######################################################################

create_approval_scripts() {
    print_header "Creating Package Approval Scripts"
    
    cat > "$REPO_BASE_DIR/scripts/approve-all-packages.sh" << 'EOF'
#!/bin/bash

REPO_BASE="/srv/localrepo"

echo "════════════════════════════════════════════════════════"
echo "  Approving All Packages"
echo "════════════════════════════════════════════════════════"

# Approve Debian packages
echo "[1/5] Approving Debian/Ubuntu packages..."
rsync -av "$REPO_BASE/debian/mirror/mirror/" "$REPO_BASE/debian/approved/"
cd "$REPO_BASE/debian/approved" && dpkg-scanpackages . /dev/null | gzip -9c > Packages.gz

# Approve RHEL packages
echo "[2/5] Approving RHEL/CentOS packages..."
rsync -av "$REPO_BASE/redhat/mirror/" "$REPO_BASE/redhat/approved/"
for repo in "$REPO_BASE/redhat/approved"/*/*; do
    [ -d "$repo" ] && createrepo --update "$repo"
done

# Approve pip packages
echo "[3/5] Approving pip packages..."
rsync -av "$REPO_BASE/pip/mirror/" "$REPO_BASE/pip/approved/"

# Approve Docker images (push to registry)
echo "[4/5] Approving Docker images..."
docker images --format "{{.Repository}}:{{.Tag}}" | grep localhost:5000 | while read img; do
    docker push "$img" 2>/dev/null || true
done

# Approve npm packages
echo "[5/5] Approving npm packages..."
# Verdaccio auto-handles this through proxy

echo ""
echo "════════════════════════════════════════════════════════"
echo "  All packages approved!"
echo "════════════════════════════════════════════════════════"
EOF
    
    chmod +x "$REPO_BASE_DIR/scripts/approve-all-packages.sh"
    print_success "Approval scripts created"
}

#######################################################################
# Setup Cron/Systemd Timer
#######################################################################

setup_automated_sync() {
    print_header "Setting Up Automated Sync Schedule"
    
    # Add cron job
    CRON_CMD="0 $SYNC_HOUR * * * $REPO_BASE_DIR/scripts/sync-all-repos.sh"
    (crontab -l 2>/dev/null | grep -v "sync-all-repos.sh"; echo "$CRON_CMD") | crontab -
    
    print_success "Cron job added: Daily sync at ${SYNC_HOUR}:00 AM"
}

#######################################################################
# Generate Client Configuration Files
#######################################################################

generate_client_configs() {
    print_header "Generating Client Configuration Files"
    
    # Debian/Ubuntu client config
    cat > "$REPO_BASE_DIR/config/debian-client.list" << EOF
# Unified Local Repository - Debian/Ubuntu
deb [trusted=yes] http://${SERVER_IP}:${WEB_PORT}/debian/approved/mirror jammy main restricted universe multiverse
deb [trusted=yes] http://${SERVER_IP}:${WEB_PORT}/debian/approved/mirror jammy-updates main restricted universe multiverse
deb [trusted=yes] http://${SERVER_IP}:${WEB_PORT}/debian/approved/mirror jammy-security main restricted universe multiverse
EOF
    
    # RHEL/CentOS client config
    cat > "$REPO_BASE_DIR/config/redhat-client.repo" << EOF
# Unified Local Repository - RHEL/CentOS

[localrepo-baseos]
name=Local Repository - BaseOS
baseurl=http://${SERVER_IP}:${WEB_PORT}/redhat/approved/rocky/9/baseos
enabled=1
gpgcheck=0

[localrepo-appstream]
name=Local Repository - AppStream
baseurl=http://${SERVER_IP}:${WEB_PORT}/redhat/approved/rocky/9/appstream
enabled=1
gpgcheck=0
EOF
    
    # pip client config
    cat > "$REPO_BASE_DIR/config/pip.conf" << EOF
[global]
index-url = http://${SERVER_IP}:${PIP_PORT}/simple/
trusted-host = ${SERVER_IP}
EOF
    
    # npm client config
    cat > "$REPO_BASE_DIR/config/.npmrc" << EOF
registry=http://${SERVER_IP}:${NPM_PORT}/
EOF
    
    # Docker daemon config
    cat > "$REPO_BASE_DIR/config/docker-daemon.json" << EOF
{
  "insecure-registries": ["${SERVER_IP}:${DOCKER_REGISTRY_PORT}"],
  "registry-mirrors": ["http://${SERVER_IP}:${DOCKER_REGISTRY_PORT}"]
}
EOF
    
    print_success "Client configuration files generated in $REPO_BASE_DIR/config/"
}

#######################################################################
# Configure Firewall
#######################################################################

configure_firewall() {
    print_header "Configuring Firewall"
    
    if command -v ufw &> /dev/null; then
        ufw allow $WEB_PORT/tcp
        ufw allow $DOCKER_REGISTRY_PORT/tcp
        ufw allow $PIP_PORT/tcp
        ufw allow $NPM_PORT/tcp
        print_success "UFW: Allowed ports $WEB_PORT, $DOCKER_REGISTRY_PORT, $PIP_PORT, $NPM_PORT"
    elif command -v firewall-cmd &> /dev/null; then
        firewall-cmd --permanent --add-port=$WEB_PORT/tcp
        firewall-cmd --permanent --add-port=$DOCKER_REGISTRY_PORT/tcp
        firewall-cmd --permanent --add-port=$PIP_PORT/tcp
        firewall-cmd --permanent --add-port=$NPM_PORT/tcp
        firewall-cmd --reload
        print_success "Firewalld: Allowed ports $WEB_PORT, $DOCKER_REGISTRY_PORT, $PIP_PORT, $NPM_PORT"
    else
        print_warning "No firewall detected. Please manually allow ports: $WEB_PORT, $DOCKER_REGISTRY_PORT, $PIP_PORT, $NPM_PORT"
    fi
}

#######################################################################
# Generate Comprehensive Documentation
#######################################################################

generate_documentation() {
    print_header "Generating Comprehensive Documentation"
    
    cat > "$REPO_BASE_DIR/README.md" << EOF
# Unified Local Repository Server

## Server Information
- **Server IP**: $SERVER_IP
- **Main Web Port**: $WEB_PORT
- **Docker Registry Port**: $DOCKER_REGISTRY_PORT
- **pip Index Port**: $PIP_PORT
- **npm Registry Port**: $NPM_PORT

## Repository Types Supported
1. ✅ Debian/Ubuntu (.deb)
2. ✅ RHEL/CentOS/Fedora (.rpm)
3. ✅ Python pip packages
4. ✅ Docker images
5. ✅ npm packages

## Directory Structure
\`\`\`
$REPO_BASE_DIR/
├── debian/          # Debian/Ubuntu packages
├── redhat/          # RHEL/CentOS packages
├── pip/             # Python pip packages
├── docker/          # Docker registry
├── npm/             # npm packages
├── scripts/         # Management scripts
├── config/          # Client configurations
└── logs/            # All logs
\`\`\`

## Management Commands

### Sync All Repositories
\`\`\`bash
$REPO_BASE_DIR/scripts/sync-all-repos.sh
\`\`\`

### Approve All Packages
\`\`\`bash
$REPO_BASE_DIR/scripts/approve-all-packages.sh
\`\`\`

## Client Configuration

### Debian/Ubuntu Clients
\`\`\`bash
# Backup original sources
sudo cp /etc/apt/sources.list /etc/apt/sources.list.backup

# Download and install local repo config
wget http://$SERVER_IP:$WEB_PORT/config/debian-client.list
sudo mv debian-client.list /etc/apt/sources.list.d/

# Disable official repos (optional)
sudo sed -i 's/^deb/# deb/g' /etc/apt/sources.list

# Update
sudo apt update
\`\`\`

### RHEL/CentOS Clients
\`\`\`bash
# Backup original repos
sudo mkdir /etc/yum.repos.d/backup
sudo mv /etc/yum.repos.d/*.repo /etc/yum.repos.d/backup/

# Download and install local repo config
wget http://$SERVER_IP:$WEB_PORT/config/redhat-client.repo
sudo mv redhat-client.repo /etc/yum.repos.d/

# Update
sudo dnf clean all && sudo dnf makecache
\`\`\`

### Python pip Configuration
\`\`\`bash
# Download pip config
mkdir -p ~/.pip
wget http://$SERVER_IP:$WEB_PORT/config/pip.conf -O ~/.pip/pip.conf

# Or use directly
pip install --index-url http://$SERVER_IP:$PIP_PORT/simple/ --trusted-host $SERVER_IP <package>
\`\`\`

### npm Configuration
\`\`\`bash
# Download npm config
wget http://$SERVER_IP:$WEB_PORT/config/.npmrc -O ~/.npmrc

# Or set registry
npm set registry http://$SERVER_IP:$NPM_PORT/
\`\`\`

### Docker Configuration
\`\`\`bash
# Download Docker daemon config
sudo wget http://$SERVER_IP:$WEB_PORT/config/docker-daemon.json -O /etc/docker/daemon.json

# Restart Docker
sudo systemctl restart docker

# Pull from local registry
docker pull $SERVER_IP:$DOCKER_REGISTRY_PORT/ubuntu:22.04
\`\`\`

## Web Interface
Access repository browser: http://$SERVER_IP:$WEB_PORT/

## Logs
All logs: $REPO_BASE_DIR/logs/

EOF
    
    print_success "Documentation generated: $REPO_BASE_DIR/README.md"
}

#######################################################################
# Print Summary
#######################################################################

print_summary() {
    clear
    print_header "UNIFIED REPOSITORY SERVER - INSTALLATION COMPLETE!"
    
    echo ""
    echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}  Installation Successful!${NC}"
    echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "${CYAN}Server Information:${NC}"
    echo "  • Server IP: $SERVER_IP"
    echo "  • Main Web Port: $WEB_PORT"
    echo "  • Docker Registry: $SERVER_IP:$DOCKER_REGISTRY_PORT"
    echo "  • pip Index: $SERVER_IP:$PIP_PORT"
    echo "  • npm Registry: $SERVER_IP:$NPM_PORT"
    echo ""
    echo -e "${CYAN}Repository Types Configured:${NC}"
    echo "  ✅ Debian/Ubuntu packages (.deb)"
    echo "  ✅ RHEL/CentOS packages (.rpm)"
    echo "  ✅ Python pip packages"
    echo "  ✅ Docker images"
    echo "  ✅ npm packages"
    echo ""
    echo -e "${CYAN}Quick Start:${NC}"
    echo "  1. Initial sync:"
    echo "     $REPO_BASE_DIR/scripts/sync-all-repos.sh"
    echo ""
    echo "  2. Approve packages:"
    echo "     $REPO_BASE_DIR/scripts/approve-all-packages.sh"
    echo ""
    echo "  3. Configure clients (see documentation)"
    echo ""
    echo -e "${CYAN}Web Interfaces:${NC}"
    echo "  • Main: http://$SERVER_IP:$WEB_PORT/"
    echo "  • Docker: http://$SERVER_IP:$DOCKER_REGISTRY_PORT/v2/_catalog"
    echo "  • pip: http://$SERVER_IP:$PIP_PORT/"
    echo "  • npm: http://$SERVER_IP:$NPM_PORT/"
    echo ""
    echo -e "${CYAN}Documentation:${NC}"
    echo "  • Full guide: $REPO_BASE_DIR/README.md"
    echo "  • Client configs: $REPO_BASE_DIR/config/"
    echo "  • Logs: $REPO_BASE_DIR/logs/"
    echo ""
    echo -e "${YELLOW}Next Steps:${NC}"
    echo "  1. Run initial sync (will take several hours)"
    echo "  2. Approve all packages"
    echo "  3. Configure your first client machine"
    echo "  4. Test package installation"
    echo ""
    echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
}

#######################################################################
# Main Installation
#######################################################################

main() {
    clear
    print_header "UNIFIED LOCAL REPOSITORY SERVER - INSTALLATION"
    
    echo -e "${YELLOW}"
    echo "This script will install a complete unified repository server supporting:"
    echo "  • Debian/Ubuntu packages"
    echo "  • RHEL/CentOS/Fedora packages"
    echo "  • Python pip packages"
    echo "  • Docker images"
    echo "  • npm packages"
    echo ""
    echo "Installation will take approximately 10-15 minutes."
    echo -e "${NC}"
    
    # Check root
    if [ "$EUID" -ne 0 ]; then
        print_error "Please run as root (sudo)"
        exit 1
    fi
    
    # Execute installation
    detect_distro
    install_base_packages
    create_directory_structure
    
    if [ "$DISTRO_TYPE" = "debian" ]; then
        configure_apt_mirror
    fi
    configure_createrepo
    
    setup_pip_repository
    setup_docker_registry
    setup_npm_registry
    configure_nginx
    
    create_master_sync_script
    create_approval_scripts
    setup_automated_sync
    generate_client_configs
    configure_firewall
    generate_documentation
    
    print_summary
}

# Run installation
main


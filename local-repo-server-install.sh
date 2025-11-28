#!/bin/bash

#######################################################################
# Local Repository Server Installation Script
# Purpose: Turn this machine into a central package repository server
# Supports: Debian/Ubuntu and RHEL/CentOS/Fedora based systems
# Author: Professional Linux DevOps & System Architect
#######################################################################

set -e  # Exit on error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
REPO_BASE_DIR="/var/local-repo"
WEB_PORT=8080
SYNC_HOUR=2  # Hour for daily sync (2 AM)
SERVER_IP=$(hostname -I | awk '{print $1}')

# Logging
LOG_FILE="/var/log/local-repo-setup.log"
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
    echo -e "${BLUE}ℹ $1${NC}"
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
                print_success "Detected: $OS $VER (Debian-based)"
                ;;
            centos|rhel|fedora|rocky|alma)
                DISTRO_TYPE="rhel"
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
# Install Required Packages
#######################################################################

install_debian_packages() {
    print_header "Installing Required Packages (Debian-based)"
    
    apt-get update
    apt-get install -y \
        apt-mirror \
        dpkg-dev \
        nginx \
        gnupg \
        wget \
        curl \
        rsync \
        cron
    
    print_success "Packages installed successfully"
}

install_rhel_packages() {
    print_header "Installing Required Packages (RHEL-based)"
    
    if command -v dnf &> /dev/null; then
        PKG_MGR="dnf"
    else
        PKG_MGR="yum"
    fi
    
    $PKG_MGR install -y \
        createrepo \
        yum-utils \
        nginx \
        wget \
        curl \
        rsync \
        cronie
    
    # Start and enable crond
    systemctl enable crond
    systemctl start crond
    
    print_success "Packages installed successfully"
}

#######################################################################
# Create Directory Structure
#######################################################################

create_directory_structure() {
    print_header "Creating Directory Structure"
    
    mkdir -p "$REPO_BASE_DIR"
    mkdir -p "$REPO_BASE_DIR/mirror"
    mkdir -p "$REPO_BASE_DIR/approved"
    mkdir -p "$REPO_BASE_DIR/staging"
    mkdir -p "$REPO_BASE_DIR/logs"
    mkdir -p "$REPO_BASE_DIR/scripts"
    mkdir -p "$REPO_BASE_DIR/config"
    
    if [ "$DISTRO_TYPE" = "debian" ]; then
        mkdir -p "$REPO_BASE_DIR/mirror/ubuntu"
        mkdir -p "$REPO_BASE_DIR/mirror/debian"
        mkdir -p "$REPO_BASE_DIR/approved/ubuntu"
        mkdir -p "$REPO_BASE_DIR/approved/debian"
    else
        mkdir -p "$REPO_BASE_DIR/mirror/centos"
        mkdir -p "$REPO_BASE_DIR/mirror/fedora"
        mkdir -p "$REPO_BASE_DIR/mirror/rhel"
        mkdir -p "$REPO_BASE_DIR/approved/centos"
        mkdir -p "$REPO_BASE_DIR/approved/fedora"
        mkdir -p "$REPO_BASE_DIR/approved/rhel"
    fi
    
    print_success "Directory structure created at $REPO_BASE_DIR"
}

#######################################################################
# Configure apt-mirror (Debian-based)
#######################################################################

configure_apt_mirror() {
    print_header "Configuring apt-mirror"
    
    cat > /etc/apt/mirror.list << 'EOF'
############# config ##################
#
set base_path    /var/local-repo/mirror
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

# Ubuntu repositories
deb http://archive.ubuntu.com/ubuntu jammy main restricted universe multiverse
deb http://archive.ubuntu.com/ubuntu jammy-updates main restricted universe multiverse
deb http://archive.ubuntu.com/ubuntu jammy-security main restricted universe multiverse

# Debian repositories (optional)
# deb http://deb.debian.org/debian bookworm main contrib non-free
# deb http://deb.debian.org/debian bookworm-updates main contrib non-free
# deb http://security.debian.org/debian-security bookworm-security main contrib non-free

clean http://archive.ubuntu.com/ubuntu
EOF
    
    print_success "apt-mirror configured"
}

#######################################################################
# Configure createrepo (RHEL-based)
#######################################################################

configure_createrepo() {
    print_header "Configuring Repository Sync for RHEL-based systems"
    
    # Create sync script for RHEL repos
    cat > "$REPO_BASE_DIR/scripts/sync-repos.sh" << 'EOF'
#!/bin/bash

REPO_BASE="/var/local-repo/mirror"
LOG_FILE="/var/local-repo/logs/sync-$(date +%Y%m%d-%H%M%S).log"

echo "Starting repository sync: $(date)" | tee -a "$LOG_FILE"

# Sync CentOS Stream 9 (or adjust to your needs)
reposync -p "$REPO_BASE/centos/9" \
    --download-metadata \
    --repo baseos \
    --repo appstream \
    --repo extras 2>&1 | tee -a "$LOG_FILE"

# Create repository metadata
createrepo --update "$REPO_BASE/centos/9/baseos" 2>&1 | tee -a "$LOG_FILE"
createrepo --update "$REPO_BASE/centos/9/appstream" 2>&1 | tee -a "$LOG_FILE"
createrepo --update "$REPO_BASE/centos/9/extras" 2>&1 | tee -a "$LOG_FILE"

echo "Sync completed: $(date)" | tee -a "$LOG_FILE"
EOF
    
    chmod +x "$REPO_BASE_DIR/scripts/sync-repos.sh"
    print_success "Repository sync script created"
}

#######################################################################
# Configure Web Server (Nginx)
#######################################################################

configure_nginx() {
    print_header "Configuring Nginx Web Server"
    
    cat > /etc/nginx/sites-available/local-repo << EOF
server {
    listen $WEB_PORT;
    server_name _;
    
    root $REPO_BASE_DIR;
    autoindex on;
    
    location / {
        try_files \$uri \$uri/ =404;
    }
    
    location /mirror {
        alias $REPO_BASE_DIR/mirror;
        autoindex on;
    }
    
    location /approved {
        alias $REPO_BASE_DIR/approved;
        autoindex on;
    }
    
    # Enable large file support
    client_max_body_size 0;
    
    # Logging
    access_log /var/log/nginx/local-repo-access.log;
    error_log /var/log/nginx/local-repo-error.log;
}
EOF
    
    # Enable site
    if [ -d /etc/nginx/sites-enabled ]; then
        ln -sf /etc/nginx/sites-available/local-repo /etc/nginx/sites-enabled/
    else
        # RHEL-based systems
        cat > /etc/nginx/conf.d/local-repo.conf << EOF
server {
    listen $WEB_PORT;
    server_name _;
    
    root $REPO_BASE_DIR;
    autoindex on;
    
    location / {
        try_files \$uri \$uri/ =404;
    }
    
    location /mirror {
        alias $REPO_BASE_DIR/mirror;
        autoindex on;
    }
    
    location /approved {
        alias $REPO_BASE_DIR/approved;
        autoindex on;
    }
    
    client_max_body_size 0;
    
    access_log /var/log/nginx/local-repo-access.log;
    error_log /var/log/nginx/local-repo-error.log;
}
EOF
    fi
    
    # Test and restart nginx
    nginx -t
    systemctl enable nginx
    systemctl restart nginx
    
    print_success "Nginx configured and started on port $WEB_PORT"
}

#######################################################################
# Create Package Approval Script
#######################################################################

create_approval_script() {
    print_header "Creating Package Approval Script"
    
    cat > "$REPO_BASE_DIR/scripts/approve-packages.sh" << 'EOF'
#!/bin/bash

#######################################################################
# Package Approval Script
# Usage: ./approve-packages.sh [--auto-approve]
#######################################################################

REPO_BASE="/var/local-repo"
MIRROR_DIR="$REPO_BASE/mirror"
APPROVED_DIR="$REPO_BASE/approved"
STAGING_DIR="$REPO_BASE/staging"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

AUTO_APPROVE=false
if [ "$1" = "--auto-approve" ]; then
    AUTO_APPROVE=true
fi

echo "═══════════════════════════════════════════════════════════"
echo "  Package Approval System"
echo "═══════════════════════════════════════════════════════════"
echo ""

# Find new packages
echo "Scanning for new packages in mirror..."

if [ -d "$MIRROR_DIR/mirror" ]; then
    # Debian-based
    NEW_PACKAGES=$(find "$MIRROR_DIR/mirror" -name "*.deb" -newer "$APPROVED_DIR" 2>/dev/null | wc -l)
    
    if [ "$NEW_PACKAGES" -gt 0 ]; then
        echo -e "${GREEN}Found $NEW_PACKAGES new packages${NC}"
        
        if [ "$AUTO_APPROVE" = true ]; then
            echo "Auto-approving all packages..."
            rsync -av "$MIRROR_DIR/mirror/" "$APPROVED_DIR/"
            
            # Regenerate package indices
            cd "$APPROVED_DIR"
            dpkg-scanpackages . /dev/null | gzip -9c > Packages.gz
            dpkg-scanpackages . /dev/null > Packages
            
            echo -e "${GREEN}All packages approved and indices updated${NC}"
        else
            echo "Review new packages in: $MIRROR_DIR/mirror"
            echo "To approve, run: rsync -av $MIRROR_DIR/mirror/ $APPROVED_DIR/"
            echo "Or run with --auto-approve flag"
        fi
    else
        echo "No new packages found"
    fi
else
    # RHEL-based
    NEW_PACKAGES=$(find "$MIRROR_DIR" -name "*.rpm" -newer "$APPROVED_DIR" 2>/dev/null | wc -l)
    
    if [ "$NEW_PACKAGES" -gt 0 ]; then
        echo -e "${GREEN}Found $NEW_PACKAGES new packages${NC}"
        
        if [ "$AUTO_APPROVE" = true ]; then
            echo "Auto-approving all packages..."
            rsync -av "$MIRROR_DIR/" "$APPROVED_DIR/"
            
            # Regenerate repository metadata
            for repo in "$APPROVED_DIR"/*; do
                if [ -d "$repo" ]; then
                    createrepo --update "$repo"
                fi
            done
            
            echo -e "${GREEN}All packages approved and metadata updated${NC}"
        else
            echo "Review new packages in: $MIRROR_DIR"
            echo "To approve, run: rsync -av $MIRROR_DIR/ $APPROVED_DIR/"
            echo "Or run with --auto-approve flag"
        fi
    else
        echo "No new packages found"
    fi
fi

echo ""
echo "═══════════════════════════════════════════════════════════"
EOF
    
    chmod +x "$REPO_BASE_DIR/scripts/approve-packages.sh"
    print_success "Approval script created"
}

#######################################################################
# Create Update Check Script
#######################################################################

create_update_check_script() {
    print_header "Creating Update Check Script"
    
    cat > "$REPO_BASE_DIR/scripts/check-updates.sh" << 'EOF'
#!/bin/bash

#######################################################################
# Check for Available Updates
#######################################################################

REPO_BASE="/var/local-repo"
LOG_FILE="$REPO_BASE/logs/update-check-$(date +%Y%m%d).log"

echo "═══════════════════════════════════════════════════════════" | tee "$LOG_FILE"
echo "  Update Check Report - $(date)" | tee -a "$LOG_FILE"
echo "═══════════════════════════════════════════════════════════" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"

# Detect distro type
if [ -f /etc/debian_version ]; then
    echo "Checking for Debian/Ubuntu updates..." | tee -a "$LOG_FILE"
    apt-get update > /dev/null 2>&1
    UPDATES=$(apt list --upgradable 2>/dev/null | grep -v "Listing" | wc -l)
    echo "Available updates: $UPDATES" | tee -a "$LOG_FILE"
    apt list --upgradable 2>/dev/null | grep -v "Listing" | tee -a "$LOG_FILE"
elif [ -f /etc/redhat-release ]; then
    echo "Checking for RHEL/CentOS/Fedora updates..." | tee -a "$LOG_FILE"
    if command -v dnf &> /dev/null; then
        UPDATES=$(dnf check-update -q | grep -v "^$" | wc -l)
        echo "Available updates: $UPDATES" | tee -a "$LOG_FILE"
        dnf check-update 2>/dev/null | tee -a "$LOG_FILE"
    else
        UPDATES=$(yum check-update -q | grep -v "^$" | wc -l)
        echo "Available updates: $UPDATES" | tee -a "$LOG_FILE"
        yum check-update 2>/dev/null | tee -a "$LOG_FILE"
    fi
fi

echo "" | tee -a "$LOG_FILE"
echo "═══════════════════════════════════════════════════════════" | tee -a "$LOG_FILE"
echo "Log saved to: $LOG_FILE"
EOF
    
    chmod +x "$REPO_BASE_DIR/scripts/check-updates.sh"
    print_success "Update check script created"
}

#######################################################################
# Create Sync Script
#######################################################################

create_sync_script() {
    print_header "Creating Automatic Sync Script"
    
    if [ "$DISTRO_TYPE" = "debian" ]; then
        cat > "$REPO_BASE_DIR/scripts/sync-mirror.sh" << 'EOF'
#!/bin/bash

LOG_FILE="/var/local-repo/logs/sync-$(date +%Y%m%d-%H%M%S).log"

echo "Starting mirror sync: $(date)" | tee "$LOG_FILE"

# Run apt-mirror
/usr/bin/apt-mirror 2>&1 | tee -a "$LOG_FILE"

# Clean old packages
bash /var/local-repo/mirror/var/clean.sh 2>&1 | tee -a "$LOG_FILE"

echo "Sync completed: $(date)" | tee -a "$LOG_FILE"

# Send notification (optional)
echo "Mirror sync completed" | mail -s "Local Repo Sync Complete" root
EOF
    else
        cat > "$REPO_BASE_DIR/scripts/sync-mirror.sh" << 'EOF'
#!/bin/bash

REPO_BASE="/var/local-repo/mirror"
LOG_FILE="/var/local-repo/logs/sync-$(date +%Y%m%d-%H%M%S).log"

echo "Starting repository sync: $(date)" | tee "$LOG_FILE"

# Sync repositories
reposync -p "$REPO_BASE" --download-metadata --newest-only 2>&1 | tee -a "$LOG_FILE"

# Update metadata
for repo in "$REPO_BASE"/*; do
    if [ -d "$repo" ]; then
        createrepo --update "$repo" 2>&1 | tee -a "$LOG_FILE"
    fi
done

echo "Sync completed: $(date)" | tee -a "$LOG_FILE"
EOF
    fi
    
    chmod +x "$REPO_BASE_DIR/scripts/sync-mirror.sh"
    print_success "Sync script created"
}

#######################################################################
# Setup Automatic Sync (Cron)
#######################################################################

setup_cron() {
    print_header "Setting Up Automatic Sync Schedule"
    
    # Add cron job for daily sync
    CRON_CMD="0 $SYNC_HOUR * * * $REPO_BASE_DIR/scripts/sync-mirror.sh"
    
    (crontab -l 2>/dev/null | grep -v "sync-mirror.sh"; echo "$CRON_CMD") | crontab -
    
    print_success "Cron job added: Daily sync at ${SYNC_HOUR}:00 AM"
}

#######################################################################
# Generate Client Configuration Files
#######################################################################

generate_client_configs() {
    print_header "Generating Client Configuration Files"
    
    if [ "$DISTRO_TYPE" = "debian" ]; then
        # Debian/Ubuntu client config
        cat > "$REPO_BASE_DIR/config/localrepo.list" << EOF
# Local Repository Server
# Place this file in /etc/apt/sources.list.d/ on client machines

deb [trusted=yes] http://${SERVER_IP}:${WEB_PORT}/approved/mirror jammy main restricted universe multiverse
deb [trusted=yes] http://${SERVER_IP}:${WEB_PORT}/approved/mirror jammy-updates main restricted universe multiverse
deb [trusted=yes] http://${SERVER_IP}:${WEB_PORT}/approved/mirror jammy-security main restricted universe multiverse
EOF
        
        print_success "Debian/Ubuntu client config: $REPO_BASE_DIR/config/localrepo.list"
    else
        # RHEL/CentOS/Fedora client config
        cat > "$REPO_BASE_DIR/config/localrepo.repo" << EOF
# Local Repository Server
# Place this file in /etc/yum.repos.d/ on client machines

[localrepo-baseos]
name=Local Repository - BaseOS
baseurl=http://${SERVER_IP}:${WEB_PORT}/approved/centos/9/baseos
enabled=1
gpgcheck=0

[localrepo-appstream]
name=Local Repository - AppStream
baseurl=http://${SERVER_IP}:${WEB_PORT}/approved/centos/9/appstream
enabled=1
gpgcheck=0

[localrepo-extras]
name=Local Repository - Extras
baseurl=http://${SERVER_IP}:${WEB_PORT}/approved/centos/9/extras
enabled=1
gpgcheck=0
EOF
        
        print_success "RHEL/CentOS/Fedora client config: $REPO_BASE_DIR/config/localrepo.repo"
    fi
}

#######################################################################
# Create Management Scripts
#######################################################################

create_management_scripts() {
    print_header "Creating Management Scripts"
    
    # Exclude packages script
    cat > "$REPO_BASE_DIR/scripts/exclude-package.sh" << 'EOF'
#!/bin/bash

# Usage: ./exclude-package.sh package-name

if [ -z "$1" ]; then
    echo "Usage: $0 <package-name>"
    exit 1
fi

EXCLUDE_FILE="/var/local-repo/config/excluded-packages.txt"

echo "$1" >> "$EXCLUDE_FILE"
echo "Package $1 added to exclusion list: $EXCLUDE_FILE"
EOF
    
    chmod +x "$REPO_BASE_DIR/scripts/exclude-package.sh"
    
    # List packages script
    cat > "$REPO_BASE_DIR/scripts/list-packages.sh" << 'EOF'
#!/bin/bash

APPROVED_DIR="/var/local-repo/approved"

echo "═══════════════════════════════════════════════════════════"
echo "  Available Packages in Approved Repository"
echo "═══════════════════════════════════════════════════════════"
echo ""

if [ -f /etc/debian_version ]; then
    find "$APPROVED_DIR" -name "*.deb" -exec dpkg-deb -f {} Package,Version \; | sort
else
    find "$APPROVED_DIR" -name "*.rpm" -exec rpm -qp --queryformat '%{NAME}-%{VERSION}-%{RELEASE}\n' {} \; 2>/dev/null | sort
fi
EOF
    
    chmod +x "$REPO_BASE_DIR/scripts/list-packages.sh"
    
    print_success "Management scripts created"
}

#######################################################################
# Configure Firewall
#######################################################################

configure_firewall() {
    print_header "Configuring Firewall"
    
    if command -v ufw &> /dev/null; then
        ufw allow $WEB_PORT/tcp
        print_success "UFW: Allowed port $WEB_PORT"
    elif command -v firewall-cmd &> /dev/null; then
        firewall-cmd --permanent --add-port=$WEB_PORT/tcp
        firewall-cmd --reload
        print_success "Firewalld: Allowed port $WEB_PORT"
    else
        print_warning "No firewall detected. Please manually allow port $WEB_PORT"
    fi
}

#######################################################################
# Generate Documentation
#######################################################################

generate_documentation() {
    print_header "Generating Documentation"
    
    cat > "$REPO_BASE_DIR/README.md" << EOF
# Local Repository Server Documentation

## Server Information
- **Server IP**: $SERVER_IP
- **Port**: $WEB_PORT
- **Repository Base**: $REPO_BASE_DIR
- **Distribution Type**: $DISTRO_TYPE

## Directory Structure

\`\`\`
$REPO_BASE_DIR/
├── mirror/          # Downloaded packages from official repos
├── approved/        # Approved packages ready for client use
├── staging/         # Temporary staging area
├── logs/           # Sync and operation logs
├── scripts/        # Management scripts
└── config/         # Client configuration files
\`\`\`

## Management Scripts

### 1. Sync Mirror
\`\`\`bash
$REPO_BASE_DIR/scripts/sync-mirror.sh
\`\`\`
Downloads latest packages from official repositories.

### 2. Check for Updates
\`\`\`bash
$REPO_BASE_DIR/scripts/check-updates.sh
\`\`\`
Shows available updates without downloading.

### 3. Approve Packages
\`\`\`bash
# Manual approval (review first)
$REPO_BASE_DIR/scripts/approve-packages.sh

# Auto-approve all
$REPO_BASE_DIR/scripts/approve-packages.sh --auto-approve
\`\`\`

### 4. List Available Packages
\`\`\`bash
$REPO_BASE_DIR/scripts/list-packages.sh
\`\`\`

### 5. Exclude Packages
\`\`\`bash
$REPO_BASE_DIR/scripts/exclude-package.sh <package-name>
\`\`\`

## Client Configuration

### Debian/Ubuntu Clients

1. **Disable official repositories** (optional but recommended):
\`\`\`bash
sudo mv /etc/apt/sources.list /etc/apt/sources.list.backup
\`\`\`

2. **Copy the local repo configuration**:
\`\`\`bash
sudo wget http://$SERVER_IP:$WEB_PORT/config/localrepo.list -O /etc/apt/sources.list.d/localrepo.list
\`\`\`

3. **Update package cache**:
\`\`\`bash
sudo apt update
\`\`\`

### RHEL/CentOS/Fedora Clients

1. **Disable official repositories** (optional):
\`\`\`bash
sudo mkdir -p /etc/yum.repos.d/backup
sudo mv /etc/yum.repos.d/*.repo /etc/yum.repos.d/backup/
\`\`\`

2. **Copy the local repo configuration**:
\`\`\`bash
sudo wget http://$SERVER_IP:$WEB_PORT/config/localrepo.repo -O /etc/yum.repos.d/localrepo.repo
\`\`\`

3. **Clear cache and update**:
\`\`\`bash
sudo dnf clean all
sudo dnf makecache
# or for yum:
sudo yum clean all
sudo yum makecache
\`\`\`

## Network Ports

| Port | Service | Purpose |
|------|---------|---------|
| $WEB_PORT | Nginx | Repository HTTP server |

## Automatic Sync Schedule

- **Frequency**: Daily
- **Time**: ${SYNC_HOUR}:00 AM
- **Cron Job**: \`0 $SYNC_HOUR * * * $REPO_BASE_DIR/scripts/sync-mirror.sh\`

## Web Interface

Access the repository browser at: http://$SERVER_IP:$WEB_PORT/

- Mirror packages: http://$SERVER_IP:$WEB_PORT/mirror/
- Approved packages: http://$SERVER_IP:$WEB_PORT/approved/

## Security Recommendations

1. **Use firewall**: Only allow $WEB_PORT from trusted networks
2. **Enable HTTPS**: Configure SSL/TLS for nginx
3. **Authentication**: Add basic auth to nginx config
4. **Package verification**: Always review packages before approval

## Workflow

1. **Sync**: Download packages from official repos → \`mirror/\`
2. **Review**: Check new packages → \`scripts/check-updates.sh\`
3. **Approve**: Move approved packages → \`approved/\`
4. **Serve**: Clients install from \`approved/\` via nginx

## Troubleshooting

### Check nginx status:
\`\`\`bash
sudo systemctl status nginx
\`\`\`

### View sync logs:
\`\`\`bash
ls -lah $REPO_BASE_DIR/logs/
\`\`\`

### Test repository access:
\`\`\`bash
curl http://$SERVER_IP:$WEB_PORT/
\`\`\`

### Verify cron job:
\`\`\`bash
crontab -l | grep sync-mirror
\`\`\`

## Manual Package Control

To only allow specific packages:

1. Create package whitelist:
\`\`\`bash
echo "package1" >> $REPO_BASE_DIR/config/allowed-packages.txt
echo "package2" >> $REPO_BASE_DIR/config/allowed-packages.txt
\`\`\`

2. Create exclusion list:
\`\`\`bash
$REPO_BASE_DIR/scripts/exclude-package.sh unwanted-package
\`\`\`

3. Review before approval:
\`\`\`bash
$REPO_BASE_DIR/scripts/approve-packages.sh
# Review the output, then manually rsync specific packages
\`\`\`

## Support

Log files location: \`$REPO_BASE_DIR/logs/\`
Configuration files: \`$REPO_BASE_DIR/config/\`
EOF
    
    print_success "Documentation generated: $REPO_BASE_DIR/README.md"
}

#######################################################################
# Print Final Summary
#######################################################################

print_summary() {
    print_header "Installation Complete!"
    
    echo ""
    echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}  Local Repository Server Successfully Installed!${NC}"
    echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "${BLUE}Server Information:${NC}"
    echo "  • Server IP: $SERVER_IP"
    echo "  • Web Port: $WEB_PORT"
    echo "  • Repository URL: http://$SERVER_IP:$WEB_PORT/"
    echo "  • Base Directory: $REPO_BASE_DIR"
    echo ""
    echo -e "${BLUE}Quick Start:${NC}"
    echo "  1. Initial sync:"
    echo "     $REPO_BASE_DIR/scripts/sync-mirror.sh"
    echo ""
    echo "  2. Approve packages:"
    echo "     $REPO_BASE_DIR/scripts/approve-packages.sh --auto-approve"
    echo ""
    echo "  3. Configure clients:"
    if [ "$DISTRO_TYPE" = "debian" ]; then
        echo "     wget http://$SERVER_IP:$WEB_PORT/config/localrepo.list"
        echo "     sudo mv localrepo.list /etc/apt/sources.list.d/"
        echo "     sudo apt update"
    else
        echo "     wget http://$SERVER_IP:$WEB_PORT/config/localrepo.repo"
        echo "     sudo mv localrepo.repo /etc/yum.repos.d/"
        echo "     sudo dnf clean all && sudo dnf makecache"
    fi
    echo ""
    echo -e "${BLUE}Management Scripts:${NC}"
    echo "  • Check updates: $REPO_BASE_DIR/scripts/check-updates.sh"
    echo "  • List packages: $REPO_BASE_DIR/scripts/list-packages.sh"
    echo "  • Exclude package: $REPO_BASE_DIR/scripts/exclude-package.sh <name>"
    echo ""
    echo -e "${BLUE}Documentation:${NC}"
    echo "  • Full guide: $REPO_BASE_DIR/README.md"
    echo "  • Log location: $REPO_BASE_DIR/logs/"
    echo ""
    echo -e "${YELLOW}Next Steps:${NC}"
    echo "  1. Run initial sync (may take several hours)"
    echo "  2. Review and approve packages"
    echo "  3. Configure client machines"
    echo "  4. Test package installation from clients"
    echo ""
    echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
}

#######################################################################
# Main Installation Flow
#######################################################################

main() {
    clear
    print_header "Local Repository Server Installation"
    
    # Check if running as root
    if [ "$EUID" -ne 0 ]; then
        print_error "Please run as root (sudo)"
        exit 1
    fi
    
    # Execute installation steps
    detect_distro
    create_directory_structure
    
    if [ "$DISTRO_TYPE" = "debian" ]; then
        install_debian_packages
        configure_apt_mirror
    else
        install_rhel_packages
        configure_createrepo
    fi
    
    configure_nginx
    create_sync_script
    create_approval_script
    create_update_check_script
    create_management_scripts
    setup_cron
    generate_client_configs
    configure_firewall
    generate_documentation
    
    print_summary
}

# Run main installation
main


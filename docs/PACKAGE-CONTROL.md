# Advanced Package Control & Approval Workflow

## Package Control Philosophy

This local repository system gives you **100% manual control** over what packages can be installed on your infrastructure. The workflow follows a strict three-stage process:

```
Official Repos → [MIRROR] → [REVIEW] → [APPROVED] → Clients
```

## Workflow Stages

### Stage 1: Mirror (Automatic)
- Downloads packages from official repositories
- Location: `/var/mirroret/mirror/`
- Runs automatically via cron (daily at 2 AM)
- No client access to this directory

### Stage 2: Review (Manual)
- Administrator reviews new packages
- Compare versions, check changelogs
- Decide which packages to approve
- Can test packages in isolated environment

### Stage 3: Approved (Serve to Clients)
- Only approved packages available here
- Location: `/var/mirroret/approved/`
- Served via nginx on port 8080
- Clients can only install from here

## Manual Approval Workflow

### Option 1: Selective Package Approval

```bash
#!/bin/bash
# Advanced selective approval script

MIRROR_DIR="/var/mirroret/mirror"
APPROVED_DIR="/var/mirroret/approved"
STAGING_DIR="/var/mirroret/staging"

# 1. Find new packages
echo "=== New Packages Available ==="
find "$MIRROR_DIR" -name "*.deb" -newer "$APPROVED_DIR" -o -name "*.rpm" -newer "$APPROVED_DIR"

# 2. Review specific package
PKG_NAME="nginx"

# For Debian/Ubuntu
find "$MIRROR_DIR" -name "${PKG_NAME}*.deb" -exec dpkg-deb -I {} \;

# For RHEL/CentOS
find "$MIRROR_DIR" -name "${PKG_NAME}*.rpm" -exec rpm -qip {} \;

# 3. Stage package for testing
find "$MIRROR_DIR" -name "${PKG_NAME}*.deb" -exec cp {} "$STAGING_DIR/" \;

# 4. Test package in isolated VM
# ... run tests ...

# 5. Approve package
find "$STAGING_DIR" -name "${PKG_NAME}*.deb" -exec mv {} "$APPROVED_DIR/" \;

# 6. Update repository metadata
if [ -f /etc/debian_version ]; then
    cd "$APPROVED_DIR"
    dpkg-scanpackages . /dev/null | gzip -9c > Packages.gz
else
    createrepo --update "$APPROVED_DIR"
fi
```

### Option 2: Version-Specific Approval

```bash
#!/bin/bash
# Approve only specific versions

PACKAGE="docker-ce"
APPROVED_VERSION="24.0.7"
MIRROR_DIR="/var/mirroret/mirror"
APPROVED_DIR="/var/mirroret/approved"

# Find exact version
if [ -f /etc/debian_version ]; then
    # Debian/Ubuntu
    PACKAGE_FILE=$(find "$MIRROR_DIR" -name "${PACKAGE}_${APPROVED_VERSION}*.deb" | head -1)
else
    # RHEL/CentOS
    PACKAGE_FILE=$(find "$MIRROR_DIR" -name "${PACKAGE}-${APPROVED_VERSION}*.rpm" | head -1)
fi

if [ -n "$PACKAGE_FILE" ]; then
    echo "Approving: $PACKAGE_FILE"
    cp "$PACKAGE_FILE" "$APPROVED_DIR/"
    
    # Update metadata
    if [ -f /etc/debian_version ]; then
        cd "$APPROVED_DIR"
        dpkg-scanpackages . /dev/null | gzip -9c > Packages.gz
    else
        createrepo --update "$APPROVED_DIR"
    fi
else
    echo "Package version not found!"
fi
```

### Option 3: Whitelist-Based Approval

```bash
#!/bin/bash
# Approve only packages from whitelist

WHITELIST="/var/mirroret/config/approved-packages.txt"
MIRROR_DIR="/var/mirroret/mirror"
APPROVED_DIR="/var/mirroret/approved"

# Create whitelist file
cat > "$WHITELIST" << EOF
nginx
curl
wget
vim
htop
git
python3
openssh-server
ufw
fail2ban
EOF

# Approve whitelisted packages
while read -r package; do
    echo "Processing: $package"
    
    if [ -f /etc/debian_version ]; then
        find "$MIRROR_DIR" -name "${package}_*.deb" -exec cp {} "$APPROVED_DIR/" \;
    else
        find "$MIRROR_DIR" -name "${package}-*.rpm" -exec cp {} "$APPROVED_DIR/" \;
    fi
done < "$WHITELIST"

# Update repository metadata
if [ -f /etc/debian_version ]; then
    cd "$APPROVED_DIR"
    dpkg-scanpackages . /dev/null | gzip -9c > Packages.gz
    dpkg-scanpackages . /dev/null > Packages
else
    createrepo --update "$APPROVED_DIR"
fi

echo "Whitelist-based approval complete!"
```

## Package Exclusion System

### Create Comprehensive Blacklist

```bash
#!/bin/bash
# /var/mirroret/scripts/manage-blacklist.sh

BLACKLIST="/var/mirroret/config/blacklist-packages.txt"
MIRROR_DIR="/var/mirroret/mirror"

# Initialize blacklist
cat > "$BLACKLIST" << EOF
# Packages to never approve
# Security risks or unwanted software

# Desktop environments (for server)
gnome*
kde*
xfce*

# Games
0ad*
chess*
solitaire*

# Development tools (if not needed)
# gcc
# make

# Risky packages
telnet
rsh-server
finger

# Old/deprecated
python2*
EOF

# Function to remove blacklisted packages from mirror
remove_blacklisted() {
    echo "Removing blacklisted packages from mirror..."
    
    while read -r pattern; do
        # Skip comments and empty lines
        [[ "$pattern" =~ ^#.*$ ]] && continue
        [[ -z "$pattern" ]] && continue
        
        echo "  Removing: $pattern"
        find "$MIRROR_DIR" -name "${pattern}*.deb" -delete 2>/dev/null
        find "$MIRROR_DIR" -name "${pattern}*.rpm" -delete 2>/dev/null
    done < "$BLACKLIST"
    
    echo "Cleanup complete!"
}

# Run cleanup
remove_blacklisted
```

### apt-mirror Configuration with Exclusions

```bash
# Edit /etc/apt/mirror.list

# Add package exclusions
set base_path    /var/mirroret/mirror
set mirror_path  $base_path/mirror
set skel_path    $base_path/skel
set var_path     $base_path/var

# Exclude packages by pattern
# Note: apt-mirror doesn't support exclusions directly
# Use post-mirror script instead

set postmirror_script $var_path/postmirror.sh
set run_postmirror 1
```

Create `/var/mirroret/mirror/var/postmirror.sh`:
```bash
#!/bin/bash

BLACKLIST="/var/mirroret/config/blacklist-packages.txt"
MIRROR_DIR="/var/mirroret/mirror/mirror"

# Remove blacklisted packages after sync
while read -r pattern; do
    [[ "$pattern" =~ ^#.*$ ]] && continue
    [[ -z "$pattern" ]] && continue
    
    find "$MIRROR_DIR" -name "${pattern}*.deb" -delete
done < "$BLACKLIST"

echo "Blacklisted packages removed"
```

## Update Preview & Comparison

### Script to Show Available Updates

```bash
#!/bin/bash
# /var/mirroret/scripts/show-updates.sh

MIRROR_DIR="/var/mirroret/mirror"
APPROVED_DIR="/var/mirroret/approved"

echo "════════════════════════════════════════════════════════"
echo "  Available Updates - Package Comparison"
echo "════════════════════════════════════════════════════════"
echo ""

if [ -f /etc/debian_version ]; then
    # Debian/Ubuntu comparison
    echo "Package Name                Current (Approved)        New (Mirror)"
    echo "────────────────────────────────────────────────────────────────"
    
    # Get packages from both locations
    APPROVED_PKGS=$(find "$APPROVED_DIR" -name "*.deb" -exec dpkg-deb -f {} Package,Version \; | sort)
    MIRROR_PKGS=$(find "$MIRROR_DIR" -name "*.deb" -exec dpkg-deb -f {} Package,Version \; | sort)
    
    # Compare versions
    comm -3 <(echo "$APPROVED_PKGS") <(echo "$MIRROR_PKGS") | while read -r line; do
        echo "$line"
    done
else
    # RHEL/CentOS comparison
    echo "Package Name                Current (Approved)        New (Mirror)"
    echo "────────────────────────────────────────────────────────────────"
    
    APPROVED_PKGS=$(find "$APPROVED_DIR" -name "*.rpm" -exec rpm -qp --queryformat '%{NAME} %{VERSION}-%{RELEASE}\n' {} \; 2>/dev/null | sort)
    MIRROR_PKGS=$(find "$MIRROR_DIR" -name "*.rpm" -exec rpm -qp --queryformat '%{NAME} %{VERSION}-%{RELEASE}\n' {} \; 2>/dev/null | sort)
    
    comm -3 <(echo "$APPROVED_PKGS") <(echo "$MIRROR_PKGS") | while read -r line; do
        echo "$line"
    done
fi

echo ""
echo "════════════════════════════════════════════════════════"
```

### Detailed Package Information

```bash
#!/bin/bash
# /var/mirroret/scripts/package-info.sh

PACKAGE_NAME="$1"
MIRROR_DIR="/var/mirroret/mirror"

if [ -z "$PACKAGE_NAME" ]; then
    echo "Usage: $0 <package-name>"
    exit 1
fi

echo "════════════════════════════════════════════════════════"
echo "  Package Information: $PACKAGE_NAME"
echo "════════════════════════════════════════════════════════"
echo ""

if [ -f /etc/debian_version ]; then
    # Debian/Ubuntu
    PKG_FILE=$(find "$MIRROR_DIR" -name "${PACKAGE_NAME}_*.deb" | head -1)
    
    if [ -n "$PKG_FILE" ]; then
        echo "Package File: $PKG_FILE"
        echo ""
        echo "--- Package Control Info ---"
        dpkg-deb -I "$PKG_FILE"
        echo ""
        echo "--- Package Contents ---"
        dpkg-deb -c "$PKG_FILE" | head -20
        echo "... (showing first 20 files)"
    else
        echo "Package not found!"
    fi
else
    # RHEL/CentOS
    PKG_FILE=$(find "$MIRROR_DIR" -name "${PACKAGE_NAME}-*.rpm" | head -1)
    
    if [ -n "$PKG_FILE" ]; then
        echo "Package File: $PKG_FILE"
        echo ""
        echo "--- Package Info ---"
        rpm -qip "$PKG_FILE"
        echo ""
        echo "--- Package Contents ---"
        rpm -qlp "$PKG_FILE" 2>/dev/null | head -20
        echo "... (showing first 20 files)"
        echo ""
        echo "--- Dependencies ---"
        rpm -qRp "$PKG_FILE" 2>/dev/null
    else
        echo "Package not found!"
    fi
fi

echo ""
echo "════════════════════════════════════════════════════════"
```

## Security-First Approval Workflow

### Security Update Detection

```bash
#!/bin/bash
# /var/mirroret/scripts/detect-security-updates.sh

MIRROR_DIR="/var/mirroret/mirror"
LOG_FILE="/var/mirroret/logs/security-updates-$(date +%Y%m%d).log"

echo "Security Update Detection - $(date)" > "$LOG_FILE"
echo "══════════════════════════════════════════════════════" >> "$LOG_FILE"
echo "" >> "$LOG_FILE"

if [ -f /etc/debian_version ]; then
    # Check for security updates (Ubuntu/Debian)
    find "$MIRROR_DIR" -path "*/ubuntu/dists/*/security/*" -name "*.deb" -mtime -1 | \
        while read -r pkg; do
            echo "SECURITY UPDATE: $(basename $pkg)" | tee -a "$LOG_FILE"
            dpkg-deb -f "$pkg" Package,Version,Description | tee -a "$LOG_FILE"
            echo "---" | tee -a "$LOG_FILE"
        done
else
    # Check for security updates (RHEL/CentOS)
    # Look for packages from security repos
    find "$MIRROR_DIR" -name "*-security-*.rpm" -mtime -1 | \
        while read -r pkg; do
            echo "SECURITY UPDATE: $(basename $pkg)" | tee -a "$LOG_FILE"
            rpm -qip "$pkg" 2>/dev/null | grep -E "Name|Version|Summary" | tee -a "$LOG_FILE"
            echo "---" | tee -a "$LOG_FILE"
        done
fi

echo "" >> "$LOG_FILE"
echo "Log saved to: $LOG_FILE"

# Send email notification (optional)
if command -v mail &> /dev/null; then
    mail -s "Security Updates Available" root < "$LOG_FILE"
fi
```

### CVE Tracking Integration

```bash
#!/bin/bash
# /var/mirroret/scripts/check-cve.sh

PACKAGE_NAME="$1"

if [ -z "$PACKAGE_NAME" ]; then
    echo "Usage: $0 <package-name>"
    exit 1
fi

echo "Checking CVEs for: $PACKAGE_NAME"
echo "══════════════════════════════════════════════════════"

# Ubuntu Security Notices
if [ -f /etc/debian_version ]; then
    echo "Checking Ubuntu Security Notices..."
    curl -s "https://ubuntu.com/security/cves?package=$PACKAGE_NAME" | \
        grep -A 5 "CVE-" | head -30
fi

# Red Hat Security Advisories
if [ -f /etc/redhat-release ]; then
    echo "Checking Red Hat Security Advisories..."
    # This would integrate with Red Hat Security API
    # Example: Check for advisories
fi

echo ""
echo "Manual verification recommended at:"
echo "  - https://cve.mitre.org/"
echo "  - https://nvd.nist.gov/"
```

## Testing Environment Setup

### Isolated Testing with Docker

```bash
#!/bin/bash
# /var/mirroret/scripts/test-package-docker.sh

PACKAGE_NAME="$1"
DISTRO="${2:-ubuntu:22.04}"

if [ -z "$PACKAGE_NAME" ]; then
    echo "Usage: $0 <package-name> [distro-image]"
    exit 1
fi

REPO_SERVER=$(hostname -I | awk '{print $1}')
REPO_PORT="8080"

echo "Testing $PACKAGE_NAME in isolated Docker container..."

# Create Dockerfile
cat > /tmp/test-package.Dockerfile << EOF
FROM $DISTRO

RUN if [ -f /etc/debian_version ]; then \\
        echo "deb [trusted=yes] http://${REPO_SERVER}:${REPO_PORT}/staging jammy main" > /etc/apt/sources.list.d/test.list && \\
        apt-get update && \\
        apt-get install -y $PACKAGE_NAME; \\
    else \\
        echo -e "[test-repo]\nname=Test\nbaseurl=http://${REPO_SERVER}:${REPO_PORT}/staging\nenabled=1\ngpgcheck=0" > /etc/yum.repos.d/test.repo && \\
        yum install -y $PACKAGE_NAME; \\
    fi

CMD ["/bin/bash"]
EOF

# Build and run
docker build -f /tmp/test-package.Dockerfile -t test-$PACKAGE_NAME .
docker run -it --rm test-$PACKAGE_NAME

echo "Test complete!"
```

## Automated Approval Rules

### Rule-Based Auto-Approval

```bash
#!/bin/bash
# /var/mirroret/scripts/auto-approve-rules.sh

RULES_FILE="/var/mirroret/config/approval-rules.conf"
MIRROR_DIR="/var/mirroret/mirror"
APPROVED_DIR="/var/mirroret/approved"

# Create rules configuration
cat > "$RULES_FILE" << EOF
# Auto-approval rules
# Format: RULE_TYPE:PACKAGE_PATTERN:CONDITION

# Always approve security updates
SECURITY:*:security
SECURITY:*:CVE-

# Auto-approve minor version updates
MINOR_UPDATE:nginx:patch
MINOR_UPDATE:curl:patch

# Require manual approval for major updates
MANUAL:kernel:major
MANUAL:systemd:major
MANUAL:glibc:*

# Auto-approve from trusted maintainers
TRUSTED:*:canonical
TRUSTED:*:redhat

# Blacklist
DENY:telnet:*
DENY:*-debuginfo:*
EOF

# Process rules
process_rules() {
    local pkg_file="$1"
    local pkg_name=$(basename "$pkg_file" | sed 's/_.*//; s/-[0-9].*//')
    
    # Check each rule
    while IFS=: read -r rule_type pattern condition; do
        # Skip comments
        [[ "$rule_type" =~ ^#.*$ ]] && continue
        
        case "$rule_type" in
            SECURITY)
                if echo "$pkg_file" | grep -q "security"; then
                    echo "AUTO-APPROVE (Security): $pkg_name"
                    cp "$pkg_file" "$APPROVED_DIR/"
                    return 0
                fi
                ;;
            DENY)
                if [[ "$pkg_name" == $pattern ]]; then
                    echo "DENIED: $pkg_name"
                    return 1
                fi
                ;;
            MANUAL)
                if [[ "$pkg_name" == $pattern ]]; then
                    echo "MANUAL REVIEW REQUIRED: $pkg_name"
                    # Add to review queue
                    echo "$pkg_file" >> /var/mirroret/logs/manual-review-queue.txt
                    return 1
                fi
                ;;
        esac
    done < "$RULES_FILE"
    
    # Default: require manual approval
    echo "DEFAULT - Manual review: $pkg_name"
    return 1
}

# Process all new packages
find "$MIRROR_DIR" -name "*.deb" -o -name "*.rpm" | while read -r pkg; do
    process_rules "$pkg"
done
```

## Rollback System

### Package Version Rollback

```bash
#!/bin/bash
# /var/mirroret/scripts/rollback-package.sh

PACKAGE_NAME="$1"
VERSION="$2"
APPROVED_DIR="/var/mirroret/approved"
ARCHIVE_DIR="/var/mirroret/archive"

if [ -z "$PACKAGE_NAME" ] || [ -z "$VERSION" ]; then
    echo "Usage: $0 <package-name> <version>"
    exit 1
fi

echo "Rolling back $PACKAGE_NAME to version $VERSION"

# Find old version in archive
if [ -f /etc/debian_version ]; then
    OLD_PKG=$(find "$ARCHIVE_DIR" -name "${PACKAGE_NAME}_${VERSION}*.deb" | head -1)
    CURRENT_PKG=$(find "$APPROVED_DIR" -name "${PACKAGE_NAME}_*.deb" | head -1)
else
    OLD_PKG=$(find "$ARCHIVE_DIR" -name "${PACKAGE_NAME}-${VERSION}*.rpm" | head -1)
    CURRENT_PKG=$(find "$APPROVED_DIR" -name "${PACKAGE_NAME}-*.rpm" | head -1)
fi

if [ -z "$OLD_PKG" ]; then
    echo "Error: Version $VERSION not found in archive!"
    exit 1
fi

# Backup current version
mkdir -p "$ARCHIVE_DIR/rollback-$(date +%Y%m%d)"
mv "$CURRENT_PKG" "$ARCHIVE_DIR/rollback-$(date +%Y%m%d)/"

# Restore old version
cp "$OLD_PKG" "$APPROVED_DIR/"

# Update repository metadata
if [ -f /etc/debian_version ]; then
    cd "$APPROVED_DIR"
    dpkg-scanpackages . /dev/null | gzip -9c > Packages.gz
else
    createrepo --update "$APPROVED_DIR"
fi

echo "Rollback complete! Clients can now downgrade to version $VERSION"
```

This advanced control system ensures maximum security and stability!

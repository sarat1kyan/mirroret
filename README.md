
---

# 🪞 **MIRRORET**

### *Enterprise-Grade Local Repository & Package Control System*

> **Take full control over every package in your infrastructure.**
> MIRRORET gives you a **secure, auditable, and centralized package repository** for all major Linux distributions.

---

## 🚀 **Overview**

**MIRRORET** is a **production-ready Local Repository Server** that gives you **100% manual control** over package deployments across your Linux infrastructure.

✔ Supports **Debian / Ubuntu / RHEL / CentOS / Fedora**

✔ Prevents unauthorized package installations

✔ Fully auditable **approval workflow**

✔ Designed for **security, compliance & forensics**

✔ Built for **enterprise-grade DevOps** and **air-gapped environments**

---

## 🔥 **Key Features**

| Feature                          | Description                             |
| -------------------------------- | --------------------------------------- |
| 🔐 **Total Manual Control**      | Approve every package before deployment |
| 🌍 **Multi-Distro Support**      | Debian, Ubuntu, RHEL, CentOS, Fedora    |
| 🛡 **Security-First Design**     | CVE checks, audits, rollback support    |
| 🔄 **Automated Syncing**         | Daily sync from official repositories   |
| 🌐 **Web Interface (Port 8080)** | Nginx-based package access              |
| 📦 **Approval Workflow**         | Mirror → Review → Approve → Deploy      |
| 📛 **Blacklist/Whitelist**       | Block or restrict unwanted packages     |
| ↩ **Rollback Support**           | Restore previous versions instantly     |
| 🧪 **Testing Environment**       | Isolated testing before approval        |

---

## 📁 **Included Files**

| File                           | Purpose                                   |
| ------------------------------ | ----------------------------------------- |
| `mirroret.sh` | Main installation script (run first)      |
| `NETWORK-ARCHITECTURE.md`      | Ports, topology & client setup            |
| `PACKAGE-CONTROL.md`           | Security, approvals & rollback procedures |
| `DIRECTORY-STRUCTURE.md`       | Repo layout & quick setup                 |
| `README.md`                    | Overview and documentation (this file)    |

---

## ⚡ **Quick Start – 5 Steps**

### 1️⃣ Install MIRRORET Server

```bash
git clone https://github.com/sarat1kyan/mirroret.git
chmod +x mirroret.sh
sudo ./mirroret.sh   # Run as root
```

### 2️⃣ First Sync (2–8 hours)

```bash
sudo /var/mirroret/scripts/sync-mirror.sh
tail -f /var/mirroret/logs/sync-*.log
```

### 3️⃣ Approve Packages

```bash
sudo /var/mirroret/scripts/approve-packages.sh --auto-approve
# OR
sudo /var/mirroret/scripts/show-updates.sh
```

### 4️⃣ Configure Clients

**Ubuntu/Debian**

```bash
REPO_SERVER="192.168.1.100"
wget http://${REPO_SERVER}:8080/config/localrepo.list
sudo mv localrepo.list /etc/apt/sources.list.d/
sudo apt update
```

**RHEL/CentOS/Fedora**

```bash
REPO_SERVER="192.168.1.100"
wget http://${REPO_SERVER}:8080/config/localrepo.repo
sudo mv localrepo.repo /etc/yum.repos.d/
sudo dnf clean all && sudo dnf makecache
```

### 5️⃣ Test Access

```bash
sudo apt install htop    # Debian/Ubuntu
sudo dnf install htop    # RHEL/CentOS
```

---

## 🧠 **System Architecture**

```text
                      MIRRORET SERVER

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
    ┌────────┐        ┌────────┐        ┌────────┐
    │ Ubuntu │        │ CentOS │        │ Debian │
    └────────┘        └────────┘        └────────┘
```

---

## 🛠 **Management Commands**

### 🗓 Daily Operations

```bash
/var/mirroret/scripts/check-updates.sh
/var/mirroret/scripts/approve-packages.sh
/var/mirroret/scripts/list-packages.sh
/var/mirroret/scripts/sync-mirror.sh
```

### 🔍 Package Control

```bash
/var/mirroret/scripts/package-info.sh nginx
/var/mirroret/scripts/exclude-package.sh telnet
/var/mirroret/scripts/detect-security-updates.sh
/var/mirroret/scripts/rollback-package.sh nginx 1.18.0
```

### 📊 Monitoring

```bash
sudo systemctl status nginx
tail -f /var/mirroret/logs/sync-*.log
df -h /var/mirroret
tail -f /var/log/nginx/mirroret-access.log
```

---

## 📂 **Directory Structure**

```text
/var/mirroret/
├── mirror/          # Raw mirrored packages
├── approved/        # Client-accessible packages
├── staging/         # Testing area
├── archive/         # Historical versions
├── logs/            # Sync & system logs
├── scripts/         # Management scripts
└── config/          # Config files
```

---

## 🔐 **Security Features**

### 📌 Approval Pipeline

```
Official Repo → Mirror → Manual Review → Approved → Clients
```

### ⚠ Detect Security Updates

```bash
/var/mirroret/scripts/detect-security-updates.sh
/var/mirroret/scripts/check-cve.sh package-name
```

### 🧱 Blacklist / Whitelist Control

```bash
echo "nginx curl wget git" > /var/mirroret/config/approved-packages.txt
echo "telnet rsh-server" > /var/mirroret/config/blacklist-packages.txt
```

### 🧪 Test in Docker

```bash
/var/mirroret/scripts/test-package-docker.sh package-name
```

---

## 🌐 **Network Configuration**

| Port | Service | Purpose            |
| ---- | ------- | ------------------ |
| 8080 | Nginx   | Client repo access |
| 22   | SSH     | Server management  |

#### 🔥 Firewall Rules

```bash
# Debian/Ubuntu
sudo ufw allow from 192.168.1.0/24 to any port 8080

# RHEL/CentOS
sudo firewall-cmd --permanent --add-rich-rule='rule family="ipv4" source address="192.168.1.0/24" port port="8080" protocol="tcp" accept'
sudo firewall-cmd --reload
```

---

## 🔄 **Automatic Sync Schedule**

```bash
crontab -l | grep sync-mirror
crontab -e      # Change sync time
```

---

## 🧰 **Typical Workflows**

### ☀ Daily Approval (5 min)

```bash
tail -50 /var/mirroret/logs/sync-*.log
/var/mirroret/scripts/detect-security-updates.sh
/var/mirroret/scripts/approve-packages.sh
```

### 🆕 New Client Setup

```bash
wget http://REPO_IP:8080/config/localrepo.list
sudo mv localrepo.list /etc/apt/sources.list.d/
sudo apt update && sudo apt install htop
```

### 🚨 Emergency Rollback

```bash
/var/mirroret/scripts/rollback-package.sh nginx 1.18.0
```

---

## 📜 **License & Credits**

**MIRRORET** — A professional DevOps solution for secure enterprise package management.

| Field            | Info                            |
| ---------------- | ------------------------------- |
| **Author**       | Mher Saratikyan                 |
| **Version**      | 1.5.2                           |
| **Last Updated** | 2025                            |
| **License**      | MIT                             |

---

## 🙏 Acknowledgments

**⭐ Star this repo if you found it helpful!**
[![BuyMeACoffee](https://raw.githubusercontent.com/pachadotdev/buymeacoffee-badges/main/bmc-donate-yellow.svg)](https://www.buymeacoffee.com/saratikyan)
[![Report Bug](https://img.shields.io/badge/Report-Bug-red.svg)](https://github.com/sarat1kyan/mirroret/issues)

> **Note**: Always test management commands in staging before production use.


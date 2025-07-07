# MirrorMaster 🪞✨

**Transform any Linux machine into a powerful repository mirroring system with this elegant and efficient bash solution!**

```bash

╔════════════════════════┤ Version v1.3 ├══════════════════════════╗
║ ███╗   ███╗██╗██████╗ ██████╗  ██████╗ ██████╗ ███████╗████████╗ ║
║ ████╗ ████║██║██╔══██╗██╔══██╗██╔═══██╗██╔══██╗██╔════╝╚══██╔══╝ ║
║ ██╔████╔██║██║██████╔╝██████╔╝██║   ██║██████╔╝█████╗     ██║    ║
║ ██║╚██╔╝██║██║██╔══██╗██╔══██╗██║   ██║██╔══██╗██╔══╝     ██║    ║
║ ██║ ╚═╝ ██║██║██║  ██║██║  ██║╚██████╔╝██║  ██║███████╗   ██║    ║
║ ╚═╝     ╚═╝╚═╝╚═╝  ╚═╝╚═╝  ╚═╝ ╚═════╝ ╚═╝  ╚═╝╚══════╝   ╚═╝    ║
║                 Enterprise Repository Management                 ║
╚══════════════════════════════════════════════════════════════════╝
```

[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](https://www.gnu.org/licenses/gpl-3.0)
[![Category](https://img.shields.io/badge/category-Software-red.svg)](https://github.com/sarat1kyan/Terminus)
[![Coverage](https://img.shields.io/badge/coverage-100%25-green.svg)](https://github.com/sarat1kyan/Terminus)
[![Compliance](https://img.shields.io/badge/compliance-CIS%20%7C%20ISO27001%20%7C%20NIST%20%7C%20STIG%20%7C%20PCI--DSS-green.svg)](https://github.com/sarat1kyan/Terminus)
[![Build Status](https://img.shields.io/badge/build-Stable%20%7C%20133511-brightgreen.svg)](https://github.com/sarat1kyan/Terminus)
[![OS](https://img.shields.io/badge/os-Linux-blue.svg)](https://www.python.org/downloads/)
[![Bash](https://img.shields.io/badge/bash-blue.svg)](https://www.python.org/downloads/)

## 🌟 Features

- **Multi-protocol Support**: Mirror repositories via `rsync`, `HTTP/HTTPS`, or `FTP`
- **Automated Syncing**: Schedule syncs every 15 min, hourly, daily, or weekly
- **Beautiful TUI**: Intuitive terminal interface with real-time stats
- **Centralized Management**: Add, remove, and configure repositories with ease
- **Comprehensive Logging**: Track access, syncs, and errors
- **Systemd Integration**: Runs as a persistent service
- **Resource Monitoring**: Disk usage and sync statistics

![MirrorMaster TUI Demo]

## 🚀 Installation

1. Clone the repository:
```bash
git clone https://github.com/sarat1kyan/mirrormaster.git
```

2. Make the script executable:
```bash
cd mirrormaster
chmod +x mirrormaster.sh
```

3. Run as root:
```bash
sudo ./mirrormaster.sh
```

## 🛠️ Configuration

The script automatically creates configuration structure:
```
/etc/mirrormaster/
├── repositories/     # Individual repo configs
├── repos.conf        # Main configuration
└── settings.conf     # Global settings

/var/mirrors/         # Mirror storage
/var/log/mirrormaster/ # Log files
```

## ⌨️ Usage

### Main Operations:
```bash
# Start interactive TUI
sudo ./mirrormaster.sh

# Run as background service
sudo ./mirrormaster.sh --service

# Perform manual sync
sudo ./mirrormaster.sh --sync
```

### TUI Features:
- **Repository Management**: Add/remove mirror sources
- **Sync Control**: Manual sync trigger
- **Log Viewer**: Access, sync, and error logs
- **System Stats**: Disk usage and access metrics
- **Scheduling**: Configure sync intervals

## 📊 Logging

Access comprehensive logs in `/var/log/mirrormaster`:
- `access.log`: Repository access history
- `sync.log`: Synchronization details
- `error.log`: Error diagnostics

![Log Viewer Demo]

## 🤝 Contributing

We welcome contributions! Please follow these steps:
1. Fork the repository
2. Create your feature branch (`git checkout -b feature/amazing-feature`)
3. Commit your changes (`git commit -m 'Add amazing feature'`)
4. Push to the branch (`git push origin feature/amazing-feature`)
5. Open a pull request

## 📜 License

Distributed under **DO WHAT THE HELL YOU WANT TO PUBLIC LICENSE**.  
See `LICENSE` for details.

---

**MirrorMaster** - Your lightweight solution for enterprise-grade repository mirroring! ✨  
_Crafted with ❤️ by **Mher Saratikyan** for sysadmins and DevOps engineers_

# 🔄 Backup Proxmox PBS & PVE System Files

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Bash](https://img.shields.io/badge/Bash-4.4+-blue.svg)](https://www.gnu.org/software/bash/)
[![Proxmox](https://img.shields.io/badge/Proxmox-PVE%20%7C%20PBS-green.svg)](https://www.proxmox.com/)
[![💖 Sponsor](https://img.shields.io/badge/Sponsor-GitHub%20Sponsors-pink?logo=github)](https://github.com/sponsors/tis24dev)
[![☕ Buy Me a Coffee](https://img.shields.io/badge/Buy%20Me%20a%20Coffee-tis24dev-yellow?logo=buymeacoffee)](https://buymeacoffee.com/tis24dev)

**Professional backup system for Proxmox Virtual Environment (PVE) and Proxmox Backup Server (PBS) settings and config and critical files** with advanced compression features, multi-storage support, intelligent notifications, and comprehensive monitoring.

---

## 📑 Table of Contents
- [🎯 What does this script do?](#-what-does-this-script-do)
- [✨ Key Features](#-key-features)
- [🚀 Quick Installation](#-quick-installation)
- [⚙️ Configuration](#️-configuration)
- [📊 Project Structure](#-project-structure)
- [🔧 Usage](#-usage)
- [📈 Monitoring](#-monitoring)
- [🛡️ Security](#️-security)
- [📋 System Requirements](#-system-requirements)
- [🤝 Contributing](#-contributing)
- [📄 License](#-license)
- [📞 Support](#-support)
- [🔄 Quick Reference](#-quick-reference)
- [⭐ Stargazers](#-stargazers)

---

**Install or Update or Reinstall (Stable)**
```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/tis24dev/proxmox-backup/main/install.sh)"
```

**Development Version or Reinstall (Latest Features)**
```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/tis24dev/proxmox-backup/main/install.sh)" -- dev
```

---

## 🎯 What does this script do?

This backup system **automatically saves all critical files** from your Proxmox environment, allowing you to completely restore the system in case of disaster recovery or migration.
All options, files to be saved, and script functions are fully configurable and can be enabled or disabled as desired.

### 📂 Files and configurations backed up:

#### **🔧 Proxmox System Configurations**
- **PVE/PBS configurations** - All Proxmox VE and Backup Server configuration files
- **Cluster configurations** - Cluster setup, nodes, quorum, corosync
- **Storage configurations** - All datastores, mount points, remote storage
- **Network configurations** - Interfaces, bridges, VLANs, firewall, routing

#### **🏗️ Virtual Machines and Containers**
- **VM/CT configurations** - All VM and container `.conf` files
- **Templates and snippets** - Custom templates and configuration snippets
- **VZDump configurations** - Backup jobs, schedules, retention policies
- **Replication configurations** - Replication jobs between nodes

#### **🔐 Security and Certificates**
- **SSL/TLS certificates** - Web interface, API, cluster certificates
- **SSH keys** - System public/private keys
- **User configurations** - Users, groups, permissions, authentication
- **Firewall configurations** - Datacenter, node, VM/CT rules

#### **🗄️ Database and Logs**
- **Proxmox database** - Configurations stored in internal database
- **System logs** - Critical logs for troubleshooting
- **Ceph configurations** - Ceph setup (if present)
- **ZFS configurations** - Pools, datasets, snapshot policies

#### **📦 Operating System**
- **Installed package list** - For identical reinstallation
- **Custom configurations** - Modified files in `/etc/`
- **Cron jobs** - Scheduled system tasks
- **Service configurations** - Custom services and modifications

#### 🚨 **Result**: 
With these backups you can **completely restore** your Proxmox system on a new server, maintaining all configurations, VMs, containers and settings exactly as they were!

---

## ✨ Key Features

### 🔄 **Backup and Storage**
- **Multi-location and cloud backups** - Simultaneous backups to local, secondary, and cloud storage
- **Automatic backup rotation** - Intelligent retention management with automatic cleanup
- **Compressed backups with verification** - Advanced compression (xz, zstd, gzip) with integrity verification
- **Preserved file structure** - Original structure maintained for simplified restoration
- **Smart deduplication** - Duplicate elimination with symlinks for space optimization
- **Parallel storage operations** - Simultaneous uploads to multiple storages for maximum speed

### 🔍 **Automatic Detection and Collection**
- **Automatic PVE/PBS detection** - Automatic detection of system type and configurations
- **Automatic datastore discovery** - Automatic discovery of all PVE and PBS datastores
- **Intelligent file collection** - Intelligent collection of critical system files, configurations, backups
- **Customizable backup paths** - Customizable paths for additional files/directories

### 📢 **Notifications and Monitoring**
- **Email notifications** - Detailed email notifications with complete reports
- **Cloud Email Service** - Centralized system to send email notifications
- **Telegram notifications** - Rich Telegram notifications with emoji and formatting
- **Simplified Telegram activation** - Unified Telegram activation with dedicated bot and unique code (10 seconds)
- **Centralized Telegram infrastructure** - Fully functional and expandable for future updates
- **Prometheus metrics** - Complete metrics export for Prometheus/Grafana
- **Advanced logging system** - Detailed multi-level logs with emoji and colors

### 🛡️ **Security and Controls**
- **Security checks** - Security checks on permissions and script file modifications
- **File integrity verification** - Integrity verification with SHA256 checksums and MD5 hashes
- **Network security audit** - Firewall checks, open ports, network configurations
- **Automatic permission management** - Automatic management of file and directory permissions

---

## 🚀 Quick Installation

### Prerequisites
- **Bash 4.4+** (included in all modern distributions)
- **Proxmox VE** or **Proxmox Backup Server**
- **rclone** (for cloud backups, automatic installation available)

### Installation Options

#### 🔄 **Automatic Installation (Recommended)**
*Smart installer that detects existing installations and asks what to do*

**Stable version (main branch):**
```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/tis24dev/proxmox-backup/main/install.sh)"
```

**Development version (dev branch - latest features):**
```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/tis24dev/proxmox-backup/main/install.sh)" -- dev
```

**How it works:**
- 🔍 Automatically detects if an installation exists
- 📋 If found, presents an interactive menu:
  - **[1] Update** - Preserves all your data and settings
  - **[2] Reinstall** - Complete fresh installation (requires typing `REMOVE-EVERYTHING`)
  - **[3] Cancel** - Exit without changes
- 🆕 If no installation exists, proceeds with fresh install automatically

**What is preserved during Update:**
- ✅ Configuration file (`backup.env`)
- ✅ Server identity and security settings
- ✅ Existing backups and logs
- ✅ Custom configurations and credentials
- ✅ Lock files and temporary data

#### 🔁 **Forced Reinstall (Advanced)**
*Skips interactive menu and forces complete removal*

**Stable version (main branch):**
```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/tis24dev/proxmox-backup/main/install.sh)" -- --reinstall
```

**Development version (dev branch):**
```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/tis24dev/proxmox-backup/main/install.sh)" -- --reinstall dev
```

**⚠️ Warning:** This will remove ALL existing data including:
- ❌ Configuration files
- ❌ Backups and logs
- ❌ Server identity
- ❌ All custom settings
- ❌ Cron jobs and symlinks

*Requires typing `REMOVE-EVERYTHING` to confirm*

**When to use --reinstall:**
- You want to start completely from scratch
- You're troubleshooting a corrupted installation
- You're moving to a new server identity
- You want to bypass the interactive menu

#### 📌 **Branch Information**

The installation system supports two branches:

- **main** - Stable, tested releases (recommended for production)
- **dev** - Development branch with latest features (may contain untested code)

The dev branch is useful for testing new features before they are released to the main branch.

**Branch selection works with all modes:**
```bash
# Automatic mode with dev branch
bash -c "$(curl -fsSL .../install.sh)" -- dev

# Forced reinstall with dev branch
bash -c "$(curl -fsSL .../install.sh)" -- --reinstall dev

# Verbose mode for debugging
bash -c "$(curl -fsSL .../install.sh)" -- --verbose
```

#### 📥 **Manual Installation**
```bash
# Clone the repository (main branch - stable)
git clone https://github.com/tis24dev/proxmox-backup.git
cd proxmox-backup

# OR clone dev branch (latest features)
# git clone -b dev https://github.com/tis24dev/proxmox-backup.git
# cd proxmox-backup

# Configure the system
cp env/backup.env.example env/backup.env
nano env/backup.env

# Set correct permissions
chmod +x script/*.sh
chmod 600 env/backup.env

# Run first backup
./script/proxmox-backup.sh
```

---

## ⚙️ Configuration

The system uses a main configuration file (`env/backup.env`) with over **90 configurable options** organized in 9 sections:

- **General system configuration**
- **Main features (enable/disable)**
- **Paths and storage configuration**
- **Compression configuration**
- **Cloud and rclone**
- **Notifications**
- **Prometheus**
- **Users and permissions**
- **Custom configurations**

### Quick Setup After Installation

#### System-wide Commands
```bash
# Quick Telegram setup (10 seconds)
proxmox-backup --telegram-setup

# Test configuration
proxmox-backup --dry-run

# First backup
proxmox-backup
```

#### Installation Method Selection Guide

**Use Default Automatic Mode (Recommended) if:**
- ✅ You want the installer to detect and ask what to do
- ✅ You're not sure if an installation already exists
- ✅ You want to choose between update or reinstall interactively
- ✅ You prefer a guided installation process

**Use --reinstall Flag if:**
- ⚡ You want to force a complete reinstallation without prompts
- ⚡ You're running automated deployment scripts
- ⚡ You know for certain you want a fresh start
- ⚡ You want to bypass all interactive confirmations (except REMOVE-EVERYTHING)

---

## 📊 Project Structure

```
proxmox-backup/
├── script/						# Main executable scripts
│   ├── proxmox-backup.sh		# Main orchestrator
│   ├── security-check.sh		# Security checks
│   ├── fix-permissions.sh		# Permission management
│   └── server-id-manager.sh	# Server identity management
├── lib/						# Modular library system (17 files)
├── env/						# Main configuration
│   └── backup.env				# Configuration file
├── config/						# System configurations
├── backup/						# Generated backup files
├── log/						# System logs
└── secure_account/				# Secure credentials
```

---

## 🔧 Usage

### System Commands (After Installation)
```bash
# Main backup commands
proxmox-backup					# Run backup
proxmox-backup --dry-run		# Test mode
proxmox-backup -v				# Detailed output
proxmox-backup --check-only		# Check configuration only

# Utility commands
proxmox-backup-security			# Security checks
proxmox-backup-permissions		# Fix permissions

# Recovery command
proxmox-restore					# Restore data from backup
```

### Manual Usage (Development)
```bash
# Navigate to installation directory
cd /opt/proxmox-backup

# Complete backup
./script/proxmox-backup.sh

# Test mode (dry-run)
./script/proxmox-backup.sh --dry-run

# Security checks
./script/security-check.sh

# Permission management
./script/fix-permissions.sh

# Restore Data
./script/proxmox-restore.sh
```

---

## 📈 Monitoring

### Prometheus Metrics
The system automatically exports metrics for Prometheus:
- Backup operation duration
- Backup sizes
- Operation status
- Errors and warnings
- Storage usage

### Intelligent Notifications
- **Telegram**: Rich notifications with emoji, formatting and inline buttons
- **Email**: Detailed reports with complete statistics
- **Logs**: Advanced logging system with multiple levels

---

## 🛡️ Security

- **Integrity verification**: SHA256 and MD5 checks on all files
- **Security checks**: Permission verification, firewall, open ports
- **Credential management**: Secure storage of credentials
- **File audit**: Detection of unauthorized or modified files

---

## 📋 System Requirements

### Minimum
- **Bash 4.4+**
- **Proxmox VE** or **Proxmox Backup Server**
- **512MB RAM** (for compression operations)
- **1GB free space** (for temporary backups)

---

## 🤝 Contributing

Contributions are welcome! To contribute:

1. **Fork** the repository  
2. Create a **branch** for your feature (`git checkout -b feature/AmazingFeature`)  
3. **Commit** your changes (`git commit -m 'Add some AmazingFeature'`)  
4. **Push** to the branch (`git push origin feature/AmazingFeature`)  
5. Open a **Pull Request**

---

## 📄 License

This project is distributed under the MIT license. See the `LICENSE` file for more details.

---

## 📞 Support

- **Complete documentation**: See `doc/README.md`
- **Detailed configuration**: See `doc/CONFIGURATION.md`
- **Issues**: Open an issue on GitHub for bugs or feature requests
- **Discussions**: Use GitHub Discussions for general questions

---

## 🔄 Quick Reference

### Installation Commands
```bash
# Automatic installation (detects existing and asks) - RECOMMENDED - Stable
bash -c "$(curl -fsSL https://raw.githubusercontent.com/tis24dev/proxmox-backup/main/install.sh)"

# Automatic installation (detects existing and asks) - Development
bash -c "$(curl -fsSL https://raw.githubusercontent.com/tis24dev/proxmox-backup/main/install.sh)" -- dev

# Verbose mode for debugging - Stable
bash -c "$(curl -fsSL https://raw.githubusercontent.com/tis24dev/proxmox-backup/main/install.sh)" -v
```

### System Commands
```bash
proxmox-backup					# Run backup
proxmox-backup --dry-run		# Test mode
proxmox-backup-security			# Security checks
proxmox-backup-permissions		# Fix permissions
proxmox-restore					# Restore data from backup
```

---

## ⭐ Stargazers

If this project is useful to you, consider giving it a ⭐!

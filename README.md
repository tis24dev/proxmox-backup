# 🔄 Backup Proxmox PBS & PVE System Files

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Bash](https://img.shields.io/badge/Bash-4.4+-blue.svg)](https://www.gnu.org/software/bash/)
[![Proxmox](https://img.shields.io/badge/Proxmox-PVE%20%7C%20PBS-green.svg)](https://www.proxmox.com/)

[![💖 Sponsor](https://img.shields.io/badge/Sponsor-GitHub%20Sponsors-pink?logo=github)](https://github.com/sponsors/tis24dev)
[![☕ Buy Me a Coffee](https://img.shields.io/badge/Buy%20Me%20a%20Coffee-tis24dev-yellow?logo=buymeacoffee)](https://buymeacoffee.com/tis24dev)

**Professional backup system for Proxmox Virtual Environment (PVE) and Proxmox Backup Server (PBS) settings and config and critical files** with advanced compression features, multi-storage support, intelligent notifications, and comprehensive monitoring.


**First Install & Upgrade**
```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/tis24dev/proxmox-backup/main/install.sh)"
```

**Remove & Clean Install**
```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/tis24dev/proxmox-backup/main/new-install.sh)"
```

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
- **Centralized Telegram infrastructure** - Currently running on temporary infrastructure, fully functional but will be expanded in the future. Future expansions should not cause any disruption to existing users.
- **Prometheus metrics** - Complete metrics export for Prometheus/Grafana
- **Advanced logging system** - Detailed multi-level logs with emoji and colors

### 🛡️ **Security and Controls**
- **Security checks** - Security checks on permissions and script file modifications
- **File integrity verification** - Integrity verification with SHA256 checksums and MD5 hashes
- **Network security audit** - Firewall checks, open ports, network configurations
- **Automatic permission management** - Automatic management of file and directory permissions

## 🚀 Quick Installation

### Prerequisites
- **Bash 4.4+** (included in all modern distributions)
- **Proxmox VE** or **Proxmox Backup Server**
- **rclone** (for cloud backups, automatic installation available)

### Installation Options

#### 🔄 **Update Installation (Recommended)**
*Preserves existing configuration, backups, and settings*

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/tis24dev/proxmox-backup/main/install.sh)"
```

**What is preserved:**
- ✅ Configuration file (`backup.env`)
- ✅ Server identity and security settings
- ✅ Existing backups and logs
- ✅ Custom configurations and credentials

#### 🆕 **Fresh Installation**
*Completely removes existing installation and starts fresh*

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/tis24dev/proxmox-backup/main/new-install.sh)"
```

**⚠️ Warning:** This will remove ALL existing data including:
- ❌ Configuration files
- ❌ Backups and logs
- ❌ Server identity
- ❌ All custom settings

*Requires typing `REMOVE-EVERYTHING` to confirm*

#### 📥 **Manual Installation**
```bash
# Clone the repository
git clone https://github.com/tis24dev/proxmox-backup.git
cd proxmox-backup

# Configure the system
cp env/backup.env.example env/backup.env
nano env/backup.env

# Set correct permissions
chmod +x script/*.sh
chmod 600 env/backup.env

# Run first backup
./script/proxmox-backup.sh
```

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

**Choose Update Installation if:**
- ✅ You have an existing installation
- ✅ You want to preserve your configuration
- ✅ You have important backups to maintain
- ✅ You're doing regular updates

**Choose Fresh Installation if:**
- ❌ You want to start completely from scratch
- ❌ You're troubleshooting a corrupted installation
- ❌ You're moving to a new server identity
- ❌ You don't mind losing existing data

## 📊 Project Structure

```
proxmox-backup/
├── script/                 # Main executable scripts
│   ├── proxmox-backup.sh      # Main orchestrator
│   ├── security-check.sh      # Security checks
│   ├── fix-permissions.sh     # Permission management
│   └── server-id-manager.sh   # Server identity management
├── lib/                    # Modular library system (17 files)
├── env/                    # Main configuration
│   └── backup.env          # Configuration file
├── config/                 # System configurations
├── backup/                 # Generated backup files
├── log/                    # System logs
└── secure_account/         # Secure credentials
```

## 🔧 Usage

### System Commands (After Installation)
```bash
# Main backup command
proxmox-backup                 # Run backup
proxmox-backup --dry-run       # Test mode
proxmox-backup --verbose       # Detailed output
proxmox-backup --check-only    # Check configuration only

# Utility commands
proxmox-backup-security        # Security checks
proxmox-backup-permissions     # Fix permissions
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
```

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

## 🛡️ Security

- **Integrity verification**: SHA256 and MD5 checks on all files
- **Security checks**: Permission verification, firewall, open ports
- **Credential management**: Secure storage of credentials
- **File audit**: Detection of unauthorized or modified files

## 📋 System Requirements

### Minimum
- **Bash 4.4+**
- **Proxmox VE** or **Proxmox Backup Server**
- **512MB RAM** (for compression operations)
- **1GB free space** (for temporary backups)

## 🤝 Contributing

Contributions are welcome! To contribute:

1. **Fork** the repository
2. Create a **branch** for your feature (`git checkout -b feature/AmazingFeature`)
3. **Commit** your changes (`git commit -m 'Add some AmazingFeature'`)
4. **Push** to the branch (`git push origin feature/AmazingFeature`)
5. Open a **Pull Request**

## 📄 License

This project is distributed under the MIT license. See the `LICENSE` file for more details.

## 📞 Support

- **Complete documentation**: See `doc/README.md`
- **Detailed configuration**: See `doc/CONFIGURATION.md`
- **Issues**: Open an issue on GitHub for bugs or feature requests
- **Discussions**: Use GitHub Discussions for general questions

## 🔄 Quick Reference

### Installation Commands
```bash
# Update (preserves data) - RECOMMENDED
bash -c "$(curl -fsSL https://raw.githubusercontent.com/tis24dev/proxmox-backup/main/install.sh)"

# Fresh installation (removes everything)
bash -c "$(curl -fsSL https://raw.githubusercontent.com/tis24dev/proxmox-backup/main/new-install.sh)"
```

### System Commands
```bash
proxmox-backup                 # Run backup
proxmox-backup --dry-run       # Test mode
proxmox-backup-security        # Security checks
proxmox-backup-permissions     # Fix permissions
```

## 📝 Changelog and Updates

### 2025-01-10
- **Storage Monitoring**: Introduced the ability to configure custom thresholds for storage space warnings on primary and secondary storage
- **Automatic Configuration**: New installations automatically include the storage monitoring section
- **Smart Updates**: During updates, the system automatically detects if storage monitoring configuration is present and, if missing, inserts it while preserving the original file and creating an automatic backup
- **Configuration**: Added `STORAGE_WARNING_THRESHOLD_PRIMARY` and `STORAGE_WARNING_THRESHOLD_SECONDARY` variables (default: 90%) to customize email warning thresholds
- **Positioning**: Configuration is automatically inserted in the "3. PATHS AND STORAGE CONFIGURATION" section of the `backup.env` file

## ⭐ Stargazers

If this project is useful to you, consider giving it a ⭐!

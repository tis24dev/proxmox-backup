# 🔄 Proxmox Backup System

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Bash](https://img.shields.io/badge/Bash-4.4+-blue.svg)](https://www.gnu.org/software/bash/)
[![Proxmox](https://img.shields.io/badge/Proxmox-PVE%20%7C%20PBS-green.svg)](https://www.proxmox.com/)

**Professional backup system for Proxmox Virtual Environment (PVE) and Proxmox Backup Server (PBS)** with advanced compression features, multi-storage support, intelligent notifications, and comprehensive monitoring.

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

### Installation
```bash
# Clone the repository
git clone https://github.com/tuo-username/proxmox-backup.git
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

### Telegram Configuration (10 seconds)
```bash
# Activate Telegram notifications in 10 seconds
./script/proxmox-backup.sh --telegram-setup
```

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

### Complete Backup
```bash
./script/proxmox-backup.sh
```

### Test Mode (Dry-run)
```bash
./script/proxmox-backup.sh --dry-run
```

### Security Checks
```bash
./script/security-check.sh
```

### Permission Management
```bash
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
- **2GB RAM** (for compression operations)
- **10GB free space** (for temporary backups)

### Recommended
- **4GB+ RAM** (for parallel operations)
- **50GB+ free space** (for multiple backups)
- **Stable internet connection** (for cloud backups)

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

- **Complete documentation**: See `proxmox-backup/README.md`
- **Detailed configuration**: See `proxmox-backup/CONFIGURATION.md`
- **Issues**: Open an issue on GitHub for bugs or feature requests
- **Discussions**: Use GitHub Discussions for general questions

## ⭐ Stargazers

If this project is useful to you, consider giving it a ⭐!

# Proxmox Backup System - Complete Documentation

Professional backup system for Proxmox Virtual Environment (PVE) and Proxmox Backup Server (PBS) with advanced compression features, multi-storage support, intelligent notifications, and comprehensive monitoring.

## Main Features

### 🔄 **Backup and Storage**
- **Multi-location and cloud backups** - Simultaneous backups to local, secondary, and cloud storage
- **Automatic rotation of old backups** - Intelligent retention management with automatic cleanup
- **Compressed backups with verification** - Advanced compression (xz, zstd, gzip) with integrity verification
- **Backups that maintain file structure** - Original structure preserved for simplified restoration
- **Smart deduplication** - Duplicate elimination with symlinks for space optimization
- **Parallel storage operations** - Simultaneous uploads to multiple storages for maximum speed
- **Intelligent retry logic** - Automatic retry with exponential backoff for failed operations

### 🔍 **Automatic Detection and Collection**
- **Automatic PVE/PBS detection** - Automatic detection of system type and configurations
- **Automatic datastore discovery** - Automatic discovery of all PVE and PBS datastores
- **Smart file collection** - Intelligent collection of critical system files, configurations, backups
- **Custom backup paths** - Customizable paths for additional files/directories
- **Configurable blacklist** - Configurable exclusion list for sensitive or temporary files

### 📢 **Notifications and Monitoring**
- **Email notifications** - Detailed email notifications with complete reports
- **Telegram notifications** - Rich Telegram notifications with emoji and formatting
- **Simplified Telegram activation** - Unified Telegram activation with dedicated bot and unique code (10 seconds, multilingual)
- **Custom Telegram API server** - Support for custom Telegram API servers
- **Prometheus metrics export** - Complete metrics export for Prometheus/Grafana
- **Advanced logging system** - Detailed multi-level logs with emoji and colors

### 🛡️ **Security and Controls**
- **Security check on permissions** - Security checks on permissions and script file modifications (deactivatable)
- **File integrity verification** - Integrity verification with SHA256 checksums and MD5 hashes
- **Network security audit** - Firewall checks, open ports, network configurations
- **Automatic permission management** - Automatic management of file and directory permissions
- **Unauthorized file detection** - Detection of unauthorized or modified files

### 📊 **System and Backup Information**
- **Export network parameters** - Complete network parameters export
- **ZFS information export** - Detailed ZFS information collection
- **Installed packages list** - Complete list of installed packages with versions
- **System information collection** - Hardware and system information collection
- **Collection of PBS job information** - Complete PBS job collection (sync, verify, prune)
- **PXAR files analysis** - Analysis and management of PXAR files in PBS datastores
- **PVE cluster configurations** - Complete cluster, VM, container configurations backup
- **Ceph configurations backup** - Complete Ceph configurations backup (if present)

### ⚙️ **Configuration and Management**
- **Separate configuration file** - Separate configuration file for complete customizations
- **90+ configuration options** - Over 90 configurable options organized in 9 sections
- **Dependency check and installation** - Dependency check and automatic installation of missing packages
- **Multiple compression algorithms** - Support for xz, zstd, gzip with optimal automatic selection
- **Bandwidth management** - Bandwidth limitation management for cloud uploads
- **Custom rclone configurations** - Customizable rclone configurations for cloud providers

### 🎯 **Advanced Features**
- **PVE-specific features** - Replication job backup, VZDump, PVE firewall configurations
- **PBS-specific features** - PBS datastore management, sync/verify/prune jobs, certificates
- **Smart chunking** - Intelligent chunking of large files for better compression
- **Prefiltering optimization** - File optimization before compression for performance
- **Multi-threading support** - Multi-thread support for intensive operations
- **Cluster awareness** - Cluster environment support with server identity management
- **API integration** - Proxmox API integration for automatic resource detection

### 🔧 **Operations and Maintenance**
- **Dry-run mode** - Test mode without modifications for configuration verification
- **Verbose logging** - Detailed logs for debugging and monitoring
- **Automatic cleanup** - Automatic cleanup of temporary files and old backups
- **Status tracking** - Operation status tracking and detailed statistics
- **Performance metrics** - Performance metrics with operation duration and throughput
- **Recovery assistance** - Recovery assistance with preserved file structure

---

## 📑 Table of Contents

  - [1. Overview](#1-overview)
  - [2. Project Structure](#2-project-structure)
  - [3. Architecture and Functions](#3-architecture-and-functions)
  - [4. System Configuration (backup.env)](#4-system-configuration-backupenv)
    - [4.1 General System Configuration](#41-general-system-configuration)
    - [4.2 Main Features](#42-main-features---enabledisable)
    - [4.3 Paths and Storage](#43-paths-and-storage-configuration)
    - [4.4 Compression](#44-compression-configuration)
    - [4.5 Cloud and rclone](#45-cloud-and-rclone-configuration)
    - [4.6 Notifications](#46-notifications-configuration)
    - [4.7 Prometheus](#47-prometheus-configuration)
    - [4.8 Users and Permissions](#48-users-and-permissions-configuration)
    - [4.9 Custom Configurations](#49-custom-configurations)
  - [5. Files Subject to Backup](#5-files-subject-to-backup)
    - [5.1 Common Files (PVE and PBS)](#51-common-files-pve-and-pbs)
    - [5.2 PVE Specific Files](#52-pve-specific-files-proxmox-virtual-environment)
    - [5.3 PBS Specific Files](#53-pbs-specific-files-proxmox-backup-server)
    - [5.4 PVE vs PBS Comparison](#54-exclusively-pve-vs-pbs-files)
  - [6. Directory Structure Tree](#6-directory-structure-tree-proxmox-backup)
  - [7. System Usage](#7-system-usage)
  - [8. Monitoring and Notifications](#8-monitoring-and-notifications)
  - [9. Security](#9-security)
  - [10. System Requirements](#10-system-requirements)
  - [11. Troubleshooting](#11-troubleshooting)
  - [12. License and Support](#12-license-and-support)

---

## 1. Overview

This backup system provides comprehensive backup management for **Proxmox Virtual Environment (PVE)** and **Proxmox Backup Server (PBS)** environments. It features:

- **Automatic system detection** (PVE or PBS)
- **Automatic datastore discovery** for all configured storage
- **Multi-storage support** (local, secondary, cloud)
- **Advanced compression** with multiple algorithms
- **Intelligent notifications** via Telegram and Email
- **Complete monitoring** with Prometheus metrics
- **Enterprise-grade security** with integrity checks
- **Modular architecture** with 17 specialized libraries

The system is designed for production environments and homelab setups, providing enterprise-level backup management with simplified configuration.

---

## 2. Project Structure

```
/proxmox-backup/
├── backup/                  # Generated backup files
│   ├── *.tar.xz            # Compressed backup archives
│   ├── *.metadata          # Backup metadata files
│   └── *.sha256            # Integrity checksums
├── config/                 # System configurations
│   └── .server_identity    # Unique server identity
├── env/                    # Main configuration
│   └── backup.env          # Primary configuration file
├── lib/                    # Modular library system (17 files)
│   ├── backup_collect.sh         # Generic file collection
│   ├── backup_collect_pbspve.sh  # PVE/PBS specific collection
│   ├── backup_create.sh          # Archive creation
│   ├── backup_manager.sh         # Operation management
│   ├── backup_verify.sh          # Integrity verification
│   ├── core.sh                   # Core functions
│   ├── environment.sh            # Environment management
│   ├── log.sh                    # Advanced logging system
│   ├── metrics.sh                # Prometheus metrics
│   ├── metrics_collect.sh        # Metrics collection
│   ├── notify.sh                 # Notification system
│   ├── security.sh               # Security controls
│   ├── storage.sh                # Storage management
│   ├── utils.sh                  # Generic utilities
│   └── utils_counting.sh         # Counters and statistics
├── log/                    # System logs
│   └── *.log              # Detailed operation logs
├── script/                 # Main executable scripts (4 files)
│   ├── proxmox-backup.sh      # Main orchestrator
│   ├── security-check.sh      # Security checks
│   ├── fix-permissions.sh     # Permission management
│   └── server-id-manager.sh   # Server identity management
└── secure_account/         # Secure credentials
    └── (sensitive files)   # Encrypted credentials
```

---

## 3. Architecture and Functions

### 3.1 Main Scripts (`script/`)

#### 3.1.1 proxmox-backup.sh - Main Script
**Function**: Main backup system orchestrator
- **Initialization**: Loads configurations, sets environment variables
- **System detection**: Automatically determines if it's PVE or PBS
- **Flow management**: Coordinates all backup phases
- **Error handling**: Trap for automatic cleanup on errors
- **Modes**: Supports --check-only, --dry-run, --verbose
- **Logging**: Sets up centralized logging system
- **Notifications**: Sends final notifications via Telegram/Email

#### 3.1.2 security-check.sh - Security Controls
**Function**: Complete system security verification
- **Integrity verification**: Checks MD5 hashes of all scripts
- **Network controls**: Verifies firewall configurations and open ports
- **File audit**: Identifies unauthorized or modified files
- **Permissions**: Verifies correct permissions on critical files
- **Report**: Generates detailed security issue report
- **Auto-remediation**: Can automatically correct some issues

#### 3.1.3 fix-permissions.sh - Permission Management
**Function**: Automatic file and directory permission correction
- **Script permissions**: Sets 755 for executable scripts
- **Configuration permissions**: 600 for sensitive files (backup.env)
- **Ownership**: Sets correct owner/group (backup:backup)
- **Directories**: Creates and corrects permissions for missing directories
- **Logging**: Records all modifications made

#### 3.1.4 server-id-manager.sh - Server Identity Management
**Function**: Manages unique server identity for backups
- **ID generation**: Creates unique identity based on hardware
- **Persistence**: Saves identity in .server_identity file
- **Verification**: Checks identity consistency between executions
- **Backup**: Ensures backups are correctly labeled
- **Cluster awareness**: Manages identity in cluster environments

### 3.2 Modular Libraries (`lib/`)

#### 3.2.1 Core System Libraries

**core.sh** - Fundamental Functions
- **Exit code management**: Sets and tracks exit codes
- **Global variables**: Initializes system variables
- **Base utilities**: Essential helper functions
- **Error handling**: Centralized error management
- **Signal handling**: System signal management

**environment.sh** - Environment Management
- **Configuration loading**: Advanced .env file parser
- **Validation**: Checks configuration consistency
- **Path resolution**: Resolves relative/absolute paths
- **Environment setup**: Sets necessary environment variables
- **Dependency check**: Verifies system dependencies

**utils.sh** - Generic Utilities (61KB, 1675 lines)
- **File operations**: Advanced file operations
- **String manipulation**: String manipulation functions
- **Date/time**: Timestamp and duration management
- **Validation**: Data validation functions
- **Helper functions**: Hundreds of utility functions

#### 3.2.2 Backup System Libraries

**backup_collect.sh** - Generic File Collection
- **Operating system**: Collects critical system files
- **Configurations**: Collects generic configurations
- **Packages**: Lists installed packages
- **Cron jobs**: Backs up cron configurations
- **Network config**: Network configurations
- **Custom paths**: Handles custom paths from CUSTOM_BACKUP_PATHS

**backup_collect_pbspve.sh** - PVE/PBS Specific Collection (58KB, 1161 lines)
- **Auto-detection**: Automatically detects PVE and PBS datastores
- **collect_pve_configs()**: Collects all PVE configurations
  - Cluster configuration (/etc/pve/)
  - VM/Container configs (.conf files)
  - Corosync configuration (if cluster)
  - Firewall rules, VZDump, Ceph
  - Backup jobs, replication, schedules
- **collect_pbs_configs()**: Collects all PBS configurations
  - PBS configuration (/etc/proxmox-backup/)
  - Datastore metadata
  - PXAR file analysis
  - Sync/verify/prune jobs
- **Datastore detection**: Intelligent storage detection system

**backup_create.sh** - Archive Creation (62KB, 1553 lines)
- **Archive creation**: Creates compressed tar archives
- **Compression**: Advanced compression management (xz, zstd, gzip)
- **Deduplication**: Eliminates duplicate files with symlinks
- **Smart chunking**: Splits large files for better compression
- **Prefiltering**: Optimizes files before compression
- **Integrity**: Generates SHA256 checksums
- **Metadata**: Creates metadata files for each backup

**backup_verify.sh** - Integrity Verification
- **Checksum verification**: Verifies SHA256 of all backups
- **Archive validation**: Checks tar archive integrity
- **Content validation**: Verifies presence of critical files in archive
- **Corruption detection**: Detects data corruption
- **Report**: Generates detailed verification report

**backup_manager.sh** - Operation Management (28KB, 683 lines)
- **Storage coordination**: Coordinates operations on multiple storages
- **Retention management**: Manages retention policies
- **Cleanup**: Automatic cleanup of old backups
- **Status tracking**: Tracks backup operation status
- **Parallel operations**: Manages parallel operations

#### 3.2.3 Storage & Cloud Libraries

**storage.sh** - Storage Management (37KB, 976 lines)
- **Multi-storage**: Manages local, secondary, cloud storage
- **Upload/Download**: File transfer operations
- **Verification**: Verifies integrity after transfers
- **Retry logic**: Automatic retry on errors
- **Bandwidth management**: Manages bandwidth limitation
- **Parallel transfers**: Parallel upload/download

#### 3.2.4 Monitoring & Notification Libraries

**log.sh** - Logging System (65KB, 1789 lines)
- **Multi-level logging**: Debug, info, warning, error
- **Emoji support**: Emoji for better readability
- **File rotation**: Automatic log file rotation
- **Structured logging**: Structured logs for parsing
- **Performance tracking**: Tracks operation performance
- **Color support**: Colored output for terminal

**notify.sh** - Notification System (36KB, 961 lines)
- **Telegram integration**: Complete Telegram notifications
- **Email support**: Email notifications with detailed reports
- **Custom API server**: Support for custom Telegram servers
- **Template system**: Customizable message templates
- **Retry logic**: Retry sending on failure
- **Rich formatting**: Formatted messages with emoji and markdown

**metrics.sh** - Prometheus Metrics (45KB, 1164 lines)
- **Prometheus integration**: Exports metrics for Prometheus
- **Performance metrics**: Operation duration, throughput
- **Counter metrics**: Processed files, errors, successes
- **Status metrics**: Storage status, backup, connectivity
- **Custom metrics**: Customizable metrics
- **Node exporter**: Prometheus node exporter compatibility

**metrics_collect.sh** - Metrics Collection
- **System metrics**: CPU, memory, disk, network
- **Backup metrics**: Backup-specific statistics
- **Storage metrics**: Storage usage, I/O performance
- **Application metrics**: Application-specific metrics
- **Historical data**: Historical data collection

#### 3.2.5 Security & Utilities Libraries

**security.sh** - Security Controls (13KB, 389 lines)
- **File integrity**: Verifies file integrity with MD5 hashes
- **Permission audit**: Checks critical file permissions
- **Network security**: Port scans, firewall checks
- **Process monitoring**: Running process monitoring
- **Unauthorized files**: Detects unauthorized files
- **Security report**: Complete system security report

**utils_counting.sh** - Counters and Statistics (27KB, 631 lines)
- **Operation counters**: Counts executed operations
- **File counters**: Tracks processed/failed files
- **Performance counters**: Measures operation performance
- **Status tracking**: Tracks global system status
- **Statistics**: Calculates detailed statistics
- **Unified counting**: Unified counting system

### 3.3 System Workflow

#### 3.3.1 Initialization Phase
1. **proxmox-backup.sh** starts the process
2. **environment.sh** loads and validates configurations
3. **core.sh** initializes global variables
4. **security.sh** performs security checks (if enabled)
5. **server-id-manager.sh** verifies/generates server identity

#### 3.3.2 Detection Phase
1. **backup_collect_pbspve.sh** detects system type (PVE/PBS)
2. **detect_all_datastores()** automatically finds all datastores
3. Determines backup strategy based on system type

#### 3.3.3 Collection Phase
1. **backup_collect.sh** collects common files (system, cron, etc.)
2. **backup_collect_pbspve.sh** collects specific files:
   - **PVE**: cluster, VM, containers, Ceph, jobs
   - **PBS**: configurations, PXAR, datastore, jobs
3. **utils_counting.sh** tracks progress

#### 3.3.4 Archive Creation Phase
1. **backup_create.sh** optimizes collected files:
   - Deduplication (if enabled)
   - Prefiltering for better compression
   - Smart chunking for large files
2. Creates compressed tar archive
3. Generates SHA256 checksum and metadata

#### 3.3.5 Storage Phase
1. **storage.sh** manages distribution to multiple storages:
   - Local upload (always)
   - Secondary upload (if enabled)
   - Cloud upload (if enabled and connected)
2. **backup_manager.sh** coordinates parallel operations
3. Verifies integrity post-upload

#### 3.3.6 Verification and Cleanup Phase
1. **backup_verify.sh** verifies backup integrity
2. **backup_manager.sh** applies retention policies
3. Cleanup temporary files and old backups

#### 3.3.7 Reporting Phase
1. **metrics.sh** updates Prometheus metrics
2. **notify.sh** sends final notifications
3. **log.sh** completes logging with summary

### 3.4 Advanced Features

#### 3.4.1 Automatic Datastore Detection
- **API-based detection**: Uses Proxmox API to detect storage
- **Fallback parsing**: Configuration parser if API unavailable
- **Multi-system support**: Detects PVE and PBS simultaneously
- **Intelligent filtering**: Filters only relevant storage for backup

#### 3.4.2 Intelligent Notification System
- **Adaptive messaging**: Adaptive messages based on result
- **Rich formatting**: Emoji, markdown, tables in notifications
- **Custom servers**: Support for custom Telegram servers
- **Fallback mechanisms**: Email if Telegram unavailable

#### 3.4.3 Advanced Storage Management
- **Parallel operations**: Simultaneous uploads to multiple storages
- **Intelligent retry**: Retry with exponential backoff
- **Bandwidth management**: Intelligent bandwidth throttling
- **Post-upload verification**: Integrity verification after each upload

#### 3.4.4 Optimized Compression
- **Multi-algorithm**: xz, zstd, gzip with auto-selection
- **Adaptive compression**: Adaptive level based on content
- **Preprocessing**: File optimization before compression
- **Deduplication**: Duplicate elimination with symlinks

---

## 4. System Configuration (`backup.env`)

The `backup.env` file contains all system configuration options. Options are organized in logical sections:

### 4.1 General System Configuration

| Parameter | Default Value | Description |
|-----------|---------------|-------------|
| `REQUIRED_BASH_VERSION` | "4.4.0" | Minimum required Bash version |
| `DEBUG_MODE` | "false" | Enable debug mode |
| `DEBUG_LEVEL` | "standard" | Debug level (standard/advanced/extreme) |
| `INSTALL_PACKAGES` | "true" | Automatically install missing packages |
| `ADDITIONAL_PACKAGES` | "curl jq..." | Additional packages to install |
| `DISABLE_COLORS` | "false" | Disable colors in output |

### 4.2 Main Features - Enable/Disable

#### 4.2.1 General Backup Features
| Parameter | Default Value | Description |
|-----------|---------------|-------------|
| `BACKUP_SYSTEM_FILES` | "true" | Critical system files backup |
| `BACKUP_CRON_JOBS` | "true" | Cron jobs backup |
| `BACKUP_NETWORK_CONFIG` | "true" | Network configurations |
| `BACKUP_PACKAGE_LIST` | "true" | Installed packages list |
| `BACKUP_ZFS_INFO` | "true" | ZFS information (if available) |
| `BACKUP_SYSTEMD_SERVICES` | "true" | Systemd services list |
| `BACKUP_CUSTOM_PATHS` | "true" | Custom paths from CUSTOM_BACKUP_PATHS |
| `BACKUP_REMOTE_CFG` | "true" | Remote configurations |

#### 4.2.2 PVE Specific Features
| Parameter | Default Value | Description |
|-----------|---------------|-------------|
| `BACKUP_PVE_CLUSTER` | "true" | PVE cluster configurations |
| `BACKUP_PVE_NODES` | "true" | PVE node configurations |
| `BACKUP_PVE_STORAGE` | "true" | PVE storage configurations |
| `BACKUP_PVE_FIREWALL` | "true" | PVE firewall rules |
| `BACKUP_PVE_USERS` | "true" | PVE users and permissions |
| `BACKUP_PVE_BACKUP_JOBS` | "true" | PVE backup jobs |
| `BACKUP_PVE_REPLICATION` | "true" | Replication information |

#### 4.2.3 PBS Specific Features
| Parameter | Default Value | Description |
|-----------|---------------|-------------|
| `BACKUP_PBS_CONFIG` | "true" | PBS configurations |
| `BACKUP_PBS_DATASTORE` | "true" | PBS datastore information |
| `BACKUP_PBS_JOBS` | "true" | PBS jobs (sync/verify/prune) |
| `BACKUP_PXAR_FILES` | "true" | PXAR files metadata |
| `BACKUP_SMALL_PXAR` | "false" | Copy small PXAR files |
| `BACKUP_PVE_BACKUP_FILES` | "true" | PVE backup files in PBS |
| `BACKUP_SMALL_PVE_BACKUPS` | "false" | Copy small PVE backup files |

#### 4.2.4 Storage Features
| Parameter | Default Value | Description |
|-----------|---------------|-------------|
| `ENABLE_SECONDARY_STORAGE` | "false" | Enable secondary storage |
| `ENABLE_CLOUD_STORAGE` | "false" | Enable cloud storage |
| `CLOUD_ONLY_ON_SUCCESS` | "true" | Upload to cloud only on success |
| `MULTI_STORAGE_PARALLEL` | "false" | Parallel processing on multiple storages |

#### 4.2.5 Security Features
| Parameter | Default Value | Description |
|-----------|---------------|-------------|
| `ENABLE_SECURITY_CHECKS` | "true" | Enable security checks |
| `CHECK_SCRIPT_INTEGRITY` | "true" | Check script integrity |
| `VERIFY_BACKUP_INTEGRITY` | "true" | Verify backup integrity |
| `FULL_SECURITY_CHECK` | "true" | Complete security check |

#### 4.2.6 Advanced Compression Features
| Parameter | Default Value | Description |
|-----------|---------------|-------------|
| `ENABLE_DEDUPLICATION` | "true" | Enable file deduplication |
| `ENABLE_PREFILTERING` | "true" | Enable file prefiltering |
| `ENABLE_SMART_CHUNKING` | "true" | Smart chunking of very large files |

#### 4.2.7 Monitoring Features
| Parameter | Default Value | Description |
|-----------|---------------|-------------|
| `ENABLE_PROMETHEUS` | "true" | Enable Prometheus metrics |
| `ENABLE_PERFORMANCE_TRACKING` | "true" | Enable performance tracking |
| `ENABLE_DETAILED_LOGGING` | "true" | Enable detailed logging |
| `SET_BACKUP_PERMISSIONS` | "true" | Set backup permissions |

### 4.3 Paths and Storage Configuration

#### 4.3.1 Automatic Detection
| Parameter | Default Value | Description |
|-----------|---------------|-------------|
| `AUTO_DETECT_DATASTORES` | "true" | Automatic datastore detection from PBS and PVE systems |

#### 4.3.2 Backup Paths
| Parameter | Default Value | Description |
|-----------|---------------|-------------|
| `BACKUP_BASE_PATH` | "/proxmox-backup/backup" | Main backup directory |
| `SECONDARY_BACKUP_PATH` | "/mnt/secondary-backup" | Secondary backup path |
| `CLOUD_BACKUP_PATH` | "/proxmox-backup/backup" | Cloud backup path |

#### 4.3.3 Log Paths
| Parameter | Default Value | Description |
|-----------|---------------|-------------|
| `LOG_BASE_PATH` | "/proxmox-backup/log" | Main log directory |
| `SECONDARY_LOG_PATH` | "/mnt/secondary-backup/log" | Secondary log path |
| `CLOUD_LOG_PATH` | "/proxmox-backup/log" | Cloud log path |

#### 4.3.4 Retention Policies
| Parameter | Default Value | Description |
|-----------|---------------|-------------|
| `MAX_LOCAL_BACKUPS` | "10" | Maximum local backups to keep |
| `MAX_SECONDARY_BACKUPS` | "15" | Maximum secondary backups to keep |
| `MAX_CLOUD_BACKUPS` | "20" | Maximum cloud backups to keep |
| `MAX_LOCAL_LOGS` | "30" | Maximum local logs to keep |
| `MAX_SECONDARY_LOGS` | "20" | Maximum secondary logs to keep |
| `MAX_CLOUD_LOGS` | "20" | Maximum cloud logs to keep |

#### 4.3.5 Custom Paths
| Parameter | Default Value | Description |
|-----------|---------------|-------------|
| `ROOT_HOME_PATH` | "/root" | Root home directory path |
| `PVE_CONFIG_PATH` | "/etc/pve" | PVE configuration path |
| `PBS_CONFIG_PATH` | "/etc/proxmox-backup" | PBS configuration path |
| `CEPH_CONFIG_PATH` | "/etc/ceph" | Ceph configuration path |

### 4.4 Compression Configuration

| Parameter | Default Value | Description |
|-----------|---------------|-------------|
| `COMPRESSION_TYPE` | "auto" | Compression type (auto/xz/zstd/gzip/none) |
| `COMPRESSION_LEVEL` | "6" | Compression level (1-9) |
| `COMPRESSION_MODE` | "balanced" | Compression mode (fast/balanced/best) |
| `COMPRESSION_THREADS` | "0" | Compression threads (0=auto, 1=single, N=specific) |

### 4.5 Cloud and rclone Configuration

#### 4.5.1 rclone Configuration
| Parameter | Default Value | Description |
|-----------|---------------|-------------|
| `RCLONE_REMOTE` | "remote" | rclone remote name |
| `RCLONE_CONFIG_PATH` | "/root/.config/rclone/rclone.conf" | rclone configuration path |
| `RCLONE_FLAGS` | "--transfers=16 --checkers=4..." | Additional rclone flags |

#### 4.5.2 Cloud Upload Modes
| Parameter | Default Value | Description |
|-----------|---------------|-------------|
| `CLOUD_UPLOAD_MODE` | "sync" | Cloud upload mode (sync/copy/move) |
| `CLOUD_BANDWIDTH_LIMIT` | "" | Bandwidth limit for cloud uploads |
| `SKIP_CLOUD_VERIFICATION` | "false" | Skip cloud upload verification |

### 4.6 Notifications Configuration

#### 4.6.1 Telegram Configuration
| Parameter | Default Value | Description |
|-----------|---------------|-------------|
| `TELEGRAM_BOT_TOKEN` | "" | Telegram bot token |
| `TELEGRAM_CHAT_ID` | "" | Telegram chat ID |
| `TELEGRAM_ENABLED` | "false" | Enable Telegram notifications |
| `TELEGRAM_ON_SUCCESS` | "true" | Send notification on success |
| `TELEGRAM_ON_ERROR` | "true" | Send notification on error |
| `TELEGRAM_SERVER_API_HOST` | "https://bot.tis24.it:1443" | Custom Telegram API server |

#### 4.6.2 Email Configuration
| Parameter | Default Value | Description |
|-----------|---------------|-------------|
| `EMAIL_ENABLED` | "false" | Enable email notifications |
| `EMAIL_TO` | "" | Recipient email address |
| `SMTP_SERVER` | "" | SMTP server |
| `SMTP_PORT` | "587" | SMTP port |
| `SMTP_USERNAME` | "" | SMTP username |
| `SMTP_PASSWORD` | "" | SMTP password |

### 4.7 Prometheus Configuration

| Parameter | Default Value | Description |
|-----------|---------------|-------------|
| `PROMETHEUS_TEXTFILE_DIR` | "/var/lib/prometheus/node-exporter" | Prometheus text file directory |

### 4.8 Users and Permissions Configuration

| Parameter | Default Value | Description |
|-----------|---------------|-------------|
| `BACKUP_USER` | "backup" | Backup user |
| `BACKUP_GROUP` | "backup" | Backup group |

### 4.9 Custom Configurations

#### 4.9.1 Custom Backup Paths
```bash
CUSTOM_BACKUP_PATHS="
/etc/custom-app/
/var/lib/custom-service/
/opt/custom-software/config/
"
```

#### 4.9.2 Backup Blacklist
```bash
BACKUP_BLACKLIST="
*.tmp
*.cache
*.log
/tmp/*
/var/tmp/*
"
```

#### 4.9.3 PXAR Options
| Parameter | Default Value | Description |
|-----------|---------------|-------------|
| `MAX_PXAR_SIZE` | "50M" | Maximum size for small PXAR files |
| `PXAR_INCLUDE_PATTERN` | "vm/100,vm/101" | Pattern to include specific PXAR files |

#### 4.9.4 PVE Backup Options
| Parameter | Default Value | Description |
|-----------|---------------|-------------|
| `MAX_PVE_BACKUP_SIZE` | "100M" | Maximum size for small PVE backup files |
| `PVE_BACKUP_INCLUDE_PATTERN` | "" | Pattern to include specific PVE backup files |

---

## 5. Files Subject to Backup

### 5.1 Common Files (PVE and PBS)

#### 5.1.1 Critical System Files
- `/etc/fstab` - Filesystem table
- `/etc/resolv.conf` - DNS configuration
- `/etc/hosts` - Host file
- `/etc/hostname` - System hostname
- `/etc/passwd` - User accounts
- `/etc/group` - User groups
- `/etc/shadow` - Password hashes
- `/etc/gshadow` - Group passwords
- `/etc/sudoers` - Sudo configurations
- `/etc/ssh/` - SSH configurations
- `/root/` - Root home directory (configurable)

#### 5.1.2 System Configurations
- **Cron**: `/etc/cron.d/`, `/etc/cron.daily/`, `/etc/cron.weekly/`
- **Logrotate**: `/etc/logrotate.d/`
- **Systemd**: Service configurations and enabled services
- **Network**: `/etc/network/interfaces`, `/etc/netplan/`
- **Firewall**: iptables rules, ufw configurations
- **Time**: `/etc/timezone`, `/etc/localtime`
- **ZFS**: ZFS configurations (if present)

#### 5.1.3 Rclone Configurations
- `/root/.config/rclone/rclone.conf` (if cloud backup enabled)

#### 5.1.4 System Information
- Installed packages list
- System version
- Hardware information

### 5.2 PVE Specific Files (Proxmox Virtual Environment)

#### 5.2.1 Cluster Configurations
- `/etc/pve/` - **Complete cluster configuration**
  - VM and container configurations
  - Storage configurations
  - User configurations
  - Firewall rules
  - Backup job configurations
- `/var/lib/pve-cluster/config.db` - Cluster configuration database

#### 5.2.2 Corosync Configurations (only if cluster configured)
- `/etc/corosync/corosync.conf` - Corosync cluster configuration

#### 5.2.3 Firewall Configurations
- `/etc/pve/firewall/` - PVE firewall rules
  - Global rules
  - VM/container rules
  - Node rules

#### 5.2.4 VM and Container Configurations
- `/etc/pve/nodes/*/qemu-server/*.conf` - **VM configurations**
- `/etc/pve/nodes/*/lxc/*.conf` - **LXC container configurations**

#### 5.2.5 Backup Configurations
- `/etc/vzdump.conf` - VZDump configuration
- Configured backup jobs
- Backup history
- Backup schedules

#### 5.2.6 Ceph Configurations (if present)
- `/etc/ceph/` - **Complete Ceph configuration**
  - `ceph.conf` - Main configuration
  - Keyring files
  - MON, OSD, MDS configurations
  - OSD, MON, PG information

#### 5.2.7 PVE Information
- PVE version (`pveversion`)
- Storage status (`pvesm status`)
- **User list** (`pveum user list`)
- **Backup job list** (`pvesh get /cluster/backup`)
- **Replication job list** (`pvesh get /nodes/*/replication`)
- **Systemd timers** related to PVE

#### 5.2.8 PVE Datastores
- **Metadata of automatically detected PVE datastores**
- **Backup file analysis** in PVE directories:
  - `.vma` files (VM backups)
  - `.tar` files (container backups)
  - Compressed variants (`.vma.gz`, `.vma.lzo`, `.tar.gz`, `.tar.lzo`)
- **Copy small backup files** (if `BACKUP_SMALL_PVE_BACKUPS=true`)

### 5.3 PBS Specific Files (Proxmox Backup Server)

#### 5.3.1 PBS Configurations
- `/etc/proxmox-backup/` - **Complete PBS configuration**
  - `datastore.cfg` - Datastore configuration
  - `user.cfg` - User configurations
  - `acl.cfg` - Access control lists
  - `jobs.cfg` - Job configurations
  - SSL certificates

#### 5.3.2 PBS Information
- PBS version (`proxmox-backup-manager version`)
- Datastore list (`proxmox-backup-manager datastore list`)
- **User list** (`proxmox-backup-manager user list`)
- **Job list** (sync, verify, prune jobs)
- **Certificate information** (`proxmox-backup-manager cert info`)

#### 5.3.3 PXAR Files
- **Metadata of .pxar files** in automatically detected datastores
- **Complete .pxar file list** per datastore
- **Copy small .pxar files** (if `BACKUP_SMALL_PXAR=true` and size < `MAX_PXAR_SIZE`)
- **Copy selected .pxar files** (if `PXAR_INCLUDE_PATTERN` configured)

#### 5.3.4 PBS Datastores
- **Automatic detection** of all configured datastores
- **Metadata per datastore**:
  - Datastore configuration
  - Namespace list
  - Backup type list
  - Backup group list
  - Snapshot list (recent)
- **PVE backup analysis** stored in PBS (if `BACKUP_PVE_BACKUP_FILES=true`)

### 5.4 Exclusively PVE vs PBS Files

#### 5.4.1 PVE Only
- **Cluster configurations**: `/etc/pve/`, `/var/lib/pve-cluster/`
- **Corosync configurations**: `/etc/corosync/corosync.conf`
- **VM/Container configs**: `.conf` files for qemu-server and lxc
- **VZDump**: `/etc/vzdump.conf`
- **Ceph configurations**: `/etc/ceph/` (if present)
- **PVE replication jobs**
- **PVE backup files**: `.vma`, `.tar` and compressed variants
- **PVE commands**: `pveversion`, `pvesm`, `pveum`, `pvesh`

#### 5.4.2 PBS Only
- **PBS configurations**: `/etc/proxmox-backup/`
- **PXAR files**: `.pxar` in datastores
- **PBS jobs**: sync-job, verify-job, prune-job
- **PBS specific datastores**: PBS datastore management
- **PBS commands**: `proxmox-backup-manager`, `proxmox-backup-client`

#### 5.4.3 Common (PVE and PBS)
- **System files**: `/etc/passwd`, `/etc/hosts`, `/etc/fstab`, etc.
- **Cron configurations**: `/etc/cron.d/`, `/etc/cron.daily/`, etc.
- **Network configurations**: `/etc/network/`, `/etc/netplan/`
- **SSH configurations**: `/etc/ssh/`
- **System information**: packages, version, hardware
- **Rclone configurations**: `/root/.config/rclone/rclone.conf`

---

## 6. Directory Structure Tree `/proxmox-backup/`

```
/proxmox-backup/
├── backup/                           # Generated backup files
│   ├── proxmox_backup_20241201_143022.tar.xz     # Main backup archive
│   ├── proxmox_backup_20241201_143022.metadata   # Backup metadata
│   ├── proxmox_backup_20241201_143022.sha256     # Integrity checksum
│   ├── proxmox_backup_20241130_120000.tar.xz     # Previous backup
│   └── (more backup files...)
├── config/                           # System configurations
│   └── .server_identity             # Unique server identity
├── env/                              # Configuration environment
│   └── backup.env                    # Main configuration file (90+ options)
├── lib/                              # Modular library system (17 files)
│   ├── backup_collect.sh             # Generic file collection (functions)
│   ├── backup_collect_pbspve.sh       # PVE/PBS specific collection (58KB)
│   ├── backup_create.sh               # Archive creation (62KB)
│   ├── backup_manager.sh              # Operation management (28KB)
│   ├── backup_verify.sh               # Integrity verification functions
│   ├── core.sh                        # Core system functions
│   ├── environment.sh                 # Environment management
│   ├── log.sh                         # Advanced logging system (65KB)
│   ├── metrics.sh                     # Prometheus metrics (45KB)
│   ├── metrics_collect.sh             # Metrics collection
│   ├── notify.sh                      # Notification system (Telegram/Email) (36KB)
│   ├── security.sh                    # Security controls (13KB)
│   ├── storage.sh                     # Storage management (37KB)
│   ├── utils.sh                       # Generic utilities (61KB, 1675 lines)
│   ├── utils_counting.sh              # Counters and statistics (27KB)
│   └── (other library files...)
├── log/                               # System operation logs
│   └── *.log                          # Detailed operation logs
├── script/                              # Main executable scripts (4 files)
│   ├── proxmox-backup.sh               # Main backup orchestrator
│   ├── security-check.sh               # Security checks
│   ├── fix-permissions.sh              # Permission management script
│   └── server-id-manager.sh            # Server identity management
└── secure_account/                        # Secure credentials storage
    ├── telegram_credentials.enc          # Encrypted Telegram credentials
    ├── email_credentials.enc             # Encrypted email credentials
    └── (other encrypted files...)
```

### 6.1 Structure Details

#### `backup/` Directory
- **Main archives**: Compressed backup files (.tar.xz, .tar.zst, .tar.gz)
- **Metadata files**: JSON files with backup information
- **Checksums**: SHA256 files for integrity verification
- **Retention**: Automatic cleanup based on MAX_LOCAL_BACKUPS

#### `config/` Directory
- **Server identity**: Unique identifier for cluster environments
- **Generated configurations**: Auto-generated configuration files

#### `env/` Directory
- **Main configuration**: backup.env with 90+ options
- **Environment variables**: All system customizations

#### `lib/` Directory (17 modular libraries)
- **Core libraries**: core.sh, environment.sh, utils.sh
- **Backup libraries**: Collection, creation, verification, management
- **Storage libraries**: Multi-storage support with cloud integration
- **Monitoring libraries**: Logging, metrics, notifications
- **Security libraries**: Integrity checks, permission management

#### `log/` Directory
- **Operation logs**: Detailed logs for each backup operation
- **Security logs**: Security check and audit logs
- **Metrics logs**: Performance and statistics logs
- **Rotation**: Automatic log rotation based on retention policies

#### `script/` Directory (4 main scripts)
- **Main orchestrator**: proxmox-backup.sh coordinates all operations
- **Security tools**: Security checks and permission management
- **Utilities**: Server identity and system management

#### `secure_account/` Directory
- **Encrypted credentials**: Secure storage for sensitive information
- **Access control**: Restricted permissions (600/700)

---

## 7. System Usage

### 7.1 Manual Execution
```bash
# Complete backup
./script/proxmox-backup.sh

# Dry run (test mode)
./script/proxmox-backup.sh --dry-run

# Verbose mode
./script/proxmox-backup.sh --verbose

# Configuration check only
./script/proxmox-backup.sh --check-only
```

### 7.2 Automatic Execution
The system can be configured for automatic execution via cron:

```bash
# Daily backup at 2:00 AM
0 2 * * * /proxmox-backup/script/proxmox-backup.sh

# Weekly security check
0 3 * * 0 /proxmox-backup/script/security-check.sh
```

### 7.3 Security Checks
```bash
# Run security checks
./script/security-check.sh

# Fix permissions
./script/fix-permissions.sh
```

---

## 8. Monitoring and Notifications

### 8.1 Telegram Notifications
- **Configuration**: Via `TELEGRAM_BOT_TOKEN` and `TELEGRAM_CHAT_ID`
- **Custom server**: Support for custom Telegram API server
- **Types**: Success, warning, error notifications with emoji

### 8.2 Email Notifications
- **Configuration**: Via SMTP parameters
- **Recipient**: Configurable or default root email
- **Content**: Detailed report with backup statistics

### 8.3 Prometheus Metrics
- **Directory**: `/var/lib/prometheus/node-exporter`
- **Metrics**: Backup duration, processed files, errors, storage status
- **Integration**: Compatible with Grafana dashboards

---

## 9. Security

### 9.1 Implemented Controls
- **Integrity verification**: SHA256 checksums for all backups
- **Security checks**: Dedicated script for system audit
- **Permission management**: Automatic for backup files and directories
- **Blacklist**: Automatic exclusion of sensitive or temporary files

### 9.2 Sensitive Files
- **Configurable**: Any type of sensitive file can be excluded
- **Encryption**: Support for encrypted backups
- **Access control**: Restricted permissions on configuration files

---

## 10. System Requirements

### 10.1 Required Dependencies
- **Bash**: Version 4.4.0 or higher
- **Packages**: `tar`, `gzip`, `zstd`, `pigz`, `jq`, `curl`, `rclone`, `gpg`
- **Space**: Sufficient for local, secondary, and temporary backups
- **Network**: Internet connection for cloud backups

### 10.2 Compatibility
- **PVE**: Proxmox Virtual Environment 6.x, 7.x, 8.x
- **PBS**: Proxmox Backup Server 2.x, 3.x
- **OS**: Debian-based systems (Debian, Ubuntu, Proxmox)

---

## 11. Troubleshooting

### 11.1 Logs and Debug
- **Detailed logs**: Available in `/proxmox-backup/log/`
- **Debug levels**: Configurable from "standard" to "extreme"
- **Emoji**: Improve log readability

### 11.2 Common Issues
1. **Cloud backup failed**: Check rclone configuration and connectivity
2. **Permission denied**: Run `fix-permissions.sh`
3. **Missing dependencies**: Enable `INSTALL_PACKAGES=true`
4. **Storage full**: Check retention policies and cleanup

---

## 12. License and Support

This system is designed for production environments and homelab. For technical support, consult the detailed logs and documentation in the `/doc/` directories.
# Proxmox Backup System - Configuration Guide
# Version: 0.2.1

Complete configuration guide for the Proxmox backup system through the `backup.env` file.

## 📑 Configuration Index

- [1. General System Configuration](#1-general-system-configuration)
- [2. Main Features - Enable/Disable](#2-main-features---enabledisable)
  - [2.1 General Backup Features](#21-general-backup-features)
  - [2.2 PVE Specific Features](#22-pve-specific-features)
  - [2.3 PBS Specific Features](#23-pbs-specific-features)
  - [2.4 Storage Features](#24-storage-features)
  - [2.5 Security Features](#25-security-features)
  - [2.6 Advanced Compression Features](#26-advanced-compression-features)
  - [2.7 Monitoring Features](#27-monitoring-features)
- [3. Paths and Storage Configuration](#3-paths-and-storage-configuration)
  - [3.1 Automatic Detection](#31-automatic-detection)
  - [3.2 Backup Paths](#32-backup-paths)
  - [3.3 Log Paths](#33-log-paths)
  - [3.4 Retention Policies](#34-retention-policies)
  - [3.5 Custom Paths](#35-custom-paths)
- [4. Compression Configuration](#4-compression-configuration)
- [5. Cloud and rclone Configuration](#5-cloud-and-rclone-configuration)
  - [5.1 rclone Configuration](#51-rclone-configuration)
  - [5.2 Cloud Upload Modes](#52-cloud-upload-modes)
- [6. Notifications Configuration](#6-notifications-configuration)
  - [6.1 Telegram Configuration](#61-telegram-configuration)
  - [6.2 Email Configuration](#62-email-configuration)
- [7. Prometheus Configuration](#7-prometheus-configuration)
- [8. Users and Permissions Configuration](#8-users-and-permissions-configuration)
- [9. Custom Configurations](#9-custom-configurations)
  - [9.1 Custom Backup Paths](#91-custom-backup-paths)
  - [9.2 Backup Blacklist](#92-backup-blacklist)
  - [9.3 PXAR Options](#93-pxar-options)
  - [9.4 PVE Backup Options](#94-pve-backup-options)

---

## 1. General System Configuration

The `backup.env` file contains all system configuration options. Options are organized in logical sections:

| Parameter | Default Value | Description |
|-----------|---------------|-------------|
| `REQUIRED_BASH_VERSION` | "4.4.0" | Minimum required Bash version |
| `DEBUG_MODE` | "false" | Enable debug mode |
| `DEBUG_LEVEL` | "standard" | Debug level (standard/advanced/extreme) |
| `INSTALL_PACKAGES` | "true" | Automatically install missing packages |
| `ADDITIONAL_PACKAGES` | "curl jq..." | Additional packages to install |
| `DISABLE_COLORS` | "false" | Disable colors in output |

---

## 2. Main Features - Enable/Disable

### 2.1 General Backup Features
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

### 2.2 PVE Specific Features
| Parameter | Default Value | Description |
|-----------|---------------|-------------|
| `BACKUP_PVE_CLUSTER` | "true" | PVE cluster configurations |
| `BACKUP_PVE_NODES` | "true" | PVE node configurations |
| `BACKUP_PVE_STORAGE` | "true" | PVE storage configurations |
| `BACKUP_PVE_FIREWALL` | "true" | PVE firewall rules |
| `BACKUP_PVE_USERS` | "true" | PVE users and permissions |
| `BACKUP_PVE_BACKUP_JOBS` | "true" | PVE backup jobs |
| `BACKUP_PVE_REPLICATION` | "true" | Replication information |

### 2.3 PBS Specific Features
| Parameter | Default Value | Description |
|-----------|---------------|-------------|
| `BACKUP_PBS_CONFIG` | "true" | PBS configurations |
| `BACKUP_PBS_DATASTORE` | "true" | PBS datastore information |
| `BACKUP_PBS_JOBS` | "true" | PBS jobs (sync/verify/prune) |
| `BACKUP_PXAR_FILES` | "true" | PXAR files metadata |
| `BACKUP_SMALL_PXAR` | "false" | Copy small PXAR files |
| `BACKUP_PVE_BACKUP_FILES` | "true" | PVE backup files in PBS |
| `BACKUP_SMALL_PVE_BACKUPS` | "false" | Copy small PVE backup files |

### 2.4 Storage Features
| Parameter | Default Value | Description |
|-----------|---------------|-------------|
| `ENABLE_SECONDARY_STORAGE` | "false" | Enable secondary storage |
| `ENABLE_CLOUD_STORAGE` | "false" | Enable cloud storage |
| `CLOUD_ONLY_ON_SUCCESS` | "true" | Upload to cloud only on success |
| `MULTI_STORAGE_PARALLEL` | "false" | Parallel processing on multiple storages |

### 2.5 Security Features
| Parameter | Default Value | Description |
|-----------|---------------|-------------|
| `ENABLE_SECURITY_CHECKS` | "true" | Enable security checks |
| `CHECK_SCRIPT_INTEGRITY` | "true" | Check script integrity |
| `VERIFY_BACKUP_INTEGRITY` | "true" | Verify backup integrity |
| `FULL_SECURITY_CHECK` | "true" | Complete security check |

### 2.6 Advanced Compression Features
| Parameter | Default Value | Description |
|-----------|---------------|-------------|
| `ENABLE_DEDUPLICATION` | "true" | Enable file deduplication |
| `ENABLE_PREFILTERING` | "true" | Enable file prefiltering |
| `ENABLE_SMART_CHUNKING` | "true" | Smart chunking of very large files |

### 2.7 Monitoring Features
| Parameter | Default Value | Description |
|-----------|---------------|-------------|
| `ENABLE_PROMETHEUS` | "true" | Enable Prometheus metrics |
| `ENABLE_PERFORMANCE_TRACKING` | "true" | Enable performance tracking |
| `ENABLE_DETAILED_LOGGING` | "true" | Enable detailed logging |
| `SET_BACKUP_PERMISSIONS` | "true" | Set backup permissions |

---

## 3. Paths and Storage Configuration

### 3.1 Automatic Detection
| Parameter | Default Value | Description |
|-----------|---------------|-------------|
| `AUTO_DETECT_DATASTORES` | "true" | Automatic datastore detection from PBS and PVE systems |

### 3.2 Backup Paths
| Parameter | Default Value | Description |
|-----------|---------------|-------------|
| `BACKUP_BASE_PATH` | "/proxmox-backup/backup" | Main backup directory |
| `SECONDARY_BACKUP_PATH` | "/mnt/secondary-backup" | Secondary backup path |
| `CLOUD_BACKUP_PATH` | "/proxmox-backup/backup" | Cloud backup path |

### 3.3 Log Paths
| Parameter | Default Value | Description |
|-----------|---------------|-------------|
| `LOG_BASE_PATH` | "/proxmox-backup/log" | Main log directory |
| `SECONDARY_LOG_PATH` | "/mnt/secondary-backup/log" | Secondary log path |
| `CLOUD_LOG_PATH` | "/proxmox-backup/log" | Cloud log path |

### 3.4 Retention Policies
| Parameter | Default Value | Description |
|-----------|---------------|-------------|
| `MAX_LOCAL_BACKUPS` | "10" | Maximum local backups to keep |
| `MAX_SECONDARY_BACKUPS` | "15" | Maximum secondary backups to keep |
| `MAX_CLOUD_BACKUPS` | "20" | Maximum cloud backups to keep |
| `MAX_LOCAL_LOGS` | "30" | Maximum local logs to keep |
| `MAX_SECONDARY_LOGS` | "20" | Maximum secondary logs to keep |
| `MAX_CLOUD_LOGS` | "20" | Maximum cloud logs to keep |

### 3.5 Custom Paths
| Parameter | Default Value | Description |
|-----------|---------------|-------------|
| `ROOT_HOME_PATH` | "/root" | Root home directory path |
| `PVE_CONFIG_PATH` | "/etc/pve" | PVE configuration path |
| `PBS_CONFIG_PATH` | "/etc/proxmox-backup" | PBS configuration path |
| `CEPH_CONFIG_PATH` | "/etc/ceph" | Ceph configuration path |

---

## 4. Compression Configuration

| Parameter | Default Value | Description |
|-----------|---------------|-------------|
| `COMPRESSION_TYPE` | "auto" | Compression type (auto/xz/zstd/gzip/none) |
| `COMPRESSION_LEVEL` | "6" | Compression level (1-9) |
| `COMPRESSION_MODE` | "balanced" | Compression mode (fast/balanced/best) |
| `COMPRESSION_THREADS` | "0" | Compression threads (0=auto, 1=single, N=specific) |

---

## 5. Cloud and rclone Configuration

### 5.1 rclone Configuration
| Parameter | Default Value | Description |
|-----------|---------------|-------------|
| `RCLONE_REMOTE` | "remote" | rclone remote name |
| `RCLONE_CONFIG_PATH` | "/root/.config/rclone/rclone.conf" | rclone configuration path |
| `RCLONE_FLAGS` | "--transfers=16 --checkers=4..." | Additional rclone flags |

### 5.2 Cloud Upload Modes
| Parameter | Default Value | Description |
|-----------|---------------|-------------|
| `CLOUD_UPLOAD_MODE` | "sync" | Cloud upload mode (sync/copy/move) |
| `CLOUD_BANDWIDTH_LIMIT` | "" | Bandwidth limit for cloud uploads |
| `SKIP_CLOUD_VERIFICATION` | "false" | Skip cloud upload verification |

---

## 6. Notifications Configuration

### 6.1 Telegram Configuration
| Parameter | Default Value | Description |
|-----------|---------------|-------------|
| `TELEGRAM_BOT_TOKEN` | "" | Telegram bot token |
| `TELEGRAM_CHAT_ID` | "" | Telegram chat ID |
| `TELEGRAM_ENABLED` | "false" | Enable Telegram notifications |
| `TELEGRAM_ON_SUCCESS` | "true" | Send notification on success |
| `TELEGRAM_ON_ERROR` | "true" | Send notification on error |
| `TELEGRAM_SERVER_API_HOST` | "https://bot.tis24.it:1443" | Custom Telegram API server |

### 6.2 Email Configuration
| Parameter | Default Value | Description |
|-----------|---------------|-------------|
| `EMAIL_ENABLED` | "false" | Enable email notifications |
| `EMAIL_TO` | "" | Recipient email address |
| `SMTP_SERVER` | "" | SMTP server |
| `SMTP_PORT` | "587" | SMTP port |
| `SMTP_USERNAME` | "" | SMTP username |
| `SMTP_PASSWORD` | "" | SMTP password |

---

## 7. Prometheus Configuration

| Parameter | Default Value | Description |
|-----------|---------------|-------------|
| `PROMETHEUS_TEXTFILE_DIR` | "/var/lib/prometheus/node-exporter" | Prometheus text file directory |

---

## 8. Users and Permissions Configuration

| Parameter | Default Value | Description |
|-----------|---------------|-------------|
| `BACKUP_USER` | "backup" | Backup user |
| `BACKUP_GROUP` | "backup" | Backup group |

---

## 9. Custom Configurations

### 9.1 Custom Backup Paths
```bash
CUSTOM_BACKUP_PATHS="
/etc/custom-app/
/var/lib/custom-service/
/opt/custom-software/config/
"
```

### 9.2 Backup Blacklist
```bash
BACKUP_BLACKLIST="
*.tmp
*.cache
*.log
/tmp/*
/var/tmp/*
"
```

### 9.3 PXAR Options
| Parameter | Default Value | Description |
|-----------|---------------|-------------|
| `MAX_PXAR_SIZE` | "50M" | Maximum size for small PXAR files |
| `PXAR_INCLUDE_PATTERN` | "vm/100,vm/101" | Pattern to include specific PXAR files |

### 9.4 PVE Backup Options
| Parameter | Default Value | Description |
|-----------|---------------|-------------|
| `MAX_PVE_BACKUP_SIZE` | "100M" | Maximum size for small PVE backup files |
| `PVE_BACKUP_INCLUDE_PATTERN` | "" | Pattern to include specific PVE backup files |

---

## 📝 Important Notes

1. **Required Configuration**: The `backup.env` file must be present and configured before running the backup system.

2. **Default Values**: All parameters have functional default values. Modify only those necessary for your configuration.

3. **Security**: Sensitive configurations (tokens, passwords) should be protected with appropriate permissions (600).

4. **Validation**: The system automatically verifies configuration validity at startup.

5. **Restart Required**: Some configuration changes require service restart to be applied.

---

**For more information, consult the main README.md file of the project.** 
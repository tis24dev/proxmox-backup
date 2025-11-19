# 🔄 Proxmox Backup PBS & PVE System Files - GO

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Go](https://img.shields.io/badge/Go-1.21+-00ADD8.svg?logo=go)](https://golang.org/)
[![Proxmox](https://img.shields.io/badge/Proxmox-PVE%20%7C%20PBS-E57000.svg)](https://www.proxmox.com/)
[![rclone](https://img.shields.io/badge/rclone-1.50+-136C9E.svg)](https://rclone.org/)
[![💖 Sponsor](https://img.shields.io/badge/Sponsor-GitHub%20Sponsors-pink?logo=github)](https://github.com/sponsors/tis24dev)
[![☕ Buy Me a Coffee](https://img.shields.io/badge/Buy%20Me%20a%20Coffee-tis24dev-yellow?logo=buymeacoffee)](https://buymeacoffee.com/tis24dev)

**Professional backup system for Proxmox Virtual Environment (PVE) and Proxmox Backup Server (PBS) configuration and critical files** - Rewritten in Go with advanced compression, multi-storage support, cloud integration, intelligent retention, and comprehensive monitoring.

> **Complete guide for installing, configuring, and using proxmox-backup**
>
> Version: 0.9.0 | Last Updated: 2025-11-17

---

### New features!!

Advanced AGE encryptio - Gotify and Webhook channels for notifications

Intelligent backup rotation - Intelligent deletion of logs associated with specific backups

---

## 📑 Table of Contents

- [🎯 Introduction](#introduction)
  - [Key Features](#key-features)
  - [System Requirements](#system-requirements)
- [🚀 Quick Start](#quick-start)
  - [1-Minute Setup](#1-minute-setup)
  - [First Backup Workflow](#first-backup-workflow)
- [💾 Installation](#installation)
  - [Prerequisites](#prerequisites)
  - [Building from Source](#building-from-source)
  - [Interactive Installation Wizard](#interactive-installation-wizard)
  - [Upgrading from Previous Bash Version](#upgrading-from-previous-bash-version-v074-bash-or-earlier)
  - [Legacy Bash Version](#legacy-bash-version-v074-bash)
- [⌨️ Command-Line Reference](#command-line-reference)
  - [Available Commands](#available-commands)
  - [Basic Operations](#basic-operations)
  - [Installation & Setup](#installation--setup)
  - [Encryption & Decryption](#encryption--decryption)
  - [Command Examples](#command-examples)
  - [Scheduling with Cron](#scheduling-with-cron)
- [⚙️ Configuration Reference](#configuration-reference)
  - [General Settings](#general-settings)
  - [Security Settings](#security-settings)
  - [Compression Settings](#compression-settings)
  - [Storage Paths](#storage-paths)
  - [Cloud Storage (rclone)](#cloud-storage-rclone)
  - [Retention Policies](#retention-policies)
  - [Encryption & Bundling](#encryption--bundling)
  - [Notifications](#notifications-telegram)
  - [Collector Options](#collector-options---pve)
- [☁️ Cloud Storage with rclone](#cloud-storage-with-rclone)
  - [Architecture](#architecture)
  - [Prerequisites](#prerequisites-1)
  - [Configuring rclone](#configuring-rclone)
  - [Performance Tuning](#performance-tuning)
  - [Testing](#testing)
  - [Troubleshooting](#troubleshooting-1)
  - [Disaster Recovery](#disaster-recovery)
- [🔐 Encryption Guide](#encryption-guide)
  - [Features](#features)
  - [Configure Recipients](#configure-recipients)
  - [Running Encrypted Backups](#running-encrypted-backups)
  - [Decrypting Backups](#decrypting-backups)
  - [Restoring Backups](#restoring-backups)
  - [Rotating Keys](#rotating-keys)
- [📝 Practical Examples](#practical-examples)
  - [Example 1: Basic Local Backup](#example-1-basic-local-backup)
  - [Example 2: Local + Secondary Storage](#example-2-local--secondary-storage)
  - [Example 3: Cloud Backup with Google Drive](#example-3-cloud-backup-with-google-drive)
  - [Example 4: Encrypted Backup with AGE](#example-4-encrypted-backup-with-age)
  - [Example 5: Backblaze B2 with Bandwidth Limiting](#example-5-backblaze-b2-with-bandwidth-limiting)
  - [Example 6: MinIO Self-Hosted](#example-6-minio-self-hosted-with-high-performance)
  - [Example 7: Multi-Notification Setup](#example-7-multi-notification-setup)
  - [Example 8: Complete Production Setup](#example-8-complete-production-setup)
- [🔧 Troubleshooting](#troubleshooting)
  - [Common Issues](#common-issues)
  - [Debug Procedures](#debug-procedures)
  - [Getting Help](#getting-help)
- [📚 Appendix](#appendix)
  - [Useful Commands](#useful-commands)
  - [FAQ](#faq)
- [🤝 Contributing](#contributing)
- [📄 License](#license)
- [📞 Support](#support)
- [⭐ Stargazers](#stargazers)

---

## Introduction

**proxmox-backup** is a comprehensive backup solution for Proxmox VE/PBS environments, rewritten in Go from a 20,370-line Bash codebase. It provides intelligent backup management with support for local, secondary, and cloud storage destinations.

### Key Features

✅ **Multi-tier Storage**: Local (critical) + Secondary (optional) + Cloud (optional)
✅ **Intelligent Retention**: Simple count-based or GFS (Grandfather-Father-Son) time-distributed
✅ **Cloud Integration**: Full rclone support for 40+ cloud providers
✅ **Encryption**: Streaming AGE encryption with no plaintext on disk
✅ **Compression**: Multiple algorithms (gzip, xz, zstd) with configurable levels
✅ **Notifications**: Telegram, Email, Gotify, and Webhook support
✅ **Advanced Features**: Parallel uploads, retry logic, batch deletion, metrics export

### System Requirements

- **OS**: Linux (Debian/Ubuntu/Proxmox tested)
- **Go**: Version 1.21+ (for building from source)
- **rclone**: Version 1.50+ (for cloud storage)
- **Disk Space**: Minimum 1GB for primary storage
- **Network**: Internet access (for cloud storage, notifications)

---

## Quick Start

### 1-Minute Setup

1. Download & start Install
```bash
cd /opt && mkdir -p proxmox-backup/build && cd proxmox-backup && wget -q https://raw.githubusercontent.com/tis24dev/go/main/build/proxmox-backup -O build/proxmox-backup && chmod +x build/proxmox-backup && ./build/proxmox-backup --install
```

2. OPTIONAL - Run igration installation from bash with old env file
```bash
./build/proxmox-backup --env-migration
```

3. Run your first backup with go version
```bash
./build/proxmox-backup
```

4. Check results
```bash
ls -lh backup/
```
```bash
cat log/backup-*.log
```

### First Backup Workflow

```bash
# Dry-run test (no actual changes)
./build/proxmox-backup --dry-run

# Real backup
./build/proxmox-backup

# View logs
tail -f log/backup-$(hostname)-*.log

# Check backup files
ls -lh backup/
```

---

## Installation

### Prerequisites (ONLY IF YOU WANT BUILD YOUR BINARY)

```bash
# Install Go (if building from source)
wget https://go.dev/dl/go1.25.4.linux-amd64.tar.gz
tar -C /usr/local -xzf go1.25.4.linux-amd64.tar.gz
export PATH=$PATH:/usr/local/go/bin

# Install rclone (for cloud storage)
curl https://rclone.org/install.sh | bash

# Install git
apt update && apt install -y git

# Install make
apt update && apt install -y make

# Verify installations
go version    # Should show go1.21+
rclone version  # Should show rclone v1.50+
git --version # Should show git 2.47.3+
make --version # Should show make 4.4.1+
```

### Building from Source

```bash
# Create folder
mkdir /opt/proxmox-backup

# Navigate to project directory
cd /opt/proxmox-backup

# Copy from github
git clone --branch main https://github.com/tis24dev/proxmox-backup.git .

# Initialize Go module
go mod init github.com/tis24dev/proxmox-backup

# Download dependencies
go mod tidy

# Build binary
make build

# Verify build
./build/proxmox-backup --version
```

### Interactive Installation Wizard

The installation wizard creates your configuration file interactively:

```bash
./build/proxmox-backup --install
```

**Wizard prompts:**

1. **Configuration file path**: Default `configs/backup.env` (accepts absolute or relative paths within repo)
2. **Secondary storage**: Optional path for backup/log copies
3. **Cloud storage**: Optional rclone remote configuration
4. **Notifications**: Enable Telegram (centralized) and email relay
5. **Encryption**: AGE encryption setup (runs sub-wizard immediately if enabled)

**Features:**
- Input sanitization (no newlines/control characters)
- Template comment preservation
- Creates all necessary directories with proper permissions (0700)
- Immediate AGE key generation if encryption is enabled

After completion, edit `configs/backup.env` manually for advanced options.

---

## Upgrading from Previous Bash Version (v0.7.4-bash or Earlier)

If you're currently using the Bash version of proxmox-backup (v0.7.4-bash or earlier), you can upgrade to the Go version with minimal effort. The Go version offers significant performance improvements while maintaining backward compatibility for most configuration variables.

### Compatibility Overview

- ✅ **Both versions can coexist**: The Bash and Go versions can run in the same directory (`/opt/proxmox-backup/`) as they use different internal paths and binary names
- ✅ **Most variables work unchanged**: ~70 configuration variables have identical names between Bash and Go
- ✅ **Automatic fallback support**: 16 renamed variables automatically read old Bash names via fallback mechanism
- ⚠️ **Some variables require manual conversion**: 2 variables have semantic changes (storage thresholds, cloud path format)
- ℹ️ **Legacy variables**: ~27 Bash-only variables are no longer used (replaced by improved internal logic)

### Migration Tools

#### Option 1: Interactive Tool

Automatic tool based on variable mapping: BACKUP_ENV_MAPPING.md (we recommend checking after migration to ensure everything went smoothly)

```bash
./build/proxmox-backup --env-migration
```

You can then manually add your custom variables by referring to the mapping guide.


#### Option 2: Migration Reference Guide (Recommended)

The project includes a complete environment variable mapping guide to help you migrate your configuration:

**📄 [BACKUP_ENV_MAPPING.md](BACKUP_ENV_MAPPING.md)** - Complete Bash → Go variable mapping reference

This guide categorizes every variable:
- **SAME**: Variables with identical names (just copy them)
- **RENAMED ✅**: Variables with new names but automatic fallback (old names still work)
- **SEMANTIC CHANGE ⚠️**: Variables requiring value conversion (e.g., percentage → GB)
- **LEGACY**: Bash-only variables no longer needed in Go

**Quick migration workflow:**
1. Open your Bash `backup.env`
1. Open your Go `backup.env`
3. Refer to `BACKUP_ENV_MAPPING.md` while copying your values
4. Most variables can be copied directly (SAME + RENAMED categories)
5. Pay attention to SEMANTIC CHANGE variables for manual conversion


### Upgrade Steps

1. **Build the Go version**
   ```bash
   cd /opt/proxmox-backup
   make build
   ```

2. **Migrate your configuration**

   **Option A: Automatic migration (recommended for existing users)**
   ```bash
   # Step 1: Preview migration (recommended first step)
   ./build/proxmox-backup --env-migration-dry-run

   # Review the output, then execute real migration
   ./build/proxmox-backup --env-migration

   # The tool will:
   # - Automatically map 70+ variables (SAME category)
   # - Convert 16 renamed variables (RENAMED category)
   # - Flag 2 variables for manual review (SEMANTIC CHANGE)
   # - Skip 27 legacy variables (LEGACY category)
   # - Create backup of existing config
   ```

   **Option B: Manual migration using mapping guide**
   ```bash
   # Edit with your Bash settings, using BACKUP_ENV_MAPPING.md as reference
   nano configs/backup.env
   ```

3. **Test the configuration**
   ```bash
   # Dry-run to verify configuration
   ./build/proxmox-backup --dry-run

   # Check the output for any warnings or errors
   ```

4. **Run a test backup**
   ```bash
   # First real backup
   ./build/proxmox-backup

   # Verify results
   ls -lh backup/
   cat log/backup-*.log
   ```

5. **Gradual cutover** (optional)

   The old Bash version remains functional and can be used as fallback during the transition period. You can run both versions in parallel for testing before fully switching to Go.

### Key Migration Notes

**Automatic variable fallbacks** - These old Bash variable names still work in Go:
- `LOCAL_BACKUP_PATH` → reads as `BACKUP_PATH`
- `ENABLE_CLOUD_BACKUP` → reads as `CLOUD_ENABLED`
- `PROMETHEUS_ENABLED` → reads as `METRICS_ENABLED`
- And 13 more (see mapping guide for complete list)

**Variables requiring conversion:**
- `STORAGE_WARNING_THRESHOLD_PRIMARY="90"` (% used) → `MIN_DISK_SPACE_PRIMARY_GB="1"` (GB free)
- `CLOUD_BACKUP_PATH="/remote:path/folder"` (full path) → `CLOUD_REMOTE_PATH="folder"` (prefix only)

**New Go-only features available:**
- GFS retention policies (`RETENTION_POLICY=gfs`)
- AGE encryption (`ENCRYPT_ARCHIVE=true`)
- Parallel cloud uploads (`CLOUD_UPLOAD_MODE=parallel`)
- Advanced security checks with auto-fix
- Gotify and webhook notifications
- Prometheus metrics export

### Troubleshooting Migration

**Problem**: "Configuration variable not recognized"
- **Solution**: Check `BACKUP_ENV_MAPPING.md` to see if the variable was renamed or is now LEGACY

**Problem**: Storage threshold warnings incorrect
- **Solution**: Convert percentage-based thresholds to GB-based (SEMANTIC CHANGE variables)

**Problem**: Cloud path not working
- **Solution**: Split `CLOUD_BACKUP_PATH` into `CLOUD_REMOTE` (remote:path) and `CLOUD_REMOTE_PATH` (prefix)

**Still having issues?**
- Review the complete mapping guide: [BACKUP_ENV_MAPPING.md](BACKUP_ENV_MAPPING.md)
- Compare your Bash config with the Go template side-by-side
- Enable debug logging: `./build/proxmox-backup --dry-run --log-level debug`

---

## Legacy Bash Version (v0.7.4-bash)

The original Bash script (20,370 lines) has been moved to the `old` branch and is no longer actively developed. However, it remains available for users who need it.

### Availability

- **Source code**: Available in the `old` branch of this repository
- **Installation script**: The `install.sh` file remains in the `main` branch for backward compatibility

### Installing the Legacy Bash Version

The legacy Bash version can still be installed using the original installation command:

#### Option 1: Fast Bash Install or Update or Reinstall
```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/tis24dev/proxmox-backup/main/install.sh)"
```

#### Option 2: Manual

Enter the /opt directory
```bash
cd /opt
```

Download the repository (stable release)
```bash
wget https://github.com/tis24dev/proxmox-backup/archive/refs/tags/v0.7.4-bash.tar.gz
```

Create the script directory
```bash
mkdir proxmox-backup
```

Extract the script files into the newly created directory, then delete the archive
```bash
tar xzf v0.7.4-bash.tar.gz -C proxmox-backup --strip-components=1 && rm v0.7.4-bash.tar.gz
```

Enter the script directory
```bash
cd proxmox-backup
```

Start the installation (runs initial checks, creates symlinks, creates cron)
```bash
./install.sh
```

Customize your settings
```bash
nano env/backup.env
```

Run first backup
```bash
./script/proxmox-backup.sh

```


**Important Notes:**

- ⚠️ **Manual confirmation required**: The `install.sh` script will ask for explicit confirmation before proceeding with the Bash version installation
- ⚠️ **Bash version only**: The `install.sh` script installs the **legacy Bash version** (v0.7.4-bash), NOT the new Go version
- 📌 **Why it exists**: The `install.sh` file remains in the `main` branch only to support existing installation URLs that may be circulating in documentation, scripts, or forums
- 🔄 **For Go version**: To install the new Go version, follow the [Installation](#installation) section above (build from source)

### Legacy vs Go Version

| Feature | Legacy Bash (v0.7.4) | Go Version (v0.9.0+) |
|---------|---------------------|---------------------|
| **Status** | Maintenance mode (old branch) | Active development (main branch) |
| **Installation** | `install.sh` script | Build from source |
| **Performance** | Slower (shell overhead) | 10-20x faster (compiled) |
| **Code size** | 20,370 lines | ~3,000 lines Go code |
| **Memory usage** | Higher (multiple processes) | Lower (single binary) |
| **Maintenance** | Archived, critical fixes only | Active development |
| **Compatibility** | Can coexist with Go version | Can coexist with Bash version |

### Recommendation

We **strongly recommend** upgrading to the Go version for:
- ✅ Better performance and reliability
- ✅ Active development and new features
- ✅ Cleaner codebase and easier maintenance
- ✅ Lower resource consumption

The legacy Bash version should only be used if you have specific compatibility requirements or cannot build the Go version.

---

## Command-Line Reference

### Available Commands (Go Version)

The binary `/opt/proxmox-backup/build/proxmox-backup` supports multiple operation modes:

#### Basic Operations

```bash
# Run backup with default config
./build/proxmox-backup

# Use custom config file
./build/proxmox-backup --config /path/to/config.env
./build/proxmox-backup -c /path/to/config.env

# Dry-run mode (test without changes)
./build/proxmox-backup --dry-run
./build/proxmox-backup -n

# Show version
./build/proxmox-backup --version
./build/proxmox-backup -v

# Show help
./build/proxmox-backup --help
./build/proxmox-backup -h
```

#### Installation & Setup

```bash
# Interactive installation wizard
./build/proxmox-backup --install

# Upgrade configuration file from embedded template
./build/proxmox-backup --upgrade-config

# Preview configuration upgrade (dry-run)
./build/proxmox-backup --upgrade-config-dry-run

# Migrate legacy Bash backup.env to Go configuration (pure migration)
./build/proxmox-backup --env-migration --old-env /opt/proxmox-backup/env/backup.env

# Or let the wizard prompt for the legacy path
./build/proxmox-backup --env-migration

# Preview migration without making changes (dry-run)
./build/proxmox-backup --env-migration-dry-run --old-env /opt/proxmox-backup/env/backup.env

# Or with interactive prompt
./build/proxmox-backup --env-migration-dry-run
```

**`--upgrade-config` use case**: After installing a new binary version, this command merges your current configuration with the latest embedded template, preserving your values while adding new options.

**`--env-migration` use case**: Pure configuration migration from a legacy Bash `backup.env` to the Go configuration file, using [BACKUP_ENV_MAPPING.md](BACKUP_ENV_MAPPING.md) to translate variable names and semantics.

**Migration workflow**:
1. Prompts for the legacy Bash `backup.env` path (or uses `--old-env` flag if provided)
2. Generates the Go `configs/backup.env` from the embedded template
3. Reads and parses the legacy Bash configuration file
4. Maps variables using [BACKUP_ENV_MAPPING.md](BACKUP_ENV_MAPPING.md) rules:
   - **SAME**: Variables copied directly (e.g., `BACKUP_ENABLED`, `COMPRESSION_TYPE`)
   - **RENAMED**: Old names automatically converted to new names (e.g., `LOCAL_BACKUP_PATH` → `BACKUP_PATH`)
   - **SEMANTIC CHANGE**: Variables flagged for manual review (e.g., `STORAGE_WARNING_THRESHOLD_*`)
   - **LEGACY**: Bash-only variables skipped (e.g., `ENABLE_EMOJI_LOG`, color codes)
5. Backs up any existing Go configuration (timestamped: `backup.env.bak-YYYYMMDD-HHMMSS`)
6. Writes the new Go configuration with migrated values
7. Reloads/validates the migrated config and prints warnings for manual review

**`--env-migration-dry-run` use case**: Preview mode that shows exactly what would be migrated without making any changes to your system. **Recommended as first step** before running `--env-migration`.

**Dry-run behavior**:
- ✅ Reads and parses the legacy Bash configuration
- ✅ Shows complete migration summary with statistics
- ✅ Lists all SEMANTIC CHANGE variables requiring manual review
- ✅ Displays the mapping for each category (SAME, RENAMED, LEGACY)
- ❌ Does NOT create or modify any files
- ❌ Does NOT run the installer
- ❌ Does NOT create configuration backups

**Why use dry-run first**:
1. **Verify variable mapping** before committing changes
2. **Identify SEMANTIC CHANGE variables** that need attention
3. **Review what gets skipped** (LEGACY category)
4. **Safe exploration** - no risk of breaking existing config

**What gets migrated**:
- ✅ ~70 unchanged variables (SAME category)
- ✅ 16 renamed variables with automatic conversion (RENAMED category)
- ⚠️ 2 variables flagged for manual review (SEMANTIC CHANGE - storage thresholds, cloud path)
- ❌ ~27 legacy variables skipped (LEGACY category - no longer needed)

**Post-migration steps**:
1. Review `configs/backup.env` for SEMANTIC CHANGE warnings
2. Manually convert storage thresholds: `%` used → `GB` free
3. Verify cloud path format: full path → prefix only
4. Test with dry-run: `./build/proxmox-backup --dry-run`
5. Check output for configuration warnings

**Example dry-run output** (`--env-migration-dry-run`):
```
[DRY-RUN] Reading legacy Bash configuration: /opt/proxmox-backup/env/backup.env
[DRY-RUN] Parsing 89 variables from legacy file...

[DRY-RUN] Migration summary:
✓ Would migrate 45 variables (SAME category)
✓ Would convert 12 variables (RENAMED category)
⚠ Manual review required: 2 variables (SEMANTIC CHANGE)
  - STORAGE_WARNING_THRESHOLD_PRIMARY → MIN_DISK_SPACE_PRIMARY_GB
    Bash: "90" (90% used) → Go: needs GB value (e.g., "10")
  - CLOUD_BACKUP_PATH → CLOUD_REMOTE_PATH
    Bash: "/gdrive:backups/folder" → Go: "backups/folder" (prefix only)
ℹ Would skip 18 legacy variables (LEGACY category)

[DRY-RUN] No files created or modified (preview mode)

✓ Dry-run complete. Run without --dry-run to execute migration.
```

**Example real migration output** (`--env-migration`):
```
✓ Migrated 45 variables (SAME category)
✓ Converted 12 variables (RENAMED category)
⚠ Review required: 2 variables (SEMANTIC CHANGE)
  - STORAGE_WARNING_THRESHOLD_PRIMARY → MIN_DISK_SPACE_PRIMARY_GB
  - CLOUD_BACKUP_PATH → CLOUD_REMOTE_PATH
ℹ Skipped 18 legacy variables (LEGACY category)

Configuration written to: /opt/proxmox-backup/configs/backup.env
Backup saved to: /opt/proxmox-backup/configs/backup.env.bak-20251117-143022

⚠ IMPORTANT: Review SEMANTIC CHANGE variables before running backup!
See BACKUP_ENV_MAPPING.md for conversion details.

Next step: ./build/proxmox-backup --dry-run
```

#### Encryption & Decryption

```bash
# Generate new AGE encryption key
./build/proxmox-backup --newkey
./build/proxmox-backup --age-newkey  # Alias

# Decrypt existing backup archive
./build/proxmox-backup --decrypt

# Restore data from backup to system
./build/proxmox-backup --restore
```

**`--newkey` workflow**:
1. Backs up existing recipient file (`recipient.txt.bak-YYYYMMDD-HHMMSS`)
2. Launches interactive AGE wizard
3. Updates `AGE_RECIPIENT_FILE` if necessary

**`--decrypt` workflow**:
1. Scans configured storage locations (local/secondary/cloud)
2. Lists available backups with metadata
3. Prompts for destination folder (default `./decrypt`)
4. Requests passphrase or AGE private key
5. Creates decrypted bundle: `<name>.tar.<algo>.decrypted.bundle.tar`

**`--restore` workflow**:
1. Same discovery as `--decrypt`
2. Extracts backup directly to system root (`/`)
3. Requires confirmation: type `RESTORE` to proceed
4. **WARNING**: Overwrites files in-place. Take system snapshot first!

#### Logging

```bash
# Set log level
./build/proxmox-backup --log-level debug
./build/proxmox-backup -l info    # debug|info|warning|error|critical
```

### Command Examples

```bash
# Standard backup
./build/proxmox-backup

# Dry-run with debug logging
./build/proxmox-backup --dry-run --log-level debug

# Use custom config
./build/proxmox-backup -c /etc/proxmox-backup/prod.env

# Generate encryption keys
./build/proxmox-backup --newkey

# Decrypt specific backup
./build/proxmox-backup --decrypt
# ... follow interactive prompts ...

# Full restore (DANGEROUS - test in VM first!)
./build/proxmox-backup --restore
# ... type RESTORE to confirm ...
```

### Scheduling with Cron

```bash
# Edit crontab
crontab -e

# Daily backup at 2 AM
0 2 * * * /opt/proxmox-backup/build/proxmox-backup >> /var/log/pbs-backup.log 2>&1

# Hourly backup
0 * * * * /opt/proxmox-backup/build/proxmox-backup

# Weekly backup (Sunday 3 AM)
0 3 * * 0 /opt/proxmox-backup/build/proxmox-backup
```

---

## Configuration Reference

The configuration file `configs/backup.env` contains 200+ variables organized into categories.

### Configuration File Location

**Default**: `/opt/proxmox-backup/configs/backup.env`
**Custom**: Specify with `--config` flag

### General Settings

```bash
# Enable/disable backup system
BACKUP_ENABLED=true                # true | false

# Enable Go pipeline (vs legacy Bash)
ENABLE_GO_BACKUP=true              # true | false

# Colored output in terminal
USE_COLOR=true                     # true | false

# Colorize "Step N/8" lines in logs
COLORIZE_STEP_LOGS=true            # true | false (requires USE_COLOR=true)

# Debug level
DEBUG_LEVEL=standard               # standard | advanced | extreme

# Dry-run mode (test without changes)
DRY_RUN=false                      # true | false

# Enable/disable always-on pprof profiling (CPU + heap)
PROFILING_ENABLED=true             # true | false (profiles written under LOG_PATH)
```

**`DEBUG_LEVEL` details**:
- `standard`: Basic operation logging
- `advanced`: Detailed command execution, file operations
- `extreme`: Full verbose output including rclone/compression internals

### Security Settings

```bash
# Security preflight check
SECURITY_CHECK_ENABLED=true                     # true | false

# Auto-update file hashes
AUTO_UPDATE_HASHES=true                         # true | false

# Auto-fix permissions
AUTO_FIX_PERMISSIONS=true                       # true | false

# Block backup on security issues
CONTINUE_ON_SECURITY_ISSUES=false               # false = block, true = warn

# Network security checks
CHECK_NETWORK_SECURITY=false                    # true | false
CHECK_FIREWALL=false                            # true | false
CHECK_OPEN_PORTS=false                          # true | false

# Suspicious port list (space-separated)
SUSPICIOUS_PORTS="6666 6665 1337 31337 4444 5555 4242 6324 8888 2222 3389 5900"

# Port whitelist (format: service:port)
PORT_WHITELIST=                                 # e.g., "sshd:22,nginx:443"

# Suspicious process names
SUSPICIOUS_PROCESSES="ncat,cryptominer,xmrig,kdevtmpfsi,kinsing,minerd,mr.sh"

# Safe process names (won't trigger alerts)
SAFE_BRACKET_PROCESSES="sshd:,systemd,cron,rsyslogd,dbus-daemon"
SAFE_KERNEL_PROCESSES="ksgxd,hwrng,usb-storage,vdev_autotrim,card1-crtc0,card1-crtc1,card1-crtc2,kvm-pit"

# Skip permission checks (use only for testing)
SKIP_PERMISSION_CHECK=false                     # true | false

# Permission management (Bash-compatible behavior)
BACKUP_USER=backup                              # System user for backup/log directory ownership
BACKUP_GROUP=backup                             # System group for backup/log directory ownership
SET_BACKUP_PERMISSIONS=false                    # true = apply chown/chmod on backup/log directories
```

**Security check behavior**:
- Verifies file permissions (0700 for directories, 0600 for sensitive files)
- Checks for suspicious open ports
- Scans for suspicious processes
- Validates file hashes to detect tampering
- **If `CONTINUE_ON_SECURITY_ISSUES=false`**: Backup aborts on any issue
- **If `CONTINUE_ON_SECURITY_ISSUES=true`**: Issues logged as warnings, backup continues

**Permission management behavior**:

When `SET_BACKUP_PERMISSIONS=true`, the system applies Bash-compatible ownership and permissions to backup/log directories:

- **Ownership (chown)**:
  - Recursively changes owner:group for:
    - `BACKUP_PATH` (primary backup directory)
    - `LOG_PATH` (primary log directory)
    - `SECONDARY_PATH` (if configured)
    - `SECONDARY_LOG_PATH` (if configured)
  - Uses `BACKUP_USER:BACKUP_GROUP` as the target owner
  - Does NOT touch binary files, config files, or system paths

- **Permissions (chmod)**:
  - Applies mode `0750` (rwxr-x---) to directories only
  - Files keep their existing permissions (unchanged)
  - Conservative and safe approach

- **Requirements**:
  - Both `BACKUP_USER` and `BACKUP_GROUP` must be set
  - User and group must already exist on the system
  - **Does NOT create users or groups** (unlike legacy Bash version)

- **Error handling**:
  - Non-fatal: All failures logged as warnings
  - Backup continues even if permission changes fail
  - User/group not found: logs warning and skips operation

- **Use cases**:
  - Migration from legacy Bash version
  - Multi-user environments requiring specific ownership
  - Shared backup storage with group access
  - NFS/CIFS mounts requiring specific ownership

- **Example**:
  ```bash
  # Create dedicated backup user/group first
  groupadd backup
  useradd -r -g backup -s /bin/false backup

  # Configure ownership
  BACKUP_USER=backup
  BACKUP_GROUP=backup
  SET_BACKUP_PERMISSIONS=true

  # Result: All backup/log directories owned by backup:backup with mode 0750
  ```

### Disk Space

```bash
# Minimum free space required (GB)
MIN_DISK_SPACE_PRIMARY_GB=1        # Primary storage
MIN_DISK_SPACE_SECONDARY_GB=1      # Secondary storage
MIN_DISK_SPACE_CLOUD_GB=1          # Cloud storage (not enforced for remote)
```

**Behavior**: Backup aborts if available space < minimum threshold.

### Storage Paths

```bash
# Base directory for all operations
BASE_DIR=/opt/proxmox-backup

# Lock file directory
LOCK_PATH=${BASE_DIR}/lock

# Credentials directory
SECURE_ACCOUNT=${BASE_DIR}/secure_account

# Primary backup storage
BACKUP_PATH=${BASE_DIR}/backup

# Primary log storage
LOG_PATH=${BASE_DIR}/log
```

**Path resolution**: `${BASE_DIR}` expands automatically. Use absolute paths or relative to `BASE_DIR`.

### Compression Settings

```bash
# Compression algorithm
COMPRESSION_TYPE=xz                # none | gzip | pigz | bzip2 | xz | lzma | zstd

# Compression level
COMPRESSION_LEVEL=9                # Range depends on algorithm (see table below)

# Compression threads (0 = auto-detect CPU cores)
COMPRESSION_THREADS=0              # 0 = auto, >0 = fixed thread count

# Compression mode
COMPRESSION_MODE=ultra             # fast | standard | maximum | ultra
```

**Compression algorithm details**:

| Algorithm | Level Range | Notes |
|-----------|-------------|-------|
| `none` | 0 | No compression |
| `gzip` | 1-9 | Single-threaded, widely compatible |
| `pigz` | 1-9 | Parallel gzip, faster on multi-core |
| `bzip2` | 1-9 | Higher compression, slower |
| `xz` | 0-9 | Excellent compression, supports `--extreme` |
| `lzma` | 0-9 | Similar to xz |
| `zstd` | 1-22 | Fast, good compression (>19 uses `--ultra`) |

**Compression modes**:
- `fast`: Lower levels, faster execution
- `standard`: Balanced
- `maximum`: Level 9 for gzip/bzip2/xz, level 19 for zstd
- `ultra`: Adds `--extreme` for xz/lzma, level 22 for zstd

**Examples**:
```bash
# Fast backup (large files, quick compression)
COMPRESSION_TYPE=zstd
COMPRESSION_LEVEL=3
COMPRESSION_MODE=fast

# Maximum compression (archival, storage limited)
COMPRESSION_TYPE=xz
COMPRESSION_LEVEL=9
COMPRESSION_MODE=ultra
COMPRESSION_THREADS=0  # Use all CPU cores

# No compression (already compressed data)
COMPRESSION_TYPE=none
```

### Advanced Optimizations

```bash
# Enable smart chunking for large files
ENABLE_SMART_CHUNKING=true         # true | false

# Enable deduplication
ENABLE_DEDUPLICATION=true          # true | false

# Enable prefiltering
ENABLE_PREFILTER=true              # true | false

# Chunking threshold (MB)
CHUNK_THRESHOLD_MB=50              # Files >50MB are chunked

# Chunk size (MB)
CHUNK_SIZE_MB=10                   # Each chunk is 10MB

# Prefilter max file size (MB)
PREFILTER_MAX_FILE_SIZE_MB=8       # Skip prefilter for files >8MB
```

**What these do**:
- **Smart chunking**: Splits large files for parallel processing
- **Deduplication**: Detects duplicate data blocks (reduces storage)
- **Prefilter**: Analyzes small files before compression (optimizes algorithm selection)

### Network Preflight

```bash
# Skip network connectivity checks
DISABLE_NETWORK_PREFLIGHT=false    # false = check, true = skip

# Use case: Offline environments without Telegram/email/cloud
```

**Behavior**:
- **false (default)**: Verifies connectivity before using network features
- **true**: Skips checks (operations may fail later if network unavailable)

### Collection Exclusions

```bash
# Glob patterns to exclude (space or comma separated)
BACKUP_EXCLUDE_PATTERNS="*/cache/**, /var/tmp/**, *.log"
```

**Pattern syntax**:
- `*`: Match any file
- `**`: Match any directory recursively
- Example: `*/cache/**` excludes all `cache/` subdirectories

### Secondary Storage

```bash
# Enable secondary storage
SECONDARY_ENABLED=false            # true | false

# Secondary backup path
SECONDARY_PATH=/mnt/secondary/backup

# Secondary log path
SECONDARY_LOG_PATH=/mnt/secondary/log
```

**Use case**: Local NAS, mounted network drive, external USB storage.

**Behavior**:
- Secondary storage is **non-critical** (failures log warnings, don't abort backup)
- Files copied via native Go (no dependency on rclone)
- Same retention policy as primary storage

### Cloud Storage (rclone)

```bash
# Enable cloud storage
CLOUD_ENABLED=false                # true | false

# rclone remote (format: remote:path)
CLOUD_REMOTE=gdrive:pbs-backups    # e.g., gdrive:backups, s3:bucket-name

# Optional prefix inside remote
CLOUD_REMOTE_PATH=                 # e.g., "datacenter1/pbs1"

# Cloud log path (full remote path)
CLOUD_LOG_PATH=                    # e.g., "gdrive:/pbs-logs"

# Upload mode
CLOUD_UPLOAD_MODE=parallel         # sequential | parallel

# Parallel worker count
CLOUD_PARALLEL_MAX_JOBS=2          # Workers for associated files

# Verify files in parallel
CLOUD_PARALLEL_VERIFICATION=true   # true | false

# Preflight write test
CLOUD_WRITE_HEALTHCHECK=false      # true | false (creates temp file to test access)
```

**Remote format**: `<remote-name>:<path>`
- `remote-name`: Configured in `rclone config`
- `:` (colon): Required separator
- `path`: Directory inside remote (optional for root)

**Examples**:
- `gdrive:pbs-backups` → Google Drive, folder "pbs-backups"
- `s3:my-bucket/backups` → S3 bucket, subfolder "backups"
- `minio:/pbs` → MinIO, absolute path "/pbs"

**Upload modes**:
- **sequential**: Upload files one at a time (lower memory, predictable)
- **parallel**: Upload main file sequentially, then associated files (.sha256, .metadata, .bundle) in parallel (faster, uses more memory)

**See [Cloud Storage with rclone](#cloud-storage-with-rclone) section for complete guide.**

### rclone Settings

```bash
# Connection timeout (seconds)
RCLONE_TIMEOUT_CONNECTION=30       # Remote accessibility check

# Operation timeout (seconds)
RCLONE_TIMEOUT_OPERATION=300       # Upload/download operations (5 minutes default)

# Bandwidth limit
RCLONE_BANDWIDTH_LIMIT=            # Empty = unlimited, "10M" = 10 MB/s

# Parallel transfers inside rclone
RCLONE_TRANSFERS=16                # Number of simultaneous file transfers

# Retry attempts
RCLONE_RETRIES=3                   # Retry count for failed operations

# Verification method
RCLONE_VERIFY_METHOD=primary       # primary | alternative

# Additional rclone flags
RCLONE_FLAGS="--checkers=4 --stats=0 --drive-use-trash=false --drive-pacer-min-sleep=10ms --drive-pacer-burst=100"
```

**Timeout tuning**:
- **CONNECTION**: Short timeout for quick accessibility check (default 30s)
- **OPERATION**: Long timeout for large file uploads (increase for slow networks)

**Bandwidth limit format**:
- `""` = Unlimited
- `"10M"` = 10 MB/s
- `"512K"` = 512 KB/s

**Verification methods**:
- **primary**: Uses `rclone lsl <file>` (fast, direct)
- **alternative**: Uses `rclone ls <directory>` then searches (slower, compatible with all remotes)

### Batch Deletion (Cloud)

```bash
# Files per batch
CLOUD_BATCH_SIZE=20                # Delete max 20 files per batch

# Pause between batches (seconds)
CLOUD_BATCH_PAUSE=1                # Wait 1 second between batches
```

**Purpose**: Avoid API rate limiting during retention cleanup.

**Example**: Deleting 50 files with `BATCH_SIZE=20`, `BATCH_PAUSE=1`:
- Batch 1: Delete files 1-20, pause 1s
- Batch 2: Delete files 21-40, pause 1s
- Batch 3: Delete files 41-50, done

**Provider tuning**:
- Google Drive: `BATCH_SIZE=10-15`, `BATCH_PAUSE=2-3`
- S3/Wasabi: `BATCH_SIZE=50-100`, `BATCH_PAUSE=1`
- Backblaze B2: `BATCH_SIZE=20-30`, `BATCH_PAUSE=2`
- MinIO (self-hosted): `BATCH_SIZE=100+`, `BATCH_PAUSE=0`

### Retention Policies

Two mutually exclusive strategies:

#### 1. Simple Retention (Count-Based)

```bash
# Retention policy mode
RETENTION_POLICY=simple            # simple | gfs

# Keep N most recent backups
MAX_LOCAL_BACKUPS=15               # Primary storage
MAX_SECONDARY_BACKUPS=15           # Secondary storage
MAX_CLOUD_BACKUPS=15               # Cloud storage
```

**Behavior**:
- Keeps N most recent backups
- Deletes all older backups
- Simple, predictable
- Good for frequent backups with limited storage

**Example**: With `MAX_LOCAL_BACKUPS=30` and daily backups, keeps last 30 days.

#### 2. GFS Retention (Grandfather-Father-Son)

```bash
# Retention policy mode
RETENTION_POLICY=gfs               # Activates GFS mode

# GFS tiers
RETENTION_DAILY=7                  # Keep last 7 daily backups (minimum accepted is 1; 0 treated as 1)
RETENTION_WEEKLY=4                 # Keep 4 weekly backups (1 per ISO week)
RETENTION_MONTHLY=12               # Keep 12 monthly backups (1 per month)
RETENTION_YEARLY=3                 # Keep 3 yearly backups (1 per year)
```

**GFS algorithm**:

| Tier | Selection Criteria | Example (7/4/12/3) |
|------|-------------------|-------------------|
| Daily | Most recent N backups | Last 7 backups (2025-11-17, 11-16, ..., 11-11) |
| Weekly | 1 per ISO week, excluding daily | Weeks 46, 45, 44, 43 (1 backup per week) |
| Monthly | 1 per month, excluding daily/weekly | Nov 2025, Oct 2025, ..., Dec 2024 |
| Yearly | 1 per year, excluding daily/weekly/monthly | 2025, 2024, 2023 |

**Benefits**:
- Better historical coverage than simple count
- Automatic time distribution
- ISO 8601 week numbering (standard)
- Efficient storage (fewer total backups)

**Example output**:
```
GFS classification → daily: 7/7, weekly: 4/4, monthly: 12/12, yearly: 2/3, to_delete: 15
Deleting old backup: pbs-backup-20220115-120000.tar.xz (created: 2022-01-15 12:00:00)
Cloud storage retention applied: deleted 15 backups (logs deleted: 15), 26 backups remaining
```

**Storage comparison**:
- **Simple**: `MAX_CLOUD_BACKUPS=1095` for 3 years daily = 1095 backups
- **GFS**: `DAILY=7, WEEKLY=4, MONTHLY=12, YEARLY=3` = ~26 backups (97% storage reduction!)

### Encryption & Bundling

```bash
# Bundle associated files into single .tar
BUNDLE_ASSOCIATED_FILES=true       # true | false

# Encrypt archive with AGE
ENCRYPT_ARCHIVE=false              # true | false

# AGE public key recipient (inline)
AGE_RECIPIENT=                     # e.g., "age1..."

# AGE recipient file path
AGE_RECIPIENT_FILE=${BASE_DIR}/identity/age/recipient.txt
```

**Bundle format**: `<name>.tar.<algo>.age.bundle.tar` containing:
- Main archive (`.tar.xz.age`)
- Checksum (`.sha256`)
- Metadata (`.metadata`)

**Encryption**:
- Uses AGE (age-encryption.org)
- Streaming encryption (no plaintext on disk)
- Supports multiple recipients
- Passphrase or key-based

**See [Encryption Guide](#encryption-guide) section for complete workflow.**

### Notifications - Telegram

```bash
# Enable Telegram notifications
TELEGRAM_ENABLED=false             # true | false

# Bot type
BOT_TELEGRAM_TYPE=centralized      # centralized | personal

# Personal mode settings
TELEGRAM_BOT_TOKEN=                # Bot token (from @BotFather)
TELEGRAM_CHAT_ID=                  # Chat ID (your user ID or group ID)
```

**Bot types**:
- **centralized**: Uses organization-wide bot (configured server-side)
- **personal**: Uses your own bot (requires `TELEGRAM_BOT_TOKEN` and `TELEGRAM_CHAT_ID`)

**Setup personal bot**:
1. Message @BotFather on Telegram: `/newbot`
2. Copy token to `TELEGRAM_BOT_TOKEN`
3. Message @userinfobot: `/start` (get your chat ID)
4. Copy ID to `TELEGRAM_CHAT_ID`

### Notifications - Email

```bash
# Enable email notifications
EMAIL_ENABLED=false                # true | false

# Delivery method
EMAIL_DELIVERY_METHOD=relay        # relay | sendmail

# Fallback to sendmail if relay fails
EMAIL_FALLBACK_SENDMAIL=true       # true | false

# Recipient (empty = auto-detect from Proxmox)
EMAIL_RECIPIENT=                   # e.g., "admin@example.com"

# From address
EMAIL_FROM=no-reply@proxmox.tis24.it
```

**Delivery methods**:
- **relay**: Uses SMTP relay (requires server configuration)
- **sendmail**: Uses local sendmail binary

### Notifications - Gotify

```bash
# Enable Gotify notifications
GOTIFY_ENABLED=false               # true | false

# Gotify server URL
GOTIFY_SERVER_URL=                 # e.g., "https://gotify.example.com"

# Application token
GOTIFY_TOKEN=                      # From Gotify Apps page

# Priority levels
GOTIFY_PRIORITY_SUCCESS=2          # Success notifications
GOTIFY_PRIORITY_WARNING=5          # Warning notifications
GOTIFY_PRIORITY_FAILURE=8          # Failure notifications
```

**Setup**:
1. Install Gotify server (https://gotify.net)
2. Create application in Gotify
3. Copy app token to `GOTIFY_TOKEN`

### Notifications - Webhook

```bash
# Enable webhook notifications
WEBHOOK_ENABLED=false              # true | false

# Comma-separated endpoint names
WEBHOOK_ENDPOINTS=                 # e.g., "discord_alerts,teams_ops"

# Default payload format
WEBHOOK_FORMAT=generic             # discord | slack | teams | generic

# Request timeout (seconds)
WEBHOOK_TIMEOUT=30

# Retry configuration
WEBHOOK_MAX_RETRIES=3
WEBHOOK_RETRY_DELAY=2              # Seconds between retries
```

**Per-endpoint configuration** (example for endpoint named `discord_alerts`):

```bash
# URL
WEBHOOK_DISCORD_ALERTS_URL=https://discord.com/api/webhooks/XXXX/YYY

# Payload format
WEBHOOK_DISCORD_ALERTS_FORMAT=discord  # discord | slack | teams | generic

# HTTP method
WEBHOOK_DISCORD_ALERTS_METHOD=POST     # POST | GET | HEAD

# Custom headers (comma-separated)
WEBHOOK_DISCORD_ALERTS_HEADERS="X-Custom-Token:abc123,X-Another:value"

# Authentication type
WEBHOOK_DISCORD_ALERTS_AUTH_TYPE=none  # none | bearer | basic | hmac

# Authentication credentials
WEBHOOK_DISCORD_ALERTS_AUTH_TOKEN=     # Bearer token
WEBHOOK_DISCORD_ALERTS_AUTH_USER=      # Basic auth username
WEBHOOK_DISCORD_ALERTS_AUTH_PASS=      # Basic auth password
WEBHOOK_DISCORD_ALERTS_AUTH_SECRET=    # HMAC secret key
```

**Supported formats**:
- **discord**: Discord webhook JSON format
- **slack**: Slack incoming webhook format
- **teams**: Microsoft Teams connector format
- **generic**: Simple JSON `{"status": "...", "message": "..."}`

### Metrics - Prometheus

```bash
# Enable Prometheus metrics export
METRICS_ENABLED=false              # true | false

# Metrics export path (textfile collector format)
METRICS_PATH=${BASE_DIR}/metrics   # Empty = /var/lib/prometheus/node-exporter
```

> ℹ️ Metrics export is available only for the Go pipeline (`ENABLE_GO_BACKUP=true`).

**Output**: Creates `proxmox_backup.prom` in `METRICS_PATH` with:
- Backup duration and start/end timestamps
- Archive size and raw bytes collected
- Files collected/failed and success/failure status
- Storage usage counters per location (local/secondary/cloud)

**Integration**: Point Prometheus node_exporter to `METRICS_PATH`.

### Collector Options - PVE

```bash
# Cluster configuration
BACKUP_CLUSTER_CONFIG=true         # /etc/pve/cluster files

# PVE firewall rules
BACKUP_PVE_FIREWALL=true           # PVE firewall configuration

# vzdump configuration
BACKUP_VZDUMP_CONFIG=true          # /etc/vzdump.conf

# Access control lists
BACKUP_PVE_ACL=true                # User permissions

# Scheduled jobs
BACKUP_PVE_JOBS=true               # Backup jobs configuration
BACKUP_PVE_SCHEDULES=true          # Cron schedules

# Replication
BACKUP_PVE_REPLICATION=true        # VM/CT replication config

# PVE backup files
BACKUP_PVE_BACKUP_FILES=true       # Include backup files from /var/lib/vz/dump
BACKUP_SMALL_PVE_BACKUPS=false     # Include small backups only
MAX_PVE_BACKUP_SIZE=100M           # Max size for "small" backups
PVE_BACKUP_INCLUDE_PATTERN=        # Glob patterns to include

# Ceph configuration
BACKUP_CEPH_CONFIG=false           # Ceph cluster config
CEPH_CONFIG_PATH=/etc/ceph         # Ceph config directory

# VM/CT configurations
BACKUP_VM_CONFIGS=true             # VM/CT config files
```

### Collector Options - PBS

```bash
# PBS datastore configs
BACKUP_DATASTORE_CONFIGS=true      # Datastore definitions

# User and permissions
BACKUP_USER_CONFIGS=true           # PBS users and tokens

# Remote configurations
BACKUP_REMOTE_CONFIGS=true         # Remote PBS servers

# Sync jobs
BACKUP_SYNC_JOBS=true              # Datastore sync jobs

# Verification jobs
BACKUP_VERIFICATION_JOBS=true      # Backup verification schedules

# Tape backup
BACKUP_TAPE_CONFIGS=true           # Tape library configuration

# Prune schedules
BACKUP_PRUNE_SCHEDULES=true        # Retention prune schedules

# PXAR metadata scanning
PXAR_SCAN_ENABLE=false             # Enable PXAR file metadata collection
PXAR_SCAN_DS_CONCURRENCY=3         # Datastores scanned in parallel
PXAR_SCAN_INTRA_CONCURRENCY=4      # Workers per datastore
PXAR_SCAN_FANOUT_LEVEL=2           # Directory depth for fan-out
PXAR_SCAN_MAX_ROOTS=2048           # Max worker roots per datastore
PXAR_STOP_ON_CAP=false             # Stop enumeration at max roots
PXAR_ENUM_READDIR_WORKERS=4        # Parallel ReadDir workers
PXAR_ENUM_BUDGET_MS=0              # Time budget for enumeration (0=disabled)
PXAR_FILE_INCLUDE_PATTERN=         # Include patterns (default: *.pxar, catalog.pxar*)
PXAR_FILE_EXCLUDE_PATTERN=         # Exclude patterns (e.g., *.tmp, *.lock)
```

**PXAR scanning**: Collects metadata from Proxmox Backup Server .pxar archives.

### Override Collection Paths

```bash
# PVE paths
PVE_CONFIG_PATH=/etc/pve
PVE_CLUSTER_PATH=/var/lib/pve-cluster
COROSYNC_CONFIG_PATH=${PVE_CONFIG_PATH}/corosync.conf
VZDUMP_CONFIG_PATH=/etc/vzdump.conf

# PBS datastore paths (comma/space separated)
PBS_DATASTORE_PATH=                # e.g., "/mnt/pbs1,/mnt/pbs2"
```

**Use case**: Working with mounted snapshots or mirrors at non-standard paths.

### Collector Options - System

```bash
# Network configuration
BACKUP_NETWORK_CONFIGS=true        # /etc/network/interfaces, /etc/hosts

# APT sources
BACKUP_APT_SOURCES=true            # /etc/apt/sources.list*

# Cron jobs
BACKUP_CRON_JOBS=true              # /etc/crontab, /etc/cron.*

# Systemd services
BACKUP_SYSTEMD_SERVICES=true       # /etc/systemd/system

# SSL certificates
BACKUP_SSL_CERTS=true              # /etc/ssl/certs, /etc/pve/local/pve-ssl.*

# Sysctl configuration
BACKUP_SYSCTL_CONFIG=true          # /etc/sysctl.conf, /etc/sysctl.d/

# Kernel modules
BACKUP_KERNEL_MODULES=true         # /etc/modules, /etc/modprobe.d/

# Firewall rules
BACKUP_FIREWALL_RULES=true         # iptables, nftables

# Installed packages
BACKUP_INSTALLED_PACKAGES=true     # dpkg -l, apt-mark showmanual

# Custom script directory
BACKUP_SCRIPT_DIR=true             # /opt/proxmox-backup directory

# Critical system files
BACKUP_CRITICAL_FILES=true         # /etc/fstab, /etc/hostname, /etc/resolv.conf

# SSH keys
BACKUP_SSH_KEYS=true               # /root/.ssh

# ZFS configuration
BACKUP_ZFS_CONFIG=true             # /etc/zfs, /etc/hostid, zpool cache & properties

# Root home directory
BACKUP_ROOT_HOME=true              # /root (excluding .cache, .local/share/Trash)

# Backup script repository
BACKUP_SCRIPT_REPOSITORY=false     # Include .git directory

# Backup configuration file
BACKUP_CONFIG_FILE=true            # Include this backup.env configuration file in the backup
```

**Note**: `BACKUP_CONFIG_FILE=true` automatically includes the `configs/backup.env` file in the backup archive. This is highly recommended for disaster recovery, as it allows you to restore your exact backup configuration along with the system files. If you have sensitive credentials in `backup.env`, ensure your backups are encrypted (`ENCRYPT_ARCHIVE=true`).

### Custom Paths & Blacklist

```bash
# Custom paths to include (one per line)
CUSTOM_BACKUP_PATHS="
# /root/.config/rclone/rclone.conf
# /srv/custom-config.yaml
# /etc/custom/tool.conf
"

# Paths to exclude (one per line)
BACKUP_BLACKLIST="
# /root/.cache
# /root/*_tmp
"
```

**Format**: Bash-style heredoc, one path per line, `#` for comments.

---

## Cloud Storage with rclone

Complete guide to configuring rclone for cloud backup storage.

### Architecture

proxmox-backup uses a **3-tier storage system**:

```
┌─────────────────────────────────────────────────────────────┐
│                    BACKUP ORCHESTRATOR                      │
└─────────────────────────────────────────────────────────────┘
                            │
            ┌───────────────┼───────────────┐
            │               │               │
            ▼               ▼               ▼
┌───────────────────┐ ┌───────────────┐ ┌─────────────────┐
│  LOCAL STORAGE    │ │   SECONDARY   │ │ CLOUD STORAGE   │
│   (Primary)       │ │   STORAGE     │ │   (rclone)      │
├───────────────────┤ ├───────────────┤ ├─────────────────┤
│ Critical: YES     │ │ Critical: NO  │ │ Critical: NO    │
│ Required: YES     │ │ Optional: YES │ │ Optional: YES   │
│ Failure: ABORT    │ │ Failure: WARN │ │ Failure: WARN   │
└───────────────────┘ └───────────────┘ └─────────────────┘
         │                    │                   │
         ▼                    ▼                   ▼
  /opt/backup/         /mnt/secondary/      gdrive:backups/
```

**Design principle**: Cloud storage is **NON-CRITICAL**. Upload failures log warnings but don't abort the backup.

### Prerequisites

#### Install rclone

```bash
# Verify installation
which rclone
rclone version

# Install via official script (recommended)
curl https://rclone.org/install.sh | sudo bash

# Or via package manager
# Debian/Ubuntu
sudo apt-get update && sudo apt-get install rclone

# CentOS/RHEL
sudo yum install rclone

# Or manual download
wget https://downloads.rclone.org/rclone-current-linux-amd64.zip
unzip rclone-current-linux-amd64.zip
sudo cp rclone-*/rclone /usr/local/bin/
sudo chmod 755 /usr/local/bin/rclone

# Verify
rclone version  # Should show v1.50+
```

#### Supported Cloud Providers

| Provider | rclone Type | Use Case |
|----------|-------------|----------|
| Google Drive | `drive` | Small/medium businesses, 15GB free |
| Amazon S3 | `s3` | Enterprise, scalable, highly available |
| Backblaze B2 | `b2` | Cost-effective, 10GB free |
| Microsoft OneDrive | `onedrive` | Microsoft 365 integration |
| Dropbox | `dropbox` | Simple, limited free space |
| MinIO | `s3` | Self-hosted S3-compatible |
| Wasabi | `s3` | S3-compatible, no egress fees |
| SFTP/FTP | `sftp`/`ftp` | Generic remote server |

### Configuring rclone

#### Interactive Configuration

```bash
# Launch interactive wizard
rclone config

# Create new remote
n                          # New remote
<remote-name>              # e.g., "gdrive", "s3backup"
<storage-type>             # e.g., "drive", "s3", "b2"
# ... follow provider-specific prompts ...
y                          # Confirm
q                          # Quit
```

#### Example 1: Google Drive

```bash
rclone config

n                          # New remote
gdrive                     # Remote name
drive                      # Storage type (Google Drive)
                          # Client ID (press enter for default)
                          # Client Secret (press enter for default)
1                          # Scope: Full access
                          # Root folder ID (press enter)
                          # Service account (press enter for no)
n                          # Advanced config? No
y                          # Auto config (opens browser for OAuth)
# [Authorize in browser]
y                          # Confirm
q                          # Quit
```

**Google Drive notes**:
- Uses OAuth2 (requires browser for first auth)
- API limit: ~1000 requests per 100 seconds
- Tuning: `CLOUD_BATCH_SIZE=10`, `CLOUD_BATCH_PAUSE=2`

**Test remote**:
```bash
rclone mkdir gdrive:pbs-backups
echo "test" > /tmp/test.txt
rclone copy /tmp/test.txt gdrive:pbs-backups/
rclone ls gdrive:pbs-backups/
# Should show: test.txt
rclone deletefile gdrive:pbs-backups/test.txt
```

#### Example 2: Amazon S3

```bash
rclone config

n                          # New remote
s3backup                   # Remote name
s3                         # Storage type
1                          # Provider: AWS
1                          # Credentials: IAM
# Or enter manually:
# AKIAIOSFODNN7EXAMPLE      # Access key ID
# wJalrXUtn...EXAMPLEKEY    # Secret access key
eu-central-1               # Region
                          # Endpoint (default AWS)
                          # Location constraint (auto)
                          # ACL (default)
n                          # Advanced config? No
y                          # Confirm
q                          # Quit
```

**S3 notes**:
- Requires Access Key ID + Secret Access Key
- Choose region close to your location
- High reliability (99.999999999% durability)
- Consider S3 Standard (hot data) or Glacier (cold storage)

#### Example 3: MinIO (Self-hosted)

```bash
rclone config

n                          # New remote
minio                      # Remote name
s3                         # Storage type (S3 compatible)
5                          # Provider: Minio
false                      # Get credentials from runtime? No
minioadmin                 # Access key (default MinIO)
minioadmin                 # Secret key (default MinIO)
                          # Region (empty for MinIO)
https://minio.example.com  # Endpoint
                          # Location constraint (empty)
n                          # Advanced config? No
y                          # Confirm
q                          # Quit
```

**MinIO notes**:
- S3-compatible, self-hosted
- Full control over data and costs
- Requires MinIO server setup
- Use HTTPS for security

#### Example 4: Backblaze B2

```bash
rclone config

n                          # New remote
b2                         # Remote name
b2                         # Storage type
001234567890abcdef         # Account ID
K001abcdefghijklmnopqrs    # Application Key
                          # Hard delete? No (default)
n                          # Advanced config? No
y                          # Confirm
q                          # Quit
```

**B2 notes**:
- Cost-effective: $0.005/GB/month (vs S3 $0.023)
- 10GB free storage + 1GB/day free download
- Lower API rate limit than S3
- Ideal for long-term archival

### Verify Configuration

```bash
# List configured remotes
rclone listremotes
# Output: gdrive:, s3backup:, minio:, b2:

# Show configuration (no passwords)
rclone config show gdrive

# Test connectivity
rclone lsf gdrive:
# Empty output or directory list = working
# Error = configuration issue
```

### Secure Configuration

```bash
# Check config file location
rclone config file
# Output: /root/.config/rclone/rclone.conf

# Set secure permissions
chmod 600 ~/.config/rclone/rclone.conf
chown root:root ~/.config/rclone/rclone.conf

# IMPORTANT: Backup rclone config
# Add to backup.env:
CUSTOM_BACKUP_PATHS="
/root/.config/rclone/rclone.conf
/opt/proxmox-backup/configs/backup.env
"
```

### Configure proxmox-backup

#### Minimal Configuration

```bash
# Edit backup.env
nano /opt/proxmox-backup/configs/backup.env

# Enable cloud storage
CLOUD_ENABLED=true
CLOUD_REMOTE=gdrive:pbs-backups

# Retention
MAX_CLOUD_BACKUPS=30
```

This is sufficient to start! Other options use sensible defaults.

#### Recommended Production Configuration

```bash
# Cloud storage
CLOUD_ENABLED=true
CLOUD_REMOTE=gdrive:pbs-backups
CLOUD_REMOTE_PATH=                    # Optional prefix
CLOUD_LOG_PATH=gdrive:/pbs-logs       # Separate log path

# Upload mode
CLOUD_UPLOAD_MODE=parallel
CLOUD_PARALLEL_MAX_JOBS=2
CLOUD_PARALLEL_VERIFICATION=true

# Timeouts
RCLONE_TIMEOUT_CONNECTION=30
RCLONE_TIMEOUT_OPERATION=300          # 5 minutes

# Bandwidth
RCLONE_BANDWIDTH_LIMIT=               # Empty = unlimited
RCLONE_TRANSFERS=4

# Retry & verification
RCLONE_RETRIES=3
RCLONE_VERIFY_METHOD=primary

# Batch deletion
CLOUD_BATCH_SIZE=20
CLOUD_BATCH_PAUSE=1

# GFS retention
RETENTION_POLICY=gfs
RETENTION_DAILY=7
RETENTION_WEEKLY=4
RETENTION_MONTHLY=12
RETENTION_YEARLY=3
```

### Performance Tuning

#### By Network Type

**Fast Network (Fiber, LAN, Datacenter)**:
```bash
CLOUD_UPLOAD_MODE=parallel
CLOUD_PARALLEL_MAX_JOBS=4
RCLONE_TRANSFERS=8
RCLONE_BANDWIDTH_LIMIT=
RCLONE_TIMEOUT_OPERATION=300
```

**Slow Network (ADSL, 4G, Satellite)**:
```bash
CLOUD_UPLOAD_MODE=sequential
CLOUD_PARALLEL_MAX_JOBS=1
RCLONE_TRANSFERS=2
RCLONE_BANDWIDTH_LIMIT=2M
RCLONE_TIMEOUT_OPERATION=1800
RCLONE_RETRIES=5
```

**Shared Network (Office, Multi-tenant)**:
```bash
CLOUD_UPLOAD_MODE=parallel
CLOUD_PARALLEL_MAX_JOBS=2
RCLONE_TRANSFERS=4
RCLONE_BANDWIDTH_LIMIT=5M
RCLONE_TIMEOUT_OPERATION=600
```

#### By Cloud Provider

**Google Drive**:
```bash
RCLONE_TIMEOUT_CONNECTION=60
RCLONE_TRANSFERS=4
CLOUD_BATCH_SIZE=10
CLOUD_BATCH_PAUSE=2
```

**Amazon S3 / Wasabi**:
```bash
RCLONE_TIMEOUT_CONNECTION=30
RCLONE_TRANSFERS=8-16
CLOUD_BATCH_SIZE=50-100
CLOUD_BATCH_PAUSE=1
```

**Backblaze B2**:
```bash
RCLONE_TIMEOUT_CONNECTION=45
RCLONE_TRANSFERS=2-4
CLOUD_BATCH_SIZE=20
CLOUD_BATCH_PAUSE=2
```

**MinIO (Self-hosted LAN)**:
```bash
RCLONE_TIMEOUT_CONNECTION=10
RCLONE_TRANSFERS=8+
CLOUD_BATCH_SIZE=100
CLOUD_BATCH_PAUSE=0
```

### Testing

```bash
# Build
cd /opt/proxmox-backup
make build

# Dry-run test
DRY_RUN=true ./build/proxmox-backup

# Check output:
# ✓ "Cloud storage initialized: gdrive:pbs-backups"
# ✓ "Cloud remote gdrive is accessible"
# ✓ "[DRY-RUN] Would upload backup to cloud storage"

# Real backup
./build/proxmox-backup

# Verify upload
rclone ls gdrive:pbs-backups/
# Should show backup files

# Verify logs
rclone ls gdrive:/pbs-logs/
# Should show log files
```

### Troubleshooting

| Error | Cause | Solution |
|-------|-------|----------|
| `rclone not found in PATH` | Not installed | `curl https://rclone.org/install.sh \| sudo bash` |
| `couldn't find configuration section 'gdrive'` | Remote not configured | `rclone config` → create remote |
| `401 unauthorized` | Credentials expired | `rclone config reconnect gdrive` or regenerate keys |
| `connection timeout (30s)` | Slow network | Increase `RCLONE_TIMEOUT_CONNECTION=60` |
| `operation timeout (300s exceeded)` | Large file + slow network | Increase `RCLONE_TIMEOUT_OPERATION=900` |
| `429 Too Many Requests` | API rate limiting | Reduce `RCLONE_TRANSFERS=2`, increase `CLOUD_BATCH_PAUSE=3` |
| `directory not found` | Path doesn't exist | `rclone mkdir gdrive:pbs-backups` |
| `403 Forbidden` | Insufficient permissions | Check bucket/remote ACL/IAM |
| `507 Insufficient Storage` | Quota exceeded | Reduce retention, increase quota, or change provider |

### Disaster Recovery

#### Backup Configuration

```bash
# Save critical configs
tar -czf /tmp/pbs-config-backup.tar.gz \
    /root/.config/rclone/rclone.conf \
    /opt/proxmox-backup/configs/backup.env

# Upload to cloud (manual)
rclone copy /tmp/pbs-config-backup.tar.gz gdrive:/pbs-disaster-recovery/

# Or automate via backup.env
CUSTOM_BACKUP_PATHS="
/root/.config/rclone/rclone.conf
/opt/proxmox-backup/configs/
"
```

#### Recovery Procedure

```bash
# 1. Setup new server
apt-get update && apt-get install rclone

# 2. Restore rclone config
# Option A: From separate backup
rclone copy gdrive:/pbs-disaster-recovery/rclone.conf /root/.config/rclone/

# Option B: Reconfigure manually
rclone config

# 3. Verify access
rclone ls gdrive:pbs-backups/

# 4. Download latest backup
LATEST=$(rclone lsf gdrive:pbs-backups/ --format "t;p" | sort -r | head -1 | cut -d';' -f2)
echo "Latest: $LATEST"
rclone copy "gdrive:pbs-backups/$LATEST" /tmp/recovery/

# 5. Extract bundle
cd /tmp/recovery
tar -xf *.bundle.tar

# 6. Verify checksum
sha256sum -c *.sha256

# 7. Decrypt (if encrypted)
age --decrypt -i /path/to/key.txt -o backup.tar.xz backup.tar.xz.age

# 8. Extract
tar -xJf backup.tar.xz -C /restore/

# 9. Restore files
cp -a /restore/* /
```

---

## Encryption Guide

proxmox-backup uses **AGE** (age-encryption.org) for streaming encryption.

### Features

- Streaming encryption (no plaintext `.tar` files on disk)
- Multiple recipient support (encrypt for multiple keys)
- Passphrase-derived keys (deterministic, passphrase never stored)
- Interactive wizards for key generation and decryption
- Secure memory handling (buffers zeroed after use)

### Configure Recipients

#### Option 1: Static Configuration

```bash
# Edit backup.env
nano /opt/proxmox-backup/configs/backup.env

# Set recipient(s)
AGE_RECIPIENT="age1..."            # Inline recipient
AGE_RECIPIENT_FILE=/opt/proxmox-backup/identity/age/recipient.txt
```

#### Option 2: Interactive Wizard

```bash
# Triggered automatically when encryption enabled without recipients
./build/proxmox-backup --install
# ... enable encryption in wizard ...

# Or run explicitly
./build/proxmox-backup --newkey
```

**Wizard options**:

1. **Use existing AGE public key**: Paste `age1…` recipient
2. **Generate from passphrase**: Enter passphrase (≥12 chars, 3/4 complexity: lower/upper/digits/symbols)
3. **Generate from private key**: Paste `AGE-SECRET-KEY-1…`
4. **Exit setup**: Abort

**Security**:
- Input hidden (no echo)
- Buffers zeroed after use
- Recipient file created with 0600 permissions
- Passphrase never stored on disk

### Running Encrypted Backups

```bash
# Enable encryption
nano /opt/proxmox-backup/configs/backup.env
ENCRYPT_ARCHIVE=true

# Provide recipient (or run wizard)
AGE_RECIPIENT="age1..."

# Run backup
./build/proxmox-backup

# Result: hostname-backup-YYYYMMDD-HHMMSS.tar.xz.age
```

**Archive format**:
- Encrypted: `.tar.xz.age`
- Bundle: `.tar.xz.age.bundle.tar` (if `BUNDLE_ASSOCIATED_FILES=true`)
- Checksum: `.sha256` (plaintext)
- Metadata: `.metadata` (plaintext)

### Decrypting Backups

```bash
./build/proxmox-backup --decrypt
```

**Workflow**:

1. **Select source**: Local, Secondary, or Cloud storage
2. **List backups**: Shows timestamp, encryption status, tool version
   ```
   [1] 2025-11-17 10:30:00 • ENCRYPTED • Tool v0.9.0 • pbs v2.4.3
   [2] 2025-11-16 10:30:00 • ENCRYPTED • Tool v0.9.0 • pbs v2.4.3
   ```
3. **Choose backup**: Enter index number
4. **Destination folder**: Default `./decrypt` (can customize)
5. **Enter passphrase or private key**: Input hidden, `0` to exit
6. **Decryption**: Creates `<name>.tar.xz.decrypted.bundle.tar`

**Output**: Decrypted bundle containing:
- Plaintext archive (`.tar.xz`)
- Checksum (`.sha256`)
- Metadata (`.metadata`)

### Restoring Backups

```bash
./build/proxmox-backup --restore
```

**Workflow**:

1. Same discovery as `--decrypt`
2. Plaintext staging in secure temp directory
3. **Confirmation**: Type `RESTORE` to proceed (or `0` to abort)
4. **Extraction**: Applies archive to system root `/`
5. **Cleanup**: Deletes staged files

**⚠️ WARNING**: Restores files **in-place** to `/`. Take system snapshot first!

**Requirements**:
- Root privileges (overwrites system files)
- Matching system architecture (Proxmox VE/PBS)
- Sufficient disk space

### Rotating Keys

```bash
# Run key rotation wizard
./build/proxmox-backup --newkey
```

**Process**:
1. Backs up existing `recipient.txt` → `recipient.txt.bak-YYYYMMDD-HHMMSS`
2. Launches wizard for new key
3. Updates `AGE_RECIPIENT_FILE`

**Best practice**: Keep old private keys until all old backups are purged by retention.

### Emergency Scenarios

| Scenario | Solution |
|----------|----------|
| Lost passphrase/private key | **No recovery possible**. Keep 2+ offline copies (password manager, printed paper). |
| Migrating to new server | Copy `recipient.txt` (public key only). Keep private keys offline. |
| Verifying integrity | Run `--decrypt` periodically to ensure backups are valid. |
| Automation | Headless runs require `AGE_RECIPIENT` set (wizard won't run). |

### Security Notes

- Passphrases read with `term.ReadPassword` (no echo)
- Buffers zeroed immediately after use
- Streaming encryption (no plaintext on disk)
- Recipient file: 0700/0600 permissions (enforced by security checks)
- **Keep private keys offline** (password manager, hardware token, printed backup)

---

## Practical Examples

### Example 1: Basic Local Backup

**Scenario**: Single server, local backup only, simple retention.

```bash
# configs/backup.env
BACKUP_ENABLED=true
BACKUP_PATH=/opt/proxmox-backup/backup
LOG_PATH=/opt/proxmox-backup/log

# Compression
COMPRESSION_TYPE=xz
COMPRESSION_LEVEL=6
COMPRESSION_MODE=standard

# Retention: Keep 15 backups
MAX_LOCAL_BACKUPS=15

# Run backup
./build/proxmox-backup
```

**Cron schedule** (daily 2 AM):
```bash
0 2 * * * /opt/proxmox-backup/build/proxmox-backup
```

---

### Example 2: Local + Secondary Storage

**Scenario**: Local SSD + secondary NAS, different retention.

```bash
# configs/backup.env
BACKUP_ENABLED=true
BACKUP_PATH=/opt/proxmox-backup/backup
LOG_PATH=/opt/proxmox-backup/log

# Secondary storage (NAS)
SECONDARY_ENABLED=true
SECONDARY_PATH=/mnt/nas/pbs-backup
SECONDARY_LOG_PATH=/mnt/nas/pbs-log

# Retention
MAX_LOCAL_BACKUPS=7        # 1 week local (SSD expensive)
MAX_SECONDARY_BACKUPS=30   # 1 month secondary (NAS cheap)

# Run backup
./build/proxmox-backup
```

---

### Example 3: Cloud Backup with Google Drive

**Scenario**: Small business, daily backups, GFS retention, Google Drive.

#### Step 1: Configure rclone

```bash
rclone config
# n > gdrive > drive > [OAuth] > y > q
rclone mkdir gdrive:pbs-backups
rclone mkdir gdrive:pbs-logs
```

#### Step 2: Configure backup.env

```bash
# configs/backup.env

# Cloud storage
CLOUD_ENABLED=true
CLOUD_REMOTE=gdrive:pbs-backups
CLOUD_LOG_PATH=gdrive:/pbs-logs
CLOUD_UPLOAD_MODE=parallel
CLOUD_PARALLEL_MAX_JOBS=3
CLOUD_PARALLEL_VERIFICATION=true

# Google Drive tuning
RCLONE_TIMEOUT_CONNECTION=60
RCLONE_TIMEOUT_OPERATION=600
RCLONE_TRANSFERS=4
RCLONE_RETRIES=3
CLOUD_BATCH_SIZE=10
CLOUD_BATCH_PAUSE=2

# GFS retention (3-year coverage)
RETENTION_POLICY=gfs
RETENTION_DAILY=7
RETENTION_WEEKLY=4
RETENTION_MONTHLY=12
RETENTION_YEARLY=3
```

#### Step 3: Test and Run

```bash
# Dry-run
./build/proxmox-backup --dry-run

# Real backup
./build/proxmox-backup

# Verify
rclone ls gdrive:pbs-backups/
rclone ls gdrive:/pbs-logs/
```

---

### Example 4: Encrypted Backup with AGE

**Scenario**: Sensitive data, encryption required, cloud storage.

#### Step 1: Generate Encryption Key

```bash
./build/proxmox-backup --newkey

# Wizard:
# [2] Generate from personal passphrase
# Enter passphrase: **************** (min 12 chars, strong)
# Confirm: ****************
# ✓ AGE recipient generated and saved
```

#### Step 2: Configure backup.env

```bash
# configs/backup.env

# Encryption
ENCRYPT_ARCHIVE=true
AGE_RECIPIENT_FILE=/opt/proxmox-backup/identity/age/recipient.txt

# Bundle (recommended with encryption)
BUNDLE_ASSOCIATED_FILES=true

# Cloud storage
CLOUD_ENABLED=true
CLOUD_REMOTE=gdrive:pbs-encrypted
MAX_CLOUD_BACKUPS=30
```

#### Step 3: Run Backup

```bash
./build/proxmox-backup

# Result: hostname-backup-YYYYMMDD-HHMMSS.tar.xz.age.bundle.tar
```

#### Step 4: Decrypt (when needed)

```bash
./build/proxmox-backup --decrypt

# Select backup: [1]
# Destination: /tmp/decrypt
# Enter passphrase: ****************
# ✓ Decryption successful
```

---

### Example 5: Backblaze B2 with Bandwidth Limiting

**Scenario**: Remote archival, slow network, cost optimization.

#### Step 1: Configure Backblaze B2

```bash
# Create B2 account (10GB free)
# Create bucket: pbs-backups (Private)
# Create Application Key (copy Key ID and Application Key)

rclone config
# n > b2 > b2 > <Key-ID> > <App-Key> > n > n > y > q
```

#### Step 2: Configure backup.env

```bash
# configs/backup.env

# Cloud storage
CLOUD_ENABLED=true
CLOUD_REMOTE=b2:pbs-backups
CLOUD_LOG_PATH=b2:pbs-backups/logs
CLOUD_UPLOAD_MODE=sequential

# Slow network tuning
RCLONE_TIMEOUT_CONNECTION=45
RCLONE_TIMEOUT_OPERATION=1800     # 30 minutes
RCLONE_BANDWIDTH_LIMIT=5M         # 5 MB/s (don't saturate office network)
RCLONE_TRANSFERS=2
RCLONE_RETRIES=5

# Batch deletion (B2 rate limiting)
CLOUD_BATCH_SIZE=20
CLOUD_BATCH_PAUSE=2

# GFS retention (long-term archival)
RETENTION_POLICY=gfs
RETENTION_DAILY=14
RETENTION_WEEKLY=8
RETENTION_MONTHLY=24
RETENTION_YEARLY=5

# Result: ~51 backups distributed over 5 years
# Cost: 51 × 0.5GB = 25.5GB × $0.005 = $0.13/month
```

#### Step 3: Schedule Nightly Backup

```bash
# Cron: 2 AM daily
0 2 * * * /opt/proxmox-backup/build/proxmox-backup
```

**Why nightly?**: Slow upload doesn't impact office hours, B2 free egress 1GB/day.

---

### Example 6: MinIO Self-Hosted with High Performance

**Scenario**: LAN-based MinIO server, fast storage, hourly backups.

#### Step 1: Configure MinIO

```bash
# Assuming MinIO running at https://minio.local:9000
# Create bucket via MinIO Console or mc client
mc mb minio-local/pbs-backups
mc mb minio-local/pbs-logs

rclone config
# n > minio > s3 > Minio > minioadmin > minioadmin > (empty region) > https://minio.local:9000 > y > q
```

#### Step 2: Configure backup.env

```bash
# configs/backup.env

# Cloud storage (MinIO LAN)
CLOUD_ENABLED=true
CLOUD_REMOTE=minio:pbs-backups
CLOUD_REMOTE_PATH=server1          # Organize by server
CLOUD_LOG_PATH=minio:/pbs-logs
CLOUD_UPLOAD_MODE=parallel
CLOUD_PARALLEL_MAX_JOBS=4
CLOUD_WRITE_HEALTHCHECK=true       # Test write access

# LAN performance tuning
RCLONE_TIMEOUT_CONNECTION=10
RCLONE_TIMEOUT_OPERATION=300
RCLONE_BANDWIDTH_LIMIT=            # Unlimited (LAN)
RCLONE_TRANSFERS=8                 # Highly parallel
RCLONE_RETRIES=2

# Batch deletion (no API limits)
CLOUD_BATCH_SIZE=100
CLOUD_BATCH_PAUSE=0

# Simple retention (168 hours = 1 week)
MAX_CLOUD_BACKUPS=168
```

#### Step 3: Hourly Backup

```bash
# Cron: every hour
0 * * * * /opt/proxmox-backup/build/proxmox-backup
```

---

### Example 7: Multi-Notification Setup

**Scenario**: Telegram + Email + Webhook (Discord) notifications.

```bash
# configs/backup.env

# Telegram
TELEGRAM_ENABLED=true
BOT_TELEGRAM_TYPE=personal
TELEGRAM_BOT_TOKEN=123456789:ABCdefGHIjklMNOpqrsTUVwxyz
TELEGRAM_CHAT_ID=987654321

# Email
EMAIL_ENABLED=true
EMAIL_DELIVERY_METHOD=relay
EMAIL_RECIPIENT=admin@example.com
EMAIL_FROM=noreply@proxmox.example.com

# Webhook (Discord)
WEBHOOK_ENABLED=true
WEBHOOK_ENDPOINTS=discord_alerts
WEBHOOK_DISCORD_ALERTS_URL=https://discord.com/api/webhooks/XXXX/YYYY
WEBHOOK_DISCORD_ALERTS_FORMAT=discord
WEBHOOK_DISCORD_ALERTS_METHOD=POST

# Run backup
./build/proxmox-backup
# Result: Notifications sent to Telegram, Email, and Discord
```

---

### Example 8: Complete Production Setup

**Scenario**: Enterprise setup with all features enabled.

```bash
# configs/backup.env

# General
BACKUP_ENABLED=true
USE_COLOR=true
DEBUG_LEVEL=standard

# Security
SECURITY_CHECK_ENABLED=true
AUTO_UPDATE_HASHES=true
AUTO_FIX_PERMISSIONS=true
CONTINUE_ON_SECURITY_ISSUES=false

# Compression (balanced)
COMPRESSION_TYPE=xz
COMPRESSION_LEVEL=6
COMPRESSION_MODE=standard
COMPRESSION_THREADS=0

# Primary storage
BACKUP_PATH=/opt/proxmox-backup/backup
LOG_PATH=/opt/proxmox-backup/log

# Secondary storage (NAS)
SECONDARY_ENABLED=true
SECONDARY_PATH=/mnt/nas/pbs-backup
SECONDARY_LOG_PATH=/mnt/nas/pbs-log

# Cloud storage (S3)
CLOUD_ENABLED=true
CLOUD_REMOTE=s3:company-backups
CLOUD_REMOTE_PATH=datacenter1/pbs1
CLOUD_LOG_PATH=s3:company-backups/logs
CLOUD_UPLOAD_MODE=parallel
CLOUD_PARALLEL_MAX_JOBS=4
RCLONE_TRANSFERS=8
RCLONE_RETRIES=3

# GFS retention (7-year compliance)
RETENTION_POLICY=gfs
RETENTION_DAILY=7
RETENTION_WEEKLY=8
RETENTION_MONTHLY=24
RETENTION_YEARLY=7

# Encryption
ENCRYPT_ARCHIVE=true
BUNDLE_ASSOCIATED_FILES=true
AGE_RECIPIENT_FILE=/opt/proxmox-backup/identity/age/recipient.txt

# Notifications
TELEGRAM_ENABLED=true
TELEGRAM_BOT_TOKEN=...
TELEGRAM_CHAT_ID=...
EMAIL_ENABLED=true
EMAIL_RECIPIENT=ops@example.com
GOTIFY_ENABLED=true
GOTIFY_SERVER_URL=https://gotify.example.com
GOTIFY_TOKEN=...

# Metrics
METRICS_ENABLED=true
METRICS_PATH=/var/lib/prometheus/node-exporter

# Collectors (all enabled)
BACKUP_CLUSTER_CONFIG=true
BACKUP_PVE_FIREWALL=true
BACKUP_DATASTORE_CONFIGS=true
BACKUP_USER_CONFIGS=true
BACKUP_NETWORK_CONFIGS=true
BACKUP_APT_SOURCES=true
BACKUP_CRON_JOBS=true
BACKUP_SYSTEMD_SERVICES=true
BACKUP_SSL_CERTS=true
BACKUP_CRITICAL_FILES=true
BACKUP_SSH_KEYS=true
BACKUP_ZFS_CONFIG=true
# Includes /etc/zfs, /etc/hostid and command snapshots for zpool/zfs
BACKUP_ROOT_HOME=true

# Custom paths
CUSTOM_BACKUP_PATHS="
/root/.config/rclone/rclone.conf
/opt/proxmox-backup/configs/backup.env
/etc/custom/app.conf
"

# Run backup
./build/proxmox-backup
```

**Cron schedule** (daily 2 AM):
```bash
0 2 * * * /opt/proxmox-backup/build/proxmox-backup >> /var/log/pbs-backup-cron.log 2>&1
```

**Result**:
- ✅ Encrypted backup on local SSD
- ✅ Copy to secondary NAS
- ✅ Upload to S3 cloud
- ✅ GFS retention (7-year compliance)
- ✅ Notifications via Telegram, Email, Gotify
- ✅ Prometheus metrics exported

---

## Troubleshooting

### Common Issues

#### 1. Build Failures

**Error**: `go: cannot find main module`

**Solution**:
```bash
cd /opt/proxmox-backup  # Ensure you're in project root
go mod init github.com/tis24dev/proxmox-backup
go mod tidy
make build
```

---

**Error**: `package xxx not found`

**Solution**:
```bash
go mod tidy  # Download dependencies
make build
```

---

#### 2. Configuration Issues

**Error**: `Configuration file not found: configs/backup.env`

**Solution**:
```bash
# Run installer to create config
./build/proxmox-backup --install

# Or copy template
cp internal/config/templates/backup.env configs/backup.env
nano configs/backup.env
```

---

**Error**: `Security check failed: Permission denied`

**Solution**:
```bash
# Fix permissions
chmod 700 /opt/proxmox-backup/backup
chmod 700 /opt/proxmox-backup/log
chmod 600 /opt/proxmox-backup/configs/backup.env

# Or enable auto-fix
nano configs/backup.env
AUTO_FIX_PERMISSIONS=true
```

---

#### 3. Cloud Storage Issues

**Error**: `rclone not found in PATH`

**Solution**:
```bash
curl https://rclone.org/install.sh | sudo bash
rclone version
```

---

**Error**: `Cloud remote gdrive not accessible: couldn't find configuration section`

**Solution**:
```bash
# Configure rclone remote
rclone config
# n > gdrive > drive > ... > y > q

# Test
rclone listremotes
# Should show: gdrive:
```

---

**Error**: `401 unauthorized`

**Solution**:
```bash
# Reconnect OAuth (Google Drive)
rclone config reconnect gdrive

# Or regenerate keys (S3/B2)
# Delete old remote and create new with fresh keys
rclone config delete s3backup
rclone config  # Create new
```

---

**Error**: `connection timeout (30s)`

**Solution**:
```bash
# Increase timeout
nano configs/backup.env
RCLONE_TIMEOUT_CONNECTION=60
```

---

**Error**: `operation timeout (300s exceeded)`

**Solution**:
```bash
# Increase operation timeout
nano configs/backup.env
RCLONE_TIMEOUT_OPERATION=900  # 15 minutes

# Or reduce file size via better compression
COMPRESSION_TYPE=zstd
COMPRESSION_LEVEL=3
COMPRESSION_MODE=fast
```

---

**Error**: `429 Too Many Requests` (API rate limiting)

**Solution**:
```bash
# Reduce parallel transfers
nano configs/backup.env
RCLONE_TRANSFERS=2
CLOUD_BATCH_SIZE=10
CLOUD_BATCH_PAUSE=3
```

---

#### 4. Encryption Issues

**Error**: `Encryption setup requires interaction but terminal unavailable`

**Solution**:
```bash
# Run key generation manually
./build/proxmox-backup --newkey

# Or set recipient directly
nano configs/backup.env
AGE_RECIPIENT="age1..."
```

---

**Error**: `Failed to decrypt: incorrect passphrase`

**Solution**:
- Verify passphrase is correct (case-sensitive)
- If using private key, paste full `AGE-SECRET-KEY-1...` string
- No recovery if passphrase lost (keep offline backups!)

---

#### 5. Disk Space Issues

**Error**: `Insufficient disk space: 0.5 GB available, 1 GB required`

**Solution**:
```bash
# Check disk usage
df -h /opt/proxmox-backup

# Clean old backups manually
rm /opt/proxmox-backup/backup/old-backup-*.tar.xz

# Or adjust retention
nano configs/backup.env
MAX_LOCAL_BACKUPS=5  # Keep fewer backups
```

---

### Debug Procedures

#### Enable Debug Logging

```bash
# Run with debug level
./build/proxmox-backup --log-level debug

# Or set in config
nano configs/backup.env
DEBUG_LEVEL=extreme

# Logs include:
# - Detailed command execution
# - rclone stdout/stderr
# - File operations
# - Retry attempts
```

---

#### Test rclone Manually

```bash
# Test upload
echo "test" > /tmp/test.txt
rclone copy /tmp/test.txt gdrive:pbs-backups/ --verbose

# Verify
rclone lsl gdrive:pbs-backups/test.txt

# Test download
rclone copy gdrive:pbs-backups/test.txt /tmp/test-download.txt
cat /tmp/test-download.txt

# Cleanup
rclone deletefile gdrive:pbs-backups/test.txt
rm /tmp/test*.txt
```

---

#### Verify Configuration Loading

```bash
# Check parsed configuration
grep -E "^CLOUD_|^RCLONE_" /opt/proxmox-backup/configs/backup.env

# Test with dry-run
./build/proxmox-backup --dry-run --log-level debug
# Check output for loaded config values
```

---

#### Analyze Log Files

```bash
# Find latest log
ls -lt /opt/proxmox-backup/log/

# View log
cat /opt/proxmox-backup/log/backup-$(hostname)-*.log

# Filter errors
grep -i "error\|fail\|warning" /opt/proxmox-backup/log/backup-*.log

# Filter cloud issues
grep -i "cloud.*error\|cloud.*fail\|cloud.*warning" /opt/proxmox-backup/log/backup-*.log
```

---

### Getting Help

#### Check Documentation

- **README.md**: Project overview
- **CHANGELOG.md**: Version history
- **This guide**: Complete reference

#### Enable Verbose Logging

```bash
./build/proxmox-backup --log-level debug 2>&1 | tee /tmp/pbs-debug.log
```

#### Report Issues

If problem persists:

1. **Gather information**:
   ```bash
   ./build/proxmox-backup --version
   rclone version
   go version
   uname -a
   ```

2. **Collect logs**:
   ```bash
   tar -czf /tmp/pbs-debug.tar.gz \
       /opt/proxmox-backup/log/backup-*.log \
       /tmp/pbs-debug.log
   ```

3. **Sanitize config** (remove credentials):
   ```bash
   cp configs/backup.env /tmp/backup.env.sanitized
   nano /tmp/backup.env.sanitized
   # Remove: TELEGRAM_BOT_TOKEN, TELEGRAM_CHAT_ID, EMAIL_*, WEBHOOK_*_URL, AGE_RECIPIENT
   ```

4. **Create GitHub issue**:
   - Repository: `github.com/tis24dev/proxmox-backup`
   - Include: Version info, sanitized config, logs
   - Describe: Expected behavior vs actual behavior

---

## Appendix

### Useful Commands

#### Build & Run

```bash
# Development build
make build

# Optimized build
go build -ldflags="-s -w" -o build/proxmox-backup ./cmd/proxmox-backup

# Run without building
make run

# Clean build artifacts
make clean
```

#### Testing

```bash
# All tests
go test ./...

# With coverage
go test -cover ./...
make test-coverage

# Specific package
go test ./internal/config

# Verbose
go test -v ./...
```

#### Dependency Management

```bash
# Add dependency
go get github.com/spf13/cobra@latest

# Update all dependencies
go get -u ./...

# Tidy up
go mod tidy

# List dependencies
go list -m all
```

#### rclone Utilities

```bash
# List remotes
rclone listremotes

# Show remote config
rclone config show gdrive

# List files (long format)
rclone lsl gdrive:pbs-backups/

# List files (short format)
rclone lsf gdrive:pbs-backups/

# Check quota
rclone about gdrive:

# Copy local → remote
rclone copy /local/file.txt gdrive:pbs-backups/

# Copy remote → local
rclone copy gdrive:pbs-backups/file.txt /local/

# Sync (WARNING: deletes non-matching files)
rclone sync /local/dir/ gdrive:pbs-backups/

# Create directory
rclone mkdir gdrive:pbs-backups/subdir

# Delete file
rclone deletefile gdrive:pbs-backups/file.txt

# Delete directory (recursive)
rclone purge gdrive:pbs-backups/old/

# Verify integrity
rclone check /local/dir/ gdrive:pbs-backups/ --checksum
```

### FAQ

**Q: Can I use multiple cloud providers?**
A: No, currently only one `CLOUD_REMOTE` is supported. Workaround: Use `rclone union` to combine multiple backends.

**Q: Do cloud logs consume too much space?**
A: Logs follow backup retention automatically. To disable cloud log upload: `CLOUD_LOG_PATH=""` (empty).

**Q: Does cloud upload slow down backups?**
A: Local backup completes first (critical). Cloud upload happens after but delays backup completion. For very slow clouds, consider separate cron job for upload.

**Q: Can I backup directly to cloud only (no local)?**
A: No, local storage is mandatory (critical). Cloud is always secondary/tertiary. Philosophy: fast local backup → slow cloud archival.

**Q: How much RAM does rclone use?**
A: Depends on `RCLONE_TRANSFERS`. Each transfer uses ~10-50MB. With `RCLONE_TRANSFERS=8` → ~80-400MB. For low-RAM systems: `RCLONE_TRANSFERS=2`.

**Q: Can I test upload without creating backup?**
A: Yes, use existing file:
```bash
rclone copy /opt/proxmox-backup/backup/existing-backup.tar.xz gdrive:pbs-backups/ --dry-run
# Remove --dry-run for real upload
```

**Q: What if I lose encryption passphrase?**
A: **No recovery**. Data is permanently unreadable. Keep 2+ offline copies (password manager, printed paper, hardware token).

**Q: How to migrate to new server?**
A: Backup critical configs:
```bash
tar -czf /tmp/pbs-migration.tar.gz \
    /root/.config/rclone/rclone.conf \
    /opt/proxmox-backup/configs/backup.env \
    /opt/proxmox-backup/identity/

# Transfer to new server, extract, rebuild
```

**Q: Can I run Bash and Go versions in parallel?**
A: Yes! They use separate directories:
- Bash: `/opt/proxmox-backup/`
- Go: `/opt/proxmox-backup/`

Test Go version while Bash remains production.

---

## Conclusion

This guide covered:

✅ Installation and setup
✅ Complete command-line reference
✅ 200+ configuration variables
✅ Cloud storage integration (rclone)
✅ Encryption with AGE
✅ 8 practical examples
✅ Comprehensive troubleshooting

### Next Steps

1. **Install**: Follow [Quick Start](#quick-start)
2. **Configure**: Edit `configs/backup.env` for your environment
3. **Test**: Run `--dry-run` before production
4. **Automate**: Set up cron jobs
5. **Monitor**: Check logs and notifications
6. **Maintain**: Periodic recovery tests, key rotation, config updates

---

## 🤝 Contributing

We welcome contributions! Here's how you can help:

### Ways to Contribute

- 🐛 **Report bugs**: Open an issue with detailed reproduction steps
- 💡 **Suggest features**: Share your ideas for improvements
- 📖 **Improve documentation**: Fix typos, add examples, clarify instructions
- 💻 **Submit code**: Fork, create a branch, and submit a pull request
- ⭐ **Star the repo**: Show your support!

### Development Setup

```bash
# Clone repository
git clone https://github.com/tis24dev/proxmox-backup.git
cd proxmox-backup

# Install dependencies
go mod tidy

# Build
make build

# Run tests
go test ./...

# Submit PR
git checkout -b feature/your-feature
git commit -m "Add: your feature description"
git push origin feature/your-feature
```

### Code Guidelines

- Follow Go best practices and conventions
- Add tests for new features
- Update documentation for changes
- Keep commits atomic and well-described

---

## 📄 License

This project is licensed under the **MIT License** - see the [LICENSE](LICENSE) file for details.

```
MIT License

Copyright (c) 2025 tis24dev

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

---

## 📞 Support

### Documentation & Resources

- 📖 **This README**: Complete user guide
- 📝 **[CHANGELOG.md](CHANGELOG.md)**: Version history and changes
- 🔧 **[rclone Documentation](https://rclone.org/docs/)**: Cloud storage integration
- 🔐 **[AGE Documentation](https://age-encryption.org)**: Encryption guide

### Get Help

- 🐛 **Bug Reports**: [GitHub Issues](https://github.com/tis24dev/proxmox-backup/issues)
- 💬 **Discussions**: [GitHub Discussions](https://github.com/tis24dev/proxmox-backup/discussions)
- 📧 **Email**: Contact via GitHub profile

### Support the Project

If you find this project useful, consider supporting its development:

[![💖 GitHub Sponsors](https://img.shields.io/badge/Sponsor-GitHub%20Sponsors-pink?logo=github&style=for-the-badge)](https://github.com/sponsors/tis24dev)
[![☕ Buy Me a Coffee](https://img.shields.io/badge/Buy%20Me%20a%20Coffee-tis24dev-yellow?logo=buymeacoffee&style=for-the-badge)](https://buymeacoffee.com/tis24dev)

Your support helps maintain and improve this project!

---

## ⭐ Stargazers

[![Stargazers repo roster for @tis24dev/proxmox-backup](https://reporoster.com/stars/tis24dev/proxmox-backup)](https://github.com/tis24dev/proxmox-backup/stargazers)

[![Star History Chart](https://api.star-history.com/svg?repos=tis24dev/proxmox-backup&type=Date)](https://star-history.com/#tis24dev/proxmox-backup&Date)

---

**Happy backing up!** 🚀

---

<div align="center">

Made with ❤️ by [tis24dev](https://github.com/tis24dev)

⭐ **Star this repo if you find it useful!** ⭐

</div>

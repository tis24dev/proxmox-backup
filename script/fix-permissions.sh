#!/bin/bash
##
# Proxmox Backup System - Fix Permissions Script
# File: fix-permissions.sh
# Version: 0.3.2
# Last Modified: 2025-11-08
# Changes: Add filesystem check
##
# Script to apply correct permissions to all backup system files
# This script must be run as root
##

set -e

# Script version (autonomo)
FIX_PERMISSIONS_VERSION="0.2.0"

# Base directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(dirname "$SCRIPT_DIR")"

# Show version
echo "Fix Permissions Script Version: $FIX_PERMISSIONS_VERSION"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Check if script is running under cron or if output is not a terminal
USE_COLORS=1
if [ ! -t 1 ]; then
    USE_COLORS=0
fi
if [[ "${DISABLE_COLORS}" == "1" || "${DISABLE_COLORS}" == "true" ]]; then
    USE_COLORS=0
fi

# Logging functions
log_step() {
    if [ "$USE_COLORS" -eq 1 ]; then
        echo -e "${CYAN}[STEP]${NC} $1"
    else
        echo "[STEP] $1"
    fi
}

log_info() {
    if [ "$USE_COLORS" -eq 1 ]; then
        echo -e "${BLUE}[INFO]${NC} $1"
    else
        echo "[INFO] $1"
    fi
}

log_success() {
    if [ "$USE_COLORS" -eq 1 ]; then
        echo -e "${GREEN}[SUCCESS]${NC} $1"
    else
        echo "[SUCCESS] $1"
    fi
}

log_warning() {
    if [ "$USE_COLORS" -eq 1 ]; then
        echo -e "${YELLOW}[WARNING]${NC} $1"
    else
        echo "[WARNING] $1"
    fi
}

log_error() {
    if [ "$USE_COLORS" -eq 1 ]; then
        echo -e "${RED}[ERROR]${NC} $1"
    else
        echo "[ERROR] $1"
    fi
}

# Check if the script is run as root
check_root() {
    if [ "$(id -u)" != "0" ]; then
        log_error "This script must be run as root"
        exit 1
    fi
}

# Load the configuration file
load_config() {
    if [ -f "$BASE_DIR/env/backup.env" ]; then
        source "$BASE_DIR/env/backup.env"
    else
        log_error "Configuration file not found: $BASE_DIR/env/backup.env"
        exit 1
    fi
}

# Detect if the filesystem actually supports Unix permissions
supports_unix_ownership() {
    local path="$1"

    if [ -z "$path" ]; then
        return 1
    fi

    # If the path does not exist yet, we assume it will support permissions when created
    if [ ! -e "$path" ]; then
        return 0
    fi

    local fstype
    fstype=$(stat -f -c %T "$path" 2>/dev/null || true)
    if [ -z "$fstype" ]; then
        fstype=$(df -T "$path" 2>/dev/null | tail -n 1 | awk '{print $2}')
    fi

    case "$fstype" in
        vfat|msdos|fat|exfat|ntfs)
            log_info "Filesystem $fstype detected on $path: skipping chown/chmod"
            return 1
            ;;
        nfs|nfs4|cifs|smb|smbfs)
            if test_ownership_capability "$path"; then
                return 0
            else
                log_info "Filesystem $fstype does not allow ownership change on $path: skipping chown/chmod"
                return 1
            fi
            ;;
        ""|unknown)
            log_warning "Cannot determine filesystem for $path: trying to apply permissions anyway"
            return 0
            ;;
        *)
            return 0
            ;;
    esac
}

# Test if a path actually allows chown (useful for NFS/CIFS shares)
test_ownership_capability() {
    local path="$1"
    local test_file="${path%/}/.fix-permissions-ownership-test.$$"

    if [ ! -w "$path" ]; then
        log_info "Cannot write to $path to test ownership change"
        return 1
    fi

    if ! touch "$test_file" 2>/dev/null; then
        log_info "Cannot create test file in $path"
        return 1
    fi

    local result=0
    if ! chown "${BACKUP_USER}:${BACKUP_GROUP}" "$test_file" 2>/dev/null; then
        log_info "Test chown failed in $path (likely root_squash/all_squash)"
        result=1
    fi

    rm -f "$test_file" 2>/dev/null || true
    return $result
}

# Apply permissions to executable scripts
fix_script_permissions() {
    log_step "Applying permissions to executable scripts"
    
    local scripts=(
        "$BASE_DIR/script/proxmox-backup.sh"
        "$BASE_DIR/script/security-check.sh"
        "$BASE_DIR/script/server-id-manager.sh"
        "$BASE_DIR/script/fix-permissions.sh"
        "$BASE_DIR/secure_account/setup_gdrive.sh"
    
        "$BASE_DIR/install.sh"
        "$BASE_DIR/new-install.sh")
    
    for script in "${scripts[@]}"; do
        if [ -f "$script" ]; then
            if [[ "$script" == "$BASE_DIR/install.sh" || "$script" == "$BASE_DIR/new-install.sh" ]]; then
                log_info "Setting permissions 744 on $script"
            else
                log_info "Setting permissions 700 on $script"
            fi
            if [[ "$script" == "$BASE_DIR/install.sh" || "$script" == "$BASE_DIR/new-install.sh" ]]; then
                chmod 744 "$script"
            else
                chmod 700 "$script"
            fi
            chown root:root "$script"

            # Also update the hash file if it exists
            local hash_file="${script}.md5"
            if [ -f "$hash_file" ]; then
                log_info "Setting permissions 600 on $hash_file"
                chmod 600 "$hash_file"
                chown root:root "$hash_file"
            fi
        else
            log_warning "Script not found: $script"
        fi
    done
}

# Apply permissions to configuration files
fix_config_permissions() {
    log_step "Applying permissions to configuration files"
    
    local config_files=(
        "$BASE_DIR/env/backup.env"
        "$BASE_DIR/secure_account/pbs1.json"
        "$BASE_DIR/lib/backup_collect.sh"
        "$BASE_DIR/lib/backup_collect_pbspve.sh"
        "$BASE_DIR/lib/backup_create.sh"
        "$BASE_DIR/lib/backup_manager.sh"
        "$BASE_DIR/lib/backup_verify.sh"
        "$BASE_DIR/lib/core.sh"
        "$BASE_DIR/lib/environment.sh"
        "$BASE_DIR/lib/log.sh"
        "$BASE_DIR/lib/metrics.sh"
        "$BASE_DIR/lib/metrics_collect.sh"
        "$BASE_DIR/lib/notify.sh"
        "$BASE_DIR/lib/security.sh"
        "$BASE_DIR/lib/storage.sh"
        "$BASE_DIR/lib/utils.sh"
		"$BASE_DIR/lib/utils_counting.sh"
		"$BASE_DIR/lib/email_relay.sh"
    )
    
    for config in "${config_files[@]}"; do
        if [ -f "$config" ]; then
            log_info "Setting permissions 400 on $config"
            chmod 400 "$config"
            chown root:root "$config"

            # Also update the hash file if it exists
            local hash_file="${config}.md5"
            if [ -f "$hash_file" ]; then
                log_info "Setting permissions 600 on $hash_file"
                chmod 600 "$hash_file"
                chown root:root "$hash_file"
            fi
        else
            log_warning "Configuration file not found: $config"
        fi
    done
}

# Apply permissions to base directories
fix_base_directories() {
    log_step "Applying permissions to base directories"
    
    local base_dirs=(
        "$BASE_DIR/backup"
        "$BASE_DIR/env"
        "$BASE_DIR/log"
        "$BASE_DIR/script"
        "$BASE_DIR/secure_account"
    )
    
    for dir in "${base_dirs[@]}"; do
        if [ -d "$dir" ]; then
            log_info "Setting permissions 750 on $dir"
            chmod 750 "$dir"
            chown root:root "$dir"
        else
            log_warning "Directory not found: $dir"
        fi
    done
}

# Apply permissions to backup and log directories
fix_backup_directories() {
    log_step "Applying permissions to backup and log directories"

    # Check if backup user and group exist
    if ! id -u "${BACKUP_USER}" &>/dev/null; then
        log_warning "Backup user ${BACKUP_USER} not found"
        return 1
    fi

    if ! getent group "${BACKUP_GROUP}" &>/dev/null; then
        log_warning "Backup group ${BACKUP_GROUP} not found"
        return 1
    fi

    # Directories to manage
    local backup_dirs=(
        "$LOCAL_BACKUP_PATH"
        "$LOCAL_LOG_PATH"
        "$SECONDARY_BACKUP_PATH"
        "$SECONDARY_LOG_PATH"
    )
    
    for dir in "${backup_dirs[@]}"; do
        if [ -z "$dir" ]; then
            continue
        fi
        if [ -d "$dir" ]; then
            if supports_unix_ownership "$dir"; then
                log_info "Setting permissions on $dir"
                if ! chown -R "${BACKUP_USER}:${BACKUP_GROUP}" "$dir"; then
                    log_warning "Cannot change ownership on $dir"
                fi
                if ! chmod -R u=rwX,g=rX,o= "$dir"; then
                    log_warning "Cannot update permissions on $dir"
                fi
            else
                log_info "Skipping permission change on $dir"
            fi
        else
            log_warning "Directory not found: $dir"
        fi
    done
}

# Main function
main() {
    log_step "Starting permission application"

    # Check root
    check_root

    # Load configuration
    load_config

    # Apply permissions in order
    fix_script_permissions
    fix_config_permissions
    fix_base_directories
    fix_backup_directories

    log_success "Permission application completed"
}

# Execute only if the script is called directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi 

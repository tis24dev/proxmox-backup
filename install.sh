#!/bin/bash

# ============================================================================
# PROXMOX BACKUP SYSTEM - AUTOMATIC INSTALLER
# ============================================================================
# Automatic installation script for Proxmox Backup System
# This script handles the complete installation process
#
# Usage: bash -c "$(curl -fsSL https://raw.githubusercontent.com/tis24dev/proxmox-backup/main/install.sh)"
#
# Version: 0.1.0
# ============================================================================

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

# Script information
SCRIPT_NAME="Proxmox Backup System Installer"
SCRIPT_VERSION="0.1.0"
REPO_URL="https://github.com/tis24dev/proxmox-backup"
INSTALL_DIR="/opt/proxmox-backup"

# Function to print colored output
print_status() {
    echo -e "${BLUE}[INFO]${RESET} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${RESET} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${RESET} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${RESET} $1"
}

print_header() {
    echo -e "${BOLD}${CYAN}================================${RESET}"
    echo -e "${BOLD}${CYAN}  $SCRIPT_NAME v$SCRIPT_VERSION${RESET}"
    echo -e "${BOLD}${CYAN}================================${RESET}"
    echo
    echo -e "${BOLD}${GREEN}This script preserves your existing configuration and data${RESET}"
    echo -e "${BOLD}${GREEN}For a complete fresh installation, use new-install.sh instead${RESET}"
    echo
}

# Function to check if running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error "This script must be run as root (use sudo)"
        exit 1
    fi
}

# Function to check system requirements
check_requirements() {
    print_status "Checking system requirements..."
    
    # Check if running on Proxmox
    PVE_DETECTED=false
    PBS_DETECTED=false
    
    # Check for PVE
    if [[ -f "/etc/pve/version" ]] || [[ -f "/etc/pve/.version" ]] || [[ -d "/etc/pve" ]]; then
        PVE_DETECTED=true
        print_success "Proxmox VE detected"
    fi
    
    # Check for PBS
    if [[ -f "/etc/proxmox-backup/version" ]] || [[ -f "/etc/proxmox-backup/.version" ]] || [[ -d "/etc/proxmox-backup" ]]; then
        PBS_DETECTED=true
        print_success "Proxmox Backup Server detected"
    fi
    
    # Additional checks for Proxmox systems
    if [[ -f "/etc/debian_version" ]] && (grep -q "proxmox" /etc/hostname 2>/dev/null || grep -q "pve\|pbs" /etc/hostname 2>/dev/null); then
        if [[ "$PVE_DETECTED" == false ]] && [[ "$PBS_DETECTED" == false ]]; then
            print_warning "Proxmox-like system detected (based on hostname)"
            PVE_DETECTED=true
        fi
    fi
    
    # Check for running Proxmox services
    if systemctl is-active --quiet pveproxy 2>/dev/null || systemctl is-active --quiet pbs 2>/dev/null; then
        if [[ "$PVE_DETECTED" == false ]] && [[ "$PBS_DETECTED" == false ]]; then
            print_success "Proxmox services detected as running"
            PVE_DETECTED=true
        fi
    fi
    
    # Check for Proxmox packages
    if dpkg -l | grep -q "proxmox-ve\|proxmox-backup-server" 2>/dev/null; then
        if [[ "$PVE_DETECTED" == false ]] && [[ "$PBS_DETECTED" == false ]]; then
            print_success "Proxmox packages detected"
            PVE_DETECTED=true
        fi
    fi
    
    if [[ "$PVE_DETECTED" == false ]] && [[ "$PBS_DETECTED" == false ]]; then
        print_warning "This system doesn't appear to be Proxmox VE or PBS"
        print_warning "The backup system may not work correctly"
        print_warning "You can continue if you're sure this is a Proxmox system"
        read -p "Continue anyway? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            exit 1
        fi
    fi
    
    # Check Bash version
    BASH_VERSION=$(bash --version | head -n1 | cut -d' ' -f4 | cut -d'.' -f1-2)
    REQUIRED_VERSION="4.4"
    
    if [[ "$(printf '%s\n' "$REQUIRED_VERSION" "$BASH_VERSION" | sort -V | head -n1)" != "$REQUIRED_VERSION" ]]; then
        print_error "Bash $REQUIRED_VERSION or higher is required. Current version: $BASH_VERSION"
        exit 1
    fi
    
    print_success "System requirements check passed"
}

# Function to install dependencies
install_dependencies() {
    print_status "Installing dependencies..."
    
    # Update package list
    apt update
    
    # Install required packages
    PACKAGES="curl wget git jq tar gzip xz-utils zstd pigz"
    apt install -y $PACKAGES
    
    # Install rclone if not present
    if ! command -v rclone &> /dev/null; then
        print_status "Installing rclone..."
        curl https://rclone.org/install.sh | bash
    fi
    
    print_success "Dependencies installed successfully"
}

# Function to safely handle the update process
safe_update_handler() {
    print_status "Starting safe update process..."

    # 1. Create a temporary directory for the full backup
    local TEMP_BACKUP_DIR
    TEMP_BACKUP_DIR=$(mktemp -d)
    if [[ ! -d "$TEMP_BACKUP_DIR" ]]; then
        print_error "Failed to create temporary backup directory. Aborting update."
        exit 1
    fi
    print_status "Created temporary backup directory at: $TEMP_BACKUP_DIR"

    # 2. Remove immutable attribute from protected files before backup
    print_status "Removing immutable attribute from protected files..."
    if [[ -f "$INSTALL_DIR/config/.server_identity" ]]; then
        if chattr -i "$INSTALL_DIR/config/.server_identity" 2>/dev/null; then
            print_status "Removed immutable attribute from .server_identity."
        else
            print_warning "Could not remove immutable attribute from .server_identity. This may not be a critical issue."
        fi
    fi

    # 3. Copy the entire current installation to the temporary directory
    print_status "Backing up the entire current installation..."
    if ! cp -a "$INSTALL_DIR/." "$TEMP_BACKUP_DIR/"; then
        print_error "Failed to back up the current installation. Aborting update."
        rm -rf "$TEMP_BACKUP_DIR"
        exit 1
    fi
    print_success "Current installation backed up successfully."

    # 4. Remove the old installation directory to make way for the new one
    print_status "Removing old installation directory..."
    if ! rm -rf "$INSTALL_DIR"; then
        print_error "Failed to remove the old installation directory."
        print_error "Your old installation is safe in: $TEMP_BACKUP_DIR"
        print_error "Please perform a manual cleanup and try again."
        exit 1
    fi
    print_success "Old installation directory removed."

    # Save the path to the backup for the restore function
    echo "$TEMP_BACKUP_DIR" > /tmp/proxmox_backup_preserve_path
}

# Function to restore critical files after the new version is cloned
restore_preserved_files() {
    if [[ ! -f /tmp/proxmox_backup_preserve_path ]]; then
        return 0 # Not an update, nothing to restore
    fi

    local TEMP_BACKUP_DIR
    TEMP_BACKUP_DIR=$(cat /tmp/proxmox_backup_preserve_path)

    if [[ -z "$TEMP_BACKUP_DIR" ]] || [[ ! -d "$TEMP_BACKUP_DIR" ]]; then
        print_warning "Could not find the temporary backup directory. Skipping file restoration."
        return
    fi

    print_status "Restoring critical files from backup..."

    # 5. Restore critical files and directories
    local PRESERVE_PATHS=(
        "config/.server_identity"
        "config/server_id"
        "env/backup.env"
        "secure_account"
        "backup"
        "log"
    )

    for path in "${PRESERVE_PATHS[@]}"; do
        local source_path="$TEMP_BACKUP_DIR/$path"
        if [[ -e "$source_path" ]]; then
            # Ensure parent directory exists in the new installation
            mkdir -p "$INSTALL_DIR/$(dirname "$path")"
            if cp -a "$source_path" "$INSTALL_DIR/$path"; then
                print_status "  ✓ Restored $path"
            else
                print_warning "  ✗ Failed to restore $path"
            fi
        fi
    done
    print_success "Critical files restored."

    # 6. Restore immutable attribute on the unique ID file
    print_status "Re-applying immutable attribute to server identity file..."
    if [[ -f "$INSTALL_DIR/config/.server_identity" ]]; then
        if chattr +i "$INSTALL_DIR/config/.server_identity" 2>/dev/null; then
            print_status "  ✓ Immutable attribute re-applied to .server_identity."
        else
            print_warning "  ✗ Failed to re-apply immutable attribute."
        fi
    fi

    # 7. Delete the temporary backup directory
    print_status "Cleaning up temporary backup directory..."
    rm -rf "$TEMP_BACKUP_DIR"
    rm -f /tmp/proxmox_backup_preserve_path
    print_success "Update cleanup complete."
}

# Function to clone repository
clone_repository() {
    print_status "Cloning repository..."
    
    # Handle existing installation safely
    if [[ -d "$INSTALL_DIR" ]]; then
        print_warning "Existing installation found at $INSTALL_DIR"
        echo
        echo -e "${BOLD}${GREEN}This script will UPDATE preserving your data:${RESET}"
        echo -e "${GREEN}  ✓ Configuration (backup.env) will be preserved${RESET}"
        echo -e "${GREEN}  ✓ Server identity will be preserved${RESET}"
        echo -e "${GREEN}  ✓ Existing backups and logs will be preserved${RESET}"
        echo -e "${GREEN}  ✓ Custom security settings will be preserved${RESET}"
        echo
        echo -e "${BOLD}${RED}For a complete fresh installation instead, use:${RESET}"
        echo -e "${RED}bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/tis24dev/proxmox-backup/main/new-install.sh)\"${RESET}"
        echo
        read -p "Continue with update (preserving data)? (y/N): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            # Mark this as an update
            touch /tmp/proxmox_backup_was_update
            safe_update_handler
        else
            print_error "Update cancelled"
            exit 1
        fi
    fi
    
    # Clone repository
    git clone "$REPO_URL" "$INSTALL_DIR"
    
    if [[ ! -d "$INSTALL_DIR" ]]; then
        print_error "Failed to clone repository"
        exit 1
    fi
    
    # Restore preserved files
    restore_preserved_files
    
    print_success "Repository cloned successfully"
}

# Function to setup configuration
setup_configuration() {
    print_status "Setting up configuration..."
    
    cd "$INSTALL_DIR"
    
    # Create configuration from repository or restored from previous installation
    if [[ -f "env/backup.env" ]]; then
        print_success "Configuration file found (preserved from previous installation or in repository)"
    else
        print_warning "Configuration file not found, creating basic config"
        mkdir -p env
        cat > env/backup.env << 'EOF'
#!/bin/bash
# Basic Proxmox Backup System Configuration - Generated by installer
SCRIPT_VERSION="0.1.0"

# General Configuration
DEBUG_LEVEL="standard"
AUTO_INSTALL_DEPENDENCIES="true"
DISABLE_COLORS="false"
MIN_BASH_VERSION="4.4.0"
REQUIRED_PACKAGES="tar gzip zstd pigz jq curl rclone gpg"

# Main Features
BACKUP_INSTALLED_PACKAGES="true"
BACKUP_SCRIPT_DIR="true"
BACKUP_CRONTABS="true"
BACKUP_ZFS_CONFIG="true"
BACKUP_CRITICAL_FILES="true"
BACKUP_NETWORK_CONFIG="true"
BACKUP_REMOTE_CFG="true"
BACKUP_CLUSTER_CONFIG="true"
BACKUP_COROSYNC_CONFIG="true"
BACKUP_PVE_FIREWALL="true"
BACKUP_VM_CONFIGS="true"
BACKUP_VZDUMP_CONFIG="true"
BACKUP_CEPH_CONFIG="true"

# Storage Configuration
BASE_DIR="/opt/proxmox-backup"
LOCAL_BACKUP_PATH="${BASE_DIR}/backup/"
LOCAL_LOG_PATH="${BASE_DIR}/log/"
MAX_LOCAL_BACKUPS=20
MAX_LOCAL_LOGS=20

# Secondary Backup Configuration - DISABLED BY DEFAULT
ENABLE_SECONDARY_BACKUP="false"
ENABLE_LOG_MANAGEMENT="true"
SECONDARY_BACKUP_PATH="/mnt/backup-secondary"
SECONDARY_LOG_PATH="/mnt/backup-secondary/log"

# Compression
COMPRESSION_TYPE="xz"
COMPRESSION_LEVEL="9"
COMPRESSION_MODE="standard"
COMPRESSION_THREADS="0"

# Cloud and rclone (disabled by default)
ENABLE_CLOUD_BACKUP="false"
RCLONE_REMOTE=""
RCLONE_BANDWIDTH_LIMIT="10M"

# Notifications (disabled by default, configure as needed)
TELEGRAM_ENABLED="false"
EMAIL_ENABLED="false"
PROMETHEUS_ENABLED="true"

# Security
SET_BACKUP_PERMISSIONS="true"
ABORT_ON_SECURITY_ISSUES="false"
AUTO_UPDATE_HASHES="true"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
GRAY='\033[0;37m'
PINK='\033[38;5;213m'
BOLD='\033[1m'
RESET='\033[0m'
EOF
    fi
    
    print_success "Configuration setup completed"
}

# Function to set permissions
set_permissions() {
    print_status "Setting up permissions..."
    
    cd "$INSTALL_DIR"
    
    # Make scripts executable
    chmod +x script/*.sh
    chmod +x lib/*.sh
    
    # Secure configuration file
    chmod 600 env/backup.env
    
    # Create necessary directories
    mkdir -p backup log config secure_account
    
    # Set ownership to root
    chown -R root:root "$INSTALL_DIR"
    
    print_success "Permissions set correctly"
}

# Function to fix permissions
run_fix_permissions() {
    print_status "Fixing file permissions..."
    
    cd "$INSTALL_DIR"
    
    if [[ -f "script/fix-permissions.sh" ]]; then
        ./script/fix-permissions.sh
        print_success "Permissions fixed"
    else
        print_warning "Fix permissions script not found, skipping"
    fi
}

# Function to run security check
run_security_check() {
    print_status "Running security check..."
    
    cd "$INSTALL_DIR"
    
    if [[ -f "script/security-check.sh" ]]; then
        if ./script/security-check.sh; then
            print_success "Security check passed"
        else
            print_warning "Security check found issues, but continuing installation"
        fi
    else
        print_warning "Security check script not found, skipping"
    fi
}

# Function to setup cron job
setup_cron() {
    print_status "Setting up automatic backup schedule..."
    
    # Check if cron job already exists
    if crontab -l 2>/dev/null | grep -q "proxmox-backup"; then
        print_warning "Cron job already exists, skipping"
        return
    fi
    
    # Create temporary cron file
    TEMP_CRON=$(mktemp)
    
    # Get existing crontab (if any)
    crontab -l 2>/dev/null > "$TEMP_CRON" || true
    
    # Add new cron job
    echo "0 2 * * * /usr/local/bin/proxmox-backup >/dev/null 2>&1" >> "$TEMP_CRON"
    
    # Install new crontab
    crontab "$TEMP_CRON"
    
    # Clean up
    rm -f "$TEMP_CRON"
    
    print_success "Cron job added for daily backups at 2 AM"
}

# Function to create symlinks
create_symlinks() {
    print_status "Creating system symlinks..."
    
    # Create symlink in /usr/local/bin
    ln -sf "$INSTALL_DIR/script/proxmox-backup.sh" /usr/local/bin/proxmox-backup
    ln -sf "$INSTALL_DIR/script/security-check.sh" /usr/local/bin/proxmox-backup-security
    ln -sf "$INSTALL_DIR/script/fix-permissions.sh" /usr/local/bin/proxmox-backup-permissions
    
    print_success "System symlinks created"
}

# Function to run first backup test
run_first_backup() {
    print_status "Running first backup test (dry-run mode)..."
    
    cd "$INSTALL_DIR"
    
    # Only run test if main script exists
    if [[ -f "script/proxmox-backup.sh" ]]; then
        if ./script/proxmox-backup.sh --dry-run 2>/dev/null; then
            print_success "First backup test completed successfully"
        else
            print_warning "First backup test had issues, but installation completed"
            print_warning "This is normal for a fresh installation - configure backup.env and try again"
        fi
    else
        print_warning "Main backup script not found in repository"
        print_warning "Please check the repository structure"
    fi
}

# Function to display completion message
show_completion() {
    echo
            if [[ -f /tmp/proxmox_backup_was_update ]]; then
            print_success "Update completed successfully!"
        else
            echo "========================================"
			print_success "🎉 FRESH INSTALLATION COMPLETED 🎉"
			echo "========================================"
        fi
    echo
    echo -e "${BOLD}${GREEN}Next steps:${RESET}"
    echo -e "1. ${CYAN}Edit configuration:${RESET} nano $INSTALL_DIR/env/backup.env"
    echo -e "2. ${CYAN}Run first backup:${RESET} ./$INSTALL_DIR/script/proxmox-backup.sh"
    echo -e "3. ${CYAN}Check logs:${RESET} tail -f $INSTALL_DIR/log/*.log"
    # Read and decode unique code from .server_identity file
    UNIQUE_CODE=""
    if [[ -f "$INSTALL_DIR/config/.server_identity" ]]; then
        # Extract encoded data from the config-like format
        local encoded=$(grep "SYSTEM_CONFIG_DATA=" "$INSTALL_DIR/config/.server_identity" 2>/dev/null | cut -d'"' -f2)
        
        if [[ -n "$encoded" ]]; then
            # Decode from base64 and extract server_id (first field)
            local decoded_data=$(echo "$encoded" | base64 -d 2>/dev/null)
            if [[ -n "$decoded_data" ]]; then
                UNIQUE_CODE=$(echo "$decoded_data" | cut -d':' -f1)
            fi
        fi
    fi
    
    if [[ -n "$UNIQUE_CODE" ]]; then
        echo -e "4. ${CYAN}Telegram:${RESET} Open bot @ProxmoxAN_bot and insert your unique code: ${BOLD}${YELLOW}$UNIQUE_CODE${RESET}"
    else
        echo -e "4. ${CYAN}Telegram:${RESET} Open bot @ProxmoxAN_bot and insert your unique code"
    fi
    echo
    echo -e "${BOLD}${YELLOW}Documentation:${RESET}"
    echo -e "- Complete docs: $INSTALL_DIR/doc/README.md"
    echo -e "- Configuration: $INSTALL_DIR/doc/CONFIGURATION.md"
    echo
    echo -e "${BOLD}${PURPLE}Quick commands:${RESET}"
    echo -e "- Backup: ${CYAN}proxmox-backup${RESET}"
    echo -e "- Test mode: ${CYAN}proxmox-backup --dry-run${RESET}"
    echo -e "- Security: ${CYAN}proxmox-backup-security${RESET}"
    echo -e "- Permissions: ${CYAN}proxmox-backup-permissions${RESET}"
    echo
    echo -e "${BOLD}${BLUE}Installation Options:${RESET}"
    echo -e "- ${GREEN}Update (preserves settings):${RESET}"
    echo -e "  ${CYAN}bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/tis24dev/proxmox-backup/main/install.sh)\"${RESET}"
    echo -e "- ${RED}Fresh install (removes everything):${RESET}"
    echo -e "  ${CYAN}bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/tis24dev/proxmox-backup/main/new-install.sh)\"${RESET}"
    echo
}

# Function to handle errors
error_handler() {
    print_error "Installation failed at step: $1"
    print_error "Check the output above for more information"
    exit 1
}

# Main installation function
main() {
    print_header
    
    # Set error handling
    trap 'error_handler "${BASH_COMMAND}"' ERR
    
    # Run installation steps
    check_root
    check_requirements
    install_dependencies
    clone_repository
    setup_configuration
    set_permissions
    run_fix_permissions
    run_security_check
    setup_cron
    create_symlinks
    run_first_backup
    show_completion
    
    # Clean up temporary markers
    rm -f /tmp/proxmox_backup_was_update 2>/dev/null || true
}

# Run main function
main "$@" 
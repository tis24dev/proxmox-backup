#!/bin/bash

# ============================================================================
# PROXMOX BACKUP SYSTEM - FRESH INSTALLATION
# ============================================================================
# Fresh installation script for Proxmox Backup System
# WARNING: This script will completely remove existing installation
#
# Usage: bash -c "$(curl -fsSL https://raw.githubusercontent.com/tis24dev/proxmox-backup/main/new-install.sh)"
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
SCRIPT_NAME="Proxmox Backup System Fresh Installer"
SCRIPT_VERSION="0.1.0"
REPO_URL="https://github.com/tis24dev/proxmox-backup"
INSTALL_DIR="/opt/proxmox-backup"
INSTALL_SCRIPT_URL="https://raw.githubusercontent.com/tis24dev/proxmox-backup/main/install.sh"

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

print_critical() {
    echo -e "${RED}${BOLD}[CRITICAL]${RESET} $1"
}

print_header() {
    echo -e "${BOLD}${RED}================================${RESET}"
    echo -e "${BOLD}${RED}  $SCRIPT_NAME v$SCRIPT_VERSION${RESET}"
    echo -e "${BOLD}${RED}================================${RESET}"
    echo
}

# Function to check if running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error "This script must be run as root (use sudo)"
        exit 1
    fi
}

# Function to show critical warning
show_critical_warning() {
    echo
    print_critical "⚠️  DANGER: COMPLETE REMOVAL OF EXISTING INSTALLATION  ⚠️"
    echo
    echo -e "${BOLD}${RED}This script will COMPLETELY REMOVE:${RESET}"
    echo -e "${RED}  • All configuration files (including backup.env)${RESET}"
    echo -e "${RED}  • Server identity and security settings${RESET}"
    echo -e "${RED}  • All existing backups and logs${RESET}"
    echo -e "${RED}  • All custom configurations${RESET}"
    echo -e "${RED}  • Everything in: ${INSTALL_DIR}${RESET}"
    echo
    echo -e "${BOLD}${YELLOW}Use this script ONLY if you want to start completely fresh!${RESET}"
    echo -e "${BOLD}${YELLOW}For updates, use the regular install.sh script instead.${RESET}"
    echo
    echo -e "${BOLD}${GREEN}Regular update (preserves settings):${RESET}"
    echo -e "${GREEN}bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/tis24dev/proxmox-backup/main/install.sh)\"${RESET}"
    echo
}

# Function to confirm removal
confirm_removal() {
    echo -e "${BOLD}${RED}To confirm complete removal, type: ${YELLOW}REMOVE-EVERYTHING${RESET}"
    echo -e "${BOLD}${RED}To cancel, type anything else or press Ctrl+C${RESET}"
    echo
    read -p "Confirmation: " -r CONFIRMATION
    
    if [[ "$CONFIRMATION" != "REMOVE-EVERYTHING" ]]; then
        print_error "Operation cancelled - incorrect confirmation"
        echo
        print_status "If you want to update preserving settings, use:"
        echo -e "${GREEN}bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/tis24dev/proxmox-backup/main/install.sh)\"${RESET}"
        exit 1
    fi
    
    print_warning "Confirmation accepted - proceeding with complete removal"
}

# Function to completely remove existing installation
complete_removal() {
    print_status "Performing complete removal of existing installation..."
    
    if [[ -d "$INSTALL_DIR" ]]; then
        print_status "Removing directory: $INSTALL_DIR"
        
        # Remove cron jobs first
        if crontab -l 2>/dev/null | grep -q "proxmox-backup"; then
            print_status "Removing cron jobs..."
            crontab -l 2>/dev/null | grep -v "proxmox-backup" | crontab - || true
        fi
        
        # Remove symlinks
        print_status "Removing system symlinks..."
        rm -f /usr/local/bin/proxmox-backup 2>/dev/null || true
        rm -f /usr/local/bin/proxmox-backup-security 2>/dev/null || true
        rm -f /usr/local/bin/proxmox-backup-permissions 2>/dev/null || true
        
        # Force removal of all files, including protected ones
        print_status "Forcing removal of all files (including protected ones)..."
        
        # Remove file attributes that might prevent deletion
        find "$INSTALL_DIR" -type f -exec chattr -i {} \; 2>/dev/null || true
        
        # Change ownership to root to ensure we can delete
        chown -R root:root "$INSTALL_DIR" 2>/dev/null || true
        
        # Force removal
        rm -rf "$INSTALL_DIR" 2>/dev/null || {
            print_warning "Some files couldn't be removed normally, trying alternative method..."
            
            # Alternative removal method for stubborn files
            find "$INSTALL_DIR" -type f -delete 2>/dev/null || true
            find "$INSTALL_DIR" -type d -delete 2>/dev/null || true
            
            # If still exists, try with force
            if [[ -d "$INSTALL_DIR" ]]; then
                print_status "Using force removal..."
                rm -rf "$INSTALL_DIR" || {
                    print_error "Could not completely remove $INSTALL_DIR"
                    print_error "Some files may be in use or require manual removal"
                    exit 1
                }
            fi
        }
        
        print_success "Complete removal successful"
    else
        print_status "No existing installation found at $INSTALL_DIR"
    fi
    
    # Clean up any remaining temporary files
    print_status "Cleaning up temporary files..."
    rm -f /tmp/proxmox_backup_* 2>/dev/null || true
    rm -f /tmp/backup_*_*.lock 2>/dev/null || true
    
    print_success "Cleanup completed"
}

# Function to run fresh installation
run_fresh_installation() {
    print_status "Starting fresh installation..."
    
    # Download and execute install.sh
    print_status "Downloading and executing install.sh..."
    
    if curl -fsSL "$INSTALL_SCRIPT_URL" | bash; then
        print_status "Base installation completed"
    else
        print_error "Fresh installation failed"
        exit 1
    fi
}

# Function to handle errors
error_handler() {
    print_error "Fresh installation failed at step: $1"
    print_error "Check the output above for more information"
    exit 1
}

# Main function
main() {
    print_header
    
    # Set error handling
    trap 'error_handler "${BASH_COMMAND}"' ERR
    
    # Check if running as root
    check_root
    
    # Show critical warning
    show_critical_warning
    
    # Confirm removal
    confirm_removal
    
    # Perform complete removal
    complete_removal
    
    # Run fresh installation
    run_fresh_installation
    
    echo
    echo "========================================"
    print_success "🎉 FRESH INSTALLATION COMPLETED 🎉"
    echo "========================================"
    echo
    print_status "The system has been completely reinstalled with default settings."
    print_status "ALL previous data has been removed and the system is now clean."
    echo
}

# Run main function
main "$@" 
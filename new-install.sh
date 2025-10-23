#!/bin/bash
##
# Proxmox Backup System - Fresh Installer
# File: new-install.sh
# Version: 1.1.0
# Last Modified: 2025-10-19
# Changes: **Added backup verification before removal - prevents data loss from corrupted backups**
##
# ============================================================================
# PROXMOX BACKUP SYSTEM - FRESH INSTALLATION
# ============================================================================
# Fresh installation script for Proxmox Backup System
# WARNING: This script will completely remove existing installation
#
# Usage: bash -c "$(curl -fsSL https://raw.githubusercontent.com/tis24dev/proxmox-backup/main/new-install.sh)"
#
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
NEW_INSTALLER_VERSION="1.1.0"
REPO_URL="https://github.com/tis24dev/proxmox-backup"
INSTALL_DIR="/opt/proxmox-backup"
INSTALL_SCRIPT_URL="https://raw.githubusercontent.com/tis24dev/proxmox-backup/main/install.sh"

# Backup verification status
BACKUP_VERIFIED=false
BACKUP_FILE=""

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
    echo -e "${BOLD}${RED}  $SCRIPT_NAME v$NEW_INSTALLER_VERSION${RESET}"
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

# Function to create temporary backup before removal
create_backup_before_removal() {
    if [[ ! -d "$INSTALL_DIR" ]]; then
        print_status "No existing installation to backup"
        return 0
    fi

    print_status "Existing installation detected at $INSTALL_DIR"
    echo
    echo -e "${BOLD}${YELLOW}BACKUP RECOMMENDATION:${RESET}"
    echo -e "${YELLOW}It is STRONGLY recommended to create a temporary backup before complete removal.${RESET}"
    echo -e "${YELLOW}This backup can be used to restore data if needed (before system reboot).${RESET}"
    echo
    read -p "Create temporary backup before removal? (Y/n): " -n 1 -r BACKUP_CHOICE
    echo

    if [[ ! $BACKUP_CHOICE =~ ^[Nn]$ ]]; then
        # Define backup location and filename in /tmp
        BACKUP_TIMESTAMP=$(date +%Y%m%d_%H%M%S)
        BACKUP_FILE="/tmp/proxmox-backup-full-${BACKUP_TIMESTAMP}.tar.gz"
        README_FILE="/tmp/proxmox-backup-restore-${BACKUP_TIMESTAMP}.txt"

        # Remove immutable attributes before backup
        print_status "Preparing files for backup..."
        if command -v chattr >/dev/null 2>&1; then
            chattr -R -i "$INSTALL_DIR" 2>/dev/null || true
        fi

        # Create compressed backup
        print_status "Creating temporary compressed backup (this may take a while)..."
        if tar czf "$BACKUP_FILE" -C "$(dirname "$INSTALL_DIR")" "$(basename "$INSTALL_DIR")" 2>/dev/null; then
            local backup_size=$(du -h "$BACKUP_FILE" | cut -f1)
            print_success "Temporary backup created successfully: $BACKUP_FILE ($backup_size)"
            echo

            # Verify backup integrity
            if verify_backup "$BACKUP_FILE"; then
                BACKUP_VERIFIED=true
                print_success "Backup verified and ready for use"
            else
                print_error "Backup verification failed!"
                print_error "The backup file may be corrupted or incomplete"

                # Remove corrupted backup
                print_status "Removing corrupted backup file..."
                rm -f "$BACKUP_FILE" 2>/dev/null || true

                echo
                echo -e "${BOLD}${RED}BACKUP VERIFICATION FAILED!${RESET}"
                echo -e "${RED}The backup could not be verified and has been removed.${RESET}"
                echo
                read -p "Do you want to continue WITHOUT backup? (y/N): " -n 1 -r CONTINUE_NO_BACKUP
                echo

                if [[ ! $CONTINUE_NO_BACKUP =~ ^[Yy]$ ]]; then
                    print_error "Operation cancelled for safety"
                    exit 1
                fi

                print_warning "Proceeding without verified backup - data loss risk!"
                BACKUP_VERIFIED=false
                BACKUP_FILE=""
                sleep 2
                return 0
            fi
            echo

            # Create README with restoration instructions
            cat > "$README_FILE" << EOF
================================================================================
PROXMOX BACKUP SYSTEM - TEMPORARY BACKUP ARCHIVE
================================================================================
Created: $(date)
Backup File: $BACKUP_FILE
Original Location: $INSTALL_DIR
Backup Size: $backup_size

================================================================================
IMPORTANT - TEMPORARY BACKUP
================================================================================
This is a TEMPORARY backup stored in /tmp/
It will be automatically deleted when the system reboots or when /tmp is cleaned.

If you need to keep this backup permanently, copy it to a safe location NOW:
  cp $BACKUP_FILE /root/proxmox-backup-full-${BACKUP_TIMESTAMP}.tar.gz

================================================================================
RESTORATION INSTRUCTIONS
================================================================================

To restore this backup manually (before system reboot):

1. Stop any running backup processes:
   pkill -f proxmox-backup

2. Remove current installation (if exists):
   rm -rf $INSTALL_DIR

3. Extract the backup:
   tar xzf "$BACKUP_FILE" -C /opt/

4. Fix permissions:
   chown -R root:root $INSTALL_DIR
   chmod -R 755 $INSTALL_DIR
   chmod 600 $INSTALL_DIR/env/backup.env

5. Recreate symlinks:
   ln -sf $INSTALL_DIR/script/proxmox-backup.sh /usr/local/bin/proxmox-backup
   ln -sf $INSTALL_DIR/script/security-check.sh /usr/local/bin/proxmox-backup-security
   ln -sf $INSTALL_DIR/script/fix-permissions.sh /usr/local/bin/proxmox-backup-permissions
   ln -sf $INSTALL_DIR/script/proxmox-restore.sh /usr/local/bin/proxmox-restore

6. Test the restoration:
   proxmox-backup --dry-run

7. Recreate cron job:
   (crontab -l 2>/dev/null; echo "0 2 * * * /usr/local/bin/proxmox-backup >/dev/null 2>&1") | crontab -

================================================================================
BACKUP CONTENTS
================================================================================
This backup contains:
- All configuration files (env/backup.env)
- Server identity and security settings
- All backups stored in backup/
- All logs stored in log/
- Custom tools in tec-tool/ (if present)
- All scripts and libraries

================================================================================
CLEANUP
================================================================================
To manually remove this temporary backup:
  rm -f $BACKUP_FILE $README_FILE

This backup was created automatically by new-install.sh v${NEW_INSTALLER_VERSION}
================================================================================
EOF

            print_success "Restoration instructions created: $README_FILE"
            echo
            echo -e "${BOLD}${YELLOW}Temporary Backup Location: ${CYAN}$BACKUP_FILE${RESET} ${YELLOW}($backup_size)${RESET}"
            echo -e "${BOLD}${YELLOW}Instructions: ${CYAN}$README_FILE${RESET}"
            echo
            echo -e "${BOLD}${RED}⚠️  IMPORTANT: This backup is TEMPORARY (in /tmp/)${RESET}"
            echo -e "${RED}   It will be deleted on system reboot or /tmp cleanup.${RESET}"
            echo -e "${GREEN}   To keep permanently, run:${RESET}"
            echo -e "${CYAN}   cp $BACKUP_FILE /root/proxmox-backup-saved-${BACKUP_TIMESTAMP}.tar.gz${RESET}"
            echo

            # Save backup location for later reference
            echo "$BACKUP_FILE" > /tmp/proxmox_backup_archive_location

        else
            print_error "Failed to create backup"
            echo
            read -p "Continue with removal anyway? (y/N): " -n 1 -r CONTINUE_ANYWAY
            echo
            if [[ ! $CONTINUE_ANYWAY =~ ^[Yy]$ ]]; then
                print_error "Operation cancelled"
                exit 1
            fi
        fi
    else
        print_warning "Backup skipped by user request"
        echo
        echo -e "${BOLD}${RED}WARNING: Proceeding without backup!${RESET}"
        echo -e "${RED}All data will be permanently lost.${RESET}"
        echo
        sleep 2
    fi
}

# Function to verify backup integrity
verify_backup() {
    local backup_archive="$1"

    print_status "Verifying backup integrity..."

    # Test 1: Check if archive is readable and valid
    if ! tar -tzf "$backup_archive" >/dev/null 2>&1; then
        print_error "Backup archive is corrupted or unreadable"
        return 1
    fi

    print_success "Archive integrity test passed"

    # Test 2: Verify critical files are present in backup
    print_status "Checking for critical files in backup..."

    local missing_files=0

    # List all files in backup
    local backup_contents=$(tar -tzf "$backup_archive" 2>/dev/null)

    # Check for env/backup.env
    if echo "$backup_contents" | grep -F "env/backup.env" >/dev/null 2>&1; then
        print_success "Found critical file: env/backup.env"
    else
        print_warning "Critical path not found in backup: env/backup.env"
        missing_files=$((missing_files + 1))
    fi

    # Check for script/ directory
    if echo "$backup_contents" | grep -F "script/" >/dev/null 2>&1; then
        print_success "Found critical directory: script/"
    else
        print_warning "Critical path not found in backup: script/"
        missing_files=$((missing_files + 1))
    fi

    if [[ $missing_files -gt 0 ]]; then
        print_warning "Some critical files may be missing from backup"
        echo
        read -p "Continue anyway? (y/N): " -n 1 -r CONTINUE_MISSING
        echo
        if [[ ! $CONTINUE_MISSING =~ ^[Yy]$ ]]; then
            print_error "Backup verification failed due to missing files"
            return 1
        fi
    else
        print_success "All critical files found in backup"
    fi

    # Test 3: Count files in backup vs original directory
    print_status "Comparing file counts..."
    local backup_file_count=$(tar -tzf "$backup_archive" 2>/dev/null | wc -l)
    local original_file_count=$(find "$INSTALL_DIR" -type f 2>/dev/null | wc -l)

    print_status "Original directory: $original_file_count files"
    print_status "Backup archive: $backup_file_count entries"

    # Allow some variance (directories are counted in tar)
    if [[ $backup_file_count -lt $((original_file_count / 2)) ]]; then
        print_warning "Backup contains significantly fewer files than original"
        echo
        read -p "Continue anyway? (y/N): " -n 1 -r CONTINUE_FEWER
        echo
        if [[ ! $CONTINUE_FEWER =~ ^[Yy]$ ]]; then
            print_error "Backup verification failed due to file count mismatch"
            return 1
        fi
    fi

    print_success "Backup verification completed successfully"
    return 0
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
        # Safety check: ensure backup was verified if one was created
        if [[ -n "$BACKUP_FILE" ]] && [[ "$BACKUP_VERIFIED" != "true" ]]; then
            print_critical "SAFETY CHECK FAILED!"
            print_error "Existing installation detected but backup was not verified"
            print_error "Cannot proceed with removal to prevent data loss"
            echo
            echo -e "${BOLD}${YELLOW}Options:${RESET}"
            echo -e "${YELLOW}1. Cancel and try creating backup again${RESET}"
            echo -e "${YELLOW}2. Continue at your own risk (data will be lost)${RESET}"
            echo
            read -p "Continue WITHOUT verified backup? (y/N): " -n 1 -r FORCE_CONTINUE
            echo

            if [[ ! $FORCE_CONTINUE =~ ^[Yy]$ ]]; then
                print_error "Operation cancelled for safety - backup not verified"
                exit 1
            fi

            print_warning "User forced continuation without verified backup"
            sleep 2
        fi

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
        rm -f /usr/local/bin/proxmox-restore 2>/dev/null || true
        
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
    
    # Clean up any remaining temporary files (except the backup we just created)
    print_status "Cleaning up old temporary files..."
    # Remove old temporary files but preserve the current backup and its location marker
    find /tmp -maxdepth 1 -name "proxmox_backup_*" -type f ! -name "proxmox_backup_archive_location" ! -name "proxmox-backup-full-*.tar.gz" ! -name "proxmox-backup-restore-*.txt" -delete 2>/dev/null || true
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

    # Create backup before removal (if installation exists)
    create_backup_before_removal

    # Confirm removal
    confirm_removal

    # Perform complete removal
    complete_removal

    # Run fresh installation
    run_fresh_installation

    echo
    echo "================================================"
    print_success "🎉 FRESH INSTALLATION COMPLETED 🎉"
    echo "================================================"
    echo
    print_status "The system has been completely reinstalled with default settings."
    print_status "ALL previous data has been removed and the system is now clean."
    echo

    # Show backup location if backup was created
    if [[ -f /tmp/proxmox_backup_archive_location ]]; then
        BACKUP_LOCATION=$(cat /tmp/proxmox_backup_archive_location)
        local backup_size=$(du -h "$BACKUP_LOCATION" 2>/dev/null | cut -f1)
        echo -e "${BOLD}${YELLOW}⚠️  Temporary Backup Information:${RESET}"
        echo -e "${CYAN}Previous installation backed up to: ${YELLOW}$BACKUP_LOCATION${RESET} ${YELLOW}($backup_size)${RESET}"
        echo -e "${CYAN}Restoration instructions: ${YELLOW}/tmp/proxmox-backup-restore-*.txt${RESET}"
        echo
        echo -e "${BOLD}${RED}IMPORTANT: Backup is in /tmp/ and will be deleted on reboot!${RESET}"
        echo -e "${GREEN}To keep permanently, copy it now:${RESET}"
        local timestamp=$(echo "$BACKUP_LOCATION" | grep -oP '\d{8}_\d{6}')
        echo -e "${CYAN}cp $BACKUP_LOCATION /root/proxmox-backup-saved-${timestamp}.tar.gz${RESET}"
        echo

        # Clean up temporary file
        rm -f /tmp/proxmox_backup_archive_location
    fi
}

# Run main function
main "$@" 
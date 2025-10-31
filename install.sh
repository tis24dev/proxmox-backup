#!/bin/bash
##
# Proxmox Backup System - Automatic Installer
# File: install.sh
# Version: 1.2.1
# Last Modified: 2025-10-30
# Changes: Added email configuration update with EMAIL_RECIPIENT preservation
##
# ============================================================================
# PROXMOX BACKUP SYSTEM - AUTOMATIC INSTALLER
# ============================================================================
# Automatic installation script for Proxmox Backup System
# This script handles the complete installation process
#
# Usage:
#   Standard installation (main branch):
#     bash -c "$(curl -fsSL https://raw.githubusercontent.com/tis24dev/proxmox-backup/main/install.sh)"
#
#   Development installation (dev branch):
#     bash -c "$(curl -fsSL https://raw.githubusercontent.com/tis24dev/proxmox-backup/main/install.sh)" -- dev
#
#   With verbose mode:
#     bash install.sh --verbose
#     bash install.sh dev --verbose
#
# ============================================================================

set -euo pipefail

# Parse command line arguments
VERBOSE_MODE=false
INSTALL_BRANCH=""

# First pass: check for flags
for arg in "$@"; do
    case $arg in
        --verbose)
            VERBOSE_MODE=true
            ;;
        main|dev)
            # Valid branch name
            INSTALL_BRANCH="$arg"
            ;;
        *)
            # Could be unknown option or branch name
            if [[ -z "$INSTALL_BRANCH" && "$arg" != "--verbose" ]]; then
                # Assume it's a branch name
                INSTALL_BRANCH="$arg"
            fi
            ;;
    esac
done

# Set default branch if not specified
INSTALL_BRANCH="${INSTALL_BRANCH:-main}"

# Validate branch name
case "$INSTALL_BRANCH" in
    main|dev)
        # Valid branch
        ;;
    *)
        echo -e "\033[0;31m[ERROR]\033[0m Invalid branch: '$INSTALL_BRANCH'. Allowed values: main, dev"
        echo ""
        echo "Usage:"
        echo "  bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/tis24dev/proxmox-backup/main/install.sh)\""
        echo "  bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/tis24dev/proxmox-backup/main/install.sh)\" -- dev"
        exit 1
        ;;
esac

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
INSTALLER_VERSION="1.1.3"
REPO_URL="https://github.com/tis24dev/proxmox-backup"
INSTALL_DIR="/opt/proxmox-backup"

# Branch-aware URLs
GITHUB_RAW_BASE="https://raw.githubusercontent.com/tis24dev/proxmox-backup/${INSTALL_BRANCH}"
INSTALL_SCRIPT_URL="${GITHUB_RAW_BASE}/install.sh"
NEW_INSTALL_SCRIPT_URL="${GITHUB_RAW_BASE}/new-install.sh"

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

# Function to check if branch exists on remote repository
check_remote_branch() {
    local branch="$1"
    print_status "Checking if branch '$branch' exists on remote repository..."

    if ! git ls-remote --heads "$REPO_URL" "$branch" 2>/dev/null | grep -q "refs/heads/$branch"; then
        print_error "Branch '$branch' does not exist on remote repository"
        echo ""
        print_status "Available branches:"
        git ls-remote --heads "$REPO_URL" 2>/dev/null | sed 's/.*refs\/heads\//  - /' || echo "  Unable to fetch branch list"
        echo ""
        print_error "Please use an existing branch or wait until '$branch' branch is created"
        return 1
    fi

    print_success "Branch '$branch' exists on remote repository"
    return 0
}

print_header() {
    echo -e "${BOLD}${CYAN}================================${RESET}"
    echo -e "${BOLD}${CYAN}  $SCRIPT_NAME v$INSTALLER_VERSION${RESET}"
    echo -e "${BOLD}${CYAN}================================${RESET}"
    echo
    echo -e "${BOLD}${GREEN}This script preserves your existing configuration and data${RESET}"
    echo -e "${BOLD}${GREEN}For a complete fresh installation, use new-install.sh instead${RESET}"
    echo

    # Show branch information
    echo -e "${BOLD}${BLUE}Installing from branch: ${INSTALL_BRANCH}${RESET}"
    if [[ "$INSTALL_BRANCH" == "dev" ]]; then
        echo -e "${BOLD}${YELLOW}WARNING: You are installing the development branch${RESET}"
        echo -e "${YELLOW}This may contain untested features and bugs${RESET}"
    fi
    echo

    if [[ "$VERBOSE_MODE" == "true" ]]; then
        echo -e "${BOLD}${YELLOW}Running in VERBOSE mode - showing all output${RESET}"
    else
        echo -e "${BOLD}${BLUE}Running in SILENT mode - use --verbose to show backup script output${RESET}"
    fi
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

# Function to safely remove existing installation by creating a full temporary backup
safe_remove_installation() {
    print_status "Safely backing up and removing existing installation..."
    
    # Change to a safe directory to avoid issues when deleting current working directory
    cd /tmp
    
    # Create temporary directory to hold the full backup
    TEMP_PRESERVE=$(mktemp -d)
    
    # --- Step 1: Remove immutable attributes before backup and deletion ---
    print_status "Removing immutable attributes from existing installation..."
    if command -v chattr >/dev/null 2>&1; then
        chattr -R -i "$INSTALL_DIR" 2>/dev/null || true
    fi
    
    # --- Step 2: Create a full backup of the existing installation ---
    print_status "Creating a full backup in a temporary directory..."
    if cp -a "$INSTALL_DIR" "$TEMP_PRESERVE/backup"; then
        print_success "Full backup created successfully at $TEMP_PRESERVE/backup"
    else
        print_error "Failed to create a full backup of the installation directory"
        rm -rf "$TEMP_PRESERVE" # Clean up temp dir on failure
        exit 1
    fi
    
    # --- Step 3: Completely remove the original installation directory ---
    print_status "Removing original installation directory..."
    if rm -rf "$INSTALL_DIR"; then
        print_success "Original installation directory removed successfully"
    else
        print_error "Failed to remove the installation directory. Manual removal may be required."
        exit 1
    fi
    
    # --- Step 4: Save the path of the temporary backup for the restore function ---
    echo "$TEMP_PRESERVE" > /tmp/proxmox_backup_preserve_path
    
    print_success "Existing installation safely backed up and removed"
}

# Function to restore critical files from the temporary backup
restore_preserved_files() {
    if [[ ! -f /tmp/proxmox_backup_preserve_path ]]; then
        return
    fi
    
    TEMP_PRESERVE=$(cat /tmp/proxmox_backup_preserve_path)
    local backup_source_dir="$TEMP_PRESERVE/backup"
    
    if [[ -d "$backup_source_dir" ]]; then
        print_status "Restoring critical files from temporary backup..."
        
        # List of critical files/directories to restore
        local PRESERVE_PATHS=(
            "config/.server_identity"
            "config/server_id"
            "env/backup.env"
            "secure_account"
            "backup"
            "log"
            "lock"
            "tec-tool"
        )
        
        for path in "${PRESERVE_PATHS[@]}"; do
            local source_path="$backup_source_dir/$path"
            if [[ -e "$source_path" ]]; then
                # Ensure the parent directory exists in the new installation
                mkdir -p "$INSTALL_DIR/$(dirname "$path")"
                
                # Remove existing file/directory if it exists to avoid nested copies
                if [[ -e "$INSTALL_DIR/$path" ]]; then
                    rm -rf "$INSTALL_DIR/$path"
                fi
                
                # Copy the file/directory back
                if cp -a "$source_path" "$INSTALL_DIR/$path"; then
                    print_status "Restored: $path"
                else
                    print_warning "Failed to restore: $path"
                fi
            fi
        done
        
        print_success "Critical files restored successfully"
    fi
    
    # Clean up the temporary backup directory and tracker file
    print_status "Cleaning up temporary backup files..."
    rm -rf "$TEMP_PRESERVE" 2>/dev/null || true
    rm -f /tmp/proxmox_backup_preserve_path 2>/dev/null || true
    print_success "Cleanup complete"
}

# Function to add storage monitoring configuration
add_storage_monitoring_config() {
    local config_file="$INSTALL_DIR/env/backup.env"
    
    if [[ ! -f "$config_file" ]]; then
        return 0
    fi
    
    # Check if storage monitoring section is already present
    if grep -q "STORAGE_WARNING_THRESHOLD_PRIMARY" "$config_file"; then
        print_status "Storage monitoring configuration already present"
        return 0
    fi
    
    print_status "Adding storage monitoring configuration section..."
    
    # Create backup
    cp "$config_file" "${config_file}.backup.$(date +%Y%m%d_%H%M%S)"
    
    # Use awk to insert after the section separator following "PATHS AND STORAGE CONFIGURATION"
    awk '
        /^# 3\. PATHS AND STORAGE CONFIGURATION$/ { found=1 }
        found && /^# =+$/ && !inserted {
            print
            print ""
            print "# ---------- Storage Monitoring ----------"
            print "# Warning thresholds for storage space usage (percentage)"
            print "# Script will generate warnings and set EXIT_CODE=1 when storage usage exceeds these thresholds"
            print "STORAGE_WARNING_THRESHOLD_PRIMARY=\"90\""
            print "STORAGE_WARNING_THRESHOLD_SECONDARY=\"90\""
            inserted=1
            next
        }
        { print }
    ' "$config_file" > "${config_file}.tmp" && mv "${config_file}.tmp" "$config_file"
    
    print_success "Storage monitoring configuration added successfully"
}

# Function to update blacklist configuration
update_blacklist_config() {
    local config_file="$INSTALL_DIR/env/backup.env"

    if [[ ! -f "$config_file" ]]; then
        return 0
    fi

    # Define required entries
    local required_entries=("/root/.npm" "/root/.dotnet" "/root/.local" "/root/.gnupg")

    # Check if ALL required entries are already present
    local all_present=true
    for entry in "${required_entries[@]}"; do
        if ! grep -q "^${entry}\$" "$config_file"; then
            all_present=false
            break
        fi
    done

    if [[ "$all_present" == "true" ]]; then
        print_status "Blacklist configuration already contains all required entries"
        return 0
    fi

    print_status "Updating blacklist configuration (ensuring all /root exclusions are present)..."

    # Create backup
    cp "$config_file" "${config_file}.backup.$(date +%Y%m%d_%H%M%S)"

    # Use awk to process the file
    # - Remove /root/.* if present
    # - Remove any existing required entries (to avoid duplicates when re-adding)
    # - Insert all 4 entries in a block after /root/.cache
    awk '
        # Remove /root/.* wildcard pattern if present
        /^\/root\/\.\*$/ { next }

        # Remove any existing entries that will be re-added (avoid duplicates)
        /^\/root\/\.npm$/ { next }
        /^\/root\/\.dotnet$/ { next }
        /^\/root\/\.local$/ { next }
        /^\/root\/\.gnupg$/ { next }

        # Insert all 4 entries after /root/.cache
        /^\/root\/\.cache$/ {
            print
            print "/root/.npm"
            print "/root/.dotnet"
            print "/root/.local"
            print "/root/.gnupg"
            next
        }

        # Print all other lines as-is
        { print }
    ' "$config_file" > "${config_file}.tmp" && mv "${config_file}.tmp" "$config_file"

    print_success "Blacklist configuration updated successfully"
}

# Function to update email configuration
update_email_config() {
    local config_file="$INSTALL_DIR/env/backup.env"

    if [[ ! -f "$config_file" ]]; then
        return 0
    fi

    if grep -q '# Email delivery method: "relay" (Cloud relay) or "sendmail" (local SMTP)' "$config_file"; then
        print_status "Email configuration already in new format"
        return 0
    fi

    print_status "Updating email configuration section to new format..."

    cp "$config_file" "${config_file}.backup.$(date +%Y%m%d_%H%M%S)"

    # Extract existing EMAIL_RECIPIENT value if present (preserve user customization)
    # Stop at # character to remove inline comments, then trim trailing spaces
    local existing_recipient=$(grep "^EMAIL_RECIPIENT=" "$config_file" 2>/dev/null | sed -n 's/^EMAIL_RECIPIENT="\([^#"]*\).*/\1/p' | sed 's/[[:space:]]*$//' || echo "")

    # Inform user if preserving a custom value
    if [[ -n "$existing_recipient" ]]; then
        print_status "Preserving existing EMAIL_RECIPIENT: $existing_recipient"
    fi

    # Use AWK to update the email section, passing the preserved recipient value
    awk -v recipient="$existing_recipient" '
        /^# ---------- Email Configuration ----------$/ {
            print "# ---------- Email Configuration ----------"
            print "# Email delivery method: \"relay\" (Cloud relay) or \"sendmail\" (local SMTP)"
            print "# Note: \"ses\" is deprecated but still supported for backward compatibility (treated as \"relay\")"
            print "EMAIL_DELIVERY_METHOD=\"relay\""
            print ""
            print "# Fallback to sendmail if cloud relay fails (rate limit, network error, etc.)"
            print "EMAIL_FALLBACK_SENDMAIL=\"true\""
            print ""
            print "# Email recipient (if empty, uses root email from Proxmox)"
            print "EMAIL_RECIPIENT=\"" recipient "\""
            print ""
            print "# Email sender (configured in Worker, cannot be overridden)"
            print "# This value is informational only - Worker uses no-reply@proxmox.tis24.it"
            print "EMAIL_FROM=\"no-reply@proxmox.tis24.it\""
            print ""
            print "# Email subject prefix"
            print "EMAIL_SUBJECT_PREFIX=\"[Proxmox-Backup]\""
            print ""
            skip=1
            next
        }
        skip {
            if (/^# =============/ || /^# ---------- Prometheus Configuration ----------$/) {
                skip=0
                print
            }
            next
        }
        { print }
    ' "$config_file" > "${config_file}.tmp" && mv "${config_file}.tmp" "$config_file"

    print_success "Email configuration updated successfully"
}

# Function to update configuration header if needed
update_config_header() {
    local config_file="$INSTALL_DIR/env/backup.env"
    
    if [[ ! -f "$config_file" ]]; then
        return 0
    fi

    # Check if the file has the configuration section marker
    if ! grep -q "# 1. GENERAL SYSTEM CONFIGURATION" "$config_file"; then
        print_warning "Configuration file format not recognized, skipping header update"
        return 0
    fi

    # Extract current header from user's file (first 20 lines until the body marker)
    local current_header=$(head -n 20 "$config_file")

    # Define reference header (must match HEADER_EOF below)
    local reference_header=$(cat <<'REFERENCE_EOF'
#!/bin/bash
# ============================================================================
# PROXMOX BACKUP SYSTEM - MAIN CONFIGURATION
# File: backup.env
# Version: 1.1.3
# Last Modified: 2025-10-25
# Changes: Automatic migration from wildcard to specific blacklist exclusions
# ============================================================================
# Main configuration file for Proxmox backup system
# This file contains all configurations needed for automated backup
# of PVE (Proxmox Virtual Environment) and PBS (Proxmox Backup Server)
#
# IMPORTANT:
# - This file must have 600 permissions and be owned by root
# - Always verify configuration before running backups in production
# - Keep backup copies of this configuration file
# - La versione del SISTEMA viene caricata dal file VERSION
# - La versione QUI indica la versione del formato di configurazione
# ============================================================================
REFERENCE_EOF
)

    # Compare headers - skip if identical
    if [[ "$current_header" == "$reference_header" ]]; then
        print_status "Configuration header already up to date"
        return 0
    fi
    
    print_status "Updating configuration file header to new format..."
    
    # Create backup
    cp "$config_file" "${config_file}.backup.$(date +%Y%m%d_%H%M%S)"
    
    # Extract everything from "# 1. GENERAL SYSTEM CONFIGURATION" onwards
    awk '
        /^# ============================================================================$/ {
            if (getline next_line > 0) {
                if (next_line ~ /^# 1\. GENERAL SYSTEM CONFIGURATION$/) {
                    found=1
                    print
                    print next_line
                } else {
                    if (found) print
                    if (found) print next_line
                }
            }
            next
        }
        found {print}
    ' "$config_file" > "${config_file}.body.tmp"
    
    # Check if we successfully extracted the body
    if [[ ! -s "${config_file}.body.tmp" ]]; then
        print_error "Failed to extract configuration body"
        rm -f "${config_file}.body.tmp"
        return 1
    fi
    
    # Create the new header and append the body
    cat > "${config_file}.tmp" << 'HEADER_EOF'
#!/bin/bash
# ============================================================================
# PROXMOX BACKUP SYSTEM - MAIN CONFIGURATION
# File: backup.env
# Version: 1.1.3
# Last Modified: 2025-10-25
# Changes: Automatic migration from wildcard to specific blacklist exclusions
# ============================================================================
# Main configuration file for Proxmox backup system
# This file contains all configurations needed for automated backup
# of PVE (Proxmox Virtual Environment) and PBS (Proxmox Backup Server)
#
# IMPORTANT:
# - This file must have 600 permissions and be owned by root
# - Always verify configuration before running backups in production
# - Keep backup copies of this configuration file
# - La versione del SISTEMA viene caricata dal file VERSION
# - La versione QUI indica la versione del formato di configurazione
# ============================================================================

HEADER_EOF
    
    # Append the body
    cat "${config_file}.body.tmp" >> "${config_file}.tmp"
    
    # Replace the original file
    mv "${config_file}.tmp" "$config_file"
    
    # Clean up temporary file
    rm -f "${config_file}.body.tmp"
    
    print_success "Configuration header updated successfully"
}

# Function to protect the server identity file
protect_identity_file() {
    local identity_file="$INSTALL_DIR/config/.server_identity"
    if [[ -f "$identity_file" ]] && command -v chattr >/dev/null 2>&1; then
        print_status "Protecting server identity file..."
        if chattr +i "$identity_file"; then
            print_success "Server identity file is now protected (immutable)."
        else
            print_warning "Failed to set immutable attribute on server identity file."
        fi
    fi
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
        echo -e "${RED}bash -c \"\$(curl -fsSL ${NEW_INSTALL_SCRIPT_URL})\"${RESET}"
        echo
        read -p "Continue with update (preserving data)? (y/N): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            # Mark this as an update
            touch /tmp/proxmox_backup_was_update
            safe_remove_installation
        else
            print_error "Update cancelled"
            exit 1
        fi
    fi

    # Check if branch exists on remote before attempting clone
    if ! check_remote_branch "$INSTALL_BRANCH"; then
        exit 1
    fi

    # Clone repository with specified branch
    print_status "Cloning repository from branch: $INSTALL_BRANCH"
    git clone -b "$INSTALL_BRANCH" "$REPO_URL" "$INSTALL_DIR"
    chmod 744 "$INSTALL_DIR/install.sh" "$INSTALL_DIR/new-install.sh"

    if [[ ! -d "$INSTALL_DIR" ]]; then
        print_error "Failed to clone repository"
        exit 1
    fi

    # Verify we got the correct branch
    cd "$INSTALL_DIR"
    CLONED_BRANCH=$(git branch --show-current)
    if [[ "$CLONED_BRANCH" != "$INSTALL_BRANCH" ]]; then
        print_warning "Branch mismatch! Expected $INSTALL_BRANCH, got $CLONED_BRANCH"
    else
        print_success "Repository cloned successfully from branch: $INSTALL_BRANCH"
    fi
    cd - > /dev/null

    # Restore preserved files
    restore_preserved_files
}

# Function to setup configuration
setup_configuration() {
    print_status "Setting up configuration..."
    
    cd "$INSTALL_DIR"
    
    # Create configuration from repository or restored from previous installation
    if [[ -f "env/backup.env" ]]; then
        print_success "Configuration file found (preserved from previous installation or in repository)"
        
        # Update configuration file if this is an update
        if [[ -f /tmp/proxmox_backup_was_update ]]; then
            update_config_header
            add_storage_monitoring_config
            update_blacklist_config
            update_email_config
        fi
    else
        print_warning "Configuration file not found, creating basic config"
        mkdir -p env
        cat > env/backup.env << 'EOF'
#!/bin/bash
# ============================================================================
# PROXMOX BACKUP SYSTEM - MAIN CONFIGURATION
# File: backup.env
# Version: 1.2.0
# Last Modified: 2025-10-27
# Changes: Cloud email setting
# ============================================================================
# Main configuration file for Proxmox backup system
# This file contains all configurations needed for automated backup
# of PVE (Proxmox Virtual Environment) and PBS (Proxmox Backup Server)
#
# IMPORTANT:
# - This file must have 600 permissions and be owned by root
# - Always verify configuration before running backups in production
# - Keep backup copies of this configuration file
# - La versione del SISTEMA viene caricata dal file VERSION
# - La versione QUI indica la versione del formato di configurazione
# ============================================================================

# ============================================================================
# 1. GENERAL SYSTEM CONFIGURATION
# ============================================================================

# Minimum required Bash version
MIN_BASH_VERSION="4.4.0"

# Debug level: "standard", "advanced" (-v), "extreme" (-x)
DEBUG_LEVEL="standard"

# Required packages for system operation
REQUIRED_PACKAGES="tar gzip zstd pigz jq curl rclone gpg"
OPTIONAL_PACKAGES=""

# Automatic installation of missing dependencies
AUTO_INSTALL_DEPENDENCIES="true"

# Disable colors in output (useful for logs or terminals that don't support colors)
DISABLE_COLORS="false"

# ============================================================================
# 2. MAIN FEATURES - ENABLE/DISABLE
# ============================================================================

# ---------- Backup Features ----------
# General system backup
BACKUP_INSTALLED_PACKAGES="true"        # List of installed packages
BACKUP_SCRIPT_DIR="true"                # Scripts directory
BACKUP_CRONTABS="true"                  # Cron tables
BACKUP_ZFS_CONFIG="true"                # ZFS configuration
BACKUP_CRITICAL_FILES="true"            # Critical system files
BACKUP_NETWORK_CONFIG="true"            # Network configuration
BACKUP_REMOTE_CFG="true"                # Remote configurations

# PVE-specific backup (Proxmox Virtual Environment)
BACKUP_CLUSTER_CONFIG="true"            # Cluster configuration /etc/pve
BACKUP_COROSYNC_CONFIG="true"           # Corosync configuration
BACKUP_PVE_FIREWALL="true"              # PVE firewall rules
BACKUP_VM_CONFIGS="true"                # VM/Container configurations
BACKUP_VZDUMP_CONFIG="true"             # vzdump configuration
BACKUP_CEPH_CONFIG="true"               # Ceph configuration (if present)

# PVE job information backup
BACKUP_PVE_JOBS="true"                  # PVE backup job information
BACKUP_PVE_SCHEDULES="true"             # Scheduled tasks and cron jobs
BACKUP_PVE_REPLICATION="true"           # Replication information

# PBS backup (Proxmox Backup Server)
BACKUP_PXAR_FILES="true"                # PXAR files
BACKUP_SMALL_PXAR="true"                # Small PXAR files
BACKUP_PVE_BACKUP_FILES="true"          # Detailed analysis of PVE backup files
BACKUP_SMALL_PVE_BACKUPS="false"        # Copy small PVE backup files (enable only if needed)

# ---------- Storage Features ----------
# Multiple backups
ENABLE_SECONDARY_BACKUP="false"         # Local secondary backup
ENABLE_CLOUD_BACKUP="false"             # Cloud backup
SECONDARY_BACKUP_REQUIRED="false"       # Secondary backup mandatory
CLOUD_BACKUP_REQUIRED="false"           # Cloud backup mandatory

# Parallel processing
MULTI_STORAGE_PARALLEL="false"          # Parallel processing on multiple storage

# ---------- Security Features ----------
# Security checks
ABORT_ON_SECURITY_ISSUES="false"        # Abort backup if security issues found
AUTO_UPDATE_HASHES="true"               # Automatically update hashes
REMOVE_UNAUTHORIZED_FILES="false"       # Remove unauthorized files
CHECK_NETWORK_SECURITY="false"          # Verify network security
CHECK_FIREWALL="false"                  # Verify firewall configuration
CHECK_OPEN_PORTS="false"                # Check open ports
FULL_SECURITY_CHECK="true"              # Complete security check

# ---------- Advanced Compression Features ----------
# Deduplication - replaces duplicate files with symlinks to save space
# WARNING: Set to "false" if experiencing backup issues
ENABLE_DEDUPLICATION="false"

# Preprocessor - optimizes files before compression
# Processes text files, logs, JSON and configuration files to improve compression
ENABLE_PREFILTER="true"

# Smart chunking - splits very large files to improve compression
# Useful for databases and large binary files but may slow down backup
ENABLE_SMART_CHUNKING="true"

# ---------- Monitoring Features ----------
# Log management
ENABLE_LOG_MANAGEMENT="true"            # Automatic log management
ENABLE_EMOJI_LOG="true"                 # Emojis in logs for better readability

# Notifications
TELEGRAM_ENABLED="true"                 # Telegram notifications
EMAIL_ENABLED="true"                    # Email notifications

# Metrics
PROMETHEUS_ENABLED="true"               # Prometheus metrics export

# ---------- Permission Management ----------
SET_BACKUP_PERMISSIONS="true"           # Set backup permissions

# ============================================================================
# 3. PATHS AND STORAGE CONFIGURATION
# ============================================================================

# ---------- Storage Monitoring ----------
# Warning thresholds for storage space usage (percentage)
# Script will generate warnings and set EXIT_CODE=1 when storage usage exceeds these thresholds
STORAGE_WARNING_THRESHOLD_PRIMARY="90"
STORAGE_WARNING_THRESHOLD_SECONDARY="90"

# ---------- Automatic Detection ----------
# Automatic detection of datastores from PBS and PVE systems
# Set to "false" to use only manual PBS_DATASTORE_PATH configuration
AUTO_DETECT_DATASTORES="true"

# ---------- Backup Paths ----------
# Local backup path (primary)
LOCAL_BACKUP_PATH="${BASE_DIR}/backup"

# Secondary backup path (external) # Write your secondary path
SECONDARY_BACKUP_PATH=""

# Cloud backup path
CLOUD_BACKUP_PATH="/proxmox-backup/backup"

# ---------- Log Paths ----------
# Local log path
LOCAL_LOG_PATH="${BASE_DIR}/log/"

# Secondary log path # Write your secondary path
SECONDARY_LOG_PATH=""

# Cloud log path
CLOUD_LOG_PATH="/proxmox-backup/log"

# ---------- Retention Policy ----------
# Maximum number of backups to keep
MAX_LOCAL_BACKUPS=20
MAX_SECONDARY_BACKUPS=20
MAX_CLOUD_BACKUPS=20

# Maximum number of logs to keep
MAX_LOCAL_LOGS=20
MAX_SECONDARY_LOGS=20
MAX_CLOUD_LOGS=20

# ---------- Custom Paths ----------
# Custom PBS and PVE paths
PBS_DATASTORE_PATH=""
PVE_CONFIG_PATH="/etc/pve"
PVE_CLUSTER_PATH="/var/lib/pve-cluster"
COROSYNC_CONFIG_PATH="/etc/corosync"
VZDUMP_CONFIG_PATH="/etc/vzdump.conf"
CEPH_CONFIG_PATH="/etc/ceph"

# ============================================================================
# 4. COMPRESSION CONFIGURATION
# ============================================================================

# Compression type
# - "zstd": Fast, good speed/compression balance
# - "xz": Better compression, slower
# - "gzip"/"pigz": Compatible, standard
COMPRESSION_TYPE="xz"

# Compression level (1=fast, 9=maximum compression)
COMPRESSION_LEVEL="9"

# Compression mode
# - "fast": Fast, basic compression
# - "standard": Balanced
# - "maximum": Maximum compression, slower
# - "ultra": Extreme compression, very slow
COMPRESSION_MODE="ultra"

# Compression threads
# - 0: Automatic (uses all available cores)
# - 1: Single-thread
# - N: Specific number of threads
COMPRESSION_THREADS="0"

# ============================================================================
# 5. CLOUD AND RCLONE CONFIGURATION
# ============================================================================

# ---------- rclone Configuration ----------
# Configured rclone remote name
RCLONE_REMOTE="gdrive"

# Bandwidth limit for rclone
RCLONE_BANDWIDTH_LIMIT="10M"

# Additional rclone flags
RCLONE_FLAGS="--transfers=16 --checkers=4 --stats=0 --drive-use-trash=false --drive-pacer-min-sleep=10ms --drive-pacer-burst=100"

# ---------- Cloud Upload Mode ----------
# Upload mode: "parallel" (recommended) or "sequential" (traditional)
# - Parallel: Uploads backup, checksum and log simultaneously
# - Sequential: Uploads files one by one
CLOUD_UPLOAD_MODE="parallel"

# Maximum number of parallel jobs for cloud upload (recommended: 3)
# Higher values may cause rate limiting on cloud providers
CLOUD_PARALLEL_MAX_JOBS="3"

# Parallel verification of uploaded files
# - true: Verify all files simultaneously (faster)
# - false: Verify files sequentially (slower but more reliable)
CLOUD_PARALLEL_VERIFICATION="true"

# Timeout for parallel uploads (in seconds)
CLOUD_PARALLEL_UPLOAD_TIMEOUT="600"

# ---------- Cloud Upload Verification ----------
# Skip upload verification (use only if experiencing persistent verification issues)
# - true: Completely disable verification (faster but less reliable)
# - false: Perform verification with retry logic (default, recommended)
SKIP_CLOUD_VERIFICATION="false"

# ============================================================================
# 6. NOTIFICATIONS CONFIGURATION
# ============================================================================

# ---------- Telegram Configuration ----------
# Tokens
TELEGRAM_BOT_TOKEN="" # For personal mode
TELEGRAM_CHAT_ID="" # For personal mode

# Bot type: "personal" or "centralized"
BOT_TELEGRAM_TYPE="centralized"

# Custom Telegram API server
TELEGRAM_SERVER_API_HOST="https://bot.tis24.it:1443" # Port 1443 must be opened on 433 of telegram server

# ---------- Email Configuration ----------
# Email delivery method: "relay" (Cloud relay) or "sendmail" (local SMTP)
# Note: "ses" is deprecated but still supported for backward compatibility (treated as "relay")
EMAIL_DELIVERY_METHOD="relay"

# Fallback to sendmail if cloud relay fails (rate limit, network error, etc.)
EMAIL_FALLBACK_SENDMAIL="true"

# Email recipient (if empty, uses root email from Proxmox)
EMAIL_RECIPIENT=""

# Email sender (configured in Worker, cannot be overridden)
# This value is informational only - Worker uses no-reply@proxmox.tis24.it
EMAIL_FROM="no-reply@proxmox.tis24.it"

# Email subject prefix
EMAIL_SUBJECT_PREFIX="[Proxmox-Backup]"

# ============================================================================
# 7. PROMETHEUS CONFIGURATION
# ============================================================================

# Directory for Prometheus node-exporter text files
PROMETHEUS_TEXTFILE_DIR="/var/lib/prometheus/node-exporter"

# ============================================================================
# 8. USERS AND PERMISSIONS CONFIGURATION
# ============================================================================

# Backup user and group
BACKUP_USER="backup"
BACKUP_GROUP="backup"

# ============================================================================
# 9. CUSTOM CONFIGURATIONS
# ============================================================================

# ---------- Custom Backup Paths ----------
# List of additional paths to include in backup
# One path per line, enclosed in quotes
CUSTOM_BACKUP_PATHS="
/root/.config/rclone/rclone.conf
/etc/apt/
/etc/gshadow
/etc/shadow
/etc/group
/root
"

# ---------- Backup Blacklist ----------
# Paths to exclude from backup
# One path per line, supports patterns and variables
# Supported formats:
#   - Exact path: /root/.cache (excludes /root/.cache and all subdirectories)
#   - Glob pattern: /root/.* (excludes all hidden files/folders in /root)
#   - Wildcard: *_cacache* (excludes any path containing "_cacache")
#   - Variables: ${BASE_DIR}/log/ (variables are expanded)
BACKUP_BLACKLIST="
/etc/proxmox-backup/.debug
/etc/proxmox-backup/.tmp
/etc/proxmox-backup/.lock
/etc/proxmox-backup/tasks
/root/.bash_history
/root/.cache
/root/.npm
/root/.dotnet
/root/.local
/root/.gnupg
/root/.codex
/root/.claude
${BASE_DIR}/log/
${BASE_DIR}/backup/
"

# ---------- PXAR Options ----------
# Maximum size for small PXAR files
MAX_PXAR_SIZE="50M"

# Pattern to include specific PXAR files
PXAR_INCLUDE_PATTERN="vm/100,vm/101"

# ---------- PVE Backup Options ----------
# Maximum size for small PVE backup files to copy
MAX_PVE_BACKUP_SIZE="100M"

# Pattern to include specific PVE backup files (e.g., "vm-100-", "ct-101-")
PVE_BACKUP_INCLUDE_PATTERN=""

# ============================================================================
# 10. ANSI COLORS FOR OUTPUT
# ============================================================================
# Color definitions for terminal output
# Used to improve readability of logs and messages

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

# ============================================================================
# END OF CONFIGURATION
# ============================================================================
# For additional support and documentation, consult:
# - Project README.md
# - Official Proxmox documentation
# - rclone documentation for cloud configurations
# ============================================================================

#END
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
    mkdir -p backup log config secure_account lock
    
    # Set ownership to root
    chown -R root:root "$INSTALL_DIR"
    
    print_success "Permissions set correctly"
}

# Function to fix permissions
run_fix_permissions() {
    print_status "Fixing file permissions..."
    
    cd "$INSTALL_DIR"
    
    if [[ -f "script/fix-permissions.sh" ]]; then
        if [[ "$VERBOSE_MODE" == "true" ]]; then
            # Verbose mode: show all output
            ./script/fix-permissions.sh
        else
            # Silent mode: hide all output
            ./script/fix-permissions.sh >/dev/null 2>&1
        fi
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
        if [[ "$VERBOSE_MODE" == "true" ]]; then
            # Verbose mode: show all output
            if ./script/security-check.sh; then
                print_success "Security check passed"
            else
                print_warning "Security check found issues, but continuing installation"
            fi
        else
            # Silent mode: hide all output
            if ./script/security-check.sh >/dev/null 2>&1; then
                print_success "Security check passed"
            else
                print_warning "Security check found issues, but continuing installation"
            fi
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
    ln -sf "$INSTALL_DIR/script/proxmox-restore.sh" /usr/local/bin/proxmox-restore
    
    print_success "System symlinks created"
}

# Function to run first backup test
run_first_backup() {
    print_status "Running first backup test (dry-run mode)..."
    
    cd "$INSTALL_DIR"
    
    # Only run test if main script exists
    if [[ -f "script/proxmox-backup.sh" ]]; then
        if [[ "$VERBOSE_MODE" == "true" ]]; then
            # Verbose mode: show all output
            if ./script/proxmox-backup.sh --dry-run; then
                print_success "First backup test completed successfully"
            else
                print_warning "First backup test had issues, but installation completed"
                print_warning "This is normal for a fresh installation - configure backup.env and try again"
            fi
        else
            # Silent mode: hide all output
            if ./script/proxmox-backup.sh --dry-run >/dev/null 2>&1; then
                print_success "First backup test completed successfully"
            else
                print_warning "First backup test had issues, but installation completed"
                print_warning "This is normal for a fresh installation - configure backup.env and try again"
            fi
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
			echo "================================================"
            print_success "🎉 UPDATE COMPLETED SUCCESSFULLY 🎉"
			echo "================================================"
        else
            echo "================================================"
			print_success "🎉 FRESH INSTALLATION COMPLETED 🎉"
			echo "================================================"
        fi
    echo
    echo -e "${BOLD}${GREEN}Next steps:${RESET}"
    echo -e "1. ${CYAN}Edit configuration:${RESET} nano $INSTALL_DIR/env/backup.env"
    echo -e "2. ${CYAN}Run first backup:${RESET} $INSTALL_DIR/script/proxmox-backup.sh"
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
    echo -e "- Restore: ${CYAN}proxmox-restore${RESET}"
    echo
    echo -e "${BOLD}${BLUE}Installation Options:${RESET}"
    echo -e "- ${GREEN}Update (preserves settings):${RESET}"
    echo -e "  ${CYAN}bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/tis24dev/proxmox-backup/main/install.sh)\"${RESET}"
    echo -e "  ${CYAN}bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/tis24dev/proxmox-backup/main/install.sh)\" -- dev${RESET}"
    echo -e "- ${RED}Fresh install (removes everything):${RESET}"
    echo -e "  ${CYAN}bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/tis24dev/proxmox-backup/main/new-install.sh)\"${RESET}"
    echo -e "  ${CYAN}bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/tis24dev/proxmox-backup/main/new-install.sh)\" -- dev${RESET}"
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

    # Ensure installer runs from a safe working directory before filesystem operations
    if ! cd "$(dirname "$INSTALL_DIR")" 2>/dev/null; then
        cd /
    fi
    print_status "Working directory set to $(pwd)"

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
    
    # Protect the identity file at the very end, after all permissions are set
    protect_identity_file
    
    show_completion
    
    # Clean up temporary markers
    rm -f /tmp/proxmox_backup_was_update 2>/dev/null || true
}

# Run main function
main "$@" 
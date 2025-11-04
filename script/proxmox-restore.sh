#!/bin/bash
##
# Proxmox Restore Script for PVE and PBS
# File: proxmox-restore.sh
# Version: 1.0.1
# Last Modified: 2025-11-03
# Changes: New selective restore
#
# This script performs restoration of Proxmox configurations from backup files
# created by the Proxmox Backup System
##

# ======= Base variables BEFORE set -u =======
# Resolve symlink to get the real script path
SCRIPT_REAL_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
export SCRIPT_DIR="$(dirname "$SCRIPT_REAL_PATH")"
export BASE_DIR="$(dirname "$SCRIPT_DIR")"
export ENV_FILE="${BASE_DIR}/env/backup.env"

# ==========================================
# INITIAL CONFIGURATION
# ==========================================

# ======= Execution environment (cron-safe) =======
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# ======= Timezone setting (cron-safe) =======
# Use system timezone with fallback to UTC (timedatectl has priority as it's the current system setting)
export TZ="${TZ:-$(timedatectl show -p Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null || echo "UTC")}"

# ======= Standard exit codes =======
EXIT_SUCCESS=0
EXIT_WARNING=1
EXIT_ERROR=2

# ==========================================
# CONFIGURATION LOADING
# ==========================================

# ======= Loading .env before enabling set -u =======
if [[ -f "$ENV_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$ENV_FILE"
    echo "Proxmox Restore Script Version: ${SCRIPT_VERSION:-1.0.1}"
else
    echo "[ERROR] Configuration file not found: $ENV_FILE"
    exit $EXIT_ERROR
fi

# ==========================================
# SHELL CONFIGURATION
# ==========================================

# ======= Safe shell mode (only after .env) =======
set -uo pipefail
set -o errexit
set -o nounset

# ==========================================
# GLOBAL VARIABLES
# ==========================================

SELECTED_LOCATION=""
SELECTED_BACKUP=""
HOSTNAME=$(hostname -f)
TIMESTAMP=$(date +"%Y-%m-%d_%H-%M-%S")
RESTORE_MODE="full"
declare -a SELECTED_CATEGORIES=()
BACKUP_VERSION="Unknown"
BACKUP_SUPPORTS_SELECTIVE="false"
SELECTED_BACKUP_LABEL=""
SELECTED_EXTRACT_DIR=""
SELECTED_TEMP_BACKUP_FILE=""
BACKUP_DETECTED_SELECTIVE="false"

# ==========================================
# COLORS AND FORMATTING
# ==========================================

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
NC='\033[0m' # No Color

# ==========================================
# LOGGING FUNCTIONS
# ==========================================

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

step() {
    echo -e "${PURPLE}[STEP]${NC} $1"
}

debug() {
    local level="${DEBUG_LEVEL:-standard}"
    if [ "$level" = "advanced" ] || [ "$level" = "extreme" ]; then
        echo -e "${CYAN}[DEBUG]${NC} $1"
    fi
}

get_display_proxmox_type() {
    if [ -n "${PROXMOX_TYPE:-}" ]; then
        echo "${PROXMOX_TYPE^^}"
    else
        echo "Unknown"
    fi
}

# ==========================================
# UTILITY FUNCTIONS
# ==========================================

# Function to check if a storage location is enabled
is_storage_enabled() {
    local storage_type="$1"

    case "$storage_type" in
        "local")
            return 0  # Local is always available
            ;;
        "secondary")
            [ "${ENABLE_SECONDARY_BACKUP:-false}" = "true" ]
            ;;
        "cloud")
            [ "${ENABLE_CLOUD_BACKUP:-false}" = "true" ]
            ;;
        *)
            return 1
            ;;
    esac
}

# Function to get storage path
get_storage_path() {
    local storage_type="$1"

    case "$storage_type" in
        "local")
            echo "$LOCAL_BACKUP_PATH"
            ;;
        "secondary")
            echo "$SECONDARY_BACKUP_PATH"
            ;;
        "cloud")
            echo "${RCLONE_REMOTE}:${CLOUD_BACKUP_PATH}"
            ;;
        *)
            return 1
            ;;
    esac
}

# Function to validate backup file integrity
validate_backup_file() {
    local backup_file="$1"
    local storage_type="$2"

    # Check if checksum file exists
    local checksum_file="${backup_file}.sha256"
    local metadata_file="${backup_file}.metadata"

    case "$storage_type" in
        "local"|"secondary")
            # Check if checksum file exists
            if [ ! -f "$checksum_file" ]; then
                return 1  # No checksum file
            fi

            # Verify checksum
            if command -v sha256sum >/dev/null 2>&1; then
                if ! sha256sum -c "$checksum_file" >/dev/null 2>&1; then
                    return 1  # Checksum verification failed
                fi
            fi

            # Check if metadata file exists
            if [ ! -f "$metadata_file" ]; then
                return 1  # No metadata file
            fi

            return 0  # File is valid
            ;;
        "cloud")
            # For cloud storage, we can't easily verify checksums
            # Just check if both files exist
            if command -v rclone >/dev/null 2>&1; then
                local checksum_exists=$(rclone ls "${RCLONE_REMOTE}:${CLOUD_BACKUP_PATH}/$(basename "$checksum_file")" 2>/dev/null | wc -l)
                local metadata_exists=$(rclone ls "${RCLONE_REMOTE}:${CLOUD_BACKUP_PATH}/$(basename "$metadata_file")" 2>/dev/null | wc -l)

                if [ "$checksum_exists" -gt 0 ] && [ "$metadata_exists" -gt 0 ]; then
                    return 0  # Both files exist
                fi
            fi
            return 1  # Files don't exist or can't verify
            ;;
    esac
}

# Function to list backup files in a location
list_backup_files() {
    local storage_type="$1"
    local storage_path="$2"

    case "$storage_type" in
        "local"|"secondary")
            if [ -d "$storage_path" ]; then
                # Find backup files excluding checksum and metadata files
                local all_files=()
                while IFS= read -r file; do
                    [ -n "$file" ] && all_files+=("$file")
                done < <(find "$storage_path" -name "*-backup-*.tar*" -type f 2>/dev/null | \
                        grep -v -E '\.(sha256|metadata|sum|md5|sha1|sha512)$' | \
                        sort -r)

                # Filter only valid backup files
                local valid_files=()
                for file in "${all_files[@]}"; do
                    if validate_backup_file "$file" "$storage_type"; then
                        valid_files+=("$file")
                    fi
                done

                # Output valid files
                printf '%s\n' "${valid_files[@]}"
            fi
            ;;
        "cloud")
            if command -v rclone >/dev/null 2>&1; then
                # Get all backup files
                local all_files=()
                while IFS= read -r file; do
                    [ -n "$file" ] && all_files+=("$file")
                done < <(rclone ls "$storage_path" 2>/dev/null | \
                        grep -E ".*-backup-.*\.tar.*" | \
                        awk '{print $2}' | \
                        grep -v -E '\.(sha256|metadata|sum|md5|sha1|sha512)$' | \
                        sort -r)

                # Filter only valid backup files
                local valid_files=()
                for file in "${all_files[@]}"; do
                    if validate_backup_file "$file" "$storage_type"; then
                        valid_files+=("$file")
                    fi
                done

                # Output valid files
                printf '%s\n' "${valid_files[@]}"
            fi
            ;;
    esac
}

# Function to read backup metadata file content without full extraction
read_backup_metadata() {
    local backup_file="$1"
    local storage_type="$2"
    local metadata_path="./var/lib/proxmox-backup-info/backup_metadata.txt"
    local content=""

    case "$storage_type" in
        "local"|"secondary")
            [ -f "$backup_file" ] || return 1
            if [[ "$backup_file" == *.tar.zst ]]; then
                command -v zstd >/dev/null 2>&1 || return 1
                content=$(zstd -dc "$backup_file" 2>/dev/null | tar -xOf - "$metadata_path" 2>/dev/null) || return 1
            elif [[ "$backup_file" == *.tar.xz ]]; then
                content=$(tar -xJOf "$backup_file" "$metadata_path" 2>/dev/null) || return 1
            elif [[ "$backup_file" == *.tar.gz ]]; then
                content=$(tar -xzOf "$backup_file" "$metadata_path" 2>/dev/null) || return 1
            elif [[ "$backup_file" == *.tar.bz2 ]]; then
                content=$(tar -xjOf "$backup_file" "$metadata_path" 2>/dev/null) || return 1
            elif [[ "$backup_file" == *.tar ]]; then
                content=$(tar -xOf "$backup_file" "$metadata_path" 2>/dev/null) || return 1
            else
                return 1
            fi
            ;;
        "cloud")
            command -v rclone >/dev/null 2>&1 || return 1
            local remote_file="${RCLONE_REMOTE}:${CLOUD_BACKUP_PATH}/$(basename "$backup_file")"
            if [[ "$backup_file" == *.tar.zst ]]; then
                command -v zstd >/dev/null 2>&1 || return 1
                content=$(rclone cat "$remote_file" ${RCLONE_FLAGS:-} 2>/dev/null | zstd -dc 2>/dev/null | tar -xOf - "$metadata_path" 2>/dev/null) || return 1
            elif [[ "$backup_file" == *.tar.xz ]]; then
                content=$(rclone cat "$remote_file" ${RCLONE_FLAGS:-} 2>/dev/null | tar -xJOf - "$metadata_path" 2>/dev/null) || return 1
            elif [[ "$backup_file" == *.tar.gz ]]; then
                content=$(rclone cat "$remote_file" ${RCLONE_FLAGS:-} 2>/dev/null | tar -xzOf - "$metadata_path" 2>/dev/null) || return 1
            elif [[ "$backup_file" == *.tar.bz2 ]]; then
                content=$(rclone cat "$remote_file" ${RCLONE_FLAGS:-} 2>/dev/null | tar -xjOf - "$metadata_path" 2>/dev/null) || return 1
            elif [[ "$backup_file" == *.tar ]]; then
                content=$(rclone cat "$remote_file" ${RCLONE_FLAGS:-} 2>/dev/null | tar -xOf - "$metadata_path" 2>/dev/null) || return 1
            else
                return 1
            fi
            ;;
        *)
            return 1
            ;;
    esac

    [ -n "$content" ] || return 1
    printf '%s\n' "$content"
    return 0
}

# Function to get backup capability label (Standard/Selective)
get_backup_type_label() {
    local backup_file="$1"
    local storage_type="$2"
    local metadata_content

    if metadata_content=$(read_backup_metadata "$backup_file" "$storage_type"); then
        local supports=$(printf '%s\n' "$metadata_content" | awk -F '=' '$1=="SUPPORTS_SELECTIVE_RESTORE"{print $2}')
        local backup_type=$(printf '%s\n' "$metadata_content" | awk -F '=' '$1=="BACKUP_TYPE"{print $2}' | tr '[:upper:]' '[:lower:]')
        local display_type="Unknown"
        case "$backup_type" in
            pve)
                display_type="PVE"
                ;;
            pbs)
                display_type="PBS"
                ;;
            both|mixed)
                display_type="PVE+PBS"
                ;;
            "")
                display_type="Unknown"
                ;;
            *)
                display_type=$(printf '%s\n' "$backup_type" | tr '[:lower:]' '[:upper:]')
                ;;
        esac

        if [ "$supports" = "true" ]; then
            printf "Selective / %s" "$display_type"
        else
            printf "Standard / %s" "$display_type"
        fi
        return 0
    fi

    if [ "$storage_type" = "cloud" ]; then
        echo "Unknown / Unknown"
    else
        echo "Standard / Unknown"
    fi
}

# Function to display storage selection menu
show_storage_menu() {
    echo ""
    echo -e "${CYAN}=== SELECT BACKUP LOCATION ===${NC}"
    echo ""

    local options=()
    local paths=()
    local count=0

    # Check local storage
    if is_storage_enabled "local"; then
        count=$((count + 1))
        options+=("$count")
        paths+=("local")
        echo -e "${GREEN}$count)${NC} Local Storage: ${LOCAL_BACKUP_PATH}"
    fi

    # Check secondary storage
    if is_storage_enabled "secondary"; then
        count=$((count + 1))
        options+=("$count")
        paths+=("secondary")
        echo -e "${GREEN}$count)${NC} Secondary Storage: ${SECONDARY_BACKUP_PATH}"
    fi

    # Check cloud storage
    if is_storage_enabled "cloud"; then
        count=$((count + 1))
        options+=("$count")
        paths+=("cloud")
        echo -e "${GREEN}$count)${NC} Cloud Storage: ${RCLONE_REMOTE}:${CLOUD_BACKUP_PATH}"
    fi

    if [ $count -eq 0 ]; then
        error "No storage enabled in configuration file"
        exit $EXIT_ERROR
    fi

    echo ""
    echo -e "${YELLOW}0)${NC} Exit"
    echo ""

    while true; do
        read -p "Select backup location to restore from [0-$count]: " choice

        if [ "$choice" = "0" ]; then
            info "Operation cancelled by user"
            exit $EXIT_SUCCESS
        elif [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le $count ]; then
            SELECTED_LOCATION="${paths[$((choice-1))]}"
            break
        else
            warning "Invalid selection. Enter a number between 0 and $count"
        fi
    done
}

# Function to display backup files menu
show_backup_menu() {
    local storage_type="$SELECTED_LOCATION"
    local storage_path=$(get_storage_path "$storage_type")

    echo ""
    echo -e "${CYAN}=== SELECT BACKUP FILE ===${NC}"
    echo ""
    info "Searching for backups in: $storage_path"
    echo ""

    # Get list of backup files
    local backup_files=()
    local backup_labels=()
    while IFS= read -r line; do
        [ -n "$line" ] && backup_files+=("$line")
    done < <(list_backup_files "$storage_type" "$storage_path")

    if [ ${#backup_files[@]} -eq 0 ]; then
        error "No backup files found in $storage_path"
        exit $EXIT_ERROR
    fi

    # Display backup files
    local count=0
    for idx in "${!backup_files[@]}"; do
        local backup_file="${backup_files[$idx]}"
        count=$((count + 1))
        local file_name=$(basename "$backup_file")
        local file_size=""
        local backup_label=$(get_backup_type_label "$backup_file" "$storage_type")
        backup_labels[$idx]="$backup_label"

        # Get file size
        case "$storage_type" in
            "local"|"secondary")
                if [ -f "$backup_file" ]; then
                    file_size=$(du -h "$backup_file" 2>/dev/null | cut -f1)
                fi
                ;;
            "cloud")
                # For cloud, we'll show the name without size for simplicity
                file_size="N/A"
                ;;
        esac

        echo -e "${GREEN}$count)${NC} $file_name ${BLUE}($file_size)${NC} ${PURPLE}[${backup_label}]${NC}"
    done

    echo ""
    echo -e "${YELLOW}0)${NC} Back to previous menu"
    echo ""

    while true; do
        read -p "Select backup file to restore [0-$count]: " choice

        if [ "$choice" = "0" ]; then
            return 1  # Go back to storage menu
        elif [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le $count ]; then
            SELECTED_BACKUP="${backup_files[$((choice-1))]}"
            SELECTED_BACKUP_LABEL="${backup_labels[$((choice-1))]}"
            break
        else
            warning "Invalid selection. Enter a number between 0 and $count"
        fi
    done

    return 0
}

# Function to confirm restore operation
confirm_restore() {
    echo ""
    echo -e "${CYAN}=== RESTORE CONFIRMATION ===${NC}"
    echo ""
    echo -e "Location: ${GREEN}$SELECTED_LOCATION${NC}"
    echo -e "Backup file: ${GREEN}$(basename "$SELECTED_BACKUP")${NC}"
    local display_type
    display_type=$(get_display_proxmox_type)
    if [ -n "$SELECTED_BACKUP_LABEL" ]; then
        echo -e "Backup type (catalog): ${GREEN}$SELECTED_BACKUP_LABEL${NC}"
    fi
    echo -e "System detected: ${GREEN}$display_type${NC}"
    if [ "$BACKUP_DETECTED_SELECTIVE" = "true" ]; then
        echo -e "Type detected: ${GREEN}Selective${NC} (version: ${GREEN}${BACKUP_VERSION:-Unknown}${NC})"
        if [ "$RESTORE_MODE" = "full" ]; then
            echo -e "Selected mode: ${GREEN}Full restore${NC}"
        else
            echo -e "Selected mode: ${GREEN}Selective restore${NC}"

            # Show detailed restoration plan
            echo ""
            echo -e "${CYAN}Will restore:${NC}"
            local category_names=()
            for cat in "${SELECTED_CATEGORIES[@]}"; do
                if [ "$cat" = "all" ]; then
                    category_names=("all categories")
                    break
                else
                    local cat_name="${AVAILABLE_CATEGORIES[$cat]:-$cat}"
                    category_names+=("$cat_name")

                    # Show specific details for storage/datastore categories
                    case "$cat" in
                        "pve_cluster")
                            echo -e "  ${GREEN}✓${NC} ${cat_name} ${BLUE}(/etc/pve, cluster database)${NC}"
                            ;;
                        "storage_pve")
                            echo -e "  ${GREEN}✓${NC} ${cat_name} ${BLUE}(storage.cfg, VM/CT storage locations)${NC}"
                            ;;
                        "pve_jobs")
                            echo -e "  ${GREEN}✓${NC} ${cat_name} ${BLUE}(vzdump jobs, schedules)${NC}"
                            ;;
                        "pbs_config")
                            echo -e "  ${GREEN}✓${NC} ${cat_name} ${BLUE}(/etc/proxmox-backup)${NC}"
                            ;;
                        "datastore_pbs")
                            echo -e "  ${GREEN}✓${NC} ${cat_name} ${BLUE}(datastore.cfg, backup repositories)${NC}"
                            ;;
                        "pbs_jobs")
                            echo -e "  ${GREEN}✓${NC} ${cat_name} ${BLUE}(sync/verify/prune jobs)${NC}"
                            ;;
                        *)
                            echo -e "  ${GREEN}✓${NC} ${cat_name}"
                            ;;
                    esac
                fi
            done
        fi
    else
        echo -e "Type detected: ${GREEN}Standard${NC}"
        echo -e "Selected mode: ${GREEN}Full restore${NC}"
    fi
    echo ""
    echo -e "${RED}WARNING: This operation will overwrite current configurations!${NC}"
    echo ""

    while true; do
        read -p "Are you sure you want to proceed with the restore? [y/N]: " confirm
        case "$confirm" in
            [yY]|[yY][eE][sS])
                return 0
                ;;
            [nN]|[nN][oO]|"")
                info "Operation cancelled by user"
                return 1
                ;;
            *)
                warning "Invalid answer. Enter 'y' for yes or 'n' for no"
                ;;
        esac
    done
}

# Function to download backup file from cloud
download_cloud_backup() {
    local remote_file="$1"
    local local_temp_file="/tmp/$(basename "$remote_file")"

    step "Downloading backup from cloud storage..." >&2

    if ! command -v rclone >/dev/null 2>&1; then
        error "rclone not found. Required to access cloud storage"
        exit $EXIT_ERROR
    fi

    if rclone copy "${RCLONE_REMOTE}:${CLOUD_BACKUP_PATH}/$(basename "$remote_file")" "/tmp/" ${RCLONE_FLAGS:-}; then
        echo "$local_temp_file"
        return 0
    else
        error "Error downloading backup from cloud"
        exit $EXIT_ERROR
    fi
}

# Function to extract backup
extract_backup() {
    local backup_file="$1"
    local extract_dir="/tmp/proxmox_restore_$$"

    step "Extracting backup..." >&2

    # Create extraction directory
    mkdir -p "$extract_dir"

    # Determine compression type and extract
    if [[ "$backup_file" == *.tar.zst ]]; then
        if command -v zstd >/dev/null 2>&1; then
            zstd -dc "$backup_file" | tar -xf - -C "$extract_dir"
        else
            error "zstd not found to extract zstd-compressed backup"
            exit $EXIT_ERROR
        fi
    elif [[ "$backup_file" == *.tar.xz ]]; then
        tar -xJf "$backup_file" -C "$extract_dir"
    elif [[ "$backup_file" == *.tar.gz ]]; then
        tar -xzf "$backup_file" -C "$extract_dir"
    elif [[ "$backup_file" == *.tar.bz2 ]]; then
        tar -xjf "$backup_file" -C "$extract_dir"
    elif [[ "$backup_file" == *.tar ]]; then
        tar -xf "$backup_file" -C "$extract_dir"
    else
        error "Unrecognized compression format: $backup_file"
        exit $EXIT_ERROR
    fi

    echo "$extract_dir"
}

# ==========================================
# SELECTIVE RESTORE FUNCTIONS
# ==========================================

# Detect backup version and selective restore support
detect_backup_version() {
    local extract_dir="$1"
    local metadata_file="$extract_dir/var/lib/proxmox-backup-info/backup_metadata.txt"

    if [ -f "$metadata_file" ]; then
        BACKUP_VERSION=$(grep "^VERSION=" "$metadata_file" 2>/dev/null | cut -d= -f2)
        BACKUP_SUPPORTS_SELECTIVE=$(grep "^SUPPORTS_SELECTIVE_RESTORE=" "$metadata_file" 2>/dev/null | cut -d= -f2)
        local detected_type
        detected_type=$(grep "^BACKUP_TYPE=" "$metadata_file" 2>/dev/null | cut -d= -f2)
        if [ -n "$detected_type" ]; then
            # Normalize to lowercase for internal use
            detected_type=${detected_type,,}
            case "$detected_type" in
                pve|pbs)
                    PROXMOX_TYPE="$detected_type"
                    ;;
            esac
        fi

        if [ "$BACKUP_SUPPORTS_SELECTIVE" = "true" ]; then
            info "Modern backup detected (v$BACKUP_VERSION) - interactive selection available"
            return 0  # Supports selective restore
        fi
    fi

    info "Legacy backup detected - using automatic full restore"
    return 1  # Does not support selective restore
}

# Validate system compatibility (PVE vs PBS)
validate_system_compatibility() {
    local extract_dir="$1"
    local backup_type="${PROXMOX_TYPE:-unknown}"
    local current_system_type="unknown"

    # Detect current running system type
    if [ -d "/etc/pve" ] && command -v pvesh >/dev/null 2>&1; then
        current_system_type="pve"
    elif [ -d "/etc/proxmox-backup" ] && command -v proxmox-backup-manager >/dev/null 2>&1; then
        current_system_type="pbs"
    fi

    # If we can't detect either system, allow restore but warn
    if [ "$current_system_type" = "unknown" ]; then
        warning "Cannot detect current system type (PVE or PBS)"
        warning "Restore will proceed but may fail if incompatible"
        return 0
    fi

    # If backup type is unknown, allow but warn
    if [ "$backup_type" = "unknown" ]; then
        warning "Cannot detect backup type from metadata"
        warning "Restore will proceed but may fail if incompatible"
        return 0
    fi

    # Check for mismatch
    if [ "$backup_type" != "$current_system_type" ]; then
        echo ""
        error "INCOMPATIBLE BACKUP DETECTED!"
        error "Backup type: ${backup_type^^}"
        error "Current system: ${current_system_type^^}"
        echo ""
        error "You are trying to restore a ${backup_type^^} backup on a ${current_system_type^^} system."
        error "This is NOT supported and will cause system malfunction!"
        echo ""

        if [ "$backup_type" = "pve" ] && [ "$current_system_type" = "pbs" ]; then
            error "PVE backups contain:"
            error "  - Cluster configuration (/etc/pve)"
            error "  - VM/Container storage settings"
            error "  - Corosync and cluster services"
            error ""
            error "PBS systems use completely different configurations."
        elif [ "$backup_type" = "pbs" ] && [ "$current_system_type" = "pve" ]; then
            error "PBS backups contain:"
            error "  - PBS datastore configurations"
            error "  - Backup server settings"
            error "  - Sync/Verify/Prune jobs"
            error ""
            error "PVE systems use completely different configurations."
        fi

        echo ""
        error "RESTORE ABORTED FOR SAFETY"
        return 1
    fi

    # Matching types - all good
    success "System compatibility verified: ${current_system_type^^} backup → ${current_system_type^^} system"
    return 0
}

# Analyze backup content and detect available categories
analyze_backup_categories() {
    local extract_dir="$1"

    declare -gA AVAILABLE_CATEGORIES

    # Detect PVE categories
    [ -d "$extract_dir/etc/pve" ] && AVAILABLE_CATEGORIES["pve_cluster"]="PVE Cluster"
    [ -f "$extract_dir/etc/pve/storage.cfg" ] && AVAILABLE_CATEGORIES["storage_pve"]="PVE Storage"
    [ -f "$extract_dir/etc/vzdump.conf" ] && [ -d "$extract_dir/var/lib/pve-cluster/info/jobs" ] && AVAILABLE_CATEGORIES["pve_jobs"]="PVE Backup Jobs"
    [ -d "$extract_dir/etc/corosync" ] && AVAILABLE_CATEGORIES["corosync"]="Corosync (Cluster)"
    [ -d "$extract_dir/etc/ceph" ] && AVAILABLE_CATEGORIES["ceph"]="Ceph Storage"

    # Detect PBS categories
    [ -d "$extract_dir/etc/proxmox-backup" ] && AVAILABLE_CATEGORIES["pbs_config"]="PBS Config"
    [ -f "$extract_dir/etc/proxmox-backup/datastore.cfg" ] && AVAILABLE_CATEGORIES["datastore_pbs"]="PBS Datastores"
    [ -d "$extract_dir/var/lib/proxmox-backup/pxar_metadata" ] && AVAILABLE_CATEGORIES["pbs_jobs"]="PBS Jobs"

    # Detect common categories
    [ -d "$extract_dir/etc/network" ] && AVAILABLE_CATEGORIES["network"]="Network Configuration"
    [ -d "$extract_dir/etc/ssl" ] && AVAILABLE_CATEGORIES["ssl"]="SSL Certificates"
    [ -d "$extract_dir/etc/ssh" ] || [ -d "$extract_dir/root/.ssh" ] && AVAILABLE_CATEGORIES["ssh"]="SSH Keys"
    [ -d "$extract_dir/usr/local" ] && AVAILABLE_CATEGORIES["scripts"]="User Scripts"
    [ -d "$extract_dir/var/spool/cron" ] && AVAILABLE_CATEGORIES["crontabs"]="Crontabs"
    [ -d "$extract_dir/etc/systemd/system" ] && AVAILABLE_CATEGORIES["services"]="Systemd Services"

    local count=${#AVAILABLE_CATEGORIES[@]}
    info "Detected $count available categories in backup"
}

# Show category selection menu
show_category_menu() {
    local extract_dir="$1"
    local system_type="${PROXMOX_TYPE:-unknown}"
    local option2_label=""
    local option2_description=""

    # Determine option 2 label based on system type
    case "$system_type" in
        pve)
            option2_label="PVE STORAGE & CLUSTER"
            option2_description="(cluster + storage + VM configs + jobs)"
            ;;
        pbs)
            option2_label="PBS DATASTORES & JOBS"
            option2_description="(datastores + sync/verify/prune)"
            ;;
        *)
            option2_label="STORAGE only"
            option2_description="(full structure + config)"
            ;;
    esac

    echo ""
    echo -e "${CYAN}=== RESTORE SELECTION ===${NC}"
    echo ""
    echo "Backup detected: v${BACKUP_VERSION} ($(get_display_proxmox_type))"
    echo "Available categories: ${#AVAILABLE_CATEGORIES[@]}"
    echo ""
    echo -e "${GREEN}1)${NC} FULL restore (everything)"
    echo -e "${GREEN}2)${NC} ${option2_label} ${BLUE}${option2_description}${NC}"
    echo -e "${GREEN}3)${NC} SYSTEM BASE only (network, SSL, SSH)"
    echo -e "${GREEN}4)${NC} CUSTOM selection"
    echo -e "${YELLOW}0)${NC} Cancel"
    echo ""

    while true; do
        read -p "Selection [1]: " choice
        choice=${choice:-1}

        case "$choice" in
            1)
                RESTORE_MODE="full"
                SELECTED_CATEGORIES=("all")
                break
                ;;
            2)
                RESTORE_MODE="selective"
                SELECTED_CATEGORIES=()

                # Add storage-related categories based on system type
                if [ "${PROXMOX_TYPE:-}" = "pve" ]; then
                    # PVE: Restore cluster, storage, and jobs
                    for cat in "pve_cluster" "storage_pve" "pve_jobs"; do
                        if [[ -v AVAILABLE_CATEGORIES[$cat] ]]; then
                            SELECTED_CATEGORIES+=("$cat")
                        fi
                    done
                elif [ "${PROXMOX_TYPE:-}" = "pbs" ]; then
                    # PBS: Restore config, datastores, and jobs
                    for cat in "pbs_config" "datastore_pbs" "pbs_jobs"; do
                        if [[ -v AVAILABLE_CATEGORIES[$cat] ]]; then
                            SELECTED_CATEGORIES+=("$cat")
                        fi
                    done
                else
                    # Unknown type: Include both for backward compatibility
                    warning "System type unknown, including all storage-related categories"
                    for cat in "pve_cluster" "storage_pve" "pve_jobs" "pbs_config" "datastore_pbs" "pbs_jobs"; do
                        if [[ -v AVAILABLE_CATEGORIES[$cat] ]]; then
                            SELECTED_CATEGORIES+=("$cat")
                        fi
                    done
                fi

                if [ ${#SELECTED_CATEGORIES[@]} -eq 0 ]; then
                    warning "No storage/datastore categories found in backup"
                    continue
                fi
                info "Selected categories: ${SELECTED_CATEGORIES[*]}"
                break
                ;;
            3)
                RESTORE_MODE="selective"
                SELECTED_CATEGORIES=()
                # Add system base categories
                for cat in "network" "ssl" "ssh" "services"; do
                    if [[ -v AVAILABLE_CATEGORIES[$cat] ]]; then
                        SELECTED_CATEGORIES+=("$cat")
                    fi
                done
                if [ ${#SELECTED_CATEGORIES[@]} -eq 0 ]; then
                    warning "No system base categories found in backup"
                    continue
                fi
                info "Selected categories: ${SELECTED_CATEGORIES[*]}"
                break
                ;;
            4)
                show_custom_selection_menu
                break
                ;;
            0)
                info "Operation cancelled by user"
                return 1
                ;;
            *)
                warning "Invalid selection. Enter a number between 0 and 4"
                ;;
        esac
    done
}

# Show custom category selection menu
show_custom_selection_menu() {
    echo ""
    echo -e "${CYAN}=== CUSTOM SELECTION ===${NC}"
    echo ""
    echo "Select categories to restore (number to toggle, ENTER to confirm):"
    echo ""

    declare -gA CATEGORY_SELECTED
    local idx=1
    declare -gA CATEGORY_INDEX

    for cat in "${!AVAILABLE_CATEGORIES[@]}"; do
        CATEGORY_INDEX[$idx]=$cat
        CATEGORY_SELECTED[$cat]=false
        echo -e "  [ ] $idx) ${AVAILABLE_CATEGORIES[$cat]}"
        ((idx++))
    done

    echo ""
    echo "Commands: [number]=toggle, [a]=all, [n]=none, [c]=continue"
    echo ""

    while true; do
        read -p "> " input

        case "$input" in
            [0-9]*)
                if [ -n "${CATEGORY_INDEX[$input]}" ]; then
                    local cat="${CATEGORY_INDEX[$input]}"
                    if [ "${CATEGORY_SELECTED[$cat]}" = "true" ]; then
                        CATEGORY_SELECTED[$cat]=false
                    else
                        CATEGORY_SELECTED[$cat]=true
                    fi
                    # Redraw menu
                    echo ""
                    idx=1
                    for c in "${!AVAILABLE_CATEGORIES[@]}"; do
                        local mark="[ ]"
                        [ "${CATEGORY_SELECTED[$c]}" = "true" ] && mark="[X]"
                        echo -e "  $mark $idx) ${AVAILABLE_CATEGORIES[$c]}"
                        ((idx++))
                    done
                    echo ""
                fi
                ;;
            [aA])
                for cat in "${!AVAILABLE_CATEGORIES[@]}"; do
                    CATEGORY_SELECTED[$cat]=true
                done
                info "All categories selected"
                ;;
            [nN])
                for cat in "${!AVAILABLE_CATEGORIES[@]}"; do
                    CATEGORY_SELECTED[$cat]=false
                done
                info "All categories deselected"
                ;;
            [cC])
                # Build selected categories list
                RESTORE_MODE="selective"
                SELECTED_CATEGORIES=()
                for cat in "${!CATEGORY_SELECTED[@]}"; do
                    [ "${CATEGORY_SELECTED[$cat]}" = "true" ] && SELECTED_CATEGORIES+=("$cat")
                done

                if [ ${#SELECTED_CATEGORIES[@]} -eq 0 ]; then
                    warning "No categories selected"
                    continue
                fi

                info "Confirmed ${#SELECTED_CATEGORIES[@]} categories"
                break
                ;;
            *)
                warning "Invalid command"
                ;;
        esac
    done
}

# Get file paths for a specific category
get_category_paths() {
    local category="$1"
    local extract_dir="$2"

    case "$category" in
        "pve_cluster")
            echo "$extract_dir/etc/pve"
            echo "$extract_dir/var/lib/pve-cluster"
            ;;
        "storage_pve")
            echo "$extract_dir/etc/pve/storage.cfg"
            echo "$extract_dir/etc/vzdump.conf"
            [ -d "$extract_dir/var/lib/pve-cluster/info/datastores" ] && echo "$extract_dir/var/lib/pve-cluster/info/datastores"
            ;;
        "pve_jobs")
            [ -d "$extract_dir/var/lib/pve-cluster/info/jobs" ] && echo "$extract_dir/var/lib/pve-cluster/info/jobs"
            [ -f "$extract_dir/etc/cron.d/vzdump" ] && echo "$extract_dir/etc/cron.d/vzdump"
            ;;
        "corosync")
            echo "$extract_dir/etc/corosync"
            ;;
        "ceph")
            echo "$extract_dir/etc/ceph"
            ;;
        "pbs_config")
            echo "$extract_dir/etc/proxmox-backup"
            echo "$extract_dir/var/lib/proxmox-backup"
            ;;
        "datastore_pbs")
            echo "$extract_dir/etc/proxmox-backup/datastore.cfg"
            [ -d "$extract_dir/var/lib/proxmox-backup/pxar_metadata" ] && echo "$extract_dir/var/lib/proxmox-backup/pxar_metadata"
            ;;
        "pbs_jobs")
            [ -f "$extract_dir/var/lib/proxmox-backup/sync_jobs.json" ] && echo "$extract_dir/var/lib/proxmox-backup/sync_jobs.json"
            [ -f "$extract_dir/var/lib/proxmox-backup/verify_jobs.json" ] && echo "$extract_dir/var/lib/proxmox-backup/verify_jobs.json"
            [ -f "$extract_dir/var/lib/proxmox-backup/prune_jobs.json" ] && echo "$extract_dir/var/lib/proxmox-backup/prune_jobs.json"
            ;;
        "network")
            echo "$extract_dir/etc/network"
            ;;
        "ssl")
            echo "$extract_dir/etc/ssl"
            ;;
        "ssh")
            [ -d "$extract_dir/etc/ssh" ] && echo "$extract_dir/etc/ssh"
            [ -d "$extract_dir/root/.ssh" ] && echo "$extract_dir/root/.ssh"
            [ -d "$extract_dir/home" ] && find "$extract_dir/home" -type d -name ".ssh" 2>/dev/null
            ;;
        "scripts")
            echo "$extract_dir/usr/local"
            ;;
        "crontabs")
            [ -f "$extract_dir/etc/crontab" ] && echo "$extract_dir/etc/crontab"
            [ -d "$extract_dir/var/spool/cron" ] && echo "$extract_dir/var/spool/cron"
            ;;
        "services")
            echo "$extract_dir/etc/systemd/system"
            echo "$extract_dir/etc/cron.d"
            ;;
        *)
            warning "Unknown category: $category"
            ;;
    esac
}

# Perform selective restore
restore_selective() {
    local extract_dir="$1"

    step "Selective restore of selected categories..."

    local backup_current_dir="/tmp/current_config_backup_${TIMESTAMP:-$SECONDS}_$$"
    mkdir -p "$backup_current_dir"

    info "Creating backup of current configurations in: $backup_current_dir"

    local restore_count=0

    for cat in "${SELECTED_CATEGORIES[@]}"; do
        local cat_name="${AVAILABLE_CATEGORIES[$cat]:-$cat}"
        info "Restoring category: $cat_name"

        # Get paths for this category
        local paths
        paths=$(get_category_paths "$cat" "$extract_dir")

        if [ -z "$paths" ]; then
            warning "No paths found for category: $cat_name"
            continue
        fi

        # Restore each path
        while IFS= read -r source_path; do
            [ -z "$source_path" ] && continue

            if [ ! -e "$source_path" ]; then
                debug "Path not found in backup: $source_path"
                continue
            fi

            # Calculate destination path
            local dest_path="${source_path#$extract_dir}"

            # Backup current file/dir if exists
            if [ -e "$dest_path" ]; then
                local parent_dir="$backup_current_dir$(dirname "$dest_path")"
                mkdir -p "$parent_dir"
                cp -a "$dest_path" "$parent_dir/" 2>/dev/null || true
            fi

            # Create parent directory
            local parent_dir=$(dirname "$dest_path")
            mkdir -p "$parent_dir"

            # Restore from backup using rsync (with automatic backup of overwritten files)
            if rsync -a --backup --backup-dir="$backup_current_dir" "$source_path" "$(dirname "$dest_path")/" 2>/dev/null; then
                debug "Restored: $dest_path"
                restore_count=$((restore_count + 1))
            else
                warning "Restore error: $dest_path"
            fi
        done <<< "$paths"

        success "Category '$cat_name' restored"
    done

    if [ $restore_count -gt 0 ]; then
        success "Selective restore completed: $restore_count items restored"
    else
        warning "No items restored"
    fi

    # Store backup location
    echo "$backup_current_dir" > /tmp/restore_backup_location.txt
    info "Backup of previous configurations saved in: $backup_current_dir"
}

# Recreate storage/datastore directory structures
recreate_storage_directories() {
    step "Recreating storage/datastore directories..."

    local created_count=0

    # Recreate PVE storage directories
    if [ -f "/etc/pve/storage.cfg" ]; then
        info "Processing PVE storage from /etc/pve/storage.cfg"

        local current_storage=""
        while IFS= read -r line; do
            # Detect storage definition
            if [[ "$line" =~ ^(dir|nfs|cifs|glusterfs|btrfs):[[:space:]]*([^[:space:]]+) ]]; then
                current_storage="${BASH_REMATCH[2]}"
                debug "Found storage: $current_storage"
            # Find path directive
            elif [[ "$line" =~ ^[[:space:]]*path[[:space:]]+(.+)$ ]]; then
                local storage_path="${BASH_REMATCH[1]}"

                if [ ! -d "$storage_path" ]; then
                    info "Creating PVE storage directory: $storage_path"
                    mkdir -p "$storage_path"

                    # Create standard PVE subdirectories
                    mkdir -p "$storage_path"/{dump,images,template,private,snippets} 2>/dev/null || true

                    # Set correct permissions
                    chown root:root "$storage_path"
                    chmod 755 "$storage_path"

                    created_count=$((created_count + 1))
                    success "Storage directory created: $storage_path"
                else
                    debug "Storage directory already exists: $storage_path"
                fi
            fi
        done < /etc/pve/storage.cfg
    fi

    # Recreate PBS datastore directories
    if [ -f "/etc/proxmox-backup/datastore.cfg" ]; then
        info "Processing PBS datastores from /etc/proxmox-backup/datastore.cfg"

        local current_datastore=""
        while IFS= read -r line; do
            # Detect datastore definition
            if [[ "$line" =~ ^datastore:[[:space:]]*([^[:space:]]+) ]]; then
                current_datastore="${BASH_REMATCH[1]}"
                debug "Found datastore: $current_datastore"
            # Find path directive
            elif [[ "$line" =~ ^[[:space:]]*path[[:space:]]+(.+)$ ]]; then
                local datastore_path="${BASH_REMATCH[1]}"

                if [ ! -d "$datastore_path" ]; then
                    info "Creating PBS datastore: $datastore_path"
                    mkdir -p "$datastore_path"

                    # Create PBS .chunks subdirectory
                    mkdir -p "$datastore_path/.chunks" 2>/dev/null || true

                    # Set correct PBS permissions
                    if command -v id >/dev/null 2>&1 && id -u backup >/dev/null 2>&1; then
                        chown backup:backup "$datastore_path"
                    else
                        chown root:root "$datastore_path"
                    fi
                    chmod 750 "$datastore_path"

                    created_count=$((created_count + 1))
                    success "PBS datastore created: $datastore_path ($current_datastore)"
                else
                    debug "Datastore already exists: $datastore_path"
                fi
            fi
        done < /etc/proxmox-backup/datastore.cfg
    fi

    if [ $created_count -gt 0 ]; then
        success "Created $created_count storage/datastore directories"
        info "Directories are ready to receive backup files"
    else
        info "No directories to create (already exist or not needed)"
    fi
}

# Prepare restore strategy (detect backup capabilities and gather user choices)
prepare_restore_strategy() {
    local extract_dir="$1"

    BACKUP_DETECTED_SELECTIVE="false"
    BACKUP_SUPPORTS_SELECTIVE="false"
    BACKUP_VERSION="Unknown"
    RESTORE_MODE="full"
    SELECTED_CATEGORIES=("all")

    if detect_backup_version "$extract_dir"; then
        BACKUP_DETECTED_SELECTIVE="true"
        BACKUP_SUPPORTS_SELECTIVE="true"
        [ -n "$BACKUP_VERSION" ] || BACKUP_VERSION="Unknown"

        # Validate system compatibility (PVE vs PBS)
        if ! validate_system_compatibility "$extract_dir"; then
            error "Cannot proceed with incompatible backup type"
            return 1
        fi

        analyze_backup_categories "$extract_dir"
        if ! show_category_menu "$extract_dir"; then
            return 1
        fi

        if [ "$RESTORE_MODE" != "full" ] && [ ${#SELECTED_CATEGORIES[@]} -eq 0 ]; then
            warning "No categories selected, full restore set as default"
            RESTORE_MODE="full"
            SELECTED_CATEGORIES=("all")
        fi
    else
        RESTORE_MODE="full"
        SELECTED_CATEGORIES=("all")
    fi

    return 0
}

# Execute restore according to previously prepared strategy
execute_restore_strategy() {
    local extract_dir="$1"

    if [ "$BACKUP_DETECTED_SELECTIVE" = "true" ]; then
        if [ "$RESTORE_MODE" = "full" ]; then
            info "Executing full restore..."
            restore_configurations "$extract_dir"
        else
            restore_selective "$extract_dir"
        fi

        recreate_storage_directories
    else
        info "Executing automatic full restore (legacy backup)..."
        restore_configurations "$extract_dir"
    fi
}

# Prepare restore context (download if needed, extract and gather strategy)
prepare_restore_context() {
    local backup_file="$SELECTED_BACKUP"

    SELECTED_TEMP_BACKUP_FILE=""
    SELECTED_EXTRACT_DIR=""
    RESTORE_MODE="full"
    SELECTED_CATEGORIES=("all")
    BACKUP_DETECTED_SELECTIVE="false"
    BACKUP_SUPPORTS_SELECTIVE="false"
    BACKUP_VERSION="Unknown"

    # Download from cloud if necessary
    if [ "$SELECTED_LOCATION" = "cloud" ]; then
        SELECTED_TEMP_BACKUP_FILE=$(download_cloud_backup "$backup_file")
        backup_file="$SELECTED_TEMP_BACKUP_FILE"
    fi

    # If type is not yet known, try to deduce it from filename
    if [ -z "${PROXMOX_TYPE:-}" ]; then
        local backup_name
        backup_name=$(basename "$backup_file")
        case "$backup_name" in
            pve-backup-*)
                PROXMOX_TYPE="pve"
                ;;
            pbs-backup-*)
                PROXMOX_TYPE="pbs"
                ;;
        esac
    fi

    # Extract backup for further analysis
    SELECTED_EXTRACT_DIR=$(extract_backup "$backup_file")

    # Prepare strategy (collect categories or set full restore)
    if ! prepare_restore_strategy "$SELECTED_EXTRACT_DIR"; then
        return 1
    fi

    return 0
}

# Cleanup temporary resources created during preparation without full log output
cleanup_temp_resources() {
    if [ -n "${SELECTED_EXTRACT_DIR:-}" ] && [ -d "$SELECTED_EXTRACT_DIR" ]; then
        rm -rf "$SELECTED_EXTRACT_DIR" 2>/dev/null || true
    fi
    if [ -n "${SELECTED_TEMP_BACKUP_FILE:-}" ] && [ -f "$SELECTED_TEMP_BACKUP_FILE" ]; then
        rm -f "$SELECTED_TEMP_BACKUP_FILE" 2>/dev/null || true
    fi
    SELECTED_EXTRACT_DIR=""
    SELECTED_TEMP_BACKUP_FILE=""
}

# Function to restore configurations
restore_configurations() {
    local extract_dir="$1"

    step "Restoring configurations..."

    # Define critical paths to restore
    local restore_paths=(
        "/etc/pve"
        "/etc/vzdump.conf"
        "/etc/corosync"
        "/etc/ceph"
        "/var/lib/pve-cluster"
        "/etc/network/interfaces"
        "/etc/hosts"
        "/etc/hostname"
        "/etc/proxmox-backup"
    )

    # Create backup of current configurations
    local backup_current_dir="/tmp/current_config_backup_$$"
    mkdir -p "$backup_current_dir"

    info "Creating backup of current configurations..."
    for path in "${restore_paths[@]}"; do
        if [ -e "$path" ]; then
            local parent_dir="$backup_current_dir$(dirname "$path")"
            mkdir -p "$parent_dir"
            cp -a "$path" "$parent_dir/" 2>/dev/null || true
        fi
    done

    # Restore configurations from backup
    info "Restoring configurations from backup..."
    local restore_count=0

    for path in "${restore_paths[@]}"; do
        local backup_path="$extract_dir$path"
        if [ -e "$backup_path" ]; then
            info "Restoring: $path"

            # Create parent directory if it doesn't exist
            local parent_dir=$(dirname "$path")
            mkdir -p "$parent_dir"

            # Remove existing and restore from backup
            rm -rf "$path" 2>/dev/null || true
            cp -a "$backup_path" "$path" 2>/dev/null || {
                warning "Unable to restore $path"
                continue
            }

            restore_count=$((restore_count + 1))
        else
            info "Not present in backup: $path"
        fi
    done

    if [ $restore_count -gt 0 ]; then
        success "Restored $restore_count configuration items"
    else
        warning "No configuration items restored"
    fi

    # Set proper permissions
    step "Setting permissions..."

    # Set PVE permissions
    if [ -d "/etc/pve" ]; then
        chown -R root:www-data /etc/pve 2>/dev/null || true
        chmod -R 640 /etc/pve 2>/dev/null || true
        chmod 755 /etc/pve 2>/dev/null || true
    fi

    # Set corosync permissions
    if [ -d "/etc/corosync" ]; then
        chown -R root:root /etc/corosync 2>/dev/null || true
        chmod -R 640 /etc/corosync 2>/dev/null || true
    fi

    # Set network permissions
    if [ -f "/etc/network/interfaces" ]; then
        chown root:root /etc/network/interfaces 2>/dev/null || true
        chmod 644 /etc/network/interfaces 2>/dev/null || true
    fi

    success "Permissions set correctly"

    # Store backup location for recovery if needed
    echo "Backup of current configurations saved in: $backup_current_dir" > /tmp/restore_backup_location.txt
    info "Backup of previous configurations saved in: $backup_current_dir"
}

# Function to restart services
restart_services() {
    step "Restarting Proxmox services..."

    local services=(
        "pve-cluster"
        "pvedaemon"
        "pve-firewall"
        "pveproxy"
        "pvestatd"
        "corosync"
        "networking"
    )

    local optional_services=(
        "proxmox-backup"
        "proxmox-backup-proxy"
        "ceph-mon"
        "ceph-mgr"
        "ceph-osd"
    )

    # Stop services in reverse order
    info "Stopping services..."
    for ((i=${#services[@]}-1; i>=0; i--)); do
        local service="${services[i]}"
        if systemctl is-active "$service" >/dev/null 2>&1; then
            info "Stopping $service..."
            systemctl stop "$service" 2>/dev/null || warning "Unable to stop $service"
        fi
    done

    # Stop optional services
    for service in "${optional_services[@]}"; do
        if systemctl is-active "$service" >/dev/null 2>&1; then
            info "Stopping $service..."
            systemctl stop "$service" 2>/dev/null || true
        fi
    done

    # Wait a moment
    sleep 3

    # Start services
    info "Starting services..."
    for service in "${services[@]}"; do
        if systemctl is-enabled "$service" >/dev/null 2>&1; then
            info "Starting $service..."
            systemctl start "$service" 2>/dev/null || warning "Unable to start $service"
            sleep 2
        fi
    done

    # Start optional services
    for service in "${optional_services[@]}"; do
        if systemctl is-enabled "$service" >/dev/null 2>&1; then
            info "Starting $service..."
            systemctl start "$service" 2>/dev/null || true
            sleep 1
        fi
    done

    # Final service status check
    step "Checking service status..."
    local failed_services=()

    for service in "${services[@]}"; do
        if systemctl is-enabled "$service" >/dev/null 2>&1; then
            if systemctl is-active "$service" >/dev/null 2>&1; then
                success "$service: ACTIVE"
            else
                error "$service: NOT ACTIVE"
                failed_services+=("$service")
            fi
        fi
    done

    if [ ${#failed_services[@]} -eq 0 ]; then
        success "All services restarted successfully"
    else
        warning "Some services failed to restart: ${failed_services[*]}"
        info "A system reboot may be required"
    fi
}

# Function to cleanup temporary files
cleanup() {
    step "Cleaning up temporary files..."

    # Remove temporary extraction directories
    for temp_dir in /tmp/proxmox_restore_* /tmp/*-backup-*.tar*; do
        if [ -e "$temp_dir" ]; then
            rm -rf "$temp_dir" 2>/dev/null || true
        fi
    done

    success "Cleanup completed"
}

# Function to show summary
show_summary() {
    echo ""
    echo -e "${CYAN}=== RESTORE SUMMARY ===${NC}"
    echo ""
    echo -e "Source location: ${GREEN}$SELECTED_LOCATION${NC}"
    echo -e "Restored file: ${GREEN}$(basename "$SELECTED_BACKUP")${NC}"
    echo -e "Restore date: ${GREEN}$(date '+%Y-%m-%d %H:%M:%S')${NC}"
    echo ""

    if [ -f "/tmp/restore_backup_location.txt" ]; then
        local backup_location=$(cat /tmp/restore_backup_location.txt)
        echo -e "${YELLOW}IMPORTANT:${NC} Backup of previous configurations available at:"
        echo -e "${BLUE}$backup_location${NC}"
        echo ""
    fi

    success "Restore completed successfully!"
    echo ""
    info "It is recommended to verify that all services are working correctly"
    info "In case of problems, it is possible to restore previous configurations"
}

# ==========================================
# MAIN FUNCTION
# ==========================================

main() {
    # Check if running as root
    if [ "$EUID" -ne 0 ]; then
        error "This script must be run as root"
        exit $EXIT_ERROR
    fi

    # Welcome message
    echo ""
    echo -e "${CYAN}================================${NC}"
    echo -e "${CYAN}  PROXMOX CONFIGURATION RESTORE${NC}"
    echo -e "${CYAN}================================${NC}"
    echo ""

    # Check if backup.env exists and is readable
    if [ ! -f "$ENV_FILE" ] || [ ! -r "$ENV_FILE" ]; then
        error "Configuration file not found or not readable: $ENV_FILE"
        exit $EXIT_ERROR
    fi

    # Main restoration loop
    while true; do
        # Show storage selection menu
        show_storage_menu

        # Show backup files menu
        if show_backup_menu; then
            if ! prepare_restore_context; then
                cleanup_temp_resources
                continue
            fi

            if ! confirm_restore; then
                cleanup_temp_resources
                exit $EXIT_SUCCESS
            fi

            # Set trap for cleanup only after confirmation
            trap cleanup EXIT

            # Perform restoration
            execute_restore_strategy "$SELECTED_EXTRACT_DIR"

            # Restart services
            restart_services

            # Show summary
            show_summary
            break
        fi
        # If show_backup_menu returns 1, go back to storage menu
    done
    # Cleanup will be handled by trap when appropriate
}

# ==========================================
# SCRIPT STARTUP
# ==========================================

main "$@"

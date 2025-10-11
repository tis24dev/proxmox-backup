#!/bin/bash
##
# Proxmox Restore Script for PVE and PBS
# File: proxmox-restore.sh
# Version: 0.2.1
# Last Modified: 2025-10-11
# Changes: Script di restore per configurazioni Proxmox
#
# This script performs restoration of Proxmox configurations from backup files
# created by the Proxmox Backup System
##

# ======= Base variables BEFORE set -u =======
# Risolve il symlink per ottenere il percorso reale dello script
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
    echo "Proxmox Restore Script Version: ${SCRIPT_VERSION:-1.0.0}"
else
    echo "[ERRORE] File di configurazione non trovato: $ENV_FILE"
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
    echo -e "${GREEN}[SUCCESSO]${NC} $1"
}

warning() {
    echo -e "${YELLOW}[AVVISO]${NC} $1"
}

error() {
    echo -e "${RED}[ERRORE]${NC} $1"
}

step() {
    echo -e "${PURPLE}[STEP]${NC} $1"
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

# Function to display storage selection menu
show_storage_menu() {
    echo ""
    echo -e "${CYAN}=== SELEZIONE UBICAZIONE BACKUP ===${NC}"
    echo ""
    
    local options=()
    local paths=()
    local count=0
    
    # Check local storage
    if is_storage_enabled "local"; then
        count=$((count + 1))
        options+=("$count")
        paths+=("local")
        echo -e "${GREEN}$count)${NC} Storage Locale: ${LOCAL_BACKUP_PATH}"
    fi
    
    # Check secondary storage
    if is_storage_enabled "secondary"; then
        count=$((count + 1))
        options+=("$count")
        paths+=("secondary")
        echo -e "${GREEN}$count)${NC} Storage Secondario: ${SECONDARY_BACKUP_PATH}"
    fi
    
    # Check cloud storage
    if is_storage_enabled "cloud"; then
        count=$((count + 1))
        options+=("$count")
        paths+=("cloud")
        echo -e "${GREEN}$count)${NC} Storage Cloud: ${RCLONE_REMOTE}:${CLOUD_BACKUP_PATH}"
    fi
    
    if [ $count -eq 0 ]; then
        error "Nessun storage abilitato nel file di configurazione"
        exit $EXIT_ERROR
    fi
    
    echo ""
    echo -e "${YELLOW}0)${NC} Esci"
    echo ""
    
    while true; do
        read -p "Seleziona l'ubicazione da cui ripristinare [0-$count]: " choice
        
        if [ "$choice" = "0" ]; then
            info "Operazione annullata dall'utente"
            exit $EXIT_SUCCESS
        elif [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le $count ]; then
            SELECTED_LOCATION="${paths[$((choice-1))]}"
            break
        else
            warning "Selezione non valida. Inserisci un numero tra 0 e $count"
        fi
    done
}

# Function to display backup files menu
show_backup_menu() {
    local storage_type="$SELECTED_LOCATION"
    local storage_path=$(get_storage_path "$storage_type")
    
    echo ""
    echo -e "${CYAN}=== SELEZIONE FILE BACKUP ===${NC}"
    echo ""
    info "Ricerca backup in: $storage_path"
    echo ""
    
    # Get list of backup files
    local backup_files=()
    while IFS= read -r line; do
        [ -n "$line" ] && backup_files+=("$line")
    done < <(list_backup_files "$storage_type" "$storage_path")
    
    if [ ${#backup_files[@]} -eq 0 ]; then
        error "Nessun file backup trovato in $storage_path"
        exit $EXIT_ERROR
    fi
    
    # Display backup files
    local count=0
    for backup_file in "${backup_files[@]}"; do
        count=$((count + 1))
        local file_name=$(basename "$backup_file")
        local file_size=""
        
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
        
        echo -e "${GREEN}$count)${NC} $file_name ${BLUE}($file_size)${NC}"
    done
    
    echo ""
    echo -e "${YELLOW}0)${NC} Torna al menu precedente"
    echo ""
    
    while true; do
        read -p "Seleziona il file backup da ripristinare [0-$count]: " choice
        
        if [ "$choice" = "0" ]; then
            return 1  # Go back to storage menu
        elif [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le $count ]; then
            SELECTED_BACKUP="${backup_files[$((choice-1))]}"
            break
        else
            warning "Selezione non valida. Inserisci un numero tra 0 e $count"
        fi
    done
    
    return 0
}

# Function to confirm restore operation
confirm_restore() {
    echo ""
    echo -e "${CYAN}=== CONFERMA RIPRISTINO ===${NC}"
    echo ""
    echo -e "Ubicazione: ${GREEN}$SELECTED_LOCATION${NC}"
    echo -e "File backup: ${GREEN}$(basename "$SELECTED_BACKUP")${NC}"
    echo ""
    echo -e "${RED}ATTENZIONE: Questa operazione sovrascriverà le configurazioni attuali!${NC}"
    echo ""
    
    while true; do
        read -p "Sei sicuro di voler procedere con il ripristino? [s/N]: " confirm
        case "$confirm" in
            [sS]|[sS][ìi])
                return 0
                ;;
            [nN]|[nN][oO]|"")
                info "Operazione annullata dall'utente"
                exit $EXIT_SUCCESS
                ;;
            *)
                warning "Risposta non valida. Inserisci 's' per sì o 'n' per no"
                ;;
        esac
    done
}

# Function to download backup file from cloud
download_cloud_backup() {
    local remote_file="$1"
    local local_temp_file="/tmp/$(basename "$remote_file")"
    
    step "Download del backup dal cloud storage..."
    
    if ! command -v rclone >/dev/null 2>&1; then
        error "rclone non trovato. È necessario per accedere al cloud storage"
        exit $EXIT_ERROR
    fi
    
    if rclone copy "${RCLONE_REMOTE}:${CLOUD_BACKUP_PATH}/$(basename "$remote_file")" "/tmp/" ${RCLONE_FLAGS:-}; then
        echo "$local_temp_file"
        return 0
    else
        error "Errore nel download del backup dal cloud"
        exit $EXIT_ERROR
    fi
}

# Function to extract backup
extract_backup() {
    local backup_file="$1"
    local extract_dir="/tmp/proxmox_restore_$$"
    
    step "Estrazione del backup..."
    
    # Create extraction directory
    mkdir -p "$extract_dir"
    
    # Determine compression type and extract
    if [[ "$backup_file" == *.tar.zst ]]; then
        if command -v zstd >/dev/null 2>&1; then
            zstd -dc "$backup_file" | tar -xf - -C "$extract_dir"
        else
            error "zstd non trovato per estrarre il backup compresso con zstd"
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
        error "Formato di compressione non riconosciuto: $backup_file"
        exit $EXIT_ERROR
    fi
    
    echo "$extract_dir"
}

# Function to restore configurations
restore_configurations() {
    local extract_dir="$1"
    
    step "Ripristino delle configurazioni..."
    
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
    
    info "Creazione backup delle configurazioni attuali..."
    for path in "${restore_paths[@]}"; do
        if [ -e "$path" ]; then
            local parent_dir="$backup_current_dir$(dirname "$path")"
            mkdir -p "$parent_dir"
            cp -a "$path" "$parent_dir/" 2>/dev/null || true
        fi
    done
    
    # Restore configurations from backup
    info "Ripristino delle configurazioni dal backup..."
    local restore_count=0
    
    for path in "${restore_paths[@]}"; do
        local backup_path="$extract_dir$path"
        if [ -e "$backup_path" ]; then
            info "Ripristino: $path"
            
            # Create parent directory if it doesn't exist
            local parent_dir=$(dirname "$path")
            mkdir -p "$parent_dir"
            
            # Remove existing and restore from backup
            rm -rf "$path" 2>/dev/null || true
            cp -a "$backup_path" "$path" 2>/dev/null || {
                warning "Impossibile ripristinare $path"
                continue
            }
            
            restore_count=$((restore_count + 1))
        else
            info "Non presente nel backup: $path"
        fi
    done
    
    if [ $restore_count -gt 0 ]; then
        success "Ripristinati $restore_count elementi di configurazione"
    else
        warning "Nessun elemento di configurazione ripristinato"
    fi
    
    # Set proper permissions
    step "Impostazione permessi..."
    
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
    
    success "Permessi impostati correttamente"
    
    # Store backup location for recovery if needed
    echo "Backup configurazioni correnti salvato in: $backup_current_dir" > /tmp/restore_backup_location.txt
    info "Backup delle configurazioni precedenti salvato in: $backup_current_dir"
}

# Function to restart services
restart_services() {
    step "Riavvio dei servizi Proxmox..."
    
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
    info "Arresto servizi..."
    for ((i=${#services[@]}-1; i>=0; i--)); do
        local service="${services[i]}"
        if systemctl is-active "$service" >/dev/null 2>&1; then
            info "Arresto $service..."
            systemctl stop "$service" 2>/dev/null || warning "Impossibile arrestare $service"
        fi
    done
    
    # Stop optional services
    for service in "${optional_services[@]}"; do
        if systemctl is-active "$service" >/dev/null 2>&1; then
            info "Arresto $service..."
            systemctl stop "$service" 2>/dev/null || true
        fi
    done
    
    # Wait a moment
    sleep 3
    
    # Start services
    info "Avvio servizi..."
    for service in "${services[@]}"; do
        if systemctl is-enabled "$service" >/dev/null 2>&1; then
            info "Avvio $service..."
            systemctl start "$service" 2>/dev/null || warning "Impossibile avviare $service"
            sleep 2
        fi
    done
    
    # Start optional services
    for service in "${optional_services[@]}"; do
        if systemctl is-enabled "$service" >/dev/null 2>&1; then
            info "Avvio $service..."
            systemctl start "$service" 2>/dev/null || true
            sleep 1
        fi
    done
    
    # Final service status check
    step "Verifica stato servizi..."
    local failed_services=()
    
    for service in "${services[@]}"; do
        if systemctl is-enabled "$service" >/dev/null 2>&1; then
            if systemctl is-active "$service" >/dev/null 2>&1; then
                success "$service: ATTIVO"
            else
                error "$service: NON ATTIVO"
                failed_services+=("$service")
            fi
        fi
    done
    
    if [ ${#failed_services[@]} -eq 0 ]; then
        success "Tutti i servizi riavviati correttamente"
    else
        warning "Alcuni servizi non sono riusciti a riavviarsi: ${failed_services[*]}"
        info "Potrebbe essere necessario un riavvio del sistema"
    fi
}

# Function to cleanup temporary files
cleanup() {
    step "Pulizia file temporanei..."
    
    # Remove temporary extraction directories
    for temp_dir in /tmp/proxmox_restore_* /tmp/*-backup-*.tar*; do
        if [ -e "$temp_dir" ]; then
            rm -rf "$temp_dir" 2>/dev/null || true
        fi
    done
    
    success "Pulizia completata"
}

# Function to show summary
show_summary() {
    echo ""
    echo -e "${CYAN}=== RIEPILOGO RIPRISTINO ===${NC}"
    echo ""
    echo -e "Ubicazione sorgente: ${GREEN}$SELECTED_LOCATION${NC}"
    echo -e "File ripristinato: ${GREEN}$(basename "$SELECTED_BACKUP")${NC}"
    echo -e "Data ripristino: ${GREEN}$(date '+%Y-%m-%d %H:%M:%S')${NC}"
    echo ""
    
    if [ -f "/tmp/restore_backup_location.txt" ]; then
        local backup_location=$(cat /tmp/restore_backup_location.txt)
        echo -e "${YELLOW}IMPORTANTE:${NC} Backup delle configurazioni precedenti disponibile in:"
        echo -e "${BLUE}$backup_location${NC}"
        echo ""
    fi
    
    success "Ripristino completato con successo!"
    echo ""
    info "È consigliabile verificare che tutti i servizi funzionino correttamente"
    info "In caso di problemi, è possibile ripristinare le configurazioni precedenti"
}

# ==========================================
# MAIN FUNCTION
# ==========================================

main() {
    # Check if running as root
    if [ "$EUID" -ne 0 ]; then
        error "Questo script deve essere eseguito come root"
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
        error "File di configurazione non trovato o non leggibile: $ENV_FILE"
        exit $EXIT_ERROR
    fi
    
    # Main restoration loop
    while true; do
        # Show storage selection menu
        show_storage_menu
        
        # Show backup files menu
        if show_backup_menu; then
            # Confirm restore operation
            confirm_restore
            break
        fi
        # If show_backup_menu returns 1, go back to storage menu
    done
    
    # Set trap for cleanup
    trap cleanup EXIT
    
    # Perform restoration
    local backup_file="$SELECTED_BACKUP"
    local temp_backup_file=""
    
    # Download from cloud if necessary
    if [ "$SELECTED_LOCATION" = "cloud" ]; then
        temp_backup_file=$(download_cloud_backup "$backup_file")
        backup_file="$temp_backup_file"
    fi
    
    # Extract backup
    local extract_dir=$(extract_backup "$backup_file")
    
    # Restore configurations
    restore_configurations "$extract_dir"
    
    # Restart services
    restart_services
    
    # Show summary
    show_summary
    
    # Cleanup will be called by trap
}

# ==========================================
# SCRIPT STARTUP
# ==========================================

main "$@" 
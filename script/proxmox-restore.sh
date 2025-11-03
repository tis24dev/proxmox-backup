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
    echo "Proxmox Restore Script Version: ${SCRIPT_VERSION:-1.0.1}"
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

        if [ "$BACKUP_SUPPORTS_SELECTIVE" = "true" ]; then
            info "Backup moderno rilevato (v$BACKUP_VERSION) - selezione interattiva disponibile"
            return 0  # Supports selective restore
        fi
    fi

    info "Backup legacy rilevato - utilizzo ripristino completo automatico"
    return 1  # Does not support selective restore
}

# Analyze backup content and detect available categories
analyze_backup_categories() {
    local extract_dir="$1"

    declare -gA AVAILABLE_CATEGORIES

    # Detect PVE categories
    [ -d "$extract_dir/etc/pve" ] && AVAILABLE_CATEGORIES["pve_cluster"]="Cluster PVE"
    [ -f "$extract_dir/etc/pve/storage.cfg" ] && AVAILABLE_CATEGORIES["storage_pve"]="Storage PVE"
    [ -f "$extract_dir/etc/vzdump.conf" ] && [ -d "$extract_dir/var/lib/pve-cluster/info/jobs" ] && AVAILABLE_CATEGORIES["pve_jobs"]="Job Backup PVE"
    [ -d "$extract_dir/etc/corosync" ] && AVAILABLE_CATEGORIES["corosync"]="Corosync (Cluster)"
    [ -d "$extract_dir/etc/ceph" ] && AVAILABLE_CATEGORIES["ceph"]="Ceph Storage"

    # Detect PBS categories
    [ -d "$extract_dir/etc/proxmox-backup" ] && AVAILABLE_CATEGORIES["pbs_config"]="Config PBS"
    [ -f "$extract_dir/etc/proxmox-backup/datastore.cfg" ] && AVAILABLE_CATEGORIES["datastore_pbs"]="Datastore PBS"
    [ -d "$extract_dir/var/lib/proxmox-backup/pxar_metadata" ] && AVAILABLE_CATEGORIES["pbs_jobs"]="Job PBS"

    # Detect common categories
    [ -d "$extract_dir/etc/network" ] && AVAILABLE_CATEGORIES["network"]="Configurazione Rete"
    [ -d "$extract_dir/etc/ssl" ] && AVAILABLE_CATEGORIES["ssl"]="Certificati SSL"
    [ -d "$extract_dir/etc/ssh" ] || [ -d "$extract_dir/root/.ssh" ] && AVAILABLE_CATEGORIES["ssh"]="Chiavi SSH"
    [ -d "$extract_dir/usr/local" ] && AVAILABLE_CATEGORIES["scripts"]="Script Utente"
    [ -d "$extract_dir/var/spool/cron" ] && AVAILABLE_CATEGORIES["crontabs"]="Crontabs"
    [ -d "$extract_dir/etc/systemd/system" ] && AVAILABLE_CATEGORIES["services"]="Servizi Systemd"

    local count=${#AVAILABLE_CATEGORIES[@]}
    info "Rilevate $count categorie disponibili nel backup"
}

# Show category selection menu
show_category_menu() {
    local extract_dir="$1"

    echo ""
    echo -e "${CYAN}=== SELEZIONE RIPRISTINO ===${NC}"
    echo ""
    echo "Backup rilevato: v${BACKUP_VERSION} (${PROXMOX_TYPE:-Unknown})"
    echo "Categorie disponibili: ${#AVAILABLE_CATEGORIES[@]}"
    echo ""
    echo -e "${GREEN}1)${NC} Ripristino COMPLETO (tutto)"
    echo -e "${GREEN}2)${NC} Solo STORAGE (struttura completa + config)"
    echo -e "${GREEN}3)${NC} Solo SISTEMA BASE (rete, SSL, SSH)"
    echo -e "${GREEN}4)${NC} Selezione PERSONALIZZATA"
    echo -e "${YELLOW}0)${NC} Annulla"
    echo ""

    while true; do
        read -p "Selezione [1]: " choice
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
                # Add storage-related categories
                for cat in "pve_cluster" "storage_pve" "pve_jobs" "datastore_pbs" "pbs_jobs"; do
                    [ -n "${AVAILABLE_CATEGORIES[$cat]}" ] && SELECTED_CATEGORIES+=("$cat")
                done
                if [ ${#SELECTED_CATEGORIES[@]} -eq 0 ]; then
                    warning "Nessuna categoria storage trovata nel backup"
                    continue
                fi
                info "Categorie selezionate: ${SELECTED_CATEGORIES[*]}"
                break
                ;;
            3)
                RESTORE_MODE="selective"
                SELECTED_CATEGORIES=()
                # Add system base categories
                for cat in "network" "ssl" "ssh" "services"; do
                    [ -n "${AVAILABLE_CATEGORIES[$cat]}" ] && SELECTED_CATEGORIES+=("$cat")
                done
                if [ ${#SELECTED_CATEGORIES[@]} -eq 0 ]; then
                    warning "Nessuna categoria sistema base trovata nel backup"
                    continue
                fi
                info "Categorie selezionate: ${SELECTED_CATEGORIES[*]}"
                break
                ;;
            4)
                show_custom_selection_menu
                break
                ;;
            0)
                info "Operazione annullata dall'utente"
                exit $EXIT_SUCCESS
                ;;
            *)
                warning "Selezione non valida. Inserisci un numero tra 0 e 4"
                ;;
        esac
    done
}

# Show custom category selection menu
show_custom_selection_menu() {
    echo ""
    echo -e "${CYAN}=== SELEZIONE PERSONALIZZATA ===${NC}"
    echo ""
    echo "Seleziona le categorie da ripristinare (spazio per toggle, INVIO per confermare):"
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
    echo "Comandi: [numero]=toggle, [a]=tutto, [n]=niente, [c]=continua"
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
                info "Tutte le categorie selezionate"
                ;;
            [nN])
                for cat in "${!AVAILABLE_CATEGORIES[@]}"; do
                    CATEGORY_SELECTED[$cat]=false
                done
                info "Tutte le categorie deselezionate"
                ;;
            [cC])
                # Build selected categories list
                RESTORE_MODE="selective"
                SELECTED_CATEGORIES=()
                for cat in "${!CATEGORY_SELECTED[@]}"; do
                    [ "${CATEGORY_SELECTED[$cat]}" = "true" ] && SELECTED_CATEGORIES+=("$cat")
                done

                if [ ${#SELECTED_CATEGORIES[@]} -eq 0 ]; then
                    warning "Nessuna categoria selezionata"
                    continue
                fi

                info "Confermate ${#SELECTED_CATEGORIES[@]} categorie"
                break
                ;;
            *)
                warning "Comando non valido"
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
            warning "Categoria sconosciuta: $category"
            ;;
    esac
}

# Perform selective restore
restore_selective() {
    local extract_dir="$1"

    step "Ripristino selettivo delle categorie scelte..."

    local backup_current_dir="/tmp/current_config_backup_${TIMESTAMP:-$SECONDS}_$$"
    mkdir -p "$backup_current_dir"

    info "Creazione backup delle configurazioni attuali in: $backup_current_dir"

    local restore_count=0

    for cat in "${SELECTED_CATEGORIES[@]}"; do
        local cat_name="${AVAILABLE_CATEGORIES[$cat]}"
        info "Ripristino categoria: $cat_name"

        # Get paths for this category
        local paths
        paths=$(get_category_paths "$cat" "$extract_dir")

        if [ -z "$paths" ]; then
            warning "Nessun path trovato per categoria: $cat_name"
            continue
        fi

        # Restore each path
        while IFS= read -r source_path; do
            [ -z "$source_path" ] && continue

            if [ ! -e "$source_path" ]; then
                debug "Path non trovato nel backup: $source_path"
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
                debug "Ripristinato: $dest_path"
                restore_count=$((restore_count + 1))
            else
                warning "Errore ripristino: $dest_path"
            fi
        done <<< "$paths"

        success "Categoria '$cat_name' ripristinata"
    done

    if [ $restore_count -gt 0 ]; then
        success "Ripristino selettivo completato: $restore_count elementi ripristinati"
    else
        warning "Nessun elemento ripristinato"
    fi

    # Store backup location
    echo "$backup_current_dir" > /tmp/restore_backup_location.txt
    info "Backup configurazioni precedenti salvato in: $backup_current_dir"
}

# Recreate storage/datastore directory structures
recreate_storage_directories() {
    step "Ricreazione directory storage/datastore..."

    local created_count=0

    # Recreate PVE storage directories
    if [ -f "/etc/pve/storage.cfg" ]; then
        info "Elaborazione storage PVE da /etc/pve/storage.cfg"

        local current_storage=""
        while IFS= read -r line; do
            # Detect storage definition
            if [[ "$line" =~ ^(dir|nfs|cifs|glusterfs|btrfs):[[:space:]]*([^[:space:]]+) ]]; then
                current_storage="${BASH_REMATCH[2]}"
                debug "Trovato storage: $current_storage"
            # Find path directive
            elif [[ "$line" =~ ^[[:space:]]*path[[:space:]]+(.+)$ ]]; then
                local storage_path="${BASH_REMATCH[1]}"

                if [ ! -d "$storage_path" ]; then
                    info "Creazione directory storage PVE: $storage_path"
                    mkdir -p "$storage_path"

                    # Create standard PVE subdirectories
                    mkdir -p "$storage_path"/{dump,images,template,private,snippets} 2>/dev/null || true

                    # Set correct permissions
                    chown root:root "$storage_path"
                    chmod 755 "$storage_path"

                    created_count=$((created_count + 1))
                    success "Directory storage creata: $storage_path"
                else
                    debug "Directory storage già esistente: $storage_path"
                fi
            fi
        done < /etc/pve/storage.cfg
    fi

    # Recreate PBS datastore directories
    if [ -f "/etc/proxmox-backup/datastore.cfg" ]; then
        info "Elaborazione datastore PBS da /etc/proxmox-backup/datastore.cfg"

        local current_datastore=""
        while IFS= read -r line; do
            # Detect datastore definition
            if [[ "$line" =~ ^datastore:[[:space:]]*([^[:space:]]+) ]]; then
                current_datastore="${BASH_REMATCH[1]}"
                debug "Trovato datastore: $current_datastore"
            # Find path directive
            elif [[ "$line" =~ ^[[:space:]]*path[[:space:]]+(.+)$ ]]; then
                local datastore_path="${BASH_REMATCH[1]}"

                if [ ! -d "$datastore_path" ]; then
                    info "Creazione datastore PBS: $datastore_path"
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
                    success "Datastore PBS creato: $datastore_path ($current_datastore)"
                else
                    debug "Datastore già esistente: $datastore_path"
                fi
            fi
        done < /etc/proxmox-backup/datastore.cfg
    fi

    if [ $created_count -gt 0 ]; then
        success "Create $created_count directory storage/datastore"
        info "Le directory sono pronte per ricevere i file di backup"
    else
        info "Nessuna directory da creare (già esistenti o non necessarie)"
    fi
}

# Smart restore wrapper - detects backup type and acts accordingly
restore_smart() {
    local extract_dir="$1"

    # Detect backup version and capabilities
    if detect_backup_version "$extract_dir"; then
        # Modern backup with selective restore support
        analyze_backup_categories "$extract_dir"
        show_category_menu "$extract_dir"

        if [ "$RESTORE_MODE" = "full" ]; then
            # User chose full restore
            info "Esecuzione ripristino completo..."
            restore_configurations "$extract_dir"
        else
            # User chose selective restore
            restore_selective "$extract_dir"
        fi

        # Recreate storage/datastore directories if needed
        recreate_storage_directories
    else
        # Legacy backup - perform full restore automatically
        info "Esecuzione ripristino completo automatico (backup legacy)..."
        restore_configurations "$extract_dir"
    fi
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

    # Restore configurations (smart detection: selective or full based on backup version)
    restore_smart "$extract_dir"

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
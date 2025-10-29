#!/bin/bash
##
# Proxmox Backup System - Fix Permissions Script
# File: fix-permissions.sh
# Version: 0.3.1
# Last Modified: 2025-10-28
# Changes: Add new file check
##
# Script per applicare i permessi corretti a tutti i file del sistema di backup
# Questo script deve essere eseguito come root
##

set -e

# Script version (autonomo)
FIX_PERMISSIONS_VERSION="0.2.0"

# Directory di base
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(dirname "$SCRIPT_DIR")"

# Mostra versione
echo "Fix Permissions Script Version: $FIX_PERMISSIONS_VERSION"

# Colori per output
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

# Funzioni di logging
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

# Verifica se lo script è eseguito come root
check_root() {
    if [ "$(id -u)" != "0" ]; then
        log_error "Questo script deve essere eseguito come root"
        exit 1
    fi
}

# Carica il file di configurazione
load_config() {
    if [ -f "$BASE_DIR/env/backup.env" ]; then
        source "$BASE_DIR/env/backup.env"
    else
        log_error "File di configurazione non trovato: $BASE_DIR/env/backup.env"
        exit 1
    fi
}

# Applica i permessi agli script eseguibili
fix_script_permissions() {
    log_step "Applico i permessi agli script eseguibili"
    
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
                log_info "Imposto permessi 744 su $script"
            else
                log_info "Imposto permessi 700 su $script"
            fi
            if [[ "$script" == "$BASE_DIR/install.sh" || "$script" == "$BASE_DIR/new-install.sh" ]]; then
                chmod 744 "$script"
            else
                chmod 700 "$script"
            fi
            chown root:root "$script"
            
            # Aggiorna anche il file hash se esiste
            local hash_file="${script}.md5"
            if [ -f "$hash_file" ]; then
                log_info "Imposto permessi 600 su $hash_file"
                chmod 600 "$hash_file"
                chown root:root "$hash_file"
            fi
        else
            log_warning "Script non trovato: $script"
        fi
    done
}

# Applica i permessi ai file di configurazione
fix_config_permissions() {
    log_step "Applico i permessi ai file di configurazione"
    
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
            log_info "Imposto permessi 400 su $config"
            chmod 400 "$config"
            chown root:root "$config"
            
            # Aggiorna anche il file hash se esiste
            local hash_file="${config}.md5"
            if [ -f "$hash_file" ]; then
                log_info "Imposto permessi 600 su $hash_file"
                chmod 600 "$hash_file"
                chown root:root "$hash_file"
            fi
        else
            log_warning "File di configurazione non trovato: $config"
        fi
    done
}

# Applica i permessi alle directory di base
fix_base_directories() {
    log_step "Applico i permessi alle directory di base"
    
    local base_dirs=(
        "$BASE_DIR/backup"
        "$BASE_DIR/env"
        "$BASE_DIR/log"
        "$BASE_DIR/script"
        "$BASE_DIR/secure_account"
    )
    
    for dir in "${base_dirs[@]}"; do
        if [ -d "$dir" ]; then
            log_info "Imposto permessi 750 su $dir"
            chmod 750 "$dir"
            chown root:root "$dir"
        else
            log_warning "Directory non trovata: $dir"
        fi
    done
}

# Applica i permessi alle directory di backup e log
fix_backup_directories() {
    log_step "Applico i permessi alle directory di backup e log"
    
    # Verifica se l'utente e il gruppo di backup esistono
    if ! id -u "${BACKUP_USER}" &>/dev/null; then
        log_warning "Utente di backup ${BACKUP_USER} non trovato"
        return 1
    fi
    
    if ! getent group "${BACKUP_GROUP}" &>/dev/null; then
        log_warning "Gruppo di backup ${BACKUP_GROUP} non trovato"
        return 1
    fi
    
    # Directory da gestire
    local backup_dirs=(
        "$LOCAL_BACKUP_PATH"
        "$LOCAL_LOG_PATH"
        "$SECONDARY_BACKUP_PATH"
        "$SECONDARY_LOG_PATH"
    )
    
    for dir in "${backup_dirs[@]}"; do
        if [ -d "$dir" ]; then
            log_info "Imposto permessi su $dir"
            chown -R "${BACKUP_USER}:${BACKUP_GROUP}" "$dir"
            chmod -R u=rwX,g=rX,o= "$dir"
        else
            log_warning "Directory non trovata: $dir"
        fi
    done
}

# Funzione principale
main() {
    log_step "Inizio applicazione permessi"
    
    # Verifica root
    check_root
    
    # Carica configurazione
    load_config
    
    # Applica i permessi in ordine
    fix_script_permissions
    fix_config_permissions
    fix_base_directories
    fix_backup_directories
    
    log_success "Applicazione permessi completata"
}

# Esegui solo se lo script è chiamato direttamente
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi 
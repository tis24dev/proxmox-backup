#!/bin/bash
# ============================================================================
# PROXMOX BACKUP SYSTEM - RESTORE SCRIPT
# ============================================================================
# Script di ripristino per Proxmox Backup System
# Questo script gestisce il ripristino completo delle configurazioni
# da backup locali, secondari o cloud configurati
#
# Utilizzo: ./proxmox-restore.sh
# Utilizzo diretto: proxmox-restore
#
# Versione: 0.1.0
# ============================================================================

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
export TZ="Europe/Rome"

# ======= Standard exit codes =======
readonly EXIT_SUCCESS=0
readonly EXIT_WARNING=1
readonly EXIT_ERROR=2

# ==========================================
# CONFIGURATION LOADING
# ==========================================

# ======= Loading .env before enabling set -u =======
if [[ -f "$ENV_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$ENV_FILE"
    echo "Proxmox Restore Script Version: ${SCRIPT_VERSION:-0.1.0}"
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

TEMP_DIR=""
SELECTED_LOCATION=""
SELECTED_BACKUP=""
RESTORE_PATH="/tmp/proxmox_restore_$$"

# ==========================================
# UTILITY FUNCTIONS
# ==========================================

# Function to print colored output
print_info() {
    echo -e "${BLUE:-}[INFO]${RESET:-} $1"
}

print_success() {
    echo -e "${GREEN:-}[SUCCESSO]${RESET:-} $1"
}

print_warning() {
    echo -e "${YELLOW:-}[ATTENZIONE]${RESET:-} $1"
}

print_error() {
    echo -e "${RED:-}[ERRORE]${RESET:-} $1"
}

print_step() {
    echo -e "${PURPLE:-}[PASSO]${RESET:-} $1"
}

print_header() {
    echo -e "${BOLD:-}${CYAN:-}=================================${RESET:-}"
    echo -e "${BOLD:-}${CYAN:-}  PROXMOX RESTORE SYSTEM v${SCRIPT_VERSION:-0.1.0}${RESET:-}"
    echo -e "${BOLD:-}${CYAN:-}=================================${RESET:-}"
    echo
    echo -e "${BOLD:-}${GREEN:-}Script di ripristino per configurazioni Proxmox${RESET:-}"
    echo -e "${BOLD:-}${YELLOW:-}ATTENZIONE: Questo script sovrascriverà le configurazioni attuali!${RESET:-}"
    echo
}

# Cleanup function
cleanup() {
    if [ -n "${TEMP_DIR:-}" ] && [ -d "${TEMP_DIR:-}" ]; then
        print_step "Pulizia file temporanei"
        rm -rf "${TEMP_DIR}" 2>/dev/null || true
    fi
    
    if [ -n "${RESTORE_PATH:-}" ] && [ -d "${RESTORE_PATH:-}" ]; then
        rm -rf "${RESTORE_PATH}" 2>/dev/null || true
    fi
}

# Error handler
handle_error() {
    local line_no=$1
    local error_code=$2
    print_error "Errore alla riga $line_no con codice di uscita $error_code"
    cleanup
    exit $EXIT_ERROR
}

# Trap per gestire errori e pulizia
trap 'handle_error ${LINENO} $?' ERR
trap 'cleanup' EXIT

# ==========================================
# MAIN FUNCTIONS
# ==========================================

# Function to check if running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error "Questo script deve essere eseguito come root (usa sudo)"
        exit $EXIT_ERROR
    fi
}

# Function to check environment file
check_env_file() {
    print_step "Controllo file di configurazione"
    
    if [[ ! -f "$ENV_FILE" ]]; then
        print_error "File di configurazione non trovato: $ENV_FILE"
        exit $EXIT_ERROR
    fi
    
    if [[ ! -r "$ENV_FILE" ]]; then
        print_error "File di configurazione non leggibile: $ENV_FILE"
        exit $EXIT_ERROR
    fi
    
    print_success "File di configurazione trovato e leggibile"
}

# Function to detect available backup locations
detect_backup_locations() {
    print_step "Rilevamento ubicazioni backup configurate"
    
    local locations=()
    local location_names=()
    local location_paths=()
    
    # Backup locale (sempre disponibile)
    if [[ -n "${LOCAL_BACKUP_PATH:-}" ]] && [[ -d "${LOCAL_BACKUP_PATH:-}" ]]; then
        locations+=("local")
        location_names+=("Backup Locale")
        location_paths+=("${LOCAL_BACKUP_PATH}")
        print_info "✓ Backup locale trovato: ${LOCAL_BACKUP_PATH}"
    else
        print_warning "✗ Percorso backup locale non configurato o non esistente"
    fi
    
    # Backup secondario
    if [[ "${ENABLE_SECONDARY_BACKUP:-false}" == "true" ]]; then
        if [[ -n "${SECONDARY_BACKUP_PATH:-}" ]] && [[ -d "${SECONDARY_BACKUP_PATH:-}" ]]; then
            locations+=("secondary")
            location_names+=("Backup Secondario")
            location_paths+=("${SECONDARY_BACKUP_PATH}")
            print_info "✓ Backup secondario trovato: ${SECONDARY_BACKUP_PATH}"
        else
            print_warning "✗ Backup secondario abilitato ma percorso non configurato o non esistente"
        fi
    else
        print_info "- Backup secondario disabilitato nella configurazione"
    fi
    
    # Backup cloud
    if [[ "${ENABLE_CLOUD_BACKUP:-false}" == "true" ]]; then
        if command -v rclone >/dev/null 2>&1; then
            if rclone lsd "${RCLONE_REMOTE:-}:${CLOUD_BACKUP_PATH:-}" >/dev/null 2>&1; then
                locations+=("cloud")
                location_names+=("Backup Cloud")
                location_paths+=("${RCLONE_REMOTE:-}:${CLOUD_BACKUP_PATH:-}")
                print_info "✓ Backup cloud accessibile: ${RCLONE_REMOTE:-}:${CLOUD_BACKUP_PATH:-}"
            else
                print_warning "✗ Backup cloud configurato ma non accessibile"
            fi
        else
            print_warning "✗ rclone non installato, backup cloud non disponibile"
        fi
    else
        print_info "- Backup cloud disabilitato nella configurazione"
    fi
    
    if [[ ${#locations[@]} -eq 0 ]]; then
        print_error "Nessuna ubicazione backup valida trovata!"
        exit $EXIT_ERROR
    fi
    
    echo
    export AVAILABLE_LOCATIONS=("${locations[@]}")
    export LOCATION_NAMES=("${location_names[@]}")
    export LOCATION_PATHS=("${location_paths[@]}")
}

# Function to let user select backup location
select_backup_location() {
    print_step "Selezione ubicazione di ripristino"
    echo
    echo "Ubicazioni backup disponibili:"
    echo
    
    for i in "${!AVAILABLE_LOCATIONS[@]}"; do
        echo "  $((i+1)). ${LOCATION_NAMES[i]} (${LOCATION_PATHS[i]})"
    done
    
    echo
    while true; do
        read -p "Seleziona l'ubicazione da cui ripristinare (1-${#AVAILABLE_LOCATIONS[@]}): " choice
        
        if [[ "$choice" =~ ^[0-9]+$ ]] && [[ $choice -ge 1 ]] && [[ $choice -le ${#AVAILABLE_LOCATIONS[@]} ]]; then
            SELECTED_LOCATION="${AVAILABLE_LOCATIONS[$((choice-1))]}"
            SELECTED_LOCATION_NAME="${LOCATION_NAMES[$((choice-1))]}"
            SELECTED_LOCATION_PATH="${LOCATION_PATHS[$((choice-1))]}"
            break
        else
            print_warning "Selezione non valida. Inserisci un numero tra 1 e ${#AVAILABLE_LOCATIONS[@]}"
        fi
    done
    
    print_success "Ubicazione selezionata: $SELECTED_LOCATION_NAME"
    echo
}

# Function to list available backups
list_available_backups() {
    print_step "Ricerca backup disponibili in $SELECTED_LOCATION_NAME"
    
    local backup_files=()
    
    case "$SELECTED_LOCATION" in
        "local"|"secondary")
            # Backup locali o secondari
            while IFS= read -r -d '' file; do
                backup_files+=("$(basename "$file")")
            done < <(find "${SELECTED_LOCATION_PATH}" -name "*.tar.*" -type f -print0 2>/dev/null | sort -z)
            ;;
        "cloud")
            # Backup cloud via rclone
            TEMP_DIR=$(mktemp -d)
            local temp_list="$TEMP_DIR/cloud_backups.txt"
            
            if rclone ls "${SELECTED_LOCATION_PATH}" --include "*.tar.*" > "$temp_list" 2>/dev/null; then
                while IFS= read -r line; do
                    if [[ -n "$line" ]]; then
                        # Estrai solo il nome del file (seconda colonna)
                        local filename=$(echo "$line" | awk '{print $2}')
                        if [[ "$filename" == *.tar.* ]]; then
                            backup_files+=("$filename")
                        fi
                    fi
                done < "$temp_list"
            fi
            ;;
    esac
    
    if [[ ${#backup_files[@]} -eq 0 ]]; then
        print_error "Nessun file backup trovato nell'ubicazione selezionata!"
        exit $EXIT_ERROR
    fi
    
    echo
    echo "File backup disponibili:"
    echo
    
    # Ordina i file per data (più recenti prima)
    IFS=$'\n' backup_files=($(sort -r <<<"${backup_files[*]}"))
    unset IFS
    
    for i in "${!backup_files[@]}"; do
        local file="${backup_files[i]}"
        local date_part=$(echo "$file" | grep -o '[0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}_[0-9]\{2\}-[0-9]\{2\}-[0-9]\{2\}' || echo "data-sconosciuta")
        echo "  $((i+1)). $file ($date_part)"
    done
    
    echo
    export BACKUP_FILES=("${backup_files[@]}")
}

# Function to let user select backup file
select_backup_file() {
    while true; do
        read -p "Seleziona il file da cui ripristinare (1-${#BACKUP_FILES[@]}): " choice
        
        if [[ "$choice" =~ ^[0-9]+$ ]] && [[ $choice -ge 1 ]] && [[ $choice -le ${#BACKUP_FILES[@]} ]]; then
            SELECTED_BACKUP="${BACKUP_FILES[$((choice-1))]}"
            break
        else
            print_warning "Selezione non valida. Inserisci un numero tra 1 e ${#BACKUP_FILES[@]}"
        fi
    done
    
    print_success "File backup selezionato: $SELECTED_BACKUP"
    echo
}

# Function to confirm restore operation
confirm_restore() {
    print_warning "ATTENZIONE: Stai per ripristinare le configurazioni Proxmox!"
    print_warning "Questa operazione sovrascriverà le configurazioni attuali."
    echo
    echo "Dettagli del ripristino:"
    echo "  - Ubicazione: $SELECTED_LOCATION_NAME"
    echo "  - File backup: $SELECTED_BACKUP"
    echo "  - Percorso: $SELECTED_LOCATION_PATH"
    echo
    
    while true; do
        read -p "Sei sicuro di voler procedere? (scrivi 'CONFERMA' per procedere, 'no' per annullare): " response
        
        case "$response" in
            "CONFERMA")
                print_success "Operazione confermata dall'utente"
                break
                ;;
            "no"|"NO"|"n"|"N")
                print_info "Operazione annullata dall'utente"
                exit $EXIT_SUCCESS
                ;;
            *)
                print_warning "Risposta non valida. Scrivi 'CONFERMA' per procedere o 'no' per annullare."
                ;;
        esac
    done
    
    echo
}

# Function to download/copy backup file
prepare_backup_file() {
    print_step "Preparazione file backup per il ripristino"
    
    # Crea directory di ripristino temporanea
    mkdir -p "$RESTORE_PATH"
    
    local local_backup_file="$RESTORE_PATH/$SELECTED_BACKUP"
    
    case "$SELECTED_LOCATION" in
        "local"|"secondary")
            # Copia locale
            print_info "Copia del file backup in corso..."
            if cp "${SELECTED_LOCATION_PATH}/${SELECTED_BACKUP}" "$local_backup_file"; then
                print_success "File backup copiato con successo"
            else
                print_error "Errore durante la copia del file backup"
                exit $EXIT_ERROR
            fi
            ;;
        "cloud")
            # Download da cloud
            print_info "Download del file backup dal cloud in corso..."
            if rclone copy "${SELECTED_LOCATION_PATH}/${SELECTED_BACKUP}" "$RESTORE_PATH/" ${RCLONE_FLAGS:-}; then
                print_success "File backup scaricato con successo"
            else
                print_error "Errore durante il download del file backup"
                exit $EXIT_ERROR
            fi
            ;;
    esac
    
    # Verifica che il file esista
    if [[ ! -f "$local_backup_file" ]]; then
        print_error "File backup non trovato dopo la preparazione: $local_backup_file"
        exit $EXIT_ERROR
    fi
    
    export LOCAL_BACKUP_FILE="$local_backup_file"
}

# Function to extract and restore backup
restore_backup() {
    print_step "Estrazione e ripristino del backup"
    
    local extract_dir="$RESTORE_PATH/extracted"
    mkdir -p "$extract_dir"
    
    # Determina il tipo di compressione dal nome del file
    local compress_ext=""
    if [[ "$SELECTED_BACKUP" == *.tar.xz ]]; then
        compress_ext="xz"
    elif [[ "$SELECTED_BACKUP" == *.tar.gz ]]; then
        compress_ext="gz"
    elif [[ "$SELECTED_BACKUP" == *.tar.zst ]]; then
        compress_ext="zst"
    elif [[ "$SELECTED_BACKUP" == *.tar ]]; then
        compress_ext="tar"
    else
        print_error "Formato di compressione non riconosciuto: $SELECTED_BACKUP"
        exit $EXIT_ERROR
    fi
    
    print_info "Estrazione backup (formato: $compress_ext)..."
    
    # Estrai il backup
    case "$compress_ext" in
        "xz")
            if tar -xf "$LOCAL_BACKUP_FILE" -C "$extract_dir"; then
                print_success "Backup estratto con successo"
            else
                print_error "Errore durante l'estrazione del backup"
                exit $EXIT_ERROR
            fi
            ;;
        "gz")
            if tar -xzf "$LOCAL_BACKUP_FILE" -C "$extract_dir"; then
                print_success "Backup estratto con successo"
            else
                print_error "Errore durante l'estrazione del backup"
                exit $EXIT_ERROR
            fi
            ;;
        "zst")
            if tar --use-compress-program=zstd -xf "$LOCAL_BACKUP_FILE" -C "$extract_dir"; then
                print_success "Backup estratto con successo"
            else
                print_error "Errore durante l'estrazione del backup"
                exit $EXIT_ERROR
            fi
            ;;
        "tar")
            if tar -xf "$LOCAL_BACKUP_FILE" -C "$extract_dir"; then
                print_success "Backup estratto con successo"
            else
                print_error "Errore durante l'estrazione del backup"
                exit $EXIT_ERROR
            fi
            ;;
    esac
    
    # Verifica che l'estrazione sia avvenuta correttamente
    if [[ ! -d "$extract_dir" ]] || [[ -z "$(ls -A "$extract_dir" 2>/dev/null)" ]]; then
        print_error "Directory estratta vuota o non trovata"
        exit $EXIT_ERROR
    fi
    
    print_step "Ripristino delle configurazioni"
    
    # Effettua il ripristino delle configurazioni
    cd "$extract_dir"
    
    # Trova la directory del backup (dovrebbe essere l'unica subdirectory)
    local backup_content_dir=$(find . -maxdepth 1 -type d ! -name "." | head -n1)
    
    if [[ -z "$backup_content_dir" ]]; then
        print_error "Struttura backup non valida"
        exit $EXIT_ERROR
    fi
    
    cd "$backup_content_dir"
    
    print_info "Ripristino configurazioni Proxmox..."
    
    # Ripristina le configurazioni principali
    if [[ -d "etc/pve" ]]; then
        print_info "Ripristino configurazioni PVE..."
        cp -a etc/pve/* /etc/pve/ 2>/dev/null || print_warning "Alcuni file PVE potrebbero non essere stati ripristinati"
    fi
    
    if [[ -d "etc/proxmox-backup" ]]; then
        print_info "Ripristino configurazioni PBS..."
        cp -a etc/proxmox-backup/* /etc/proxmox-backup/ 2>/dev/null || print_warning "Alcuni file PBS potrebbero non essere stati ripristinati"
    fi
    
    if [[ -d "etc/corosync" ]]; then
        print_info "Ripristino configurazioni Corosync..."
        cp -a etc/corosync/* /etc/corosync/ 2>/dev/null || print_warning "Alcuni file Corosync potrebbero non essere stati ripristinati"
    fi
    
    if [[ -d "etc/ceph" ]]; then
        print_info "Ripristino configurazioni Ceph..."
        cp -a etc/ceph/* /etc/ceph/ 2>/dev/null || print_warning "Alcuni file Ceph potrebbero non essere stati ripristinati"
    fi
    
    if [[ -f "etc/vzdump.conf" ]]; then
        print_info "Ripristino configurazione vzdump..."
        cp etc/vzdump.conf /etc/vzdump.conf 2>/dev/null || print_warning "File vzdump.conf non ripristinato"
    fi
    
    # Ripristina altre configurazioni se presenti
    if [[ -d "root" ]]; then
        print_info "Ripristino configurazioni root..."
        cp -a root/* /root/ 2>/dev/null || print_warning "Alcune configurazioni root potrebbero non essere state ripristinate"
    fi
    
    print_success "Configurazioni ripristinate con successo"
}

# Function to restart services
restart_services() {
    print_step "Riavvio servizi Proxmox"
    
    local services_restarted=0
    local services_failed=0
    
    # Lista dei servizi Proxmox da riavviare
    local pve_services=("pveproxy" "pvedaemon" "pvestatd" "pvescheduler" "pve-cluster")
    local pbs_services=("proxmox-backup" "proxmox-backup-proxy")
    local common_services=("corosync" "pve-firewall")
    
    # Funzione per riavviare un servizio
    restart_service() {
        local service=$1
        
        if systemctl is-enabled "$service" >/dev/null 2>&1; then
            print_info "Riavvio servizio: $service"
            if systemctl restart "$service" >/dev/null 2>&1; then
                print_success "Servizio $service riavviato con successo"
                ((services_restarted++))
            else
                print_warning "Errore nel riavvio del servizio: $service"
                ((services_failed++))
            fi
        else
            print_info "Servizio $service non abilitato, salto il riavvio"
        fi
    }
    
    # Riavvia servizi PVE se presenti
    for service in "${pve_services[@]}"; do
        restart_service "$service"
    done
    
    # Riavvia servizi PBS se presenti
    for service in "${pbs_services[@]}"; do
        restart_service "$service"
    done
    
    # Riavvia servizi comuni se presenti
    for service in "${common_services[@]}"; do
        restart_service "$service"
    done
    
    echo
    print_success "Riavvio servizi completato:"
    print_info "  - Servizi riavviati con successo: $services_restarted"
    if [[ $services_failed -gt 0 ]]; then
        print_warning "  - Servizi con errori: $services_failed"
    fi
    
    # Breve pausa per permettere ai servizi di avviarsi
    print_info "Attesa avvio servizi..."
    sleep 5
}

# Function to verify restore
verify_restore() {
    print_step "Verifica del ripristino"
    
    local verification_ok=true
    
    # Verifica servizi PVE
    if command -v pvesh >/dev/null 2>&1; then
        if systemctl is-active --quiet pveproxy; then
            print_success "✓ Servizio PVE Proxy attivo"
        else
            print_warning "✗ Servizio PVE Proxy non attivo"
            verification_ok=false
        fi
    fi
    
    # Verifica servizi PBS
    if command -v proxmox-backup-manager >/dev/null 2>&1; then
        if systemctl is-active --quiet proxmox-backup; then
            print_success "✓ Servizio Proxmox Backup attivo"
        else
            print_warning "✗ Servizio Proxmox Backup non attivo"
            verification_ok=false
        fi
    fi
    
    # Verifica cluster se presente
    if [[ -f "/etc/corosync/corosync.conf" ]]; then
        if systemctl is-active --quiet corosync; then
            print_success "✓ Servizio Corosync attivo"
        else
            print_warning "✗ Servizio Corosync non attivo"
            verification_ok=false
        fi
    fi
    
    if [[ "$verification_ok" == "true" ]]; then
        print_success "Verifica del ripristino completata con successo"
    else
        print_warning "Verifica completata con alcuni avvisi - controlla i log di sistema"
    fi
}

# ==========================================
# MAIN FUNCTION
# ==========================================

main() {
    # Trap per gestire errori
    trap 'handle_error ${LINENO} $?' ERR
    
    print_header
    
    # Controlli preliminari
    check_root
    check_env_file
    
    # Rilevamento ubicazioni backup
    detect_backup_locations
    
    # Selezione ubicazione
    select_backup_location
    
    # Lista backup disponibili
    list_available_backups
    
    # Selezione file backup
    select_backup_file
    
    # Conferma operazione
    confirm_restore
    
    # Preparazione file backup
    prepare_backup_file
    
    # Ripristino
    restore_backup
    
    # Riavvio servizi
    restart_services
    
    # Verifica finale
    verify_restore
    
    echo
    print_success "Ripristino completato con successo!"
    print_info "Il sistema Proxmox è stato ripristinato dal backup: $SELECTED_BACKUP"
    print_info "Ubicazione: $SELECTED_LOCATION_NAME"
    
    echo
    print_warning "IMPORTANTE:"
    print_warning "- Verifica che tutti i servizi funzionino correttamente"
    print_warning "- Controlla i log di sistema per eventuali errori"
    print_warning "- Testa le funzionalità critiche del sistema"
    
    # Cleanup automatico
    cleanup
    
    exit $EXIT_SUCCESS
}

# ==========================================
# SCRIPT STARTUP
# ==========================================

main "$@" 
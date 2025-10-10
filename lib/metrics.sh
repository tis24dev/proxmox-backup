#!/bin/bash

# DEPENDENCY VALIDATION
# =====================
# Validate required dependencies and set fallback flags
validate_metrics_dependencies() {
    local missing_critical=()
    local missing_optional=()
    
    # Critical dependencies
    local critical_deps=("bc" "find" "stat" "date" "awk")
    for dep in "${critical_deps[@]}"; do
        if ! command -v "$dep" &>/dev/null; then
            missing_critical+=("$dep")
        fi
    done
    
    # Optional dependencies with fallback flags
    command -v jq &>/dev/null || METRICS_NO_JQ=true
    command -v rclone &>/dev/null || METRICS_NO_RCLONE=true
    command -v tar &>/dev/null || METRICS_NO_TAR=true
    command -v top &>/dev/null || METRICS_NO_TOP=true
    
    # Report missing critical dependencies
    if [ ${#missing_critical[@]} -gt 0 ]; then
        error "Critical dependencies missing for metrics module: ${missing_critical[*]}"
        error "Please install missing packages: apt-get install ${missing_critical[*]}"
        return 1
    fi
    
    # Report missing optional dependencies
    if [ ${#missing_optional[@]} -gt 0 ]; then
        warning "Optional dependencies missing: ${missing_optional[*]}"
        warning "Some metrics features may be limited"
    fi
    
    debug "Metrics dependencies validated successfully"
    return 0
}

# Initialize dependency validation
if ! validate_metrics_dependencies; then
    error "Metrics module initialization failed due to missing dependencies"
    return 1
fi

# GLOBAL VARIABLES AND ARRAYS
# ============================

# Array associativo globale per le metriche di sistema
declare -A SYSTEM_METRICS

# Lock file for metrics operations coordination with backup_manager
declare -g METRICS_LOCK_FILE="/tmp/proxmox_backup_metrics_$$.lock"

# Timeout settings for various operations
declare -g METRICS_CLOUD_TIMEOUT=300  # 5 minutes for cloud operations
declare -g METRICS_TAR_TIMEOUT=600    # 10 minutes for tar operations
declare -g METRICS_LOCK_TIMEOUT=60    # 1 minute for lock acquisition

# Global variables for system metrics
declare -g SYSTEM_CPU_USAGE=0
declare -g SYSTEM_MEM_TOTAL=0
declare -g SYSTEM_MEM_FREE=0
declare -g SYSTEM_MEM_USED=0
declare -g SYSTEM_LOAD_AVG=""

# Global variables for backup age
declare -g BACKUP_PRI_OLDEST_AGE=0
declare -g BACKUP_PRI_NEWEST_AGE=0
declare -g BACKUP_PRI_AVG_AGE=0
declare -g BACKUP_SEC_OLDEST_AGE=0
declare -g BACKUP_SEC_NEWEST_AGE=0
declare -g BACKUP_SEC_AVG_AGE=0
declare -g BACKUP_CLO_OLDEST_AGE=0
declare -g BACKUP_CLO_NEWEST_AGE=0
declare -g BACKUP_CLO_AVG_AGE=0

# Global variables for backup speed and timing
declare -g BACKUP_SPEED=0
declare -g BACKUP_SPEED_HUMAN="0 MB/s"
declare -g BACKUP_TIME_ESTIMATE=0
declare -g BACKUP_TIME_ESTIMATE_HUMAN="0m"
declare -g BACKUP_START_TIME=0
declare -g BACKUP_END_TIME=0
declare -g SECONDARY_COPY_START_TIME=0
declare -g SECONDARY_COPY_END_TIME=0
declare -g CLOUD_UPLOAD_START_TIME=0
declare -g CLOUD_UPLOAD_END_TIME=0
declare -g EXPECTED_BACKUP_SIZE=0

# Global variables for status emojis
declare -g EMOJI_BACKUP_PRIMARIO="⚠️"
declare -g EMOJI_BACKUP_SECONDARIO="⚠️"
declare -g EMOJI_BACKUP_CLOUD="⚠️"
declare -g EMOJI_LOG_PRIMARIO="⚠️"
declare -g EMOJI_LOG_SECONDARIO="⚠️"
declare -g EMOJI_LOG_CLOUD="⚠️"
declare -g EMOJI_EMAIL="ERR-EMO"

# Variable for emoji logging
declare -g ENABLE_EMOJI_LOG="${ENABLE_EMOJI_LOG:-false}"
declare -g EMOJI_LOG_FILE="/tmp/log_check_emoji.txt"

# METRICS COORDINATION AND LOCKING
# =================================
# Coordinate metrics operations with backup_manager to prevent race conditions

# Acquire metrics lock with coordination with backup_manager
acquire_metrics_lock() {
    local operation="$1"
    local timeout="${2:-$METRICS_LOCK_TIMEOUT}"
    
    debug "Acquiring metrics lock for operation: $operation"
    
    # Try to acquire lock with timeout
    if timeout "$timeout" flock -x "$METRICS_LOCK_FILE" true 2>/dev/null; then
        debug "Metrics lock acquired for: $operation"
        return 0
    else
        warning "Failed to acquire metrics lock for: $operation within ${timeout}s"
        return 1
    fi
}

# Release metrics lock
release_metrics_lock() {
    local operation="$1"
    
    if [ -f "$METRICS_LOCK_FILE" ]; then
        rm -f "$METRICS_LOCK_FILE" 2>/dev/null
        debug "Metrics lock released for: $operation"
    fi
}

# Function to save a metric in the system with race condition protection
save_metric() {
    local metric_name="$1"
    local metric_value="$2"
    local metric_labels="${3:-}"

    # Validate input parameters
    if [ -z "$metric_name" ] || [ -z "$metric_value" ]; then
        warning "Invalid metric parameters: name='$metric_name', value='$metric_value'"
        return 1
    fi

    # Acquire lock for thread-safe operation
    if acquire_metrics_lock "save_metric"; then
        # Create a unique key combining name and labels
        local metric_key="${metric_name}${metric_labels:+|$metric_labels}"
        SYSTEM_METRICS["$metric_key"]="$metric_value"
        release_metrics_lock "save_metric"
        return 0
    else
        warning "Failed to save metric due to lock timeout: $metric_name"
        return 1
    fi
}

# Funzione per ottenere una metrica dal sistema con validazione
get_metric() {
    local metric_name="$1"
    local metric_labels="${2:-}"
    
    # Validate input
    if [ -z "$metric_name" ]; then
        warning "Invalid metric name for get_metric"
        echo "0"
        return 1
    fi
    
    local metric_key="${metric_name}${metric_labels:+|$metric_labels}"
    echo "${SYSTEM_METRICS[$metric_key]:-0}"
}

# Function to add Prometheus metrics (modified to use system metrics)
update_prometheus_metrics() {
    # If Prometheus is not enabled, exit immediately
    if [ "$PROMETHEUS_ENABLED" != "true" ]; then
        return 0
    fi

    # Make sure the metrics file exists
    if [ ! -f "$METRICS_FILE" ]; then
        error "Metrics file not found: $METRICS_FILE"
        return 1
    fi

    local metric_name="$1"
    local metric_type="$2"
    local metric_help="$3"
    local metric_value="$4"
    local metric_labels="${5:-}"

    # Save the metric in the system
    save_metric "$metric_name" "$metric_value" "$metric_labels"

    # Add metric header if it doesn't already exist
    if ! grep -q "^# HELP ${metric_name} " "$METRICS_FILE"; then
        echo "# HELP ${metric_name} ${metric_help}" >> "$METRICS_FILE"
        echo "# TYPE ${metric_name} ${metric_type}" >> "$METRICS_FILE"
    fi

    # Add the metric with any labels
    if [ -n "$metric_labels" ]; then
        echo "${metric_name}{${metric_labels}} ${metric_value}" >> "$METRICS_FILE"
    else
        echo "${metric_name} ${metric_value}" >> "$METRICS_FILE"
    fi
}

# Funzione per esportare tutte le metriche di sistema in Prometheus
export_system_metrics_to_prometheus() {
    if [ "$PROMETHEUS_ENABLED" != "true" ]; then
        return 0
    fi

    step "Exporting system metrics to Prometheus"

    # Create the metrics file
    echo "# Proxmox Backup Metrics - Generated at $(date '+%Y-%m-%d %H:%M:%S')" > "$METRICS_FILE"

    # Definisci le metriche e i loro tipi
    declare -A metric_types=(
        ["proxmox_backup_start_time"]="gauge"
        ["proxmox_backup_type"]="gauge"
        ["proxmox_backup_script_version"]="gauge"
        ["proxmox_version"]="gauge"
        ["proxmox_backup_errors_total"]="gauge"
        ["proxmox_backup_error_category"]="gauge"
        ["proxmox_backup_phase_duration_seconds"]="gauge"
        ["proxmox_backup_files_total"]="gauge"
        ["proxmox_backup_directories_total"]="gauge"
        ["proxmox_backup_size_bytes"]="gauge"
        ["proxmox_backup_count"]="gauge"
        ["proxmox_backup_disk_free_bytes"]="gauge"
        ["proxmox_backup_success"]="gauge"
        ["proxmox_backup_compression_ratio"]="gauge"
        ["proxmox_backup_verify_success"]="gauge"
        ["proxmox_backup_system_cpu_usage"]="gauge"
        ["proxmox_backup_system_memory_bytes"]="gauge"
        ["proxmox_backup_system_load"]="gauge"
        ["proxmox_backup_age_days"]="gauge"
        ["proxmox_backup_speed_bytes"]="gauge"
        ["proxmox_backup_eta_seconds"]="gauge"
        ["proxmox_backup_end_time"]="gauge"
        ["proxmox_backup_duration_seconds"]="gauge"
        ["proxmox_backup_size_uncompressed_bytes"]="gauge"
        ["proxmox_backup_included_files"]="gauge"
        ["proxmox_backup_missing_files"]="gauge"
    )

    # Definisci le descrizioni delle metriche
    declare -A metric_help=(
        ["proxmox_backup_start_time"]="Unix timestamp of backup start"
        ["proxmox_backup_type"]="Type of proxmox installation"
        ["proxmox_backup_script_version"]="Version of the backup script"
        ["proxmox_version"]="Version of proxmox installation"
        ["proxmox_backup_errors_total"]="Total number of errors by severity"
        ["proxmox_backup_error_category"]="Number of errors by category"
        ["proxmox_backup_phase_duration_seconds"]="Duration of each backup phase in seconds"
        ["proxmox_backup_files_total"]="Total number of files in backup"
        ["proxmox_backup_directories_total"]="Total number of directories in backup"
        ["proxmox_backup_size_bytes"]="Size of backup file in bytes"
        ["proxmox_backup_count"]="Number of backup files"
        ["proxmox_backup_disk_free_bytes"]="Free disk space in bytes"
        ["proxmox_backup_success"]="Overall success of backup (1=success, 0=failure)"
        ["proxmox_backup_compression_ratio"]="Compression ratio of backup"
        ["proxmox_backup_verify_success"]="Success of backup verification (1=success, 0=failure)"
        ["proxmox_backup_system_cpu_usage"]="CPU usage percentage during backup"
        ["proxmox_backup_system_memory_bytes"]="System memory in bytes"
        ["proxmox_backup_system_load"]="System load average"
        ["proxmox_backup_age_days"]="Age of backup in days"
        ["proxmox_backup_speed_bytes"]="Backup speed in bytes per second"
        ["proxmox_backup_eta_seconds"]="Estimated time remaining in seconds"
        ["proxmox_backup_end_time"]="Unix timestamp of backup end"
        ["proxmox_backup_duration_seconds"]="Duration of backup process in seconds"
        ["proxmox_backup_size_uncompressed_bytes"]="Size of backup before compression in bytes"
        ["proxmox_backup_included_files"]="Number of files included in the backup"
        ["proxmox_backup_missing_files"]="Number of files missing from the backup"
    )

    # Esporta tutte le metriche
    for metric_key in "${!SYSTEM_METRICS[@]}"; do
        # Extract name and labels from key
        IFS='|' read -r metric_name metric_labels <<< "$metric_key"

        # Get type and help text
        local metric_type="${metric_types[$metric_name]:-gauge}"
        local metric_help_text="${metric_help[$metric_name]:-$metric_name}"

        # Add metric header if it doesn't already exist
        if ! grep -q "^# HELP ${metric_name} " "$METRICS_FILE"; then
            echo "# HELP ${metric_name} ${metric_help_text}" >> "$METRICS_FILE"
            echo "# TYPE ${metric_name} ${metric_type}" >> "$METRICS_FILE"
        fi

        # Aggiungi la metrica con eventuali etichette
        if [ -n "$metric_labels" ]; then
            echo "${metric_name}{${metric_labels}} ${SYSTEM_METRICS[$metric_key]}" >> "$METRICS_FILE"
        else
            echo "${metric_name} ${SYSTEM_METRICS[$metric_key]}" >> "$METRICS_FILE"
        fi
    done

    success "System metrics exported to Prometheus"
}

# Funzione per inizializzare le metriche Prometheus
initialize_prometheus_metrics() {
    if [ "$PROMETHEUS_ENABLED" != "true" ]; then
        return 0
    fi

    info "Initializing Prometheus metrics"

    # Create the metrics file
    echo "# Proxmox Backup Metrics - Generated at $(date '+%Y-%m-%d %H:%M:%S')" > "$METRICS_FILE"

    # Metriche di base
    update_prometheus_metrics "proxmox_backup_start_time" "gauge" "Unix timestamp of backup start" "${START_TIME:-$(date +%s)}"
    update_prometheus_metrics "proxmox_backup_type" "gauge" "Type of proxmox installation" "1" "type=\"${PROXMOX_TYPE:-ve}\""
    update_prometheus_metrics "proxmox_backup_script_version" "gauge" "Version of the backup script" "1" "version=\"${SCRIPT_VERSION}\""

    if [ -n "${PROXMOX_VERSION:-}" ]; then
        update_prometheus_metrics "proxmox_version" "gauge" "Version of proxmox installation" "1" "type=\"${PROXMOX_TYPE:-ve}\",version=\"$PROXMOX_VERSION\""
    fi

    # Initialize counters for error categories (verranno aggiornati durante l'esecuzione)
    update_prometheus_metrics "proxmox_backup_errors_total" "gauge" "Total number of errors by severity" "0" "severity=\"critical\""
    update_prometheus_metrics "proxmox_backup_errors_total" "gauge" "Total number of errors by severity" "0" "severity=\"warning\""
    update_prometheus_metrics "proxmox_backup_errors_total" "gauge" "Total number of errors by severity" "0" "severity=\"info\""

    # Inizializza metriche per le categorie di errori specifiche
    for category in "verification" "integrity" "archive_structure" "archive_content" "missing_directory" "extraction" "file_content" "sample_extraction" "structure_extraction"; do
        update_prometheus_metrics "proxmox_backup_error_category" "gauge" "Number of errors by category" "0" "category=\"$category\""
    done

    # Inizializza metriche per le varie fasi del backup
    for phase in "setup" "collect" "compress" "verify" "secondary" "cloud" "cleanup"; do
        update_prometheus_metrics "proxmox_backup_phase_duration_seconds" "gauge" "Duration of each backup phase in seconds" "0" "phase=\"$phase\""
    done

    # Metriche per i conteggi di file
    update_prometheus_metrics "proxmox_backup_files_total" "gauge" "Total number of files in backup" "0" "location=\"local\""
    update_prometheus_metrics "proxmox_backup_directories_total" "gauge" "Total number of directories in backup" "0"

    # Metriche per dimensioni dei backup
    update_prometheus_metrics "proxmox_backup_size_bytes" "gauge" "Size of backup file in bytes" "0" "location=\"local\""
    update_prometheus_metrics "proxmox_backup_size_bytes" "gauge" "Size of backup file in bytes" "0" "location=\"secondary\""
    update_prometheus_metrics "proxmox_backup_size_bytes" "gauge" "Size of backup file in bytes" "0" "location=\"cloud\""

    # Metriche per il conteggio dei backup
    update_prometheus_metrics "proxmox_backup_count" "gauge" "Number of backup files" "0" "location=\"local\""
    update_prometheus_metrics "proxmox_backup_count" "gauge" "Number of backup files" "0" "location=\"secondary\""
    update_prometheus_metrics "proxmox_backup_count" "gauge" "Number of backup files" "0" "location=\"cloud\""

    # Metriche per lo spazio disponibile
    update_prometheus_metrics "proxmox_backup_disk_free_bytes" "gauge" "Free disk space in bytes" "0" "location=\"local\""
    update_prometheus_metrics "proxmox_backup_disk_free_bytes" "gauge" "Free disk space in bytes" "0" "location=\"secondary\""

    # Metriche di stato
    update_prometheus_metrics "proxmox_backup_success" "gauge" "Overall success of backup (1=success, 0=failure)" "0"

    # Metriche per il rapporto di compressione
    update_prometheus_metrics "proxmox_backup_compression_ratio" "gauge" "Compression ratio of backup" "0"

    # Metriche per la verifica del backup
    update_prometheus_metrics "proxmox_backup_verify_success" "gauge" "Success of backup verification (1=success, 0=failure)" "0"

    # Nuove metriche di sistema
    update_prometheus_metrics "proxmox_backup_system_cpu_usage" "gauge" "CPU usage percentage during backup" "0"
    update_prometheus_metrics "proxmox_backup_system_memory_bytes" "gauge" "System memory in bytes" "0" "type=\"total\""
    update_prometheus_metrics "proxmox_backup_system_memory_bytes" "gauge" "System memory in bytes" "0" "type=\"free\""
    update_prometheus_metrics "proxmox_backup_system_memory_bytes" "gauge" "System memory in bytes" "0" "type=\"used\""
    update_prometheus_metrics "proxmox_backup_system_load" "gauge" "System load average" "0" "period=\"1min\""
    update_prometheus_metrics "proxmox_backup_system_load" "gauge" "System load average" "0" "period=\"5min\""
    update_prometheus_metrics "proxmox_backup_system_load" "gauge" "System load average" "0" "period=\"15min\""

    # New backup age metrics
    update_prometheus_metrics "proxmox_backup_age_days" "gauge" "Age of backup in days" "0" "location=\"local\",type=\"oldest\""
    update_prometheus_metrics "proxmox_backup_age_days" "gauge" "Age of backup in days" "0" "location=\"local\",type=\"newest\""
    update_prometheus_metrics "proxmox_backup_age_days" "gauge" "Age of backup in days" "0" "location=\"local\",type=\"average\""
    update_prometheus_metrics "proxmox_backup_age_days" "gauge" "Age of backup in days" "0" "location=\"secondary\",type=\"oldest\""
    update_prometheus_metrics "proxmox_backup_age_days" "gauge" "Age of backup in days" "0" "location=\"secondary\",type=\"newest\""
    update_prometheus_metrics "proxmox_backup_age_days" "gauge" "Age of backup in days" "0" "location=\"cloud\",type=\"oldest\""
    update_prometheus_metrics "proxmox_backup_age_days" "gauge" "Age of backup in days" "0" "location=\"cloud\",type=\"newest\""

    # New speed metrics
    update_prometheus_metrics "proxmox_backup_speed_bytes" "gauge" "Backup speed in bytes per second" "0"
    update_prometheus_metrics "proxmox_backup_eta_seconds" "gauge" "Estimated time remaining in seconds" "0"

    info "Prometheus metrics initialized"
}

# Funzione per aggiornare le metriche dal file di error tracking
update_error_metrics() {
    if [ "$PROMETHEUS_ENABLED" != "true" ]; then
        return 0
    fi

    debug "Updating error metrics for Prometheus"

    # Count by severity
    local critical_count=0
    local warning_count=0
    local info_count=0

    # Conteggi per categoria
    local category_counts=()

    # Analyze errors and update counters
    for error_entry in "${ERROR_LIST[@]}"; do
        IFS='|' read -r err_category err_severity err_message err_details <<< "$error_entry"

        # Increment severity counters
        case "$err_severity" in
            "critical") critical_count=$((critical_count + 1)) ;;
            "warning") warning_count=$((warning_count + 1)) ;;
            "info") info_count=$((info_count + 1)) ;;
        esac

        # Update category counters
        local found=false
        for i in "${!category_counts[@]}"; do
            IFS='|' read -r cat_name cat_count <<< "${category_counts[$i]}"
            if [ "$cat_name" == "$err_category" ]; then
                category_counts[$i]="${cat_name}|$((cat_count + 1))"
                found=true
                break
            fi
        done

        if [ "$found" == "false" ]; then
            category_counts+=("${err_category}|1")
        fi
    done

    # Update Prometheus metrics for severities
    update_prometheus_metrics "proxmox_backup_errors_total" "gauge" "Total number of errors by severity" "$critical_count" "severity=\"critical\""
    update_prometheus_metrics "proxmox_backup_errors_total" "gauge" "Total number of errors by severity" "$warning_count" "severity=\"warning\""
    update_prometheus_metrics "proxmox_backup_errors_total" "gauge" "Total number of errors by severity" "$info_count" "severity=\"info\""

    # Update category metrics
    for category_entry in "${category_counts[@]}"; do
        IFS='|' read -r cat_name cat_count <<< "$category_entry"
        update_prometheus_metrics "proxmox_backup_error_category" "gauge" "Number of errors by category" "$cat_count" "category=\"$cat_name\""
    done

    # Set metric for verification success
    local verify_success=1
    if [ $critical_count -gt 0 ] || [ $warning_count -gt 0 ]; then
        verify_success=0
    fi
    update_prometheus_metrics "proxmox_backup_verify_success" "gauge" "Success of backup verification (1=success, 0=failure)" "$verify_success"

    debug "Error metrics updated for Prometheus"
}

# Funzione per aggiornare le metriche del filesystem
update_filesystem_metrics() {
if [ "$PROMETHEUS_ENABLED" != "true" ]; then
        return 0
    fi

    debug "Updating filesystem metrics for Prometheus"

    # Get available space for local backup
    if [ -d "$LOCAL_BACKUP_PATH" ]; then
        local free_bytes=$(get_free_space "$LOCAL_BACKUP_PATH")
        update_prometheus_metrics "proxmox_backup_disk_free_bytes" "gauge" "Free disk space in bytes" "$free_bytes" "location=\"local\""
    fi

    # Get available space for secondary backup
    if [ "${ENABLE_SECONDARY_BACKUP:-false}" = "true" ] && [ -d "$SECONDARY_BACKUP_PATH" ]; then
        local free_bytes=$(get_free_space "$SECONDARY_BACKUP_PATH")
        update_prometheus_metrics "proxmox_backup_disk_free_bytes" "gauge" "Free disk space in bytes" "$free_bytes" "location=\"secondary\""
    fi

    # Get current backup count
    if [ -d "$LOCAL_BACKUP_PATH" ]; then
        local count=$(count_files_in_dir "$LOCAL_BACKUP_PATH" "${PROXMOX_TYPE}-backup-*.tar*" "*.sha256")
        update_prometheus_metrics "proxmox_backup_count" "gauge" "Number of backup files" "$count" "location=\"local\""
    fi

    if [ "${ENABLE_SECONDARY_BACKUP:-false}" = "true" ] && [ -d "$SECONDARY_BACKUP_PATH" ]; then
        local count=$(count_files_in_dir "$SECONDARY_BACKUP_PATH" "${PROXMOX_TYPE}-backup-*.tar*" "*.sha256")
        update_prometheus_metrics "proxmox_backup_count" "gauge" "Number of backup files" "$count" "location=\"secondary\""
    fi

    debug "Filesystem metrics updated for Prometheus"
}

# Funzione per aggiornare le metriche del file di backup
update_backup_file_metrics() {
    if [ "$PROMETHEUS_ENABLED" != "true" ]; then
        return 0
    fi

    debug "Updating backup file metrics for Prometheus"

    if [ -n "$BACKUP_FILE" ] && [ -f "$BACKUP_FILE" ]; then
        # Dimensione del file di backup in bytes utilizzando la funzione centralizzata
        local size_bytes=$(get_file_size "$BACKUP_FILE")
        update_prometheus_metrics "proxmox_backup_size_bytes" "gauge" "Size of backup file in bytes" "$size_bytes" "location=\"local\""

        # Numero di file e directory (ottenuto direttamente)
        local file_count dir_count
        read file_count dir_count < <(count_files_in_backup "$BACKUP_FILE" "true")
        if [ -n "$file_count" ] && [ -n "$dir_count" ]; then
            update_prometheus_metrics "proxmox_backup_files_total" "gauge" "Total number of files in backup" "$file_count"
            update_prometheus_metrics "proxmox_backup_directories_total" "gauge" "Total number of directories in backup" "$dir_count"
        fi

        # Update compression metrics
        update_prometheus_metrics "proxmox_backup_size_uncompressed_bytes" "gauge" "Size of backup before compression in bytes" "${uncompressed_size:-0}"

        # Update compression metric only if we have a valid value
        if [ -n "$COMPRESSION_RATIO" ] && [ "$COMPRESSION_RATIO" != "Unknown" ]; then
            # Convert percentage value to decimal by removing % symbol
            local ratio=${COMPRESSION_RATIO/\%/}
            if [ -n "$ratio" ]; then
                update_prometheus_metrics "proxmox_backup_compression_ratio" "gauge" "Compression ratio of backup" "$ratio"
            fi
        fi

        # Update system metrics (now SYSTEM_CPU_USAGE is already declared)
        update_prometheus_metrics "proxmox_backup_system_cpu_usage" "gauge" "CPU usage percentage during backup" "${SYSTEM_CPU_USAGE:-0}"
        update_prometheus_metrics "proxmox_backup_system_memory_bytes" "gauge" "System memory in bytes" "${SYSTEM_MEM_TOTAL:-0}" "type=\"total\""
        update_prometheus_metrics "proxmox_backup_system_memory_bytes" "gauge" "System memory in bytes" "${SYSTEM_MEM_FREE:-0}" "type=\"free\""
        update_prometheus_metrics "proxmox_backup_system_memory_bytes" "gauge" "System memory in bytes" "${SYSTEM_MEM_USED:-0}" "type=\"used\""

        # Update load average metrics
        if [ -n "$SYSTEM_LOAD_AVG" ]; then
            IFS=' ' read -r load1 load5 load15 <<< "$SYSTEM_LOAD_AVG"
            update_prometheus_metrics "proxmox_backup_system_load" "gauge" "System load average" "${load1:-0}" "period=\"1min\""
            update_prometheus_metrics "proxmox_backup_system_load" "gauge" "System load average" "${load5:-0}" "period=\"5min\""
            update_prometheus_metrics "proxmox_backup_system_load" "gauge" "System load average" "${load15:-0}" "period=\"15min\""
        fi

        # Update backup age metrics (now variables are already declared)
        update_prometheus_metrics "proxmox_backup_age_days" "gauge" "Age of backup in days" "${BACKUP_PRI_OLDEST_AGE:-0}" "location=\"local\",type=\"oldest\""
        update_prometheus_metrics "proxmox_backup_age_days" "gauge" "Age of backup in days" "${BACKUP_PRI_NEWEST_AGE:-0}" "location=\"local\",type=\"newest\""
        update_prometheus_metrics "proxmox_backup_age_days" "gauge" "Age of backup in days" "${BACKUP_PRI_AVG_AGE:-0}" "location=\"local\",type=\"average\""
        update_prometheus_metrics "proxmox_backup_age_days" "gauge" "Age of backup in days" "${BACKUP_SEC_OLDEST_AGE:-0}" "location=\"secondary\",type=\"oldest\""
        update_prometheus_metrics "proxmox_backup_age_days" "gauge" "Age of backup in days" "${BACKUP_SEC_NEWEST_AGE:-0}" "location=\"secondary\",type=\"newest\""
        update_prometheus_metrics "proxmox_backup_age_days" "gauge" "Age of backup in days" "${BACKUP_CLO_OLDEST_AGE:-0}" "location=\"cloud\",type=\"oldest\""
        update_prometheus_metrics "proxmox_backup_age_days" "gauge" "Age of backup in days" "${BACKUP_CLO_NEWEST_AGE:-0}" "location=\"cloud\",type=\"newest\""

        # Update speed metrics (now variables are already declared)
        if [ "${BACKUP_SPEED:-0}" -gt 0 ]; then
            update_prometheus_metrics "proxmox_backup_speed_bytes" "gauge" "Backup speed in bytes per second" "${BACKUP_SPEED:-0}"
        fi
        if [ "${BACKUP_TIME_ESTIMATE:-0}" -gt 0 ]; then
            update_prometheus_metrics "proxmox_backup_eta_seconds" "gauge" "Estimated time remaining in seconds" "${BACKUP_TIME_ESTIMATE:-0}"
        fi
    fi

    debug "Backup file metrics updated for Prometheus"
}

# Funzione per aggiornare le metriche di esecuzione per fase
update_phase_metrics() {
    if [ "$PROMETHEUS_ENABLED" != "true" ]; then
        return 0
    fi

    local phase="$1"
    local start_time="$2"
    local end_time="${3:-$(date +%s)}"

    local duration=$((end_time - start_time))
    update_prometheus_metrics "proxmox_backup_phase_duration_seconds" "gauge" "Duration of each backup phase in seconds" "$duration" "phase=\"$phase\""

    debug "Updated phase metrics for $phase: $duration seconds"
}

# Funzione per esportare le metriche finali
export_prometheus_metrics() {
    if [ "$PROMETHEUS_ENABLED" != "true" ]; then
        return 0
    fi

    # Aggiorna le metriche finali
    local end_time=$(date +%s)
    local duration=$((end_time - START_TIME))

    update_prometheus_metrics "proxmox_backup_end_time" "gauge" "Unix timestamp of backup end" "$end_time"
    update_prometheus_metrics "proxmox_backup_duration_seconds" "gauge" "Duration of backup process in seconds" "$duration"
    update_prometheus_metrics "proxmox_backup_success" "gauge" "Overall success of backup (1=success, 0=failure)" "$([[ $EXIT_CODE -eq 0 ]] && echo 1 || echo 0)"

    # Check that the output directory exists
    if [ ! -d "$PROMETHEUS_TEXTFILE_DIR" ]; then
        info "Creating Prometheus textfile directory: $PROMETHEUS_TEXTFILE_DIR"
        if mkdir -p "$PROMETHEUS_TEXTFILE_DIR" 2>/dev/null; then
            debug "Created Prometheus textfile directory: $PROMETHEUS_TEXTFILE_DIR"
            # Set appropriate permissions
            chmod 755 "$PROMETHEUS_TEXTFILE_DIR" 2>/dev/null || true
        else
            warning "Failed to create Prometheus textfile directory: $PROMETHEUS_TEXTFILE_DIR"
            warning "Check permissions and available disk space"
            return 1
        fi
    fi

    # Copia il file di metriche nella posizione finale
    if ! cp "$METRICS_FILE" "${PROMETHEUS_TEXTFILE_DIR}/proxmox_backup.prom"; then
        warning "Failed to copy metrics file to Prometheus directory"
        return 1
    fi

    return 0
}

export_metrics() {
    if [ "$PROMETHEUS_ENABLED" != "true" ]; then
        return $EXIT_SUCCESS
    fi

    step "Checking Prometheus directory"

    info "Checking Prometheus directory presence"

    # Check that the output directory exists and is writable
    if [ ! -d "$PROMETHEUS_TEXTFILE_DIR" ]; then
        info "Directory not present"

        # Try to create the directory
        if mkdir -p "$PROMETHEUS_TEXTFILE_DIR" 2>/dev/null; then
            info "Creating directory"
            # Set correct permissions
            chmod 755 "$PROMETHEUS_TEXTFILE_DIR" 2>/dev/null
            success "Directory verified successfully"
        else
            warning "Unable to create Prometheus directory: $PROMETHEUS_TEXTFILE_DIR"
            set_exit_code "warning"
            return $EXIT_WARNING
        fi
    else
        # Check if the directory is writable
        if [ -w "$PROMETHEUS_TEXTFILE_DIR" ]; then
            info "Directory present"
            success "Directory verified successfully"
        else
            warning "Prometheus directory exists but is not writable: $PROMETHEUS_TEXTFILE_DIR"
            set_exit_code "warning"
            return $EXIT_WARNING
        fi
    fi

    # Copia il file delle metriche nella posizione finale
    if ! cp "$METRICS_FILE" "${PROMETHEUS_TEXTFILE_DIR}/proxmox_backup.prom"; then
        warning "Failed to copy metrics file to Prometheus directory"
        set_exit_code "warning"
        return $EXIT_WARNING
    fi

    info "Metriche Prometheus esportate in ${PROMETHEUS_TEXTFILE_DIR}/proxmox_backup.prom"
    success "Prometheus metrics exported successfully"
    return $EXIT_SUCCESS
}

# Update Prometheus metrics at the end of the backup
update_final_metrics() {
    if [ "$PROMETHEUS_ENABLED" != "true" ]; then
        return 0
    fi

    step "Updating final Prometheus metrics"

    # Update all system metrics
    update_error_metrics
    update_filesystem_metrics
    update_backup_file_metrics

    # Esporta tutte le metriche in Prometheus
    export_system_metrics_to_prometheus

    success "Prometheus metrics updated successfully"
}

# Funzione per contare i file nel backup e aggiornare le metriche
count_backup_files() {
    # Variabili globali per i conteggi dei file
    declare -g FILES_INCLUDED
    declare -g FILE_MISSING

    debug "Counting files in backup"

    # Conteggio file inclusi
    FILES_INCLUDED=0
    FILE_MISSING=0

    if [ -n "$BACKUP_FILE" ] && [ -f "$BACKUP_FILE" ]; then
        FILES_INCLUDED=$(count_files_in_backup "$BACKUP_FILE")
        FILE_MISSING=$(count_missing_files)

        # Aggiorna metriche Prometheus se abilitato
        if [ "$PROMETHEUS_ENABLED" == "true" ]; then
            update_prometheus_metrics "proxmox_backup_included_files" "gauge" "Number of files included in the backup" "$FILES_INCLUDED"
            update_prometheus_metrics "proxmox_backup_missing_files" "gauge" "Number of files missing from the backup" "$FILE_MISSING"
        fi
    fi

    debug "Files in backup: $FILES_INCLUDED included, $FILE_MISSING missing"
    return 0
}

# ======= Funzioni centralizzate per il calcolo di dimensioni e compressione =======

# CENTRALIZED CALCULATION FUNCTIONS
# ==================================
# Centralized functions for size, compression, and performance calculations

# Calcola il rapporto di compressione in diversi formati
calculate_compression_ratio() {
    local original_size="$1"
    local compressed_size="$2"
    local format="${3:-percent}"  # 'percent', 'decimal', o 'human'

    # Input validation
    if [ -z "$original_size" ] || [ -z "$compressed_size" ]; then
        echo "Unknown"
        return 1
    fi

    # Validate numeric inputs
    if ! [[ "$original_size" =~ ^[0-9]+$ ]] || ! [[ "$compressed_size" =~ ^[0-9]+$ ]]; then
        echo "Unknown"
        return 1
    fi

    if [ "$original_size" -eq 0 ]; then
        echo "Unknown"
        return 1
    fi

    local ratio
    if [ "$format" = "percent" ]; then
        ratio=$(echo "scale=2; (1 - $compressed_size / $original_size) * 100" | bc -l 2>/dev/null || echo "0")
        echo "${ratio}%"
    elif [ "$format" = "human" ]; then
        ratio=$(echo "scale=2; (1 - $compressed_size / $original_size) * 100" | bc -l 2>/dev/null || echo "0")
        echo "riduzione ${ratio}% (${original_size} → ${compressed_size})"
    else
        ratio=$(echo "scale=2; $original_size / $compressed_size" | bc -l 2>/dev/null || echo "1")
        echo "$ratio"
    fi
    return 0
}

# Calcola dimensione in formato human-readable con fallback
format_size_human() {
    local size_bytes="$1"

    # Input validation
    if [ -z "$size_bytes" ]; then
        echo "0B"
        return 1
    fi

    # Validate numeric input
    if ! [[ "$size_bytes" =~ ^[0-9]+$ ]]; then
        echo "0B"
        return 1
    fi

    if [ "$size_bytes" -lt 1 ]; then
        echo "0B"
        return 1
    fi

    # Use the manual formatting function
    format_size_manual "$size_bytes"
}

# Manual size formatting fallback
format_size_manual() {
    local size_bytes="$1"
    
    if [ "$size_bytes" -ge 1099511627776 ]; then  # >= 1TB
        echo "$(echo "scale=1; $size_bytes / 1099511627776" | bc 2>/dev/null || echo "0")TB"
    elif [ "$size_bytes" -ge 1073741824 ]; then   # >= 1GB
        echo "$(echo "scale=1; $size_bytes / 1073741824" | bc 2>/dev/null || echo "0")GB"
    elif [ "$size_bytes" -ge 1048576 ]; then      # >= 1MB
        echo "$(echo "scale=1; $size_bytes / 1048576" | bc 2>/dev/null || echo "0")MB"
    elif [ "$size_bytes" -ge 1024 ]; then         # >= 1KB
        echo "$(echo "scale=1; $size_bytes / 1024" | bc 2>/dev/null || echo "0")KB"
    else
        echo "${size_bytes}B"
    fi
}

# Calcola la dimensione di un file
get_file_size() {
    local file_path="$1"

    if [ ! -f "$file_path" ]; then
        echo "0"
        return 1
    fi

    stat -c%s "$file_path" 2>/dev/null || echo "0"
}

# Calculate transfer speed
calculate_transfer_speed() {
    local size_bytes="$1"
    local elapsed_seconds="$2"
    local format="${3:-bytes}"  # 'bytes' o 'human'

    # Verifica che i parametri siano numeri validi
    if ! [[ "$size_bytes" =~ ^[0-9]+$ ]] || ! [[ "$elapsed_seconds" =~ ^[0-9]+$ ]] || [ "$elapsed_seconds" -eq 0 ]; then
        if [ "$format" = "human" ]; then
            echo "0 MB/s"
        else
            echo "0"
        fi
        return 1
    fi

    # Calculate speed in bytes/second
    local speed
    speed=$(echo "scale=2; $size_bytes / $elapsed_seconds" | bc 2>/dev/null || echo "0")

    # Rimuovi eventuali decimali per il formato bytes
    if [ "$format" = "bytes" ]; then
        speed=$(printf "%.0f" "$speed" 2>/dev/null)
    fi

    # Assicurati che speed sia un numero intero valido
    speed=${speed%.*}
    speed=${speed// /}

    # Verifica che sia un numero valido prima delle comparazioni
    if ! [[ "$speed" =~ ^[0-9]+$ ]]; then
        if [ "$format" = "human" ]; then
            echo "0 MB/s"
        else
            echo "0"
        fi
        return 1
    fi

    if [ "$format" = "human" ]; then
        # Converti in formato human-readable
        if [ "$speed" -gt 1073741824 ]; then  # > 1GB/s
            echo "$(echo "scale=2; $speed/1073741824" | bc) GB/s"
        elif [ "$speed" -gt 1048576 ]; then   # > 1MB/s
            echo "$(echo "scale=2; $speed/1048576" | bc) MB/s"
        elif [ "$speed" -gt 1024 ]; then      # > 1KB/s
            echo "$(echo "scale=2; $speed/1024" | bc) KB/s"
        else
            echo "${speed} B/s"
        fi
    else
        echo "$speed"
    fi
}

# Calcola il tempo stimato rimanente
calculate_eta() {
    local remaining_size="$1"
    local speed="$2"
    local format="${3:-seconds}"  # 'seconds' o 'human'

    # Verifica che i parametri siano numeri validi
    if ! [[ "$remaining_size" =~ ^[0-9]+$ ]] || ! [[ "$speed" =~ ^[0-9]+$ ]] || [ "$speed" -lt 1 ]; then
        if [ "$format" = "human" ]; then
            echo "0s"
        else
            echo "0"
        fi
        return 1
    fi

    # Calcola l'ETA in secondi
    local eta
    eta=$(echo "scale=0; $remaining_size / $speed" | bc 2>/dev/null || echo "0")

    # Assicurati che eta sia un numero intero valido
    eta=$(printf "%.0f" "$eta" 2>/dev/null)
    # Rimuovi eventuali decimali residui e spazi
    eta=${eta%.*}
    eta=${eta// /}

    # Verifica che sia un numero valido prima delle comparazioni
    if ! [[ "$eta" =~ ^[0-9]+$ ]]; then
        if [ "$format" = "human" ]; then
            echo "0s"
        else
            echo "0"
        fi
        return 1
    fi

    if [ "$format" = "human" ]; then
        # Converti in formato human-readable
        if [ "$eta" -gt 86400 ]; then  # > 24h
            local days=$((eta / 86400))
            local hours=$(( (eta % 86400) / 3600 ))
            echo "${days}d ${hours}h"
        elif [ "$eta" -gt 3600 ]; then  # > 1h
            local hours=$((eta / 3600))
            local minutes=$(( (eta % 3600) / 60 ))
            echo "${hours}h ${minutes}m"
        elif [ "$eta" -gt 60 ]; then    # > 1m
            local minutes=$((eta / 60))
            local seconds=$((eta % 60))
            echo "${minutes}m ${seconds}s"
        else
            echo "${eta}s"
        fi
    else
        echo "$eta"
    fi
}

# Calcola la dimensione dei backup in una directory
calculate_backups_size() {
    local backup_dir="$1"
    local pattern="$2"
    local format="${3:-bytes}"  # 'bytes' o 'human'

    # Utilizza get_dir_size come funzione base, escludendo automaticamente i file .sha256
    get_dir_size "$backup_dir" "$pattern" "*.sha256" "$format"
}

# Funzione centralizzata per formattare la durata
format_duration() {
    local duration_seconds="$1"

    if [ -z "$duration_seconds" ] || [ "$duration_seconds" -lt 0 ]; then
        echo "00:00:00"
        return 1
    fi

    printf '%02d:%02d:%02d' $((duration_seconds / 3600)) $((duration_seconds % 3600 / 60)) $((duration_seconds % 60))
}

# Funzione centralizzata per formattare la durata in modo human-readable
format_duration_human() {
    local duration_seconds="$1"

    if [ -z "$duration_seconds" ] || [ "$duration_seconds" -lt 0 ]; then
        echo "0s"
        return 1
    fi

    if [ "$duration_seconds" -gt 3600 ]; then
        echo "$(($duration_seconds / 3600))h $(($duration_seconds % 3600 / 60))m"
    elif [ "$duration_seconds" -gt 60 ]; then
        echo "$(($duration_seconds / 60))m $(($duration_seconds % 60))s"
    else
        echo "${duration_seconds}s"
    fi
}

# Convert sizes between different units of measurement
convert_size() {
    local size="$1"
    local from_unit="${2:-B}"  # Default: Byte
    local to_unit="${3:-B}"    # Default: Byte

    if [ -z "$size" ] || ! [[ "$size" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        echo "0"
        return 1
    fi

    # Converti input in byte
    local size_in_bytes
    case "$from_unit" in
        "B")  size_in_bytes="$size" ;;
        "KB") size_in_bytes=$(echo "scale=0; $size * 1024" | bc) ;;
        "MB") size_in_bytes=$(echo "scale=0; $size * 1024 * 1024" | bc) ;;
        "GB") size_in_bytes=$(echo "scale=0; $size * 1024 * 1024 * 1024" | bc) ;;
        "TB") size_in_bytes=$(echo "scale=0; $size * 1024 * 1024 * 1024 * 1024" | bc) ;;
        *)    size_in_bytes="$size" ;;
    esac

    # Convert from bytes to desired unit
    local result
    case "$to_unit" in
        "B")  result="$size_in_bytes" ;;
        "KB") result=$(echo "scale=2; $size_in_bytes / 1024" | bc) ;;
        "MB") result=$(echo "scale=2; $size_in_bytes / 1024 / 1024" | bc) ;;
        "GB") result=$(echo "scale=2; $size_in_bytes / 1024 / 1024 / 1024" | bc) ;;
        "TB") result=$(echo "scale=2; $size_in_bytes / 1024 / 1024 / 1024 / 1024" | bc) ;;
        *)    result="$size_in_bytes" ;;
    esac

    echo "$result"
    return 0
}

# CLEANUP AND ERROR HANDLING
# ==========================
# Enhanced cleanup and error handling functions for metrics module

# Cleanup function for metrics module
cleanup_metrics() {
    local exit_code="${1:-0}"
    
    debug "Cleaning up metrics module resources"
    
    # Release any held locks
    release_metrics_lock "cleanup"
    
    # Clean up temporary files
    if [ -n "$METRICS_LOCK_FILE" ] && [ -f "$METRICS_LOCK_FILE" ]; then
        rm -f "$METRICS_LOCK_FILE" 2>/dev/null
    fi
    
    # Clean up any orphaned temporary files from this session
    find /tmp -name "backup_process_*_$$.pid" -mtime +1 -delete 2>/dev/null || true
    find /tmp -name "backup_manager_*_$$.lock" -mtime +1 -delete 2>/dev/null || true
    find /tmp -name "proxmox_backup_metrics_$$.lock" -mtime +1 -delete 2>/dev/null || true
    
    debug "Metrics module cleanup completed with exit code: $exit_code"
    return "$exit_code"
}

# Enhanced error reporting for metrics operations
report_metrics_error() {
    local operation="$1"
    local error_message="$2"
    local error_level="${3:-warning}"
    
    # Log the error
    case "$error_level" in
        "critical")
            error "METRICS ERROR [$operation]: $error_message"
            ;;
        "warning")
            warning "METRICS WARNING [$operation]: $error_message"
            ;;
        *)
            info "METRICS INFO [$operation]: $error_message"
            ;;
    esac
    
    # If error tracking is available, add to error list
    if declare -f add_error >/dev/null 2>&1; then
        add_error "metrics" "$error_level" "$operation" "$error_message"
    fi
    
    # Update metrics status if Prometheus is enabled
    if [ "$PROMETHEUS_ENABLED" == "true" ]; then
        case "$error_level" in
            "critical")
                save_metric "proxmox_backup_metrics_errors_total" "1" "severity=\"critical\",operation=\"$operation\""
                ;;
            "warning")
                save_metric "proxmox_backup_metrics_errors_total" "1" "severity=\"warning\",operation=\"$operation\""
                ;;
        esac
    fi
}

# Validate Proxmox environment for metrics collection
validate_proxmox_environment() {
    debug "Validating Proxmox environment for metrics collection"
    
    # Check if we're running on a Proxmox system
    if [ ! -f /etc/pve/local/pve-ssl.pem ] && [ ! -f /etc/proxmox-backup/proxy.key ]; then
        warning "Not running on a detected Proxmox system, some metrics may be limited"
        return 1
    fi
    
    # Validate Proxmox type
    if [ -z "$PROXMOX_TYPE" ]; then
        warning "PROXMOX_TYPE not set, defaulting to 've'"
        PROXMOX_TYPE="ve"
    fi
    
    # Validate storage paths exist
    local validation_errors=0
    
    if [ -n "$LOCAL_BACKUP_PATH" ] && [ ! -d "$LOCAL_BACKUP_PATH" ]; then
        report_metrics_error "validation" "Local backup path does not exist: $LOCAL_BACKUP_PATH" "warning"
        validation_errors=$((validation_errors + 1))
    fi
    
    if [ "${ENABLE_SECONDARY_BACKUP:-false}" = "true" ] && [ -n "$SECONDARY_BACKUP_PATH" ] && [ ! -d "$SECONDARY_BACKUP_PATH" ]; then
        report_metrics_error "validation" "Secondary backup path does not exist: $SECONDARY_BACKUP_PATH" "warning"
        validation_errors=$((validation_errors + 1))
    fi
    
    if [ "$validation_errors" -gt 0 ]; then
        warning "Proxmox environment validation completed with $validation_errors warnings"
        return 2
    fi
    
    debug "Proxmox environment validation successful"
    return 0
}

# Set up signal handlers for graceful shutdown
setup_metrics_signal_handlers() {
    # Set up cleanup on exit
    trap 'cleanup_metrics $?' EXIT
    
    # Set up cleanup on signals
    trap 'cleanup_metrics 1' TERM INT
    
    debug "Metrics signal handlers configured"
}

# Initialize metrics module with enhanced error handling
initialize_metrics_module() {
    debug "Initializing metrics module"
    
    # Set up signal handlers
    setup_metrics_signal_handlers
    
    # Validate environment
    if ! validate_proxmox_environment; then
        warning "Metrics module initialized with environment warnings"
    fi
    
    # Initialize Prometheus metrics if enabled
    if [ "$PROMETHEUS_ENABLED" == "true" ]; then
        if ! initialize_prometheus_metrics; then
            report_metrics_error "initialization" "Failed to initialize Prometheus metrics" "warning"
        fi
    fi
    
    debug "Metrics module initialization completed"
    return 0
}

# Test function for metrics module
test_metrics_module() {
    echo -e "${GREEN}[INFO] Testing metrics module functionality${RESET}"
    
    local test_errors=0
    
    # Test dependency validation
    if ! validate_metrics_dependencies; then
        echo -e "${RED}[ERROR] Dependency validation failed${RESET}"
        test_errors=$((test_errors + 1))
    fi
    
    # Test basic metric operations
    if save_metric "test_metric" "100" "test=\"true\""; then
        local retrieved_value=$(get_metric "test_metric" "test=\"true\"")
        if [ "$retrieved_value" = "100" ]; then
            echo -e "${GREEN}[OK] Basic metric operations working${RESET}"
        else
            echo -e "${RED}[ERROR] Metric retrieval failed: expected 100, got $retrieved_value${RESET}"
            test_errors=$((test_errors + 1))
        fi
    else
        echo -e "${RED}[ERROR] Metric save operation failed${RESET}"
        test_errors=$((test_errors + 1))
    fi
    
    # Test calculation functions
    local test_ratio=$(calculate_compression_ratio "1000" "500" "percent")
    if [[ "$test_ratio" =~ ^50\.00% ]]; then
        echo -e "${GREEN}[OK] Compression ratio calculation working${RESET}"
    else
        echo -e "${RED}[ERROR] Compression ratio calculation failed: got $test_ratio${RESET}"
        test_errors=$((test_errors + 1))
    fi
    
    # Test size formatting
    local test_size=$(format_size_human "1048576")
    if [[ "$test_size" =~ ^1\.0MB$ ]] || [[ "$test_size" =~ ^1\.0MiB$ ]]; then
        echo -e "${GREEN}[OK] Size formatting working${RESET}"
    else
        echo -e "${RED}[ERROR] Size formatting failed: got $test_size${RESET}"
        test_errors=$((test_errors + 1))
    fi
    
    if [ "$test_errors" -eq 0 ]; then
        echo -e "${GREEN}[SUCCESS] All metrics module tests passed${RESET}"
        return 0
    else
        echo -e "${RED}[FAILURE] Metrics module tests failed with $test_errors errors${RESET}"
        return 1
    fi
}

# Initialize the module when sourced
if [ "${BASH_SOURCE[0]}" != "${0}" ]; then
    # Module is being sourced, initialize it
    initialize_metrics_module
fi

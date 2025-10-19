#!/bin/bash
##
# Proxmox Backup System - Metrics Collection Library
# File: metrics_collect.sh
# Version: 0.2.4
# Last Modified: 2025-10-19
# Changes: Remove duplicate system metrics collection
##

# Funzione per raccogliere tutte le metriche del backup
collect_metrics() {
    step "Collecting system metrics"
    debug "=== collect_metrics() started - Initial EXIT_CODE: ${EXIT_CODE} ==="

    # Collect system statistics (now variables are already declared)
    SYSTEM_LOAD_AVG=$(cat /proc/loadavg 2>/dev/null | awk '{print $1" "$2" "$3}' || echo "N/A")

    if [ -f /proc/meminfo ]; then
        SYSTEM_MEM_TOTAL=$(grep MemTotal /proc/meminfo | awk '{print $2}')
        SYSTEM_MEM_FREE=$(grep MemAvailable /proc/meminfo | awk '{print $2}')
        if [ -n "$SYSTEM_MEM_TOTAL" ] && [ -n "$SYSTEM_MEM_FREE" ]; then
            SYSTEM_MEM_USED=$((SYSTEM_MEM_TOTAL - SYSTEM_MEM_FREE))
        fi
    fi

    # Calculate CPU usage
    if command -v top &>/dev/null; then
        SYSTEM_CPU_USAGE=$(top -bn1 | grep "Cpu(s)" | sed "s/.*, *\([0-9.]*\)%* id.*/\1/" | awk '{print 100 - $1}')
    fi

    # Global variables for backup counts
    BACKUP_PRI_COUNT=0
    BACKUP_SEC_COUNT=0
    BACKUP_CLO_COUNT=0

    # Global variables for log counts
    LOG_PRI_COUNT=0
    LOG_SEC_COUNT=0
    LOG_CLO_COUNT=0

    # Variables for maximum limits (o usa valori predefiniti)
    BACKUP_PRI_MAX=${MAX_LOCAL_BACKUPS:-50}
    BACKUP_SEC_MAX=${MAX_SECONDARY_BACKUPS:-50}
    BACKUP_CLO_MAX=${MAX_CLOUD_BACKUPS:-50}
    LOG_PRI_MAX=${MAX_LOCAL_LOGS:-50}
    LOG_SEC_MAX=${MAX_SECONDARY_LOGS:-50}
    LOG_CLO_MAX=${MAX_CLOUD_LOGS:-50}

    # Variabili per lo stato
    BACKUP_PRI_STATUS="OK"
    BACKUP_SEC_STATUS="OK"
    BACKUP_CLO_STATUS="OK"

    # Pattern per il nome dei file
    local pattern="${PROXMOX_TYPE}-backup-*.tar*"
    local log_pattern="${PROXMOX_TYPE}-backup-*.log"

    # Initialize global variables for metrics
    # Informazioni sul backup
    BACKUP_SIZE=0
    BACKUP_SIZE_HUMAN="0B"
    FILES_INCLUDED=0
    COMPRESSION_RATIO="0%"

    # Inizializzo variabili per i diversi timestamp
    START_TIME=${START_TIME:-$(date +%s)}
    END_TIME=0

    # Nuove metriche per lo spazio su disco
    DISK_SPACE_PRIMARY_TOTAL=0
    DISK_SPACE_PRIMARY_FREE=0
    DISK_SPACE_PRIMARY_USED=0
    DISK_SPACE_PRIMARY_PERC=0
    DISK_SPACE_SECONDARY_TOTAL=0
    DISK_SPACE_SECONDARY_FREE=0
    DISK_SPACE_SECONDARY_USED=0
    DISK_SPACE_SECONDARY_PERC=0

    # Backup age (in days)
    BACKUP_PRI_OLDEST_AGE=0
    BACKUP_PRI_NEWEST_AGE=0
    BACKUP_PRI_AVG_AGE=0
    BACKUP_SEC_OLDEST_AGE=0
    BACKUP_SEC_NEWEST_AGE=0
    BACKUP_SEC_AVG_AGE=0
    BACKUP_CLO_OLDEST_AGE=0
    BACKUP_CLO_NEWEST_AGE=0

    # Backup speed statistics
    BACKUP_SPEED=0
    BACKUP_SPEED_HUMAN="0 MB/s"
    BACKUP_TIME_ESTIMATE=0
    BACKUP_TIME_ESTIMATE_HUMAN="0m"

    # Tempistiche dettagliate (in secondi dall'epoca e in formato data leggibile)
    BACKUP_PRI_CREATION_TIME=0
    BACKUP_PRI_CREATION_TIME_HUMAN=""
    BACKUP_SEC_COPY_TIME=0
    BACKUP_SEC_COPY_TIME_HUMAN=""
    BACKUP_CLO_UPLOAD_TIME=0
    BACKUP_CLO_UPLOAD_TIME_HUMAN=""
    BACKUP_DURATION_PRIMARY=0
    BACKUP_DURATION_SECONDARY=0
    BACKUP_DURATION_CLOUD=0
    BACKUP_DURATION_PRIMARY_HUMAN=""
    BACKUP_DURATION_SECONDARY_HUMAN=""
    BACKUP_DURATION_CLOUD_HUMAN=""

    # Emoji per gli stati
    EMOJI_SUCCESS="✅"
    EMOJI_WARNING="⚠️"
    EMOJI_ERROR="❌"
    EMOJI_SKIP="➖"
    EMOJI_INFO="ℹ️"
    EMOJI_PENDING="⏳"

    # Conta backup primari usando la funzione centralizzata
    if [ -d "$LOCAL_BACKUP_PATH" ]; then
        # Use new counting system instead of centralized count_backups function
        CHECK_COUNT "BACKUP_PRIMARY" true  # Silent mode
        BACKUP_PRI_COUNT=$COUNT_BACKUP_PRIMARY

        # Calculate primary backup age (now variables are already declared)
        if [ "$BACKUP_PRI_COUNT" -gt 0 ]; then
            # Find oldest backup
            local oldest_backup=$(find_oldest_file "$LOCAL_BACKUP_PATH" "$pattern" "*.sha256")
            if [ -n "$oldest_backup" ]; then
                BACKUP_PRI_OLDEST_AGE=$(get_file_age "$oldest_backup")
            fi

            # Find newest backup
            local newest_backup=$(find_newest_file "$LOCAL_BACKUP_PATH" "$pattern" "*.sha256")
            if [ -n "$newest_backup" ]; then
                BACKUP_PRI_NEWEST_AGE=$(get_file_age "$newest_backup")
            fi

            # Calculate average age
            local sum_age=0
            local count=0

            # Get all files and their ages
            local timestamp_file=$(create_temp_file "timestamps")
            get_file_timestamps "$LOCAL_BACKUP_PATH" "$pattern" "*.sha256" > "$timestamp_file"

            while read -r timestamp_line; do
                local timestamp=$(echo "$timestamp_line" | cut -d' ' -f1)
                local file=$(echo "$timestamp_line" | cut -d' ' -f2-)
                local age=$(get_file_age "$file")
                sum_age=$((sum_age + age))
                count=$((count + 1))
            done < "$timestamp_file"

            cleanup_temp_file "$timestamp_file"

            if [ "$count" -gt 0 ]; then
                BACKUP_PRI_AVG_AGE=$((sum_age / count))
            fi
        fi

        # Calculate disk space for primary path
        if [ -d "$LOCAL_BACKUP_PATH" ]; then
            local disk_info=$(get_disk_info "$LOCAL_BACKUP_PATH" "text")
            if [ $? -eq 0 ]; then
                DISK_SPACE_PRIMARY_TOTAL=$(echo "$disk_info" | grep -o "total=[0-9]*" | cut -d= -f2)
                DISK_SPACE_PRIMARY_FREE=$(echo "$disk_info" | grep -o "free=[0-9]*" | cut -d= -f2)
                DISK_SPACE_PRIMARY_USED=$(echo "$disk_info" | grep -o "used=[0-9]*" | cut -d= -f2)
                DISK_SPACE_PRIMARY_PERC=$(echo "$disk_info" | grep -o "percent=[0-9]*" | cut -d= -f2)
            fi
        fi

        # Calculate total size of primary backups using centralized function
        BACKUP_PRI_TOTAL_SIZE=0
        BACKUP_PRI_TOTAL_SIZE_HUMAN="0B"
        local total_size=$(get_dir_size "$LOCAL_BACKUP_PATH" "$pattern" "*.sha256" "bytes")
        if [ -n "$total_size" ] && [ "$total_size" -gt 0 ]; then
            BACKUP_PRI_TOTAL_SIZE=$total_size
            BACKUP_PRI_TOTAL_SIZE_HUMAN=$(format_size_human "$total_size")
        fi
    fi

    # Count secondary backups using new counting system
    if [ "${ENABLE_SECONDARY_BACKUP:-false}" = "true" ] && [ -d "$SECONDARY_BACKUP_PATH" ]; then
        # Use new counting system instead of centralized count_backups function
        CHECK_COUNT "BACKUP_SECONDARY" true  # Silent mode
        BACKUP_SEC_COUNT=$COUNT_BACKUP_SECONDARY
        # Limit count to maximum allowed for safety
        if [ "$BACKUP_SEC_COUNT" -gt "$BACKUP_SEC_MAX" ]; then
            BACKUP_SEC_COUNT="$BACKUP_SEC_MAX"
        fi

        # Calculate total size of secondary backups using centralized function
        BACKUP_SEC_TOTAL_SIZE=0
        BACKUP_SEC_TOTAL_SIZE_HUMAN="0B"
        local total_size=$(get_dir_size "$SECONDARY_BACKUP_PATH" "$pattern" "*.sha256" "bytes")
        if [ -n "$total_size" ] && [ "$total_size" -gt 0 ]; then
            BACKUP_SEC_TOTAL_SIZE=$total_size
            BACKUP_SEC_TOTAL_SIZE_HUMAN=$(format_size_human "$total_size")
        fi
    else
        # Secondary backup disabilitato o percorso non disponibile
        BACKUP_SEC_COUNT=0
        BACKUP_SEC_TOTAL_SIZE=0
        BACKUP_SEC_TOTAL_SIZE_HUMAN="0B"
        local is_secondary_configured=false
        local emoji_value=$(get_status_emoji "backup" "secondary")
        EMOJI_SEC="$emoji_value"
    fi

    # Calculate disk space for secondary path
    # Check both that the directory exists and that secondary backup is enabled
    if [ "${ENABLE_SECONDARY_BACKUP:-false}" = "true" ] && [ -d "$SECONDARY_BACKUP_PATH" ]; then
        local disk_info=$(get_disk_info "$SECONDARY_BACKUP_PATH" "text")
        if [ $? -eq 0 ]; then
            DISK_SPACE_SECONDARY_TOTAL=$(echo "$disk_info" | grep -o "total=[0-9]*" | cut -d= -f2)
            DISK_SPACE_SECONDARY_FREE=$(echo "$disk_info" | grep -o "free=[0-9]*" | cut -d= -f2)
            DISK_SPACE_SECONDARY_USED=$(echo "$disk_info" | grep -o "used=[0-9]*" | cut -d= -f2)
            DISK_SPACE_SECONDARY_PERC=$(echo "$disk_info" | grep -o "percent=[0-9]*" | cut -d= -f2)
        fi
    else
        # If secondary backup is disabled, set null values
        DISK_SPACE_SECONDARY_TOTAL=0
        DISK_SPACE_SECONDARY_FREE=0
        DISK_SPACE_SECONDARY_USED=0
        DISK_SPACE_SECONDARY_PERC=0
    fi

    # Count cloud backups using new counting system
    if [ "${ENABLE_CLOUD_BACKUP:-true}" = "true" ] && [ "${METRICS_NO_RCLONE:-false}" != "true" ]; then
        if [ -n "${RCLONE_REMOTE}" ] && [ -n "${CLOUD_BACKUP_PATH}" ]; then
            # Use new counting system instead of centralized count_backups function
            CHECK_COUNT "BACKUP_CLOUD" true  # Silent mode
            BACKUP_CLO_COUNT=$COUNT_BACKUP_CLOUD
            
            # Limit count to maximum allowed for safety
            if [ "$BACKUP_CLO_COUNT" -gt "$BACKUP_CLO_MAX" ]; then
                BACKUP_CLO_COUNT="$BACKUP_CLO_MAX"
            fi
            
            local cloud_backups=$(mktemp)

                # If possible, calculate total size of cloud backups
                BACKUP_CLO_TOTAL_SIZE=0
                BACKUP_CLO_TOTAL_SIZE_HUMAN="0B"
                if [ "${METRICS_NO_JQ:-false}" != "true" ]; then
                    if timeout "$METRICS_CLOUD_TIMEOUT" rclone size "${RCLONE_REMOTE}:${CLOUD_BACKUP_PATH}" --json 2>/dev/null > "$cloud_backups"; then
                        local cloud_size=$(jq -r '.bytes' "$cloud_backups" 2>/dev/null)
                        if [ -n "$cloud_size" ] && [ "$cloud_size" != "null" ] && [[ "$cloud_size" =~ ^[0-9]+$ ]]; then
                            BACKUP_CLO_TOTAL_SIZE=$cloud_size
                            BACKUP_CLO_TOTAL_SIZE_HUMAN=$(format_size_human "$cloud_size")
                        fi
                    fi
                else
                    debug "jq not available, skipping cloud size calculation"
                fi
            rm -f "$cloud_backups" 2>/dev/null
        else
            debug "Cloud backup configuration incomplete"
            BACKUP_CLO_COUNT=0
        fi
    else
        debug "Cloud backup disabled or rclone not available"
        BACKUP_CLO_COUNT=0
    fi

    # Use new unified counting system for logs
    # CHECK_COUNT "LOG_ALL" already called in main script - reuse variables
    
    # Log primari - usa variabile dal sistema unificato
    LOG_PRI_COUNT=$COUNT_LOG_PRIMARY
    if [ -d "$LOCAL_LOG_PATH" ] && [ "$LOG_PRI_COUNT" -gt 0 ]; then
        # Calculate primary log age
        # Find oldest log
        local oldest_log=$(find "$LOCAL_LOG_PATH" -maxdepth 1 -type f -name "$log_pattern" -not -name "*.log.*" -printf "%T@ %p\n" | sort -n | head -1)
        local oldest_timestamp=$(echo "$oldest_log" | cut -d' ' -f1)
        LOG_PRI_OLDEST_AGE=$(( ($(date +%s) - ${oldest_timestamp%.*}) / 86400 ))

        # Find newest log
        local newest_log=$(find "$LOCAL_LOG_PATH" -maxdepth 1 -type f -name "$log_pattern" -not -name "*.log.*" -printf "%T@ %p\n" | sort -nr | head -1)
        local newest_timestamp=$(echo "$newest_log" | cut -d' ' -f1)
        LOG_PRI_NEWEST_AGE=$(( ($(date +%s) - ${newest_timestamp%.*}) / 86400 ))

        # Calculate average age - usa array temporaneo invece di pipe
        local sum_age=0
        local count=0

        # Get all files and their ages
        local timestamp_file=$(create_temp_file "log_timestamps")
        get_file_timestamps "$LOCAL_LOG_PATH" "$log_pattern" "*.log.*" > "$timestamp_file"

        while read -r timestamp_line; do
            local timestamp=$(echo "$timestamp_line" | cut -d' ' -f1)
            local age=$(get_file_age "$timestamp_line")
            sum_age=$((sum_age + age))
            count=$((count + 1))
        done < "$timestamp_file"

        cleanup_temp_file "$timestamp_file"

        if [ "$count" -gt 0 ]; then
            LOG_PRI_AVG_AGE=$((sum_age / count))
        fi

        # Calcola dimensione totale dei log primari
        LOG_PRI_TOTAL_SIZE=0
        LOG_PRI_TOTAL_SIZE_HUMAN="0B"

        # Creiamo un file temporaneo per salvare l'output
        local temp_file=$(mktemp)

        # Eseguiamo il comando e salviamo l'output in un file temporaneo
        find "$LOCAL_LOG_PATH" -maxdepth 1 -type f -name "$log_pattern" -not -name "*.log.*" -exec du -bc {} \; 2>/dev/null > "$temp_file" || true

        # Estrai la riga del totale e ottieni solo il valore numerico
        local total_size=$(grep "total$" "$temp_file" | awk '{print $1}')

        # Pulisci il file temporaneo
        rm -f "$temp_file"

        # Verifica che il risultato sia un numero valido
        if [ -n "$total_size" ] && [[ "$total_size" =~ ^[0-9]+$ ]]; then
            LOG_PRI_TOTAL_SIZE=$total_size
            LOG_PRI_TOTAL_SIZE_HUMAN=$(format_size_human "$total_size")
        fi
    else
        # No primary logs or directory not available
        LOG_PRI_OLDEST_AGE=0
        LOG_PRI_NEWEST_AGE=0
        LOG_PRI_AVG_AGE=0
        LOG_PRI_TOTAL_SIZE=0
        LOG_PRI_TOTAL_SIZE_HUMAN="0B"
    fi

    # Log secondari - usa variabile dal sistema unificato
    LOG_SEC_COUNT=$COUNT_LOG_SECONDARY
    if [ "${ENABLE_SECONDARY_BACKUP:-false}" = "true" ] && [ -d "$SECONDARY_LOG_PATH" ] && [ "$LOG_SEC_COUNT" -gt 0 ]; then
        # Calculate secondary log age
        # Find oldest log
        local oldest_log=$(find "$SECONDARY_LOG_PATH" -maxdepth 1 -type f -name "$log_pattern" -not -name "*.log.*" -printf "%T@ %p\n" | sort -n | head -1)
        local oldest_timestamp=$(echo "$oldest_log" | cut -d' ' -f1)
        LOG_SEC_OLDEST_AGE=$(( ($(date +%s) - ${oldest_timestamp%.*}) / 86400 ))

        # Find newest log
        local newest_log=$(find "$SECONDARY_LOG_PATH" -maxdepth 1 -type f -name "$log_pattern" -not -name "*.log.*" -printf "%T@ %p\n" | sort -nr | head -1)
        local newest_timestamp=$(echo "$newest_log" | cut -d' ' -f1)
        LOG_SEC_NEWEST_AGE=$(( ($(date +%s) - ${newest_timestamp%.*}) / 86400 ))

        # Calcola dimensione totale dei log secondari
        LOG_SEC_TOTAL_SIZE=0
        LOG_SEC_TOTAL_SIZE_HUMAN="0B"
        local total_size=$(get_dir_size "$SECONDARY_LOG_PATH" "$log_pattern" "*.log.*" "bytes")
        if [ -n "$total_size" ] && [ "$total_size" -gt 0 ]; then
            LOG_SEC_TOTAL_SIZE=$total_size
            LOG_SEC_TOTAL_SIZE_HUMAN=$(format_size_human "$total_size")
        fi
    else
        # Secondary backup disabilitato o percorso non disponibile
        LOG_SEC_TOTAL_SIZE=0
        LOG_SEC_TOTAL_SIZE_HUMAN="0B"
        LOG_SEC_OLDEST_AGE=0
        LOG_SEC_NEWEST_AGE=0
        local is_secondary_configured=false
        local emoji_value=$(get_status_emoji "log" "secondary")
        LOG_SEC_EMOJI="$emoji_value"
    fi

    # Log cloud - usa variabile dal sistema unificato
    LOG_CLO_COUNT=$COUNT_LOG_CLOUD
    if [ "${ENABLE_CLOUD_BACKUP:-true}" = "true" ] && command -v rclone &>/dev/null; then
        if [ -n "${RCLONE_REMOTE}" ] && [ -n "${CLOUD_LOG_PATH}" ] && [ "$LOG_CLO_COUNT" -gt 0 ]; then
            # Limit count to maximum allowed for safety
            if [ "$LOG_CLO_COUNT" -gt "$LOG_CLO_MAX" ]; then
                LOG_CLO_COUNT="$LOG_CLO_MAX"
            fi

            # Se possibile, calcola la dimensione totale dei log su cloud
            LOG_CLO_TOTAL_SIZE=0
            LOG_CLO_TOTAL_SIZE_HUMAN="0B"
            local cloud_logs=$(mktemp)
            if rclone size "${RCLONE_REMOTE}:${CLOUD_LOG_PATH}" --json 2>/dev/null > "$cloud_logs"; then
                local cloud_size=$(jq -r '.bytes' "$cloud_logs" 2>/dev/null)
                if [ -n "$cloud_size" ] && [ "$cloud_size" != "null" ]; then
                    LOG_CLO_TOTAL_SIZE=$cloud_size
                    LOG_CLO_TOTAL_SIZE_HUMAN=$(format_size_human "$cloud_size")
                fi
            fi
            rm -f "$cloud_logs" 2>/dev/null
        else
            # Cloud not configured or no logs
            LOG_CLO_TOTAL_SIZE=0
            LOG_CLO_TOTAL_SIZE_HUMAN="0B"
        fi
    else
        # Cloud backup disabilitato o rclone non disponibile
        LOG_CLO_TOTAL_SIZE=0
        LOG_CLO_TOTAL_SIZE_HUMAN="0B"
        local is_cloud_configured=false
        local emoji_value=$(get_status_emoji "log" "cloud")
        LOG_CLO_EMOJI="$emoji_value"
    fi

    # Imposta lo stato basato sulle operazioni
    if [ -n "${COPY_TO_SECONDARY+x}" ] && [ "$COPY_TO_SECONDARY" == "true" ] && [ "$BACKUP_SEC_COUNT" -eq 0 ]; then
        BACKUP_SEC_STATUS="WARNING"
    fi

    if [ -n "${UPLOAD_TO_CLOUD+x}" ] && [ "$UPLOAD_TO_CLOUD" == "true" ] && [ "$BACKUP_CLO_COUNT" -eq 0 ]; then
        BACKUP_CLO_STATUS="WARNING"
    fi

    # Verificare lo spazio libero su disco primario
    local primary_threshold=${STORAGE_WARNING_THRESHOLD_PRIMARY:-90}
    debug "Checking primary storage: ${DISK_SPACE_PRIMARY_PERC}% used, threshold: ${primary_threshold}%, current EXIT_CODE: ${EXIT_CODE}"
    if [ "$DISK_SPACE_PRIMARY_PERC" -gt "$primary_threshold" ]; then
        BACKUP_PRI_STATUS="WARNING"
        warning "Primary storage almost full: ${DISK_SPACE_PRIMARY_PERC}% used (threshold: ${primary_threshold}%)"
        debug "Setting EXIT_CODE to warning due to primary storage threshold exceeded"
        set_exit_code "warning"
        debug "After set_exit_code, EXIT_CODE is now: ${EXIT_CODE}"
    else
        debug "Primary storage usage is within threshold (${DISK_SPACE_PRIMARY_PERC}% <= ${primary_threshold}%)"
    fi

    # Verificare lo spazio libero su disco secondario
    local secondary_threshold=${STORAGE_WARNING_THRESHOLD_SECONDARY:-90}
    debug "Checking secondary storage: ${DISK_SPACE_SECONDARY_PERC}% used, threshold: ${secondary_threshold}%, current EXIT_CODE: ${EXIT_CODE}"
    if [ "$DISK_SPACE_SECONDARY_PERC" -gt "$secondary_threshold" ]; then
        BACKUP_SEC_STATUS="WARNING"
        warning "Secondary storage almost full: ${DISK_SPACE_SECONDARY_PERC}% used (threshold: ${secondary_threshold}%)"
        debug "Setting EXIT_CODE to warning due to secondary storage threshold exceeded"
        set_exit_code "warning"
        debug "After set_exit_code, EXIT_CODE is now: ${EXIT_CODE}"
    else
        debug "Secondary storage usage is within threshold (${DISK_SPACE_SECONDARY_PERC}% <= ${secondary_threshold}%)"
    fi

    # Calcola dimensione del backup corrente se disponibile
    if [ -n "$BACKUP_FILE" ] && [ -f "$BACKUP_FILE" ]; then
        # Uso le funzioni centralizzate per calcolare dimensioni
        BACKUP_SIZE=$(get_file_size "$BACKUP_FILE")
        BACKUP_SIZE_HUMAN=$(format_size_human "$BACKUP_SIZE")

        # Calcola numero di file nel backup usando funzione centralizzata
        if [ "${METRICS_NO_TAR:-false}" != "true" ]; then
            # Use centralized function instead of manual tar+wc counting
            BACKUP_FILES_COUNT=$(count_files_in_backup "$BACKUP_FILE")
            # Validate count is numeric
            if ! [[ "$BACKUP_FILES_COUNT" =~ ^[0-9]+$ ]]; then
                BACKUP_FILES_COUNT=0
            fi
        else
            debug "tar not available, skipping file count in backup"
            BACKUP_FILES_COUNT=0
        fi

        # Calcola efficienza compressione se disponibile l'archivio non compresso
        if [ -n "${TEMP_DIR}" ] && [ -d "${TEMP_DIR}" ] && [ -f "$BACKUP_FILE" ]; then
            # Usa la funzione centralizzata per ottenere tutti i dati di compressione
            local compression_data=$(get_compression_data "$TEMP_DIR" "$BACKUP_FILE" "all")

            # Extract values using a more robust approach
            COMPRESSION_RATIO=$(echo "$compression_data" | grep -o "ratio=[^[:space:]]*" | cut -d= -f2)

            # Estrai anche le dimensioni prima e dopo la compressione per le metriche
            uncompressed_size=$(echo "$compression_data" | grep -o "size_before=[^[:space:]]*" | cut -d= -f2)

            # Aggiorna le metriche Prometheus se abilitato
            if [ "$PROMETHEUS_ENABLED" == "true" ]; then
                # Update compression metrics
                update_prometheus_metrics "proxmox_backup_size_uncompressed_bytes" "gauge" "Size of backup before compression in bytes" "${uncompressed_size:-0}"

                # Update compression metric only if we have a valid value
                if [ "$COMPRESSION_RATIO" != "Unknown" ]; then
                    # Estrai il valore percentuale senza il simbolo %
                    local ratio_percent=$(echo "$compression_data" | grep -o "percent=[^[:space:]]*" | cut -d= -f2)
                    update_prometheus_metrics "proxmox_backup_compression_ratio" "gauge" "Compression ratio of backup" "${ratio_percent:-0}"
                fi
            fi
        fi

        # Calculate backup speed if execution time is available
        if [ -n "${BACKUP_START_TIME+x}" ] && [ "$BACKUP_START_TIME" != "" ]; then
            local current_time=$(date +%s)
            local elapsed_time=$((current_time - BACKUP_START_TIME))

            if [ "$elapsed_time" -gt 0 ] && [ "$BACKUP_SIZE" -gt 0 ]; then
                # Use centralized function to calculate speed
                BACKUP_SPEED=$(calculate_transfer_speed "$BACKUP_SIZE" "$elapsed_time" "bytes")
                BACKUP_SPEED_HUMAN=$(calculate_transfer_speed "$BACKUP_SIZE" "$elapsed_time" "human")
            else
                BACKUP_SPEED=0
                BACKUP_SPEED_HUMAN="0 MB/s"
            fi
        fi

        # Stima il tempo rimanente per completare il backup
        if [ -n "${EXPECTED_BACKUP_SIZE+x}" ] && [ "$EXPECTED_BACKUP_SIZE" != "" ] && [ "$EXPECTED_BACKUP_SIZE" -gt 0 ] && [ "$BACKUP_SPEED" -gt 0 ]; then
            local remaining_size=$((EXPECTED_BACKUP_SIZE - BACKUP_SIZE))
            if [ "$remaining_size" -gt 0 ]; then
                # Uso la funzione centralizzata per calcolare l'ETA
                BACKUP_TIME_ESTIMATE=$(calculate_eta "$remaining_size" "$BACKUP_SPEED" "seconds")
                BACKUP_TIME_ESTIMATE_HUMAN=$(calculate_eta "$remaining_size" "$BACKUP_SPEED" "human")
            else
                BACKUP_TIME_ESTIMATE=0
                BACKUP_TIME_ESTIMATE_HUMAN="0s"
            fi
        fi

        # Analizza il contenuto del backup con timeout se abbiamo tar
        if [ "${METRICS_NO_TAR:-false}" != "true" ] && [ "$BACKUP_FILES_COUNT" -gt 0 ]; then
            # Find largest files in backup with timeout protection
            BACKUP_LARGEST_FILES=""
            BACKUP_LARGEST_FILES_SIZE=0

            local largest_files_output=$(mktemp)
            if timeout "$METRICS_TAR_TIMEOUT" tar -tvf "$BACKUP_FILE" 2>/dev/null | sort -nr -k3 | head -5 > "$largest_files_output" 2>/dev/null; then
                BACKUP_LARGEST_FILES=$(cat "$largest_files_output" 2>/dev/null)
                # Sum of sizes of 5 largest files
                BACKUP_LARGEST_FILES_SIZE=$(awk '{sum+=$3} END {print sum}' "$largest_files_output" 2>/dev/null || echo "0")
                # Validate size is numeric
                if ! [[ "$BACKUP_LARGEST_FILES_SIZE" =~ ^[0-9]+$ ]]; then
                    BACKUP_LARGEST_FILES_SIZE=0
                fi
            else
                debug "Failed to analyze backup content or operation timed out"
            fi
            rm -f "$largest_files_output" 2>/dev/null
        fi
    fi

	# Formatta stringhe per backup con emoji
	BACKUP_PRI_STATUS_STR="$COUNT_BACKUP_PRIMARY/${BACKUP_PRI_MAX}"
    BACKUP_SEC_STATUS_STR="$COUNT_BACKUP_SECONDARY/${BACKUP_SEC_MAX}"
    BACKUP_CLO_STATUS_STR="$COUNT_BACKUP_CLOUD/${BACKUP_CLO_MAX}"

    BACKUP_PRI_STATUS_STR_EMOJI="${EMOJI_PRI} $BACKUP_PRI_STATUS_STR"
    BACKUP_SEC_STATUS_STR_EMOJI="${EMOJI_SEC} $BACKUP_SEC_STATUS_STR"
    BACKUP_CLO_STATUS_STR_EMOJI="${EMOJI_CLO} $BACKUP_CLO_STATUS_STR"

    # Formatta stringhe per log con emoji
    LOG_PRI_STATUS_STR="${LOG_PRI_COUNT}/${LOG_PRI_MAX}"
    LOG_SEC_STATUS_STR="${LOG_SEC_COUNT}/${LOG_SEC_MAX}"
    LOG_CLO_STATUS_STR="${LOG_CLO_COUNT}/${LOG_CLO_MAX}"
	
	LOG_PRI_STATUS_STR_EMOJI="${LOG_PRI_EMOJI} $LOG_PRI_STATUS_STR"
	LOG_SEC_STATUS_STR_EMOJI="${LOG_SEC_EMOJI} $LOG_SEC_STATUS_STR"
	LOG_CLO_STATUS_STR_EMOJI="${LOG_CLO_EMOJI} $LOG_CLO_STATUS_STR"

    # Imposta emoji globale in base al codice di uscita
    case $EXIT_CODE in
        0)
            BACKUP_STATUS_EMOJI="$EMOJI_SUCCESS"
            ;;
        1)
            BACKUP_STATUS_EMOJI="$EMOJI_WARNING"
            ;;
        *)
            BACKUP_STATUS_EMOJI="$EMOJI_ERROR"
            ;;
    esac

    # Calcola tempistiche dettagliate
    # Se abbiamo i timestamp di inizio/fine, calcola le durate
    if [ -n "${BACKUP_START_TIME+x}" ] && [ "$BACKUP_START_TIME" != "" ]; then
        # Backup primario
        if [ -n "${BACKUP_END_TIME+x}" ] && [ "$BACKUP_END_TIME" != "" ]; then
            BACKUP_PRI_CREATION_TIME=$BACKUP_END_TIME
            BACKUP_PRI_CREATION_TIME_HUMAN=$(format_timestamp "$BACKUP_END_TIME")
            BACKUP_DURATION_PRIMARY=$(calculate_time_difference "$BACKUP_START_TIME" "$BACKUP_END_TIME" "seconds")

            # Formatta la durata usando la funzione centralizzata
            BACKUP_DURATION_PRIMARY_HUMAN=$(format_duration_human "$BACKUP_DURATION_PRIMARY")
        fi

        # Backup secondario
        if [ -n "${SECONDARY_COPY_START_TIME+x}" ] && [ "$SECONDARY_COPY_START_TIME" != "" ] && [ -n "${SECONDARY_COPY_END_TIME+x}" ] && [ "$SECONDARY_COPY_END_TIME" != "" ]; then
            BACKUP_SEC_COPY_TIME=$SECONDARY_COPY_END_TIME
            BACKUP_SEC_COPY_TIME_HUMAN=$(format_timestamp "$SECONDARY_COPY_END_TIME")
            BACKUP_DURATION_SECONDARY=$(calculate_time_difference "$SECONDARY_COPY_START_TIME" "$SECONDARY_COPY_END_TIME" "seconds")

            # Formatta la durata usando la funzione centralizzata
            BACKUP_DURATION_SECONDARY_HUMAN=$(format_duration_human "$BACKUP_DURATION_SECONDARY")
        fi

        # Backup cloud
        if [ -n "${CLOUD_UPLOAD_START_TIME+x}" ] && [ "$CLOUD_UPLOAD_START_TIME" != "" ] && [ -n "${CLOUD_UPLOAD_END_TIME+x}" ] && [ "$CLOUD_UPLOAD_END_TIME" != "" ]; then
            BACKUP_CLO_UPLOAD_TIME=$CLOUD_UPLOAD_END_TIME
            BACKUP_CLO_UPLOAD_TIME_HUMAN=$(format_timestamp "$CLOUD_UPLOAD_END_TIME")
            BACKUP_DURATION_CLOUD=$(calculate_time_difference "$CLOUD_UPLOAD_START_TIME" "$CLOUD_UPLOAD_END_TIME" "seconds")

            # Formatta la durata usando la funzione centralizzata
            BACKUP_DURATION_CLOUD_HUMAN=$(format_duration_human "$BACKUP_DURATION_CLOUD")
        fi
    fi

    # Se non abbiamo i timestamp espliciti, prova a ricavarli dal file di backup principale
    if [ "$BACKUP_PRI_CREATION_TIME" -eq 0 ] && [ -n "$BACKUP_FILE" ] && [ -f "$BACKUP_FILE" ]; then
        local file_timestamp=$(get_file_timestamp "$BACKUP_FILE")
        if [ -n "$file_timestamp" ]; then
            BACKUP_PRI_CREATION_TIME=$file_timestamp
            BACKUP_PRI_CREATION_TIME_HUMAN=$(format_timestamp "$file_timestamp")
        fi
    fi
    # Raccolta informazioni sui file di backup
    count_backup_files

    debug "=== collect_metrics() completed - Final EXIT_CODE: ${EXIT_CODE} ==="
    success "Metrics collection completed"
}


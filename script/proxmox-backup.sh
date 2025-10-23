#!/bin/bash
##
# Proxmox Backup Script for PVE and PBS
# File: proxmox-backup.sh
# Version: 0.3.0
# Last Modified: 2025-10-23
# Changes: improve error handling and fix critical path/tracking bugs and fix race condition
#
# This script performs comprehensive backups for Proxmox VE and Proxmox Backup Server
# and uploads them to local, secondary, and cloud storage.
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

# ======= Loading VERSION file =======
VERSION_FILE="${BASE_DIR}/VERSION"
if [[ -f "$VERSION_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$VERSION_FILE"
fi

# ======= Loading .env before enabling set -u =======
if [[ -f "$ENV_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$ENV_FILE"
    echo "Proxmox Backup Script Version: ${SCRIPT_VERSION:-0.0.0}"
else
    echo "[WARNING] Configuration file not found: $ENV_FILE"
    SCRIPT_VERSION="${SCRIPT_VERSION:-0.0.0}"
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

PROXMOX_TYPE=""
TIMESTAMP=$(date +"%Y-%m-%d_%H-%M-%S")
START_TIME=$(date +%s)
END_TIME=""
BACKUP_DURATION=""
BACKUP_DURATION_FORMATTED=""
HOSTNAME=$(hostname -f)
EXIT_CODE=0
LOG_FILE=""
BACKUP_FILE=""
METRICS_FILE="/tmp/proxmox_backup_metrics_$$.prom"

# ==========================================
# MODULE IMPORTS
# ==========================================

# NOTE: .env has already been loaded above
source "${BASE_DIR}/lib/environment.sh"
source "${BASE_DIR}/lib/core.sh"
source "${BASE_DIR}/lib/log.sh"
source "${BASE_DIR}/lib/utils.sh"
source "${BASE_DIR}/lib/backup_collect.sh"
source "${BASE_DIR}/lib/backup_collect_pbspve.sh"
source "${BASE_DIR}/lib/backup_create.sh"
source "${BASE_DIR}/lib/backup_verify.sh"
source "${BASE_DIR}/lib/storage.sh"
source "${BASE_DIR}/lib/notify.sh"
source "${BASE_DIR}/lib/metrics.sh"
source "${BASE_DIR}/lib/security.sh"
source "${BASE_DIR}/lib/backup_manager.sh"
source "${BASE_DIR}/lib/utils_counting.sh"
source "${BASE_DIR}/lib/metrics_collect.sh" 

# ==========================================
# MAIN FUNCTIONS
# ==========================================

# Cleanup stale lock files at script startup
cleanup_stale_locks() {
    debug "Cleaning up stale lock files at startup"

    # Rimuove lock files orfani nella directory lock del progetto
    if [ -d "${BASE_DIR}/lock" ]; then
        # Cerca tutti i lock files e verifica se sono in uso
        find "${BASE_DIR}/lock" -name "*.lock" -type f 2>/dev/null | while read -r lock_file; do
            # Tenta di acquisire un lock non-bloccante
            # Se riesce, il file non è in uso e può essere rimosso
            if flock -n "$lock_file" true 2>/dev/null; then
                debug "Removing unused lock file: $lock_file"
                rm -f "$lock_file" 2>/dev/null || true
            else
                debug "Lock file in use, keeping: $lock_file"
            fi
        done
        debug "Cleaned up stale lock files in ${BASE_DIR}/lock/"
    fi

    # Rimuove anche vecchi lock files in /tmp (compatibilità con versioni precedenti)
    # Per questi usiamo il vecchio metodo basato su età perché sono temporanei
    find /tmp -name "backup_*_*.lock" -mmin +60 -delete 2>/dev/null || true
    find /tmp -name "proxmox_backup_metrics_*.lock" -mmin +60 -delete 2>/dev/null || true

    debug "Stale lock cleanup completed"
}

# Cleanup handler that properly manages the exit code
cleanup_handler() {
    # Save the original exit code
    local exit_status=$?
    
    # Disable errexit to ensure cleanup completes
    set +e
    
    debug "=== START CLEANUP_HANDLER ==="
    debug "Original exit status: $exit_status"
    debug "Current EXIT_CODE: $EXIT_CODE"
    debug "TEMP_DIR value: ${TEMP_DIR:-'not set'}"

    # Flush log buffer before cleanup to ensure all messages are written
    if command -v force_flush_log_buffer >/dev/null 2>&1; then
        debug "Flushing log buffer in cleanup handler"
        force_flush_log_buffer
    fi

    # Execute existing cleanup function - DOES NOT EXPORT PROMETHEUS HERE
    cleanup

    # Preserve original exit code if EXIT_CODE is still 0
    if [ $EXIT_CODE -eq 0 ] && [ $exit_status -ne 0 ]; then
        debug "Updating EXIT_CODE from 0 to $exit_status"
        EXIT_CODE=$exit_status
    fi
    
    # Additional cleanup of temporary directory if it still exists (with security guards)
    if [ -n "${TEMP_DIR:-}" ]; then
        debug "Additional cleanup of temporary directory in handler: $TEMP_DIR"
        if safe_cleanup_temp_dir; then
            debug "Temporary directory successfully removed in handler"
        else
            debug "Failed to remove temporary directory in handler (may have been skipped for security)"
        fi
    else
        debug "TEMP_DIR variable not set in cleanup handler"
    fi
    
    # Additional cleanup of metrics file if it still exists
    if [ -n "${METRICS_FILE:-}" ] && [ -f "${METRICS_FILE:-}" ]; then
        debug "Additional cleanup of metrics file in handler: $METRICS_FILE"
        if rm -f "${METRICS_FILE}" 2>/dev/null; then
            debug "Metrics file successfully removed in handler: $METRICS_FILE"
        else
            debug "Failed to remove metrics file in handler: $METRICS_FILE"
        fi
    fi
    
    # Additional cleanup of orphaned lock files (immediate removal for empty files)

    # Pulizia lock files nella directory del progetto
    if [ -d "${BASE_DIR}/lock" ]; then
        shopt -s nullglob
        local project_locks=("${BASE_DIR}/lock"/*.lock)
        shopt -u nullglob

        if [ ${#project_locks[@]} -eq 0 ]; then
            debug "No orphaned project lock files found in ${BASE_DIR}/lock"
        else
            debug "Found ${#project_locks[@]} project lock file(s) to check"
            for lock_file in "${project_locks[@]}"; do
                debug "Checking lock file in handler: $lock_file"
                # Non rimuoviamo se il lock è ancora attivo (flock check)
                if ! flock -n "$lock_file" true 2>/dev/null; then
                    debug "Lock file still in use, skipping: $lock_file"
                else
                    debug "Removing unused lock file in handler: $lock_file"
                    rm -f "$lock_file" 2>/dev/null || true
                fi
            done
        fi
    fi

    # Pulizia vecchi lock files in /tmp (compatibilità)
    shopt -s nullglob
    local tmp_locks=(/tmp/backup_status_update_*.lock /tmp/backup_*_*.lock /tmp/proxmox_backup_metrics_*.lock)
    shopt -u nullglob

    if [ ${#tmp_locks[@]} -eq 0 ]; then
        debug "No orphaned /tmp lock files found"
    else
        debug "Found ${#tmp_locks[@]} /tmp lock file(s) to check"
        for lock_file in "${tmp_locks[@]}"; do
            if [ -f "$lock_file" ]; then
                # Remove empty lock files immediately
                if [ ! -s "$lock_file" ]; then
                    debug "Removing empty orphaned lock file in handler: $lock_file"
                    rm -f "$lock_file" 2>/dev/null || true
                else
                    debug "Skipping non-empty lock file in handler: $lock_file"
                fi
            fi
        done
    fi
    
    debug "Final EXIT_CODE: $EXIT_CODE"
    debug "=== END CLEANUP_HANDLER ==="
}

# Main function - orchestrates the entire backup process
main() {
    # Initialize start timestamp right at the beginning
    START_TIME=$(date +%s)
    debug "Backup started at: $(date -d "@$START_TIME" '+%Y-%m-%d %H:%M:%S')"
    
    # Disable previous traps to avoid conflicts
    trap '' EXIT
    trap '' ERR
    
    # Set new traps before activating errexit
    trap 'cleanup_handler' EXIT
    trap 'handle_error ${LINENO} $?' ERR
    
    # Activate errexit mode to stop on errors
    set -e

    # Cleanup stale lock files before starting
    cleanup_stale_locks

    step "Starting main backup process"

    parse_arguments "$@"
    check_env_file
    check_proxmox_type
    setup_logging
    start_logging
    verify_script_security
    
    # Configura Telegram all'inizio, subito dopo i controlli di sicurezza
    if ! setup_telegram_if_needed; then
        set_exit_code "warning"
    fi
    
    check_dependencies
    setup_dirs
    get_server_id
    
    # Test cloud connectivity using the unified counting system
    # This function automatically handles ENABLE_CLOUD_BACKUP status and sets appropriate variables
    if ! CHECK_COUNT "CLOUD_CONNECTIVITY" true; then
        debug "Cloud connectivity test completed with warnings"
        # The CHECK_COUNT function has already updated ENABLE_CLOUD_BACKUP and status variables
    fi
    
    if [ "$CHECK_ONLY_MODE" == "true" ]; then
        success "Check-only mode completed successfully."
        update_backup_duration
        get_server_id
        telegram_configure
        send_notifications
        log_summary
        
        # Use return instead of exit
        debug "Ending CHECK_ONLY_MODE with code: $EXIT_CODE"
        return $EXIT_CODE
    fi
    
    # Perform primary backup
    if ! perform_backup; then
        error "Backup operation failed"
        set_exit_code "error"
        set_backup_status "primary" $EXIT_ERROR
    else
        set_backup_status "primary" $EXIT_SUCCESS
    fi

    # Manage storage operations (backup operations only, not logs)
    backup_manager_storage
    
    # Now proceed with cleanup and notifications
    set_permissions
    
    update_final_metrics
    
    # Update backup counts for final log using new counting system
    CHECK_COUNT "BACKUP_PRIMARY" true  # Silent mode for debug
    CHECK_COUNT "BACKUP_SECONDARY" true  # Silent mode for debug
    if [ "${ENABLE_CLOUD_BACKUP:-true}" == "true" ]; then
        CHECK_COUNT "BACKUP_CLOUD" true  # Silent mode for debug
    else
        debug "Cloud backup disabled, skipping cloud count"
    fi
    
    # Update log counts for status and metrics using new counting system
    CHECK_COUNT "LOG_ALL" true  # Silent mode - populates all log count variables
    
    # Update status emojis before notifications
    EMOJI_PRI=$(get_status_emoji "backup" "primary")
    EMOJI_SEC=$(get_status_emoji "backup" "secondary")
    EMOJI_CLO=$(get_status_emoji "backup" "cloud")
    LOG_PRI_EMOJI=$(get_status_emoji "log" "primary")
    LOG_SEC_EMOJI=$(get_status_emoji "log" "secondary")
    LOG_CLO_EMOJI=$(get_status_emoji "log" "cloud")
    
    # Collect all metrics before notifications
    collect_metrics
    
    # Calculate final duration before notifications
    update_backup_duration
    
    # Send notifications
    send_notifications
    
    # Dedicated log management at the end of the process
    manage_logs
    
    # Update status emojis after log management
    EMOJI_PRI=$(get_status_emoji "backup" "primary")
    EMOJI_SEC=$(get_status_emoji "backup" "secondary")
    EMOJI_CLO=$(get_status_emoji "backup" "cloud")
    LOG_PRI_EMOJI=$(get_status_emoji "log" "primary")
    LOG_SEC_EMOJI=$(get_status_emoji "log" "secondary")
    LOG_CLO_EMOJI=$(get_status_emoji "log" "cloud")
    
    # Display final summary and status as the very last thing
    log_summary
    
    debug "BACKUP DIRECT FUNCTION COUNT PRI:$COUNT_BACKUP_PRIMARY SEC:$COUNT_BACKUP_SECONDARY CLO:$COUNT_BACKUP_CLOUD"
    
    success "Backup process completed with exit code: $EXIT_CODE"
    
    # Final Prometheus metrics export
    if [ "$PROMETHEUS_ENABLED" == "true" ]; then
        step "Exporting Prometheus metrics"
        if export_prometheus_metrics; then
            info "Prometheus metrics exported to ${PROMETHEUS_TEXTFILE_DIR:-/var/lib/prometheus/node-exporter}/proxmox_backup.prom"
        else
            warning "Failed to export Prometheus metrics"
        fi
    fi
    
    # Final cleanup message
    step "Cleaning up temporary files"

    # Explicit cleanup of temporary directory (with security guards)
    if safe_cleanup_temp_dir; then
        debug "Temporary directory removed successfully in final cleanup"
    else
        debug "Temporary directory cleanup skipped or failed in final cleanup"
    fi
    
    # Explicit cleanup of metrics file
    if [ -n "${METRICS_FILE:-}" ] && [ -f "${METRICS_FILE:-}" ]; then
        debug "Explicitly removing metrics file: $METRICS_FILE"
        if rm -f "${METRICS_FILE}" 2>/dev/null; then
            debug "Metrics file removed successfully: $METRICS_FILE"
        else
            warning "Failed to remove metrics file: $METRICS_FILE"
        fi
    else
        debug "No metrics file to clean up or file already removed"
    fi
    
    # Explicit cleanup of orphaned lock files
    debug "Cleaning up orphaned lock files"
    for lock_file in /tmp/backup_status_update_*.lock /tmp/backup_*_*.lock; do
        if [ -f "$lock_file" ]; then
            # Remove empty lock files immediately
            if [ ! -s "$lock_file" ]; then
                debug "Removing empty orphaned lock file: $lock_file"
                if rm -f "$lock_file" 2>/dev/null; then
                    debug "Orphaned lock file removed successfully: $lock_file"
                else
                    warning "Failed to remove orphaned lock file: $lock_file"
                fi
            else
                debug "Skipping non-empty lock file: $lock_file"
            fi
        fi
    done
    
    success "Cleanup completed successfully"
    
    # Use return instead of exit
    debug "Ending main() with code: $EXIT_CODE"
    return $EXIT_CODE
}

# ==========================================
# SCRIPT STARTUP
# ==========================================

main "$@"

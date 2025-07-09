#!/bin/bash

# ======= AUTONOMOUS COUNTING SYSTEM - DOCUMENTATION =======
#  
# This section provides complete documentation for the autonomous counting system.
# All variables and commands available for use in scripts.
#
# ===============================================================================
# GLOBAL VARIABLES AVAILABLE AFTER CHECK_COUNT CALLS
# ===============================================================================
#
# BACKUP COUNT VARIABLES:
# -----------------------
# $COUNT_BACKUP_PRIMARY      - Number of backup files in primary location
# $COUNT_BACKUP_SECONDARY    - Number of backup files in secondary location  
# $COUNT_BACKUP_CLOUD        - Number of backup files in cloud storage
# $COUNT_BACKUP_ALL          - Total number of backup files (primary + secondary + cloud)
#
# LOG COUNT VARIABLES:
# --------------------
# $COUNT_LOG_PRIMARY         - Number of log files in primary location
# $COUNT_LOG_SECONDARY       - Number of log files in secondary location
# $COUNT_LOG_CLOUD           - Number of log files in cloud storage  
# $COUNT_LOG_ALL             - Total number of log files (primary + secondary + cloud)
#
# CLOUD CONNECTIVITY VARIABLES:
# ------------------------------
# $COUNT_CLOUD_CONNECTIVITY_STATUS - Cloud connectivity status: "ok", "error", "disabled", "unknown"
# $COUNT_CLOUD_CONNECTION_ERROR    - Boolean: "true" if cloud connection has errors, "false" otherwise
#
# ===============================================================================
# COMMANDS TO UPDATE VARIABLES
# ===============================================================================
#
# BACKUP COUNTING COMMANDS:
# -------------------------
# CHECK_COUNT "BACKUP_PRIMARY"    - Updates $COUNT_BACKUP_PRIMARY
# CHECK_COUNT "BACKUP_SECONDARY"  - Updates $COUNT_BACKUP_SECONDARY  
# CHECK_COUNT "BACKUP_CLOUD"      - Updates $COUNT_BACKUP_CLOUD
# CHECK_COUNT "BACKUP_ALL"        - Updates all backup variables and $COUNT_BACKUP_ALL
#
# LOG COUNTING COMMANDS:
# ----------------------
# CHECK_COUNT "LOG_PRIMARY"       - Updates $COUNT_LOG_PRIMARY
# CHECK_COUNT "LOG_SECONDARY"     - Updates $COUNT_LOG_SECONDARY
# CHECK_COUNT "LOG_CLOUD"         - Updates $COUNT_LOG_CLOUD  
# CHECK_COUNT "LOG_ALL"           - Updates all log variables and $COUNT_LOG_ALL
#
# CONNECTIVITY TESTING COMMAND:
# ------------------------------
# CHECK_COUNT "CLOUD_CONNECTIVITY" - Tests cloud connectivity and updates status variables
#
# ===============================================================================
# SILENT MODE (OPTIONAL SECOND PARAMETER)
# ===============================================================================
#
# All commands support silent mode to suppress output:
# CHECK_COUNT "BACKUP_ALL" true    - Updates variables without console output
# CHECK_COUNT "LOG_CLOUD" true     - Updates variables without console output
#
# ===============================================================================
# CONFIGURATION VARIABLES (backup.env)
# ===============================================================================
#
# Timeout settings that can be configured in backup.env:
# CLOUD_CONNECTIVITY_TIMEOUT=10   - Timeout for cloud connectivity test (default: 10s)
# CLOUD_LIST_TIMEOUT=15           - Timeout for cloud file listing (default: 15s)
# LOCAL_FIND_TIMEOUT=10           - Timeout for local file searches (default: 10s)
#
# ===============================================================================
# USAGE EXAMPLES
# ===============================================================================
#
# Example 1: Count all backups and use variables
# -----------------------------------------------
# CHECK_COUNT "BACKUP_ALL"
# echo "Primary backups: $COUNT_BACKUP_PRIMARY"
# echo "Total backups: $COUNT_BACKUP_ALL"
#
# Example 2: Test cloud connectivity before operations  
# -----------------------------------------------------
# CHECK_COUNT "CLOUD_CONNECTIVITY"
# if [ "$COUNT_CLOUD_CONNECTIVITY_STATUS" = "ok" ]; then
#     CHECK_COUNT "BACKUP_CLOUD"
#     echo "Cloud backups available: $COUNT_BACKUP_CLOUD"
# else
#     echo "Cloud not available: $COUNT_CLOUD_CONNECTIVITY_STATUS"
# fi
#
# Example 3: Silent counting for internal logic
# ----------------------------------------------
# CHECK_COUNT "LOG_ALL" true
# if [ "$COUNT_LOG_ALL" -gt 50 ]; then
#     echo "Warning: Too many logs ($COUNT_LOG_ALL)"
# fi
#
# Example 4: Conditional logic based on counts
# ---------------------------------------------
# CHECK_COUNT "BACKUP_PRIMARY"
# if [ "$COUNT_BACKUP_PRIMARY" -eq 0 ]; then
#     echo "ERROR: No primary backups found!"
#     exit 1
# elif [ "$COUNT_BACKUP_PRIMARY" -gt 20 ]; then
#     echo "INFO: Consider rotation, found $COUNT_BACKUP_PRIMARY backups"
# fi
#
# Example 5: Status checking with proper error handling
# ------------------------------------------------------
# CHECK_COUNT "BACKUP_CLOUD"
# case "$COUNT_CLOUD_CONNECTIVITY_STATUS" in
#     "ok")
#         echo "✅ Cloud OK - Backups: $COUNT_BACKUP_CLOUD"
#         ;;
#     "error")
#         echo "❌ Cloud Error - Connection failed"
#         ;;
#     "disabled")
#         echo "➖ Cloud Disabled - Skipping cloud operations"
#         ;;
#     "unknown")
#         echo "❓ Cloud Status Unknown - Run connectivity test first"
#         ;;
# esac
#
# ===============================================================================
# PROMETHEUS METRICS (AUTO-UPDATED)
# ===============================================================================
#
# When PROMETHEUS_ENABLED=true, these metrics are automatically updated:
# - proxmox_backup_count_primary     (gauge) - Primary backup count
# - proxmox_backup_count_secondary   (gauge) - Secondary backup count  
# - proxmox_backup_count_cloud       (gauge) - Cloud backup count
# - proxmox_backup_count_total       (gauge) - Total backup count
# - proxmox_log_count_primary        (gauge) - Primary log count
# - proxmox_log_count_secondary      (gauge) - Secondary log count
# - proxmox_log_count_cloud          (gauge) - Cloud log count  
# - proxmox_log_count_total          (gauge) - Total log count
# - proxmox_cloud_connectivity       (gauge) - Cloud connectivity (1=ok, 0=error, -1=disabled, -2=unknown)
#
# ===============================================================================
# ENABLE/DISABLE CONFIGURATION VARIABLES
# ===============================================================================
#
# These configuration variables affect counting behavior:
# ENABLE_SECONDARY_BACKUP=false     - Disables secondary backup/log counting
# ENABLE_CLOUD_BACKUP=false         - Disables cloud backup/log counting  
# ENABLE_LOG_MANAGEMENT=false       - Disables ALL log counting (primary, secondary, cloud)
#
# ===============================================================================

# ======= AUTONOMOUS COUNTING SYSTEM ======= # Single unified counting function - This is the ONLY function you need to use
CHECK_COUNT() {
    local type="$1"
    local silent="${2:-false}"  # Optional parameter for silent mode
    
    # Validate input
    if [ -z "$type" ]; then
        echo "ERROR: Missing type parameter"
        echo "Usage: CHECK_COUNT <type> [silent]"
        echo "Valid types: BACKUP_PRIMARY, BACKUP_SECONDARY, BACKUP_CLOUD, BACKUP_ALL, LOG_PRIMARY, LOG_SECONDARY, LOG_CLOUD, LOG_ALL, CLOUD_CONNECTIVITY"
        return 1
    fi
    
    case "$type" in
        "CLOUD_CONNECTIVITY")
            _TEST_CLOUD_CONNECTIVITY
            local connectivity_result=$?
            _UPDATE_PROMETHEUS_METRICS
            if [ "$silent" != "true" ]; then
                echo "COUNT_CLOUD_CONNECTIVITY_STATUS=$COUNT_CLOUD_CONNECTIVITY_STATUS"
                echo "COUNT_CLOUD_CONNECTION_ERROR=$COUNT_CLOUD_CONNECTION_ERROR"
                if [ "$COUNT_CLOUD_CONNECTIVITY_STATUS" = "error" ]; then
                    echo "ERROR_DESCRIPTION=$(_GET_COUNT_ERROR_DESCRIPTION "A")"
                fi
                echo "EXIT_CODE=$connectivity_result"
            fi
            return $connectivity_result
            ;;
        "BACKUP_PRIMARY")
            _COUNT_BACKUPS_AUTONOMOUS "primary"
            _UPDATE_PROMETHEUS_METRICS
            if [ "$silent" != "true" ]; then
                echo "COUNT_BACKUP_PRIMARY=$COUNT_BACKUP_PRIMARY"
                if [ "$COUNT_CLOUD_CONNECTION_ERROR" = "true" ]; then
                    echo "COUNT_CLOUD_CONNECTION_ERROR=$COUNT_CLOUD_CONNECTION_ERROR"
                fi
            fi
            ;;
        "BACKUP_SECONDARY")
            _COUNT_BACKUPS_AUTONOMOUS "secondary"
            _UPDATE_PROMETHEUS_METRICS
            if [ "$silent" != "true" ]; then
                echo "COUNT_BACKUP_SECONDARY=$COUNT_BACKUP_SECONDARY"
                if [ "${ENABLE_SECONDARY_BACKUP:-false}" != "true" ]; then
                    echo "STATUS=DISABLED"
                fi
            fi
            ;;
        "BACKUP_CLOUD")
            _COUNT_BACKUPS_AUTONOMOUS "cloud"
            _UPDATE_PROMETHEUS_METRICS
            if [ "$silent" != "true" ]; then
                echo "COUNT_BACKUP_CLOUD=$COUNT_BACKUP_CLOUD"
                if [ "${ENABLE_CLOUD_BACKUP:-true}" != "true" ]; then
                    echo "STATUS=DISABLED"
                elif [ "$COUNT_CLOUD_CONNECTION_ERROR" = "true" ]; then
                    echo "COUNT_CLOUD_CONNECTION_ERROR=$COUNT_CLOUD_CONNECTION_ERROR"
                    echo "ERROR_DESCRIPTION=$(_GET_COUNT_ERROR_DESCRIPTION "A")"
                fi
            fi
            ;;
        "BACKUP_ALL")
            _COUNT_BACKUPS_AUTONOMOUS "all"
            _UPDATE_PROMETHEUS_METRICS
            if [ "$silent" != "true" ]; then
                echo "COUNT_BACKUP_PRIMARY=$COUNT_BACKUP_PRIMARY"
                echo "COUNT_BACKUP_SECONDARY=$COUNT_BACKUP_SECONDARY"
                echo "COUNT_BACKUP_CLOUD=$COUNT_BACKUP_CLOUD"
                echo "COUNT_BACKUP_ALL=$COUNT_BACKUP_ALL"
                if [ "$COUNT_CLOUD_CONNECTION_ERROR" = "true" ]; then
                    echo "COUNT_CLOUD_CONNECTION_ERROR=$COUNT_CLOUD_CONNECTION_ERROR"
                fi
            fi
            ;;
        "LOG_PRIMARY")
            _COUNT_LOGS_AUTONOMOUS "primary"
            _UPDATE_PROMETHEUS_METRICS
            if [ "$silent" != "true" ]; then
                echo "COUNT_LOG_PRIMARY=$COUNT_LOG_PRIMARY"
                if [ "${ENABLE_LOG_MANAGEMENT:-true}" != "true" ]; then
                    echo "STATUS=DISABLED"
                fi
            fi
            ;;
        "LOG_SECONDARY")
            _COUNT_LOGS_AUTONOMOUS "secondary"
            _UPDATE_PROMETHEUS_METRICS
            if [ "$silent" != "true" ]; then
                echo "COUNT_LOG_SECONDARY=$COUNT_LOG_SECONDARY"
                if [ "${ENABLE_LOG_MANAGEMENT:-true}" != "true" ] || [ "${ENABLE_SECONDARY_BACKUP:-false}" != "true" ]; then
                    echo "STATUS=DISABLED"
                fi
            fi
            ;;
        "LOG_CLOUD")
            _COUNT_LOGS_AUTONOMOUS "cloud"
            _UPDATE_PROMETHEUS_METRICS
            if [ "$silent" != "true" ]; then
                echo "COUNT_LOG_CLOUD=$COUNT_LOG_CLOUD"
                if [ "${ENABLE_LOG_MANAGEMENT:-true}" != "true" ]; then
                    echo "STATUS=LOG_MANAGEMENT_DISABLED"
                elif [ "${ENABLE_CLOUD_BACKUP:-true}" != "true" ]; then
                    echo "STATUS=CLOUD_DISABLED"
                elif [ "$COUNT_CLOUD_CONNECTION_ERROR" = "true" ]; then
                    echo "COUNT_CLOUD_CONNECTION_ERROR=$COUNT_CLOUD_CONNECTION_ERROR"
                    echo "ERROR_DESCRIPTION=$(_GET_COUNT_ERROR_DESCRIPTION "A")"
                fi
            fi
            ;;
        "LOG_ALL")
            _COUNT_LOGS_AUTONOMOUS "all"
            _UPDATE_PROMETHEUS_METRICS
            if [ "$silent" != "true" ]; then
                echo "COUNT_LOG_PRIMARY=$COUNT_LOG_PRIMARY"
                echo "COUNT_LOG_SECONDARY=$COUNT_LOG_SECONDARY"
                echo "COUNT_LOG_CLOUD=$COUNT_LOG_CLOUD"
                echo "COUNT_LOG_ALL=$COUNT_LOG_ALL"
                if [ "${ENABLE_LOG_MANAGEMENT:-true}" != "true" ]; then
                    echo "STATUS=LOG_MANAGEMENT_DISABLED"
                elif [ "$COUNT_CLOUD_CONNECTION_ERROR" = "true" ]; then
                    echo "COUNT_CLOUD_CONNECTION_ERROR=$COUNT_CLOUD_CONNECTION_ERROR"
                fi
            fi
            ;;
        *)
            echo "ERROR: Invalid type '$type'. Valid types: BACKUP_PRIMARY, BACKUP_SECONDARY, BACKUP_CLOUD, BACKUP_ALL, LOG_PRIMARY, LOG_SECONDARY, LOG_CLOUD, LOG_ALL, CLOUD_CONNECTIVITY"
            return 1
            ;;
    esac
    
    return 0
}

# ======= AUTONOMOUS COUNTING SYSTEM =======
# Completely independent counting functions for backups and logs
# These functions perform their own counting without relying on existing functions
# Global variables for autonomous counting system
#
#
# Raccogliere i valori
#
# CHECK_COUNT "BACKUP_PRIMARY"      # Conta backup primary
# CHECK_COUNT "BACKUP_SECONDARY"    # Conta backup secondary  
# CHECK_COUNT "BACKUP_CLOUD"        # Conta backup cloud
# CHECK_COUNT "BACKUP_ALL"          # Conta tutti i backup
# CHECK_COUNT "LOG_PRIMARY"         # Conta log primary
# CHECK_COUNT "LOG_SECONDARY"       # Conta log secondary
# CHECK_COUNT "LOG_CLOUD"           # Conta log cloud
# CHECK_COUNT "LOG_ALL"         
#
# Utilizzare i valori
#
# $COUNT_BACKUP_PRIMARY"
# $COUNT_BACKUP_SECONDARY"
# $COUNT_BACKUP_CLOUD"
# $COUNT_BACKUP_ALL"
# $COUNT_LOG_PRIMARY"
# $COUNT_LOG_SECONDARY" 
# $COUNT_LOG_CLOUD"
# $COUNT_LOG_ALL"
#

COUNT_BACKUP_PRIMARY=0
COUNT_BACKUP_SECONDARY=0
COUNT_BACKUP_CLOUD=0
COUNT_BACKUP_ALL=0
COUNT_LOG_PRIMARY=0
COUNT_LOG_SECONDARY=0
COUNT_LOG_CLOUD=0
COUNT_LOG_ALL=0

# Global variable to track cloud connection errors (enhanced version)
COUNT_CLOUD_CONNECTION_ERROR="false"

# Global variable for cloud connectivity test result
COUNT_CLOUD_CONNECTIVITY_STATUS="unknown"  # Values: "ok", "error", "disabled", "unknown"

# Configurable timeouts (can be overridden in backup.env)
CLOUD_CONNECTIVITY_TIMEOUT="${CLOUD_CONNECTIVITY_TIMEOUT:-10}"
CLOUD_LIST_TIMEOUT="${CLOUD_LIST_TIMEOUT:-15}"
LOCAL_FIND_TIMEOUT="${LOCAL_FIND_TIMEOUT:-10}"

# Helper function to get file extensions based on compression type
_GET_COMPRESSION_EXTENSIONS() {
    local compression_type="${1:-${COMPRESSION_TYPE:-xz}}"
    
    case "$compression_type" in
        "zstd") echo "zst" ;;
        "xz") echo "xz" ;;
        "gzip"|"pigz") echo "gz" ;;
        "bzip2") echo "bz2" ;;
        "lzma") echo "lzma" ;;
        *) echo "zst|xz|gz|bz2|lzma" ;;
    esac
}

# Helper function to get error descriptions
_GET_COUNT_ERROR_DESCRIPTION() {
    local error_code="$1"
    case "$error_code" in
        "E") echo "Error: Invalid location" ;;
        "R") echo "Error: Rclone not found" ;;
        "C") echo "Error: Missing Rclone configuration" ;;
        "A") echo "Error: Cloud access failed" ;;
        "P") echo "Error: Path does not exist" ;;
        "T") echo "Error: Connection timeout" ;;
        "D") echo "Error: Service disabled" ;;
        *) echo "Unknown error" ;;
    esac
}

# Helper function to test cloud connectivity (standalone)
_TEST_CLOUD_CONNECTIVITY() {
    # Reset connectivity status
    COUNT_CLOUD_CONNECTION_ERROR="false"
    COUNT_CLOUD_CONNECTIVITY_STATUS="unknown"
    
    # Check if cloud backup is enabled
    if [ "${ENABLE_CLOUD_BACKUP:-true}" != "true" ]; then
        COUNT_CLOUD_CONNECTIVITY_STATUS="disabled"
        return 0
    fi
    
    debug "Testing cloud connectivity with ${CLOUD_CONNECTIVITY_TIMEOUT}s timeout"
    
    # Check if rclone is available
    if ! command -v rclone &> /dev/null; then
        warning "Cloud backup is enabled but rclone command not found"
        warning "Install rclone to enable cloud backup functionality: apt-get install rclone"
        warning "Or disable cloud backup by setting ENABLE_CLOUD_BACKUP=\"false\" in backup.env"
        COUNT_CLOUD_CONNECTION_ERROR="true"
        COUNT_CLOUD_CONNECTIVITY_STATUS="error"
        return 1
    fi
    
    # Test rclone configuration (this will show NOTICE messages if config file is missing)
    debug "Checking rclone configuration..."
    rclone_with_labels listremotes >/dev/null
    
    # Check if remote is configured
    if [ -z "${RCLONE_REMOTE:-}" ]; then
        warning "Cloud backup is enabled but RCLONE_REMOTE not configured in backup.env"
        warning "Configure RCLONE_REMOTE variable or disable cloud backup"
        COUNT_CLOUD_CONNECTION_ERROR="true"
        COUNT_CLOUD_CONNECTIVITY_STATUS="error"
        return 1
    fi
    
    # Check if the specified remote exists in rclone configuration
    if ! rclone_with_labels listremotes 2>/dev/null | grep -q "^${RCLONE_REMOTE}:$"; then
        warning "Cloud backup is enabled but rclone remote '${RCLONE_REMOTE}' not configured"
        warning "Configure rclone remote with: rclone config"
        warning "Or disable cloud backup by setting ENABLE_CLOUD_BACKUP=\"false\" in backup.env"
        COUNT_CLOUD_CONNECTION_ERROR="true"
        COUNT_CLOUD_CONNECTIVITY_STATUS="error"
        return 1
    fi
    
    # Test basic connectivity with configurable timeout
    if ! timeout "${CLOUD_CONNECTIVITY_TIMEOUT}" rclone about "${RCLONE_REMOTE}:" ${RCLONE_FLAGS:-} &>/dev/null; then
        warning "Cloud backup is enabled but connectivity test failed for remote '${RCLONE_REMOTE}'"
        warning "Check rclone configuration and network connectivity"
        warning "Test manually with: rclone about ${RCLONE_REMOTE}:"
        COUNT_CLOUD_CONNECTION_ERROR="true"
        COUNT_CLOUD_CONNECTIVITY_STATUS="error"
        return 1
    fi
    
    # Test backup path accessibility (integrated from storage.sh)
    if ! timeout "${CLOUD_CONNECTIVITY_TIMEOUT}" rclone mkdir "${RCLONE_REMOTE}:${CLOUD_BACKUP_PATH}" ${RCLONE_FLAGS:-} 2>/dev/null; then
        warning "Cloud backup path not accessible: ${RCLONE_REMOTE}:${CLOUD_BACKUP_PATH}"
        warning "Check path permissions and rclone configuration"
        COUNT_CLOUD_CONNECTION_ERROR="true"
        COUNT_CLOUD_CONNECTIVITY_STATUS="error"
        return 1
    fi
    
    # Test log path accessibility (integrated from log.sh)
    if ! timeout "${CLOUD_CONNECTIVITY_TIMEOUT}" rclone mkdir "${RCLONE_REMOTE}:${CLOUD_LOG_PATH}" ${RCLONE_FLAGS:-} 2>/dev/null; then
        debug "Cloud log path not accessible: ${RCLONE_REMOTE}:${CLOUD_LOG_PATH}"
        # Log path failure is not critical - continue with warning
        debug "Warning: Cloud log path accessibility failed, but continuing"
    fi
    
    # All tests passed
    debug "Cloud connectivity test passed (including path accessibility)"
    COUNT_CLOUD_CONNECTIVITY_STATUS="ok"
    return 0
}

# Helper function to update Prometheus metrics
_UPDATE_PROMETHEUS_METRICS() {
    # Update metrics only if Prometheus is enabled
    if [ "${PROMETHEUS_ENABLED:-false}" = "true" ] && command -v update_prometheus_metrics &>/dev/null; then
        debug "Updating Prometheus metrics for counting system"
        
        # Update backup metrics
        update_prometheus_metrics "proxmox_backup_count_primary" "gauge" "Number of backups in primary path" "$COUNT_BACKUP_PRIMARY" 2>/dev/null || true
        update_prometheus_metrics "proxmox_backup_count_secondary" "gauge" "Number of backups in secondary path" "$COUNT_BACKUP_SECONDARY" 2>/dev/null || true
        update_prometheus_metrics "proxmox_backup_count_cloud" "gauge" "Number of backups in cloud" "$COUNT_BACKUP_CLOUD" 2>/dev/null || true
        update_prometheus_metrics "proxmox_backup_count_total" "gauge" "Total number of backups" "$COUNT_BACKUP_ALL" 2>/dev/null || true
        
        # Update log metrics
        update_prometheus_metrics "proxmox_log_count_primary" "gauge" "Number of logs in primary path" "$COUNT_LOG_PRIMARY" 2>/dev/null || true
        update_prometheus_metrics "proxmox_log_count_secondary" "gauge" "Number of logs in secondary path" "$COUNT_LOG_SECONDARY" 2>/dev/null || true
        update_prometheus_metrics "proxmox_log_count_cloud" "gauge" "Number of logs in cloud" "$COUNT_LOG_CLOUD" 2>/dev/null || true
        update_prometheus_metrics "proxmox_log_count_total" "gauge" "Total number of logs" "$COUNT_LOG_ALL" 2>/dev/null || true
        
        # Update cloud connectivity status
        local cloud_status
        case "$COUNT_CLOUD_CONNECTIVITY_STATUS" in
            "ok") cloud_status="1" ;;
            "error") cloud_status="0" ;;
            "disabled") cloud_status="-1" ;;
            *) cloud_status="-2" ;;  # unknown
        esac
        update_prometheus_metrics "proxmox_cloud_connectivity" "gauge" "Cloud connectivity status (1=ok, 0=error, -1=disabled, -2=unknown)" "$cloud_status" 2>/dev/null || true
        
        debug "Prometheus metrics updated successfully"
    else
        debug "Prometheus not enabled or update_prometheus_metrics not available"
    fi
}

# Main autonomous counting function for backups
_COUNT_BACKUPS_AUTONOMOUS() {
    local location="$1"
    local count=0
    
    case "$location" in
        "primary")
            local backup_path="${LOCAL_BACKUP_PATH:-}"
            if [ -n "$backup_path" ] && [ -d "$backup_path" ]; then
                # Use helper function for extensions
                local extensions=$(_GET_COMPRESSION_EXTENSIONS)
                
                # Count backup files, excluding checksums and metadata
                count=$(timeout "${LOCAL_FIND_TIMEOUT}" find "$backup_path" -maxdepth 1 -type f -name "${PROXMOX_TYPE:-*}-backup-*.tar.${extensions}" -not -name "*.sha256" -not -name "*.metadata" 2>/dev/null | wc -l)
            fi
            COUNT_BACKUP_PRIMARY=$count
            ;;
        "secondary")
            # Check if secondary backup is enabled
            if [ "${ENABLE_SECONDARY_BACKUP:-false}" != "true" ]; then
                count=0
            else
                local backup_path="${SECONDARY_BACKUP_PATH:-}"
                if [ -n "$backup_path" ] && [ -d "$backup_path" ]; then
                    # Use helper function for extensions
                    local extensions=$(_GET_COMPRESSION_EXTENSIONS)
                    
                    count=$(timeout "${LOCAL_FIND_TIMEOUT}" find "$backup_path" -maxdepth 1 -type f -name "${PROXMOX_TYPE:-*}-backup-*.tar.${extensions}" -not -name "*.sha256" -not -name "*.metadata" 2>/dev/null | wc -l)
                fi
            fi
            COUNT_BACKUP_SECONDARY=$count
            ;;
        "cloud")
            # Check if cloud backup is enabled
            if [ "${ENABLE_CLOUD_BACKUP:-true}" != "true" ]; then
                count=0
                debug "Cloud backup disabled, count set to 0"
            else
                if command -v rclone &> /dev/null; then
                    if rclone_with_labels listremotes 2>/dev/null | grep -q "^${RCLONE_REMOTE:-}:"; then
                        local cloud_backups=$(mktemp)
                        if timeout "${CLOUD_LIST_TIMEOUT}" rclone lsl --fast-list "${RCLONE_REMOTE}:${CLOUD_BACKUP_PATH}" ${RCLONE_FLAGS:-} 2>/dev/null | grep "${PROXMOX_TYPE:-}-backup.*\.tar" | grep -v "\.sha256$" | grep -v "\.metadata$" > "$cloud_backups"; then
                            count=$(wc -l < "$cloud_backups")
                            debug "Found $count backup files in cloud"
                        else
                            debug "Failed to list cloud backup files"
                        fi
                        rm -f "$cloud_backups"
                    else
                        debug "Rclone remote not found"
                    fi
                else
                    debug "Rclone command not available"
                fi
            fi
            COUNT_BACKUP_CLOUD=$count
            ;;
        "all")
            _COUNT_BACKUPS_AUTONOMOUS "primary"
            _COUNT_BACKUPS_AUTONOMOUS "secondary"
            _COUNT_BACKUPS_AUTONOMOUS "cloud"
            COUNT_BACKUP_ALL=$((COUNT_BACKUP_PRIMARY + COUNT_BACKUP_SECONDARY + COUNT_BACKUP_CLOUD))
            ;;
    esac
    
    return 0
}

# Main autonomous counting function for logs
_COUNT_LOGS_AUTONOMOUS() {
    local location="$1"
    local count=0
    
    # Check if log management is globally disabled
    if [ "${ENABLE_LOG_MANAGEMENT:-true}" != "true" ]; then
        count=0
        case "$location" in
            "primary")
                COUNT_LOG_PRIMARY=$count
                ;;
            "secondary")
                COUNT_LOG_SECONDARY=$count
                ;;
            "cloud")
                COUNT_LOG_CLOUD=$count
                ;;
            "all")
                COUNT_LOG_PRIMARY=0
                COUNT_LOG_SECONDARY=0
                COUNT_LOG_CLOUD=0
                COUNT_LOG_ALL=0
                ;;
        esac
        debug "Log management disabled, all counts set to 0"
        return 0
    fi
    
    case "$location" in
        "primary")
            local log_path="${LOCAL_LOG_PATH:-}"
            if [ -n "$log_path" ] && [ -d "$log_path" ]; then
                # Count log files, excluding rotated logs
                count=$(timeout "${LOCAL_FIND_TIMEOUT}" find "$log_path" -maxdepth 1 -type f -name "${PROXMOX_TYPE:-*}-backup-*.log" -not -name "*.log.*" 2>/dev/null | wc -l)
                debug "Found $count log files in primary path"
            else
                debug "Primary log path not found or empty: $log_path"
            fi
            COUNT_LOG_PRIMARY=$count
            ;;
        "secondary")
            # Check if secondary backup is enabled
            if [ "${ENABLE_SECONDARY_BACKUP:-false}" != "true" ]; then
                count=0
                debug "Secondary backup disabled, log count set to 0"
            else
                local log_path="${SECONDARY_LOG_PATH:-}"
                if [ -n "$log_path" ] && [ -d "$log_path" ]; then
                    count=$(timeout "${LOCAL_FIND_TIMEOUT}" find "$log_path" -maxdepth 1 -type f -name "${PROXMOX_TYPE:-*}-backup-*.log" -not -name "*.log.*" 2>/dev/null | wc -l)
                    debug "Found $count log files in secondary path"
                else
                    debug "Secondary log path not found or empty: $log_path"
                fi
            fi
            COUNT_LOG_SECONDARY=$count
            ;;
        "cloud")
            # Check if cloud backup is enabled
            if [ "${ENABLE_CLOUD_BACKUP:-true}" != "true" ]; then
                count=0
                debug "Cloud backup disabled, log count set to 0"
            else
                if command -v rclone &> /dev/null; then
                    if rclone_with_labels listremotes 2>/dev/null | grep -q "^${RCLONE_REMOTE:-}:"; then
                        local cloud_logs=$(mktemp)
                        if timeout "${CLOUD_LIST_TIMEOUT}" rclone lsl --fast-list "${RCLONE_REMOTE}:${CLOUD_LOG_PATH}" ${RCLONE_FLAGS:-} 2>/dev/null | grep "${PROXMOX_TYPE:-}-backup.*\.log$" > "$cloud_logs"; then
                            count=$(wc -l < "$cloud_logs")
                            debug "Found $count log files in cloud"
                        else
                            debug "Failed to list cloud log files"
                        fi
                        rm -f "$cloud_logs"
                    else
                        debug "Rclone remote not found for logs"
                    fi
                else
                    debug "Rclone command not available for logs"
                fi
            fi
            COUNT_LOG_CLOUD=$count
            ;;
        "all")
            _COUNT_LOGS_AUTONOMOUS "primary"
            _COUNT_LOGS_AUTONOMOUS "secondary"
            _COUNT_LOGS_AUTONOMOUS "cloud"
            COUNT_LOG_ALL=$((COUNT_LOG_PRIMARY + COUNT_LOG_SECONDARY + COUNT_LOG_CLOUD))
            ;;
    esac
    
    return 0
}

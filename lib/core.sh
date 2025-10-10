#!/bin/bash
# Version: 0.2.1
# ==========================================
# CORE FUNCTIONALITY FOR PROXMOX BACKUP SYSTEM
# ==========================================
#
# This module provides core functionality for the Proxmox backup system including:
# - Command line argument parsing and validation
# - Comprehensive error handling with structured logging
# - Exit code management with severity levels
# - Resource cleanup and temporary file management
# - Final status display with color support
#
# Dependencies:
# ============
# REQUIRED MODULES (must be sourced before this module):
# - logging.sh: Provides logging functions (step, info, debug, error, warning, success)
#   * Functions: step(), info(), debug(), error(), warning(), success()
#   * Variables: LOG_FILE, DEBUG_LEVEL, CURRENT_LOG_LEVEL
#
# - notifications.sh: Provides notification functions for error reporting
#   * Functions: send_telegram_notification(), send_email_notification()
#   * Variables: TELEGRAM_ENABLED, TELEGRAM_BOT_TOKEN, TELEGRAM_CHAT_ID, EMAIL_ENABLED
#
# - utils.sh: Provides utility functions
#   * Functions: show_usage()
#   * Variables: SCRIPT_DIR
#
# SYSTEM DEPENDENCIES:
# - bash: Version 4.0+ (for associative arrays and advanced features)
# - date: For timestamp operations (coreutils package)
# - rm: For file cleanup operations (coreutils package)
# - command: For command availability checking (built-in)
#
# Global Variables Used:
# =====================
# CONFIGURATION VARIABLES:
# - COMPRESSION_TYPE: Backup compression method (default: "xz")
#   * Supported values: "xz", "gzip", "bzip2", "none"
#   * Used by backup creation functions
#
# - DEBUG_LEVEL: Logging verbosity level
#   * Values: "basic", "advanced", "extreme"
#   * Controls amount of debug information displayed
#
# - CURRENT_LOG_LEVEL: Numeric log level for filtering
#   * Values: 1=ERROR, 2=WARNING, 3=INFO, 4=DEBUG, 5=TRACE
#   * Used by logging functions to filter messages
#
# MODE CONTROL VARIABLES:
# - CHECK_ONLY_MODE: When "true", only performs environment checks
#   * Set by --check-only command line option
#   * Prevents actual backup operations from running
#
# - DRY_RUN_MODE: When "true", simulates operations without making changes
#   * Set by --dry-run command line option
#   * Used throughout system for safe testing
#
# - ENV_FILE: Path to environment configuration file
#   * Set by -e/--env command line option
#   * Must be readable file containing variable definitions
#
# PATH VARIABLES:
# - LOCAL_LOG_PATH: Directory for log file storage
#   * Default: "${SCRIPT_DIR}/../log"
#   * Must be writable by backup user
#
# - LOCAL_BACKUP_PATH: Directory for local backup storage
#   * Default: "${SCRIPT_DIR}/../backup"
#   * Must be writable by backup user
#
# - TEMP_DIR: Temporary directory for backup operations
#   * Created during backup process
#   * Automatically cleaned up on exit
#
# EXIT CODE CONSTANTS:
# - EXIT_SUCCESS: Successful completion (value: 0)
# - EXIT_WARNING: Warning condition (value: 1)
# - EXIT_ERROR: Error condition (value: 2)
# - EXIT_CODE: Current exit code (modified during execution)
#
# NOTIFICATION VARIABLES:
# - TELEGRAM_ENABLED: Enable/disable Telegram notifications
# - TELEGRAM_BOT_TOKEN: Bot token for Telegram API
# - TELEGRAM_CHAT_ID: Chat ID for Telegram messages
# - EMAIL_ENABLED: Enable/disable email notifications
#
# METRICS VARIABLES:
# - PROMETHEUS_ENABLED: Enable/disable Prometheus metrics export
# - METRICS_FILE: Temporary file for metrics collection
#
# PROXMOX DETECTION:
# - PROXMOX_TYPE: Detected Proxmox type ("pve", "pbs", "unknown")
#   * Auto-detected based on available commands
#   * Used for type-specific operations
#
# COLOR CONTROL:
# - USE_COLORS: Enable/disable color output (1=enabled, 0=disabled)
# - DISABLE_COLORS: Alternative color control ("true"/"false")
# - Color constants: GREEN, YELLOW, RED, RESET
#
# Exit Codes:
# - 0: Success - all operations completed successfully
# - 1: Warning - some non-critical issues occurred
# - 2: Error - critical error occurred, backup may be incomplete
#
# Race Condition Protection:
# - File locking for shared resources
# - Atomic operations for critical sections
# - Proper cleanup on signal termination
#
# Author: Proxmox Backup System

# Last Modified: 2024
# ==========================================

# Enable strict error handling for better reliability
set -euo pipefail

# Define exit code constants for consistency
readonly EXIT_SUCCESS=0
readonly EXIT_WARNING=1
readonly EXIT_ERROR=2

# Initialize global exit code
EXIT_CODE=${EXIT_SUCCESS}

# Command line argument parsing with comprehensive validation
# Parses and validates all command line arguments, setting appropriate
# global variables and performing input validation to prevent issues.
#
# Supported Arguments:
#   -h, --help: Display usage information and exit
#   -v, --verbose: Enable advanced debug logging
#   -x, --extreme: Enable extreme debug logging (trace level)
#   -e, --env FILE: Specify environment configuration file
#   --dry-run: Enable dry-run mode (no actual changes)
#   --check-only: Enable check-only mode (environment validation only)
#
# Validation Rules:
# - Environment file must exist and be readable
# - Mutually exclusive options are properly handled
# - Unknown options trigger usage display and error exit
#
# Global Variables Set:
# - CHECK_ONLY_MODE: Boolean flag for check-only operation
# - DRY_RUN_MODE: Boolean flag for dry-run operation
# - COMPRESSION_TYPE: Backup compression method (with default)
# - DEBUG_LEVEL: Logging verbosity level
# - CURRENT_LOG_LEVEL: Numeric log level
# - ENV_FILE: Path to environment configuration file
#
# Returns:
#   0: Arguments parsed successfully
#   1: Invalid arguments or validation failure
parse_arguments() {
    step "Parsing command line arguments"
    
    # Set default values with proper initialization
    CHECK_ONLY_MODE="false"
    DRY_RUN_MODE="false"
    
    # Default compression type if not defined
    if [ -z "${COMPRESSION_TYPE:-}" ]; then
        COMPRESSION_TYPE="xz"
        info "COMPRESSION_TYPE not specified, defaulting to xz"
    fi
    
    # Validate mutually exclusive options
    local has_check_only=false
    local has_dry_run=false
    
    # First pass: check for mutually exclusive options
    local temp_args=("$@")
    for arg in "${temp_args[@]}"; do
        case "$arg" in
            --check-only) has_check_only=true ;;
            --dry-run) has_dry_run=true ;;
        esac
    done
    
    # Validate mutual exclusivity
    if [ "$has_check_only" = true ] && [ "$has_dry_run" = true ]; then
        error "Error: --check-only and --dry-run options are mutually exclusive"
        show_usage
        exit ${EXIT_ERROR}
    fi
    
    # Parse arguments with enhanced validation
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                show_usage
                exit ${EXIT_SUCCESS}
                ;;
            -v|--verbose)
                DEBUG_LEVEL="advanced"
                CURRENT_LOG_LEVEL=3  # Set to DEBUG level
                debug "Verbose logging enabled"
                ;;
            -x|--extreme)
                DEBUG_LEVEL="extreme"
                CURRENT_LOG_LEVEL=4  # Set to TRACE level
                debug "Extreme logging enabled"
                ;;
            -e|--env)
                # Enhanced validation for environment file
                if [[ $# -lt 2 ]]; then
                    error "Error: Environment file path required after -e/--env option"
                    show_usage
                    exit ${EXIT_ERROR}
                fi
                
                local env_file="$2"
                
                # Validate file existence and readability
                if [[ ! -f "$env_file" ]]; then
                    error "Error: Environment file '$env_file' does not exist"
                    exit ${EXIT_ERROR}
                fi
                
                if [[ ! -r "$env_file" ]]; then
                    error "Error: Environment file '$env_file' is not readable"
                    exit ${EXIT_ERROR}
                fi
                
                # Additional security check for file content
                if [[ ! -s "$env_file" ]]; then
                    warning "Warning: Environment file '$env_file' is empty"
                fi
                
                ENV_FILE="$env_file"
                debug "Environment file set to: $ENV_FILE"
                shift
                ;;
            --dry-run)
                DRY_RUN_MODE="true"
                info "Running in dry-run mode (no changes will be made)"
                ;;
            --check-only)
                CHECK_ONLY_MODE="true"
                info "Running in check-only mode (only checking environment and dependencies)"
                ;;
            --)
                # End of options marker
                shift
                break
                ;;
            -*)
                error "Unknown option: $1"
                show_usage
                exit ${EXIT_ERROR}
                ;;
            *)
                # Positional arguments (currently not supported)
                error "Unexpected positional argument: $1"
                error "This script does not accept positional arguments"
                show_usage
                exit ${EXIT_ERROR}
                ;;
        esac
        shift
    done
    
    # Post-parsing validation
    if [[ $# -gt 0 ]]; then
        error "Unexpected additional arguments: $*"
        show_usage
        exit ${EXIT_ERROR}
    fi
    
    success "Command line arguments parsed successfully"
}

# Enhanced error handling function with structured logging and race condition protection
# Provides comprehensive error handling with detailed logging, notification support,
# and proper cleanup. Includes protection against race conditions in multi-process
# environments and structured logging for automated parsing.
#
# Arguments:
#   $1: Line number where error occurred
#   $2: Exit code of failed command
#
# Global Variables Used:
# - BASH_COMMAND: Last executed command (automatic bash variable)
# - LOG_FILE: Path to log file for error recording
# - PROXMOX_TYPE: Type of Proxmox system for context
# - Various notification and metrics variables
#
# Features:
# - Structured JSON logging for automated parsing
# - Race condition protection for metrics updates
# - Automatic Proxmox type detection
# - Comprehensive notification support
# - Proper resource cleanup
# - Detailed error context capture
#
# Returns:
#   Current EXIT_CODE value
handle_error() {
    local line_no=$1
    local error_code=$2
    local last_command="${BASH_COMMAND}"
    local timestamp=$(date +"%Y-%m-%d %H:%M:%S")
    local iso_timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    
    # Ensure log initialization with fallback
    if [ -z "${LOG_FILE+x}" ] || [ ! -f "$LOG_FILE" ]; then
        # Fallback logging to stderr when LOG_FILE not available
        {
            echo "$timestamp [ERROR] Error occurred but LOG_FILE not set!"
            echo "$timestamp [ERROR] Command: $last_command"
            echo "$timestamp [ERROR] Line: $line_no, Exit code: $error_code"
        } >&2
    fi
    
    # Structured logging for automated parsing
    local structured_log=""
    if [ -n "${LOG_FILE+x}" ] && [ -f "$LOG_FILE" ]; then
        structured_log=$(cat <<EOF
{
  "timestamp": "$iso_timestamp",
  "level": "ERROR",
  "event": "command_failure",
  "line_number": $line_no,
  "exit_code": $error_code,
  "command": "$last_command",
  "pid": $$,
  "hostname": "$(hostname 2>/dev/null || echo 'unknown')",
  "user": "$(whoami 2>/dev/null || echo 'unknown')",
  "working_directory": "$(pwd 2>/dev/null || echo 'unknown')"
}
EOF
)
        echo "STRUCTURED_LOG: $structured_log" >> "$LOG_FILE"
    fi
    
    # Determine error type and log with enhanced context
    if [[ "$error_code" -eq 127 || "$last_command" == *"command not found"* ]]; then
        error "Command not found error: $last_command"
        error "This may indicate missing dependencies or incorrect PATH"
    elif [[ "$error_code" -eq 130 ]]; then
        error "Process interrupted by user (SIGINT): $last_command"
    elif [[ "$error_code" -eq 143 ]]; then
        error "Process terminated (SIGTERM): $last_command"
    else
        error "Error occurred in command: $last_command"
    fi
    
    error "On line $line_no with exit code $error_code"
    set_exit_code "error"
    
    # Enhanced Proxmox type detection with caching
    if [ -z "${PROXMOX_TYPE:-}" ]; then
        debug "Detecting Proxmox type for error context"
        
        # Ensure proper PATH for detection
        local additional_paths="/usr/bin:/usr/sbin:/bin:/sbin"
        if [[ ":$PATH:" != *":$additional_paths:"* ]]; then
            export PATH="$PATH:$additional_paths"
        fi
        
        # Try multiple detection methods
        if command -v pveversion >/dev/null 2>&1 || [ -x "/usr/bin/pveversion" ] || [ -x "/usr/sbin/pveversion" ]; then
            PROXMOX_TYPE="pve"
            debug "Detected Proxmox VE environment"
        elif command -v proxmox-backup-manager >/dev/null 2>&1 || [ -x "/usr/bin/proxmox-backup-manager" ] || [ -x "/usr/sbin/proxmox-backup-manager" ]; then
            PROXMOX_TYPE="pbs"
            debug "Detected Proxmox Backup Server environment"
        elif [ -f "/etc/pve/pve.version" ] && [ -r "/etc/pve/pve.version" ]; then
            PROXMOX_TYPE="pve"
            debug "Detected PVE from version file"
        elif [ -d "/etc/pve" ] && [ -d "/var/lib/pve-cluster" ]; then
            PROXMOX_TYPE="pve"
            debug "Detected PVE from directory structure"
        elif [ -d "/etc/proxmox-backup" ] || [ -d "/var/lib/proxmox-backup" ]; then
            PROXMOX_TYPE="pbs"
            debug "Detected PBS from directory structure"
        else
            PROXMOX_TYPE="unknown"
            debug "Unknown Proxmox environment - no detection methods succeeded"
        fi
    fi
    
    # Ensure paths are defined with enhanced validation
    if [ -z "${LOCAL_LOG_PATH+x}" ]; then
        LOCAL_LOG_PATH="${SCRIPT_DIR}/../log"
        debug "LOCAL_LOG_PATH not set, using default: $LOCAL_LOG_PATH"
    fi
    
    if [ -z "${LOCAL_BACKUP_PATH+x}" ]; then
        LOCAL_BACKUP_PATH="${SCRIPT_DIR}/../backup"
        debug "LOCAL_BACKUP_PATH not set, using default: $LOCAL_BACKUP_PATH"
    fi
    
    # Race condition protection for metrics updates
    local metrics_lock="/tmp/backup_metrics_$$.lock"
    if [ "${PROMETHEUS_ENABLED:-false}" == "true" ] && [ -n "${METRICS_FILE:-}" ]; then
        # Use file locking to prevent race conditions in metrics updates
        (
            flock -x -w 10 200 || {
                warning "Failed to acquire metrics lock, skipping metrics update"
                exit 0
            }
            
            if [ -f "$METRICS_FILE" ]; then
                {
                    echo "# HELP proxmox_backup_success Overall success of backup (1=success, 0=failure)"
                    echo "# TYPE proxmox_backup_success gauge"
                    echo "proxmox_backup_success 0"
                    echo "# HELP proxmox_backup_error_code Last error code encountered"
                    echo "# TYPE proxmox_backup_error_code gauge"
                    echo "proxmox_backup_error_code $error_code"
                    echo "# HELP proxmox_backup_error_line Line number where error occurred"
                    echo "# TYPE proxmox_backup_error_line gauge"
                    echo "proxmox_backup_error_line $line_no"
                } >> "$METRICS_FILE"
            fi
        ) 200>"$metrics_lock"
        
        # Clean up lock file
        rm -f "$metrics_lock" 2>/dev/null || true
    fi
    
    # Enhanced error message with more context
    local error_message="Backup failed with error code $error_code in command: $last_command on line $line_no"
    local detailed_message="$error_message (PID: $$, Host: $(hostname 2>/dev/null || echo 'unknown'), Time: $timestamp)"
    
    # Send notifications with enhanced error handling
    local notification_failed=false
    
    if [ "${TELEGRAM_ENABLED:-false}" == "true" ] && [ -n "${TELEGRAM_BOT_TOKEN:-}" ] && [ -n "${TELEGRAM_CHAT_ID:-}" ]; then
        if ! send_telegram_notification "failure" "$detailed_message"; then
            warning "Failed to send Telegram notification"
            notification_failed=true
        fi
    fi
    
    if [ "${EMAIL_ENABLED:-false}" == "true" ]; then
        if ! send_email_notification "failure" "$detailed_message"; then
            warning "Failed to send email notification"
            notification_failed=true
        fi
    fi
    
    # Set warning if notifications failed
    if [ "$notification_failed" = true ]; then
        set_exit_code "warning"
    fi
    
    # Enhanced temporary directory cleanup
    if [ -n "${TEMP_DIR+x}" ] && [ -d "$TEMP_DIR" ]; then
        debug "Cleaning up temporary directory: $TEMP_DIR"
        if ! rm -rf "$TEMP_DIR" 2>/dev/null; then
            warning "Failed to remove temporary directory: $TEMP_DIR"
        fi
    fi
    
    return $EXIT_CODE
}

# Enhanced exit code management with comprehensive severity levels
# Manages exit codes based on severity levels, ensuring that more severe
# conditions override less severe ones. Supports custom exit codes and
# provides detailed logging of exit code changes.
#
# Arguments:
#   $1: Severity level ("success", "warning", "error", "critical", or numeric code)
#
# Severity Hierarchy (higher values override lower values):
# - success: 0 (only set if current code is 0)
# - warning: 1 (set if current code is 0)
# - error: 2 (set if current code is 0 or 1)
# - critical: 3 (always set, highest priority)
# - custom: Any numeric value (handled with validation)
#
# Global Variables Modified:
# - EXIT_CODE: Updated based on severity level
#
# Returns:
#   0: Exit code updated successfully
#   1: Invalid severity level provided
set_exit_code() {
    local severity="$1"
    local old_exit_code=$EXIT_CODE
    local new_exit_code
    
    # Input validation
    if [ -z "$severity" ]; then
        error "set_exit_code: severity parameter is required"
        return 1
    fi
    
    case "$severity" in
        "success")
            # Only set success if no errors have occurred
            if [ $EXIT_CODE -eq 0 ]; then
                new_exit_code=$EXIT_SUCCESS
            else
                debug "Not setting success exit code, current code is $EXIT_CODE"
                return 0
            fi
            ;;
        "warning")
            # Set warning only if no errors have occurred
            if [ $EXIT_CODE -eq 0 ]; then
                new_exit_code=$EXIT_WARNING
            else
                debug "Not overriding exit code $EXIT_CODE with warning"
                return 0
            fi
            ;;
        "error")
            # Set error if current code is success or warning
            if [ $EXIT_CODE -le $EXIT_WARNING ]; then
                new_exit_code=$EXIT_ERROR
            else
                debug "Not overriding exit code $EXIT_CODE with error"
                return 0
            fi
            ;;
        "critical")
            # Critical always overrides (highest priority)
            new_exit_code=3
            ;;
        [0-9]*)
            # Custom numeric exit code with validation
            if ! [[ "$severity" =~ ^[0-9]+$ ]] || [ "$severity" -lt 0 ] || [ "$severity" -gt 255 ]; then
                error "set_exit_code: invalid numeric exit code '$severity' (must be 0-255)"
                return 1
            fi
            
            # Only set if new code is higher priority (higher number)
            if [ "$severity" -gt $EXIT_CODE ]; then
                new_exit_code=$severity
            else
                debug "Not overriding exit code $EXIT_CODE with lower priority code $severity"
                return 0
            fi
            ;;
        *)
            error "set_exit_code: unknown severity level '$severity'"
            error "Valid values: success, warning, error, critical, or numeric (0-255)"
            return 1
            ;;
    esac
    
    # Update exit code and log the change
    EXIT_CODE=$new_exit_code
    
    if [ $old_exit_code -ne $new_exit_code ]; then
        debug "Exit code changed: $old_exit_code -> $new_exit_code (severity: $severity)"
    fi
    
    return 0
}

# Enhanced cleanup function with comprehensive resource management
# Performs thorough cleanup of all temporary resources including files,
# directories, lock files, and process-related resources. Includes
# proper error handling and language consistency improvements.
#
# Features:
# - Comprehensive temporary resource cleanup
# - Lock file and PID file removal
# - Metrics file cleanup with race condition protection
# - Enhanced error handling and logging
# - Verification of cleanup success
# - Support for custom cleanup hooks
#
# Global Variables Used:
# - TEMP_DIR: Main temporary directory for cleanup
# - METRICS_FILE: Temporary metrics file
# - Various lock and PID files (auto-detected)
#
# Returns:
#   0: Cleanup completed successfully
#   1: Some cleanup operations failed (non-fatal)
cleanup() {
    step "Cleaning up temporary files and resources"
    
    local cleanup_errors=0
    
    # Ensure TEMP_DIR is properly initialized
    if [ -z "${TEMP_DIR+x}" ]; then
        debug "TEMP_DIR not defined, no temporary directory to clean"
        TEMP_DIR=""
    fi
    
    # Main temporary directory cleanup
    debug "TEMP_DIR cleanup check - Value: '${TEMP_DIR:-not set}'"
    if [ -n "$TEMP_DIR" ] && [ -d "$TEMP_DIR" ]; then
        debug "Removing temporary directory: $TEMP_DIR"
        
        # Enhanced removal with retry mechanism
        local retry_count=0
        local max_retries=3
        
        while [ $retry_count -lt $max_retries ]; do
            if rm -rf "$TEMP_DIR" 2>/dev/null; then
                debug "Successfully removed temporary directory: $TEMP_DIR"
                break
            else
                retry_count=$((retry_count + 1))
                if [ $retry_count -lt $max_retries ]; then
                    warning "Failed to remove temporary directory (attempt $retry_count/$max_retries), retrying..."
                    sleep 1
                else
                    warning "Unable to remove temporary directory: $TEMP_DIR after $max_retries attempts"
                    cleanup_errors=$((cleanup_errors + 1))
                fi
            fi
        done
        
        # Verify removal success
        if [ ! -d "$TEMP_DIR" ]; then
            debug "Temporary directory removal verified successfully: $TEMP_DIR"
        else
            warning "Temporary directory still exists after cleanup attempts: $TEMP_DIR"
            cleanup_errors=$((cleanup_errors + 1))
        fi
    elif [ -n "$TEMP_DIR" ] && [ ! -d "$TEMP_DIR" ]; then
        debug "Temporary directory already removed or doesn't exist: $TEMP_DIR"
    else
        debug "No temporary directory found or TEMP_DIR variable not defined"
    fi
    
    # Lock files cleanup (auto-detect and remove)
    debug "Cleaning up lock files"
    local lock_pattern="/tmp/backup_*_$$.lock"
    for lock_file in $lock_pattern; do
        if [ -f "$lock_file" ]; then
            debug "Removing lock file: $lock_file"
            if ! rm -f "$lock_file" 2>/dev/null; then
                warning "Failed to remove lock file: $lock_file"
                cleanup_errors=$((cleanup_errors + 1))
            fi
        fi
    done
    
    # PID files cleanup
    debug "Cleaning up PID files"
    local pid_pattern="/tmp/backup_process_*_$$.pid"
    for pid_file in $pid_pattern; do
        if [ -f "$pid_file" ]; then
            debug "Removing PID file: $pid_file"
            if ! rm -f "$pid_file" 2>/dev/null; then
                warning "Failed to remove PID file: $pid_file"
                cleanup_errors=$((cleanup_errors + 1))
            fi
        fi
    done
    
    # Metrics file cleanup with race condition protection
    if [ -n "${METRICS_FILE:-}" ] && [ -f "$METRICS_FILE" ]; then
        debug "Removing temporary metrics file: $METRICS_FILE"
        
        # Use lock to prevent race conditions during metrics cleanup
        local metrics_cleanup_lock="/tmp/metrics_cleanup_$$.lock"
        (
            if flock -x -w 5 200; then
                if ! rm -f "$METRICS_FILE" 2>/dev/null; then
                    warning "Unable to remove metrics file: $METRICS_FILE"
                    cleanup_errors=$((cleanup_errors + 1))
                fi
            else
                warning "Failed to acquire lock for metrics cleanup"
                cleanup_errors=$((cleanup_errors + 1))
            fi
        ) 200>"$metrics_cleanup_lock"
        
        # Clean up the cleanup lock
        rm -f "$metrics_cleanup_lock" 2>/dev/null || true
    fi
    
    # Additional temporary files cleanup (status files, etc.)
    debug "Cleaning up additional temporary files"
    local temp_patterns=(
        "/tmp/backup_status_*_$$.tmp"
        "/tmp/backup_metrics_$$.lock"
        "/tmp/backup_*_$$.tmp"
        "/tmp/proxmox_backup_metrics_$$.prom"
        "/tmp/backup_status_update_$$.lock"
        "/tmp/*_$$.lock"
        "/tmp/*_$$.prom"
    )
    
    # Additional cleanup for orphaned files from other processes
    debug "Cleaning up orphaned temporary files from other processes"
    local orphaned_patterns=(
        "/tmp/backup_status_update_*.lock"
        "/tmp/proxmox_backup_metrics_*.prom"
        "/tmp/backup_*_*.lock"
        "/tmp/metrics_cleanup_*.lock"
    )
    
    # Clean current process files first
    for pattern in "${temp_patterns[@]}"; do
        for temp_file in $pattern; do
            if [ -f "$temp_file" ]; then
                debug "Removing temporary file: $temp_file"
                if ! rm -f "$temp_file" 2>/dev/null; then
                    warning "Failed to remove temporary file: $temp_file"
                    cleanup_errors=$((cleanup_errors + 1))
                fi
            fi
        done
    done
    
    # Clean orphaned files from other processes (with age check for safety)
    for pattern in "${orphaned_patterns[@]}"; do
        for temp_file in $pattern; do
            if [ -f "$temp_file" ]; then
                # Different age thresholds based on file type
                local age_threshold=60  # Default: 1 hour
                local should_remove=false
                
                case "$temp_file" in
                    *backup_status_update*.lock)
                        # Lock files can be removed after 5 minutes
                        age_threshold=5
                        ;;
                    *metrics_cleanup*.lock)
                        # Metrics cleanup locks can be removed after 2 minutes
                        age_threshold=2
                        ;;
                    *.prom)
                        # Prometheus files can be removed after 30 minutes
                        age_threshold=30
                        ;;
                esac
                
                # Check if file is older than threshold
                if [ $(find "$temp_file" -mmin +${age_threshold} 2>/dev/null | wc -l) -gt 0 ]; then
                    should_remove=true
                elif [[ "$temp_file" == *backup_status_update*.lock ]] && [ $(find "$temp_file" -mmin +1 2>/dev/null | wc -l) -gt 0 ]; then
                    # For backup status update locks, also check if they're empty and older than 1 minute
                    if [ ! -s "$temp_file" ]; then
                        should_remove=true
                        debug "Removing empty backup status lock file older than 1 minute: $temp_file"
                    fi
                fi
                
                if [ "$should_remove" = true ]; then
                    debug "Removing orphaned temporary file (age threshold: ${age_threshold}min): $temp_file"
                    if ! rm -f "$temp_file" 2>/dev/null; then
                        warning "Failed to remove orphaned temporary file: $temp_file"
                        cleanup_errors=$((cleanup_errors + 1))
                    fi
                else
                    debug "Skipping recent orphaned file (threshold: ${age_threshold}min): $temp_file"
                fi
            fi
        done
    done
    
    # Custom cleanup hooks (if defined)
    if declare -f custom_cleanup_hook >/dev/null 2>&1; then
        debug "Executing custom cleanup hook"
        if ! custom_cleanup_hook; then
            warning "Custom cleanup hook failed"
            cleanup_errors=$((cleanup_errors + 1))
        fi
    fi
    
    # Report cleanup results
    if [ $cleanup_errors -eq 0 ]; then
        debug "All cleanup operations completed successfully"
        return 0
    else
        warning "Cleanup completed with $cleanup_errors errors"
        return 1
    fi
}

# Enhanced cleanup wrapper with improved exit code preservation
# Wrapper function that ensures proper cleanup execution while preserving
# the original exit code. Includes enhanced error handling and proper
# signal management for reliable cleanup in all scenarios.
#
# Features:
# - Preserves original exit codes accurately
# - Disables errexit during cleanup to ensure completion
# - Enhanced logging and debugging
# - Proper signal handling
# - Cleanup verification
#
# Returns:
#   Original exit code (preserved from calling context)
cleanup_wrapper() {
    # Save the original exit code before executing any operations
    local original_exit_code=$?
    
    # Disable errexit to ensure cleanup completes even if individual operations fail
    set +e
    
    debug "Executing cleanup_wrapper with original exit code: $original_exit_code"
    
    # Execute the main cleanup function
    if cleanup; then
        debug "Cleanup function completed successfully"
    else
        warning "Cleanup function completed with warnings"
    fi
    
    # Preserve the original exit code if EXIT_CODE is still at default
    if [ "$EXIT_CODE" -eq 0 ] && [ "$original_exit_code" -ne 0 ]; then
        debug "Updating EXIT_CODE from 0 to original exit code: $original_exit_code"
        EXIT_CODE=$original_exit_code
    fi
    
    debug "Cleanup wrapper completed with final EXIT_CODE: $EXIT_CODE"
    
    # Re-enable errexit for any subsequent operations
    set -e
    
    return $EXIT_CODE
}

# Function to display final status with colors
display_final_status() {
    local status
    local color
    
    case $EXIT_CODE in
        0)
            status="SUCCESS"
            color="${GREEN}"
            ;;
        1)
            status="WARNING"
            color="${YELLOW}"
            ;;
        2)
            status="ERROR"
            color="${RED}"
            ;;
        *)
            status="UNKNOWN"
            color="${RED}"
            ;;
    esac
    
    # Se i colori sono disabilitati, mostra senza formattazione ANSI
    if [ "${USE_COLORS:-1}" -eq 0 ] || [ "${DISABLE_COLORS:-false}" == "true" ]; then
        echo -e "\n==============================================================="
        echo -e "      $status"
        echo -e "===============================================================\n"
    else
        # Color entire block with exit code color, reset only after last line
        echo -e "\n${color}==============================================================="
        echo -e "      $status"
        echo -e "===============================================================${RESET}\n"
    fi
}
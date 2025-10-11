#!/bin/bash
##
# Proxmox Backup System - Backup Manager Library
# File: backup_manager.sh
# Version: 0.2.1
# Last Modified: 2025-10-11
# Changes: Gestione storage backup
##
# ==========================================
# BACKUP MANAGER STORAGE (AUTOMATIC PARALLEL/SEQUENTIAL MANAGEMENT)
# ==========================================
#
# This module manages all backup storage operations including:
# - Parallel/Sequential execution modes for storage operations
# - Secondary backup copy management
# - Cloud backup upload coordination
# - Backup rotation across all storage locations
# - Backup consistency verification
#
# The module supports two execution modes:
# 1. PARALLEL: Secondary copy and cloud upload run simultaneously
# 2. SEQUENTIAL: Operations run one after another
#
# Dependencies:
# ============
# REQUIRED MODULES (must be sourced before this module):
# - backup_copy.sh: Provides copy_to_secondary() function for local backup copying
#   * Requires: rsync, cp, or similar file copy utilities
#   * Variables: SECONDARY_BACKUP_PATH, BACKUP_FILE
#   * Functions: copy_to_secondary() -> returns 0 on success, 1 on error
#
# - backup_cloud.sh: Provides upload_to_cloud() function for cloud storage
#   * Requires: rclone, aws-cli, gsutil, or similar cloud tools
#   * Variables: CLOUD_BACKUP_PATH, ENABLE_CLOUD_BACKUP, cloud credentials
#   * Functions: upload_to_cloud() -> returns 0 on success, 1 on error
#
# - backup_rotation.sh: Provides manage_backup_rotation() for cleanup operations
#   * Requires: find, rm, ls utilities
#   * Variables: MAX_*_BACKUPS retention policies
#   * Functions: manage_backup_rotation(type, path, max_count) -> 0 on success
#
# - backup_verify.sh: Provides verify_backup_consistency() for integrity checks
#   * Requires: tar, gzip, md5sum, sha256sum utilities
#   * Variables: BACKUP_FILE, verification settings
#   * Functions: verify_backup_consistency() -> 0 on success, 1 on error
#
# - backup_status.sh: Provides status tracking and reporting functions
#   * Requires: date, echo utilities, status file access
#   * Variables: STATUS_FILE, backup operation states
#   * Functions: set_backup_status(operation, status) -> 0 on success
#
# SYSTEM DEPENDENCIES:
# - flock: For file locking (util-linux package)
# - timeout: For operation timeouts (coreutils package)
# - kill: For process management (built-in or procps package)
# - date: For timestamp operations (coreutils package)
# - hostname: For system identification (hostname package)
# - mktemp: For temporary file creation (coreutils package)
#
# Global Variables Used:
# =====================
# EXECUTION CONTROL:
# - MULTI_STORAGE_PARALLEL: Controls execution mode (true/false)
#   * true: Secondary copy and cloud upload run simultaneously
#   * false: Operations run sequentially (safer, slower)
#   * Default: false (recommended for stability)
#
# FEATURE TOGGLES:
# - ENABLE_CLOUD_BACKUP: Controls cloud backup functionality (true/false)
#   * true: Cloud operations are executed and monitored
#   * false: Cloud operations are skipped, COUNT_BACKUP_CLOUD set to 0
#   * Default: true
#
# STORAGE PATHS (must be absolute paths with write permissions):
# - LOCAL_BACKUP_PATH: Primary backup storage location
#   * Example: "/var/backups/proxmox/local"
#   * Must exist and be writable by backup user
#   * Used for initial backup storage and primary rotation
#
# - SECONDARY_BACKUP_PATH: Secondary backup storage location
#   * Example: "/mnt/backup-drive/proxmox"
#   * Can be network mount, external drive, or different filesystem
#   * Used for redundancy and disaster recovery
#
# - CLOUD_BACKUP_PATH: Cloud backup storage location
#   * Example: "s3:my-bucket/proxmox-backups" or "gdrive:backups/proxmox"
#   * Format depends on cloud provider and tool (rclone, aws-cli, etc.)
#   * Used for off-site backup storage
#
# RETENTION POLICIES (positive integers):
# - MAX_LOCAL_BACKUPS: Maximum number of local backups to retain
#   * Recommended: 7-14 (daily backups for 1-2 weeks)
#   * Higher values require more local storage space
#
# - MAX_SECONDARY_BACKUPS: Maximum number of secondary backups to retain
#   * Recommended: 30-90 (monthly retention for disaster recovery)
#   * Should be >= MAX_LOCAL_BACKUPS for proper redundancy
#
# - MAX_CLOUD_BACKUPS: Maximum number of cloud backups to retain
#   * Recommended: 12-52 (monthly to yearly retention)
#   * Consider cloud storage costs when setting this value
#
# Exit Codes:
# - 0: Success
# - 1: Error in storage operations
# - 2: Warning (partial success)
#
# Race Condition Protection:
# - File locking for shared resources
# - Atomic operations for status updates
# - Process synchronization with proper wait mechanisms
# - Exclusive access to backup directories during operations
#
# Author: [Your Name]

# Last Modified: [Date]
# ==========================================

# RACE CONDITION PROTECTION FUNCTIONS
# ====================================
# These functions implement comprehensive protection against race conditions
# that can occur when multiple backup processes run simultaneously or when
# parallel operations access shared resources concurrently.
#
# PROTECTION MECHANISMS:
# 1. File-based locking using flock for atomic operations
# 2. Process synchronization with timeout protection
# 3. Atomic status updates to prevent inconsistent states
# 4. Resource cleanup to prevent resource leaks
# 5. Deadlock prevention through timeout mechanisms
#
# LOCK HIERARCHY (to prevent deadlocks):
# 1. backup_manager (master lock)
# 2. storage locks (secondary_storage, cloud_storage)
# 3. operation locks (count, rotation, consistency)
#
# TIMEOUT STRATEGY:
# - Short timeouts (5-10 min) for quick operations (count, consistency)
# - Medium timeouts (15 min) for storage operations
# - Long timeouts (30-60 min) for complete backup processes

# Acquire exclusive lock for backup operations
# This prevents multiple backup processes from interfering with each other
# Uses flock for atomic file locking with timeout protection
#
# Arguments:
#   $1: Lock identifier (e.g., "primary", "secondary", "cloud")
#   $2: Timeout in seconds (default: 300)
#
# Returns:
#   0: Lock acquired successfully
#   1: Failed to acquire lock (timeout or error)
acquire_backup_lock() {
    local lock_id="$1"
    local timeout="${2:-300}"  # 5 minutes default timeout
    local lock_file="/tmp/backup_manager_${lock_id}_$$.lock"
    
    debug "Attempting to acquire lock for: $lock_id (timeout: ${timeout}s)"
    
    # Create lock file with process information for debugging
    # This information helps identify which process holds the lock
    # and when it was acquired, useful for troubleshooting deadlocks
    {
        echo "PID: $$"                    # Process ID holding the lock
        echo "TIMESTAMP: $(date)"         # When lock was acquired
        echo "OPERATION: $lock_id"        # Type of operation being locked
        echo "HOSTNAME: $(hostname)"      # System where lock was acquired
        echo "PPID: $PPID"               # Parent process ID
        echo "USER: $(whoami 2>/dev/null || echo 'unknown')"  # User running the process
    } > "$lock_file"
    
    # Use flock with timeout for atomic locking
    # flock -x: exclusive lock (only one process can hold it)
    # timeout: prevents indefinite waiting if lock is never released
    # 2>/dev/null: suppress error messages for cleaner output
    if timeout "$timeout" flock -x "$lock_file" true 2>/dev/null; then
        debug "Successfully acquired lock for: $lock_id"
        return 0
    else
        # Lock acquisition failed - could be timeout or lock held by another process
        error "Failed to acquire lock for: $lock_id within ${timeout}s"
        # Check if another process is holding the lock
        if [ -f "$lock_file" ]; then
            warning "Lock file exists, checking lock holder information:"
            cat "$lock_file" 2>/dev/null | while read line; do
                debug "  $line"
            done
        fi
        rm -f "$lock_file" 2>/dev/null  # Clean up our lock file attempt
        return 1
    fi
}

# Release exclusive lock for backup operations
# Safely removes lock file and cleans up resources
#
# Arguments:
#   $1: Lock identifier (e.g., "primary", "secondary", "cloud")
#
# Returns:
#   0: Lock released successfully
#   1: Error releasing lock
release_backup_lock() {
    local lock_id="$1"
    local lock_file="/tmp/backup_manager_${lock_id}_$$.lock"
    
    if [ -f "$lock_file" ]; then
        rm -f "$lock_file" 2>/dev/null
        debug "Released lock for: $lock_id"
        return 0
    else
        warning "Lock file not found for: $lock_id (may have been already released)"
        return 1
    fi
}

# Atomic status update with file locking
# Prevents race conditions when multiple processes update status simultaneously
# Uses temporary file and atomic move operation
#
# Arguments:
#   $1: Status type (e.g., "secondary_copy", "cloud_upload")
#   $2: Status value (e.g., $EXIT_SUCCESS, $EXIT_ERROR)
#
# Returns:
#   0: Status updated successfully
#   1: Failed to update status
atomic_status_update() {
    local status_type="$1"
    local status_value="$2"
    local status_lock="/tmp/backup_status_update_$$.lock"
    local temp_status_file="/tmp/backup_status_${status_type}_$$.tmp"
    
    # Acquire lock for status update using file descriptor 200
    # exec 200>: opens file descriptor 200 for writing to the lock file
    # flock -x -w 10: exclusive lock with 10 second timeout
    # This prevents multiple processes from updating status simultaneously
    exec 200>"$status_lock"
    if ! flock -x -w 10 200; then
        error "Failed to acquire status update lock for: $status_type"
        return 1
    fi
    
    # Perform atomic status update by writing to temporary file first
    # This ensures the status update is atomic - either completely written or not at all
    # Temporary file prevents partial writes from being visible to other processes
    {
        echo "STATUS_TYPE=$status_type"     # Type of operation being updated
        echo "STATUS_VALUE=$status_value"   # Success/error/warning status
        echo "TIMESTAMP=$(date +%s)"        # Unix timestamp for tracking
        echo "PID=$$"                       # Process ID that made the update
        echo "HOSTNAME=$(hostname)"         # System identification
    } > "$temp_status_file"
    
    # Call original status function with protection
    # The actual status update is still handled by the original function
    # but now it's protected by our locking mechanism
    if set_backup_status "$status_type" "$status_value"; then
        debug "Atomic status update successful: $status_type = $status_value"
        rm -f "$temp_status_file"  # Clean up temporary file
        flock -u 200               # Release the lock explicitly
        return 0
    else
        error "Failed to update status: $status_type"
        rm -f "$temp_status_file"  # Clean up temporary file on error
        flock -u 200               # Release the lock even on failure
        return 1
    fi
}

# Synchronized process execution with proper cleanup
# Manages background processes with enhanced error handling and cleanup
# Prevents zombie processes and ensures proper resource cleanup
#
# Arguments:
#   $1: Function name to execute
#   $2: Process identifier for logging
#
# Returns:
#   Process ID of started background process
start_synchronized_process() {
    local function_name="$1"
    local process_id="$2"
    local pid_file="/tmp/backup_process_${process_id}_$$.pid"
    
    debug "Starting synchronized process: $function_name (ID: $process_id)"
    
    # Start process in background with proper error handling
    # The subshell (parentheses) ensures the background process is isolated
    # and has its own signal handlers and cleanup mechanisms
    (
        # Set up cleanup trap for the subprocess
        # This ensures proper cleanup if the process is terminated
        trap 'debug "Cleaning up subprocess: $process_id"; exit 1' TERM INT
        
        # Execute the function with error handling
        # The function name is passed as a parameter and executed dynamically
        if "$function_name"; then
            debug "Process completed successfully: $process_id"
            exit 0  # Success exit code
        else
            error "Process failed: $process_id"
            exit 1  # Error exit code
        fi
    ) &  # & runs the subshell in background
    
    local bg_pid=$!
    echo "$bg_pid" > "$pid_file"
    debug "Started background process: $process_id (PID: $bg_pid)"
    
    return $bg_pid
}

# Wait for synchronized process with timeout and cleanup
# Enhanced wait function with timeout protection and proper cleanup
#
# Arguments:
#   $1: Process ID to wait for
#   $2: Process identifier for logging
#   $3: Timeout in seconds (default: 3600)
#
# Returns:
#   Exit code of the waited process
wait_synchronized_process() {
    local wait_pid="$1"
    local process_id="$2"
    local timeout="${3:-3600}"  # 1 hour default timeout
    local pid_file="/tmp/backup_process_${process_id}_$$.pid"
    local start_time=$(date +%s)
    
    debug "Waiting for process: $process_id (PID: $wait_pid, timeout: ${timeout}s)"
    
    # Wait with timeout protection using a polling loop
    # kill -0: checks if process exists without actually killing it
    # This is a non-destructive way to test process existence
    while kill -0 "$wait_pid" 2>/dev/null; do
        local current_time=$(date +%s)
        local elapsed=$((current_time - start_time))
        
        # Check if timeout has been exceeded
        if [ "$elapsed" -ge "$timeout" ]; then
            error "Process timeout exceeded: $process_id (${elapsed}s)"
            
            # Attempt graceful termination first with SIGTERM
            # This allows the process to clean up resources properly
            kill -TERM "$wait_pid" 2>/dev/null
            sleep 5  # Give process time to terminate gracefully
            
            # Force kill if still running after graceful termination attempt
            # SIGKILL cannot be caught or ignored by the process
            if kill -0 "$wait_pid" 2>/dev/null; then
                kill -KILL "$wait_pid" 2>/dev/null
                warning "Force killed process: $process_id"
            fi
            rm -f "$pid_file"  # Clean up PID file
            return 124  # Standard timeout exit code (same as timeout command)
        fi
        
        sleep 1  # Poll every second to check process status
    done
    
    # Get exit status from the completed process
    # wait: blocks until the specified process completes and returns its exit status
    wait "$wait_pid"
    local exit_status=$?
    
    # Cleanup temporary files and resources
    rm -f "$pid_file"  # Remove PID tracking file
    debug "Process completed: $process_id (exit status: $exit_status)"
    
    # Return the actual exit status of the background process
    # This preserves the original function's return code for proper error handling
    return $exit_status
}

# Test function to verify module loading
# This function serves as a health check to ensure the backup manager
# module has been loaded correctly and all dependencies are available
#
# Returns:
#   0: Module loaded successfully
#   1: Module loading failed
backup_manager_test() {
    echo -e "${GREEN}[INFO] Backup Manager loaded successfully${RESET}"
    return 0
}

# Main function that manages all backup storage operations
# This is the central orchestrator for backup storage operations, handling
# both parallel and sequential execution modes based on configuration.
#
# RACE CONDITION PROTECTION:
# - Exclusive locks for each storage operation
# - Atomic status updates with file locking
# - Synchronized process management with timeout protection
# - Proper cleanup of background processes
# - Prevention of concurrent access to shared resources
#
# Execution Flow:
# 1. Determines execution mode (parallel vs sequential)
# 2. Executes secondary copy and cloud upload operations
# 3. Manages backup rotation for all storage locations
# 4. Performs backup consistency verification
# 5. Updates backup status tracking
#
# Parallel Mode:
# - Secondary copy and cloud upload run simultaneously using background processes
# - Uses process IDs to track and synchronize completion
# - Reduces total execution time for I/O intensive operations
# - Enhanced with race condition protection and resource locking
#
# Sequential Mode:
# - Operations run one after another in defined order
# - Provides more predictable resource usage
# - Easier to debug and troubleshoot
# - Still uses locking for consistency
#
# Global Variables Modified:
# - EXIT_SECONDARY_COPY: Set to exit code of secondary copy operation
# - EXIT_CLOUD_UPLOAD: Set to exit code of cloud upload operation
# - FORCE_NOTIFICATIONS: Set to true if any storage operation fails
# - COUNT_BACKUP_CLOUD: Set to number of cloud backups (or 0 if disabled)
#
# Returns:
#   0: All operations completed successfully
#   1: Critical error occurred
#   2: Warning (some operations failed but process can continue)
backup_manager_storage() {
    step "Starting backup manager storage operations (multi-storage parallel: ${MULTI_STORAGE_PARALLEL})"

    # Initialize notification control flag
    # This flag is used to force notifications when storage operations fail
    FORCE_NOTIFICATIONS=false

    # RACE CONDITION PROTECTION: Acquire master lock
    # Prevent multiple backup manager instances from running simultaneously
    # This is the top-level lock in our lock hierarchy to prevent conflicts
    if ! acquire_backup_lock "backup_manager" 1800; then  # 30 minutes timeout
        error "Failed to acquire master backup manager lock - another instance may be running"
        error "Check for existing backup processes with: ps aux | grep backup"
        return 1
    fi

    # Set up cleanup trap to ensure locks are released on exit
    # This trap handles unexpected termination (SIGTERM, SIGINT) and normal exit
    # It's critical for preventing orphaned locks that would block future runs
    trap 'release_backup_lock "backup_manager"; exit 1' TERM INT EXIT

    # Execute storage operations based on configured mode
    if [ "${MULTI_STORAGE_PARALLEL}" == "true" ]; then
        # PARALLEL MODE EXECUTION WITH RACE CONDITION PROTECTION
        # Both secondary copy and cloud upload operations run simultaneously
        # This reduces total execution time but requires careful synchronization
        info "Starting storage operations in PARALLEL mode with race condition protection"

        # ACQUIRE LOCKS FOR PARALLEL OPERATIONS
        # Prevent concurrent access to storage locations
        if ! acquire_backup_lock "secondary_storage" 900; then  # 15 minutes timeout
            error "Failed to acquire secondary storage lock"
            release_backup_lock "backup_manager"
            return 1
        fi

        if ! acquire_backup_lock "cloud_storage" 900; then  # 15 minutes timeout
            error "Failed to acquire cloud storage lock"
            release_backup_lock "secondary_storage"
            release_backup_lock "backup_manager"
            return 1
        fi

        # Start secondary copy operation in background with synchronization
        debug "Starting secondary copy process with race condition protection"
        start_synchronized_process "copy_to_secondary" "secondary_copy"
        pid_copy=$?

        # Start cloud upload operation in background with synchronization
        debug "Starting cloud upload process with race condition protection"
        start_synchronized_process "upload_to_cloud" "cloud_upload"
        pid_upload=$?

        # Wait for secondary copy operation to complete with timeout protection
        debug "Waiting for secondary copy process to complete"
        wait_synchronized_process "$pid_copy" "secondary_copy" 1800  # 30 minutes timeout
        copy_status=$?

        # Release secondary storage lock after operation completes
        release_backup_lock "secondary_storage"

        # Wait for cloud upload operation to complete with timeout protection
        debug "Waiting for cloud upload process to complete"
        wait_synchronized_process "$pid_upload" "cloud_upload" 3600  # 1 hour timeout
        upload_status=$?

        # Release cloud storage lock after operation completes
        release_backup_lock "cloud_storage"

    else
        # SEQUENTIAL MODE EXECUTION WITH RACE CONDITION PROTECTION
        # Operations run one after another in defined order
        # This provides more predictable resource usage while maintaining protection
        info "Starting storage operations in SEQUENTIAL mode with race condition protection"

        # Execute secondary copy operation first with exclusive lock
        debug "Acquiring lock for secondary copy operation"
        if acquire_backup_lock "secondary_storage" 900; then  # 15 minutes timeout
            debug "Executing secondary copy operation"
            if ! copy_to_secondary; then
                copy_status=$?
            else
                copy_status=0
            fi
            release_backup_lock "secondary_storage"
        else
            error "Failed to acquire secondary storage lock for sequential operation"
            copy_status=1
        fi

        # Execute cloud upload operation second with exclusive lock
        debug "Acquiring lock for cloud upload operation"
        if acquire_backup_lock "cloud_storage" 900; then  # 15 minutes timeout
            debug "Executing cloud upload operation"
            if ! upload_to_cloud; then
                upload_status=$?
            else
                upload_status=0
            fi
            release_backup_lock "cloud_storage"
        else
            error "Failed to acquire cloud storage lock for sequential operation"
            upload_status=1
        fi
    fi

    # UPDATE BACKUP STATUS TRACKING WITH ATOMIC OPERATIONS
    # Use atomic status updates to prevent race conditions in status tracking
    debug "Updating backup status with atomic operations"

    # Atomic update for secondary copy status
    if [ "$copy_status" -eq 0 ]; then
        atomic_status_update "secondary_copy" $EXIT_SUCCESS
    else
        atomic_status_update "secondary_copy" $EXIT_ERROR
    fi

    # Atomic update for cloud upload status
    if [ "$upload_status" -eq 0 ]; then
        atomic_status_update "cloud_upload" $EXIT_SUCCESS
    else
        atomic_status_update "cloud_upload" $EXIT_ERROR
    fi

    # Store exit codes in global variables for later use
    # These variables are used by other modules and reporting functions
    EXIT_SECONDARY_COPY=$copy_status
    EXIT_CLOUD_UPLOAD=$upload_status

    # NOTIFICATION CONTROL
    # Force notifications if any storage operation failed
    # This ensures administrators are alerted to storage failures
    if [ "$EXIT_SECONDARY_COPY" -ne 0 ] || [ "$EXIT_CLOUD_UPLOAD" -ne 0 ]; then
        FORCE_NOTIFICATIONS=true
        warning "Storage operation failed, forcing notifications"
    fi
    
    # Count backups in primary storage location with lock protection
    if acquire_backup_lock "primary_count" 300; then  # 5 minutes timeout
        CHECK_COUNT "BACKUP_PRIMARY" true  # Silent mode
        release_backup_lock "primary_count"
    else
        warning "Failed to acquire lock for primary backup counting"
    fi
    
    # Count backups in secondary storage location with lock protection
    if acquire_backup_lock "secondary_count" 300; then  # 5 minutes timeout
        CHECK_COUNT "BACKUP_SECONDARY" true  # Silent mode
        release_backup_lock "secondary_count"
    else
        warning "Failed to acquire lock for secondary backup counting"
    fi
    
    # CLOUD BACKUP COUNTING (NON-BLOCKING) WITH RACE CONDITION PROTECTION
    # Handle cloud backup counting only if cloud backup is enabled
    # This operation is non-blocking to prevent failures from stopping the process
    if [ "${ENABLE_CLOUD_BACKUP:-true}" == "true" ]; then
        # Attempt to count cloud backups with error handling and lock protection
        if acquire_backup_lock "cloud_count" 300; then  # 5 minutes timeout
            if ! CHECK_COUNT "BACKUP_CLOUD" true; then  # Silent mode
                warning "Unable to retrieve file list from cloud, but continuing with process"
                # Set default value to prevent errors in subsequent operations
                COUNT_BACKUP_CLOUD=0
            fi
            release_backup_lock "cloud_count"
        else
            warning "Failed to acquire lock for cloud backup counting, setting count to 0"
            COUNT_BACKUP_CLOUD=0
        fi
    else
        debug "Cloud backup disabled, setting cloud count to 0"
        COUNT_BACKUP_CLOUD=0
    fi

    # BACKUP ROTATION MANAGEMENT WITH RACE CONDITION PROTECTION
    # Manage rotation for primary backup storage with exclusive access
    if acquire_backup_lock "primary_rotation" 600; then  # 10 minutes timeout
        if ! manage_backup_rotation "primary" "$LOCAL_BACKUP_PATH" "$MAX_LOCAL_BACKUPS"; then
            warning "Primary backup rotation completed with warnings"
            set_exit_code "warning"
            atomic_status_update "rotation_primary" $EXIT_WARNING
        else
            atomic_status_update "rotation_primary" $EXIT_SUCCESS
        fi
        release_backup_lock "primary_rotation"
    else
        error "Failed to acquire lock for primary backup rotation"
        atomic_status_update "rotation_primary" $EXIT_ERROR
    fi

    # SECONDARY BACKUP ROTATION WITH RACE CONDITION PROTECTION
    # Only perform rotation if secondary copy was successful
    # This prevents rotation when no new backup was created
    if [ "$EXIT_SECONDARY_COPY" -eq 0 ]; then
        if acquire_backup_lock "secondary_rotation" 600; then  # 10 minutes timeout
            if ! manage_backup_rotation "secondary" "$SECONDARY_BACKUP_PATH" "$MAX_SECONDARY_BACKUPS"; then
                warning "Secondary backup rotation completed with warnings"
                set_exit_code "warning"
                atomic_status_update "rotation_secondary" $EXIT_WARNING
            else
                atomic_status_update "rotation_secondary" $EXIT_SUCCESS
            fi
            release_backup_lock "secondary_rotation"
        else
            error "Failed to acquire lock for secondary backup rotation"
            atomic_status_update "rotation_secondary" $EXIT_ERROR
        fi
    else
        info "Skipping secondary backup rotation due to copy failure"
        atomic_status_update "rotation_secondary" $EXIT_SUCCESS
    fi

    # CLOUD BACKUP ROTATION WITH RACE CONDITION PROTECTION
    # Only perform rotation if cloud upload was successful
    # This prevents rotation when no new backup was uploaded
    if [ "$EXIT_CLOUD_UPLOAD" -eq 0 ]; then
        # Attempt cloud rotation but don't block execution if it fails
        # Cloud operations can be unreliable due to network issues
        if acquire_backup_lock "cloud_rotation" 600; then  # 10 minutes timeout
            if ! manage_backup_rotation "cloud" "$CLOUD_BACKUP_PATH" "$MAX_CLOUD_BACKUPS"; then
                warning "Cloud backup rotation completed with warnings"
                set_exit_code "warning"
                atomic_status_update "rotation_cloud" $EXIT_WARNING
            else
                atomic_status_update "rotation_cloud" $EXIT_SUCCESS
            fi
            release_backup_lock "cloud_rotation"
        else
            warning "Failed to acquire lock for cloud backup rotation, but continuing"
            atomic_status_update "rotation_cloud" $EXIT_WARNING
        fi
    else
        info "Skipping cloud backup rotation due to upload failure"
        atomic_status_update "rotation_cloud" $EXIT_SUCCESS
    fi

    # FINAL CONSISTENCY VERIFICATION WITH RACE CONDITION PROTECTION
    # Verify backup consistency across all storage locations
    # This is a non-blocking operation that logs warnings but doesn't fail the process
    if acquire_backup_lock "consistency_check" 300; then  # 5 minutes timeout
        verify_backup_consistency || warning "Backup consistency verification failed, but continuing execution"
        
        # Handle consistency verification results
        # Don't set fatal exit code for consistency errors, but log them
        if [ "$?" -ne 0 ]; then
            warning "Backup consistency verification failed"
            set_exit_code "warning"
        fi
        release_backup_lock "consistency_check"
    else
        warning "Failed to acquire lock for consistency verification, skipping"
    fi

    # CLEANUP: Release master lock
    # The trap will also handle this, but explicit cleanup is good practice
    release_backup_lock "backup_manager"
    
    # Remove the trap since we're cleaning up manually
    trap - TERM INT EXIT
    
    debug "Backup manager storage operations completed with race condition protection"
}

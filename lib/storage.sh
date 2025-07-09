#!/bin/bash
# Backup storage management

# Global variable initialization
has_errors=false
EXIT_BACKUP_ROTATION_PRIMARY=$EXIT_SUCCESS

# Constants for standardized timeouts
readonly RCLONE_TIMEOUT_SHORT=30
readonly RCLONE_TIMEOUT_MEDIUM=60
readonly RCLONE_TIMEOUT_LONG=300

# Cache for configuration checks
_secondary_backup_enabled=""
_cloud_backup_enabled=""

# Helper function to check if secondary backup is enabled
is_secondary_backup_enabled() {
    if [ -z "$_secondary_backup_enabled" ]; then
        _secondary_backup_enabled=$([ "${ENABLE_SECONDARY_BACKUP:-false}" = "true" ] && echo "true" || echo "false")
    fi
    [ "$_secondary_backup_enabled" = "true" ]
}

# Helper function to check if cloud backup is enabled and working
is_cloud_backup_enabled() {
    # Use the unified counting system which provides comprehensive cloud status
    # This includes connectivity testing, not just configuration checks
    if [ -z "${COUNT_CLOUD_CONNECTIVITY_STATUS:-}" ]; then
        # If connectivity status is not available, fall back to basic config check
        [ "${ENABLE_CLOUD_BACKUP:-true}" = "true" ]
    else
        # Use the comprehensive status from the unified system
        [ "${ENABLE_CLOUD_BACKUP:-true}" = "true" ] && [ "$COUNT_CLOUD_CONNECTIVITY_STATUS" = "ok" ]
    fi
}

# Helper function to check directory existence with cache
check_directory_exists() {
    local dir="$1"
    [ -n "$dir" ] && [ -d "$dir" ]
}

# Copy backups to secondary storage
copy_to_secondary() {
    step "Copying backup to secondary storage"
    
    # Check if secondary backup is enabled
    if ! is_secondary_backup_enabled; then
        info "Secondary backup is disabled, skipping secondary copy"
        set_backup_status "secondary_copy" $EXIT_SUCCESS
        return $EXIT_SUCCESS
    fi
    
    if [ "$DRY_RUN_MODE" = "true" ]; then
        info "Dry run mode: Would copy backup to secondary location"
        set_backup_status "secondary_copy" $EXIT_SUCCESS
        return $EXIT_SUCCESS
    fi
    
    if [ -z "$BACKUP_FILE" ] || [ ! -f "$BACKUP_FILE" ]; then
        warning "Backup file not found, skipping secondary copy"
        set_exit_code "warning"
        set_backup_status "secondary_copy" $EXIT_WARNING
        return $EXIT_WARNING
    fi
    
    # Check if secondary backup is enabled
    if [ "${ENABLE_SECONDARY_BACKUP:-false}" != "true" ]; then
        debug "Secondary backup is disabled, skipping directory creation and copy"
        set_backup_status "secondary_copy" $EXIT_SUCCESS
        return $EXIT_SUCCESS
    fi
    
    mkdir -p "$SECONDARY_BACKUP_PATH" "$SECONDARY_LOG_PATH" 2>/dev/null || {
        warning "Failed to create secondary backup paths: $SECONDARY_BACKUP_PATH"
        set_exit_code "warning"
        set_backup_status "secondary_copy" $EXIT_WARNING
        return $EXIT_WARNING
    }
    
    # Copy backup file
    debug "Original file: $BACKUP_FILE ->"
    if ! cp "$BACKUP_FILE" "$SECONDARY_BACKUP_PATH/"; then
        error "Failed to copy backup to secondary location"
        set_exit_code "warning"
        set_backup_status "secondary_copy" $EXIT_WARNING
        return $EXIT_WARNING
    fi
    debug "Copied file: $SECONDARY_BACKUP_PATH/$(basename "$BACKUP_FILE")"
    
    # Copy hash file
    debug "Original hash: ${BACKUP_FILE}.sha256 ->"
    if ! cp "${BACKUP_FILE}.sha256" "$SECONDARY_BACKUP_PATH/"; then
        error "Failed to copy backup checksum to secondary location"
        set_exit_code "warning"
        set_backup_status "secondary_copy" $EXIT_WARNING
        return $EXIT_WARNING
    fi
    debug "Copied hash: $SECONDARY_BACKUP_PATH/$(basename "${BACKUP_FILE}.sha256")"
    
    # Copy log file if it exists
    if [ -f "$LOG_FILE" ]; then
        debug "Original log: $LOG_FILE ->"
        if ! cp "$LOG_FILE" "$SECONDARY_LOG_PATH/"; then
            warning "Failed to copy log to secondary location"
            set_exit_code "warning"
            set_backup_status "secondary_copy" $EXIT_WARNING
        fi
        debug "Copied: $SECONDARY_LOG_PATH/$(basename "$LOG_FILE")"
    fi
    
    success "Backup copied to secondary location successfully"
    set_backup_status "secondary_copy" $EXIT_SUCCESS
    return $EXIT_SUCCESS
}

# Enhanced verification with simplified retry logic
verify_cloud_backup_upload() {
    local backup_basename="$1"
    local max_attempts="${2:-2}"  # Reduced from 3 to 2 attempts
    
    # Check if verification should be skipped
    if [ "${SKIP_CLOUD_VERIFICATION:-false}" = "true" ]; then
        debug "Cloud backup verification disabled by configuration - skipping verification"
        return 0
    fi
    
    debug "Verifying backup upload to cloud storage"
    
    local attempt=0
    while [ $attempt -lt $max_attempts ]; do
        attempt=$((attempt + 1))
        
        if [ $attempt -eq 1 ]; then
            debug "Verifying backup upload (attempt $attempt of $max_attempts)"
        else
            warning "Backup verification failed, retrying (attempt $attempt of $max_attempts)"
            sleep 2  # Brief pause before retry
        fi
        
        # Primary verification method
        if timeout $RCLONE_TIMEOUT_SHORT rclone lsl "${RCLONE_REMOTE}:${CLOUD_BACKUP_PATH}/$backup_basename" ${RCLONE_FLAGS} >/dev/null 2>&1; then
            if [ $attempt -eq 1 ]; then
                debug "Backup upload verification successful on first attempt"
            else
                success "Backup upload verification successful on attempt $attempt"
            fi
            return 0
        fi
        
        warning "Primary verification failed on attempt $attempt"
    done
    
    # Single alternative verification method (simplified)
    warning "Primary verification failed, trying alternative method"
    if timeout $RCLONE_TIMEOUT_SHORT rclone ls "${RCLONE_REMOTE}:${CLOUD_BACKUP_PATH}" ${RCLONE_FLAGS} 2>/dev/null | grep -q "$(basename "$backup_basename")$"; then
        success "Alternative backup verification successful"
        return 0
    fi
    
    warning "Backup verification failed after $max_attempts attempts and alternative method"
    return 1
}

# ===========================================
# PARALLEL CLOUD UPLOAD FUNCTIONS
# ===========================================

# Upload backup file asynchronously
upload_backup_file_async() {
    local result_file="/tmp/upload_backup_$$"
    local start_time=$(date +%s)
    
    debug "Starting asynchronous backup file upload"
    debug "Starting backup file upload to cloud storage"
    
    if timeout $RCLONE_TIMEOUT_LONG rclone copy "$BACKUP_FILE" "${RCLONE_REMOTE}:${CLOUD_BACKUP_PATH}/" --bwlimit=${RCLONE_BANDWIDTH_LIMIT} ${RCLONE_FLAGS} --stats=10s --stats-one-line 2>&1 | while read -r line; do
        debug "Backup upload progress: $line"
    done; then
        local end_time=$(date +%s)
        local duration=$((end_time - start_time))
        echo "backup_upload=SUCCESS duration=$duration" > "$result_file"
        debug "Backup file upload completed successfully in ${duration}s"
    else
        local end_time=$(date +%s)
        local duration=$((end_time - start_time))
        echo "backup_upload=FAILED duration=$duration" > "$result_file"
        debug "Backup file upload failed after ${duration}s"
    fi
}

# Upload checksum file asynchronously
upload_checksum_file_async() {
    local result_file="/tmp/upload_checksum_$$"
    local start_time=$(date +%s)
    
    debug "Starting asynchronous checksum file upload"
    debug "Starting checksum file upload to cloud storage"
    
    if [ ! -f "${BACKUP_FILE}.sha256" ]; then
        echo "checksum_upload=SKIPPED reason=file_not_found" > "$result_file"
        debug "Checksum file not found, skipping upload"
        return 0
    fi
    
    if timeout $RCLONE_TIMEOUT_MEDIUM rclone copy "${BACKUP_FILE}.sha256" "${RCLONE_REMOTE}:${CLOUD_BACKUP_PATH}/" ${RCLONE_FLAGS} 2>/dev/null; then
        local end_time=$(date +%s)
        local duration=$((end_time - start_time))
        echo "checksum_upload=SUCCESS duration=$duration" > "$result_file"
        debug "Checksum file upload completed successfully in ${duration}s"
    else
        local end_time=$(date +%s)
        local duration=$((end_time - start_time))
        echo "checksum_upload=FAILED duration=$duration" > "$result_file"
        debug "Checksum file upload failed after ${duration}s"
    fi
}

# Verify checksum file upload
verify_cloud_checksum_upload() {
    local checksum_basename="$1"
    local max_attempts="${2:-2}"
    
    if [ "${SKIP_CLOUD_VERIFICATION:-false}" = "true" ]; then
        debug "Cloud checksum verification disabled by configuration"
        return 0
    fi
    
    debug "Verifying checksum file upload to cloud storage"
    
    local attempt=0
    while [ $attempt -lt $max_attempts ]; do
        attempt=$((attempt + 1))
        
        if timeout $RCLONE_TIMEOUT_SHORT rclone lsl "${RCLONE_REMOTE}:${CLOUD_BACKUP_PATH}/$checksum_basename" ${RCLONE_FLAGS} >/dev/null 2>&1; then
            debug "Checksum file verification successful on attempt $attempt"
            return 0
        fi
        
        if [ $attempt -lt $max_attempts ]; then
            debug "Checksum verification failed on attempt $attempt, retrying"
            sleep 1
        fi
    done
    
    debug "Checksum file verification failed after $max_attempts attempts"
    return 1
}

# Wait for parallel uploads to complete
wait_for_parallel_uploads() {
    local upload_pids=("$@")
    local failed_uploads=0
    local total_uploads=${#upload_pids[@]}
    
    debug "Waiting for $total_uploads parallel uploads to complete"
    
    # Wait for all background processes
    for pid in "${upload_pids[@]}"; do
        if wait "$pid"; then
            debug "Upload process $pid completed successfully"
        else
            warning "Upload process $pid failed"
            ((failed_uploads++))
        fi
    done
    
    # Check results from temporary files
    local backup_result=""
    local checksum_result=""
    
    if [ -f "/tmp/upload_backup_$$" ]; then
        backup_result=$(cat "/tmp/upload_backup_$$")
        rm -f "/tmp/upload_backup_$$"
    fi
    
    if [ -f "/tmp/upload_checksum_$$" ]; then
        checksum_result=$(cat "/tmp/upload_checksum_$$")
        rm -f "/tmp/upload_checksum_$$"
    fi
    
    # Process results
    debug "Upload results: backup=[$backup_result] checksum=[$checksum_result]"
    
    # Check if backup upload succeeded (critical)
    if [[ "$backup_result" == *"backup_upload=SUCCESS"* ]]; then
        info "Backup file upload completed successfully"
    else
        error "Backup file upload failed - this is critical"
        return 1
    fi
    
    # Check checksum upload (warning if failed)
    if [[ "$checksum_result" == *"checksum_upload=SUCCESS"* ]]; then
        debug "Checksum file upload completed successfully"
    elif [[ "$checksum_result" == *"checksum_upload=SKIPPED"* ]]; then
        debug "Checksum file upload skipped (file not found)"
    else
        warning "Checksum file upload failed"
    fi
    
    return 0
}

# Verify all uploads in parallel
verify_cloud_uploads_parallel() {
    local verify_pids=()
    local backup_basename=$(basename "$BACKUP_FILE")
    local checksum_basename="${backup_basename}.sha256"
    
    info "Starting parallel verification of uploaded files"
    
    # Create temporary files for verification results
    local backup_verify_file="/tmp/verify_backup_$$"
    local checksum_verify_file="/tmp/verify_checksum_$$"
    
    # Start backup verification in background
    {
        if verify_cloud_backup_upload "$backup_basename"; then
            echo "backup_verify=SUCCESS" > "$backup_verify_file"
        else
            echo "backup_verify=FAILED" > "$backup_verify_file"
        fi
    } &
    verify_pids[0]=$!
    
    # Start checksum verification in background
    {
        if [ -f "${BACKUP_FILE}.sha256" ] && verify_cloud_checksum_upload "$checksum_basename"; then
            echo "checksum_verify=SUCCESS" > "$checksum_verify_file"
        else
            echo "checksum_verify=FAILED" > "$checksum_verify_file"
        fi
    } &
    verify_pids[1]=$!
    
    # Wait for all verifications to complete
    for pid in "${verify_pids[@]}"; do
        wait "$pid"
    done
    
    # Read and process verification results
    local backup_verify_result=""
    local checksum_verify_result=""
    
    [ -f "$backup_verify_file" ] && backup_verify_result=$(cat "$backup_verify_file")
    [ -f "$checksum_verify_file" ] && checksum_verify_result=$(cat "$checksum_verify_file")
    
    # Cleanup temporary files
    rm -f "$backup_verify_file" "$checksum_verify_file"
    
    # Evaluate results
    debug "Verification results: backup=[$backup_verify_result] checksum=[$checksum_verify_result]"
    
    if [[ "$backup_verify_result" == *"backup_verify=SUCCESS"* ]]; then
        info "Backup file verification successful"
        
        # Check checksum verification (non-critical)
        if [[ "$checksum_verify_result" == *"checksum_verify=SUCCESS"* ]]; then
            debug "Checksum file verification also successful"
        else
            warning "Checksum file verification failed (non-critical)"
        fi
        
        return 0
    else
        warning "Backup file verification failed"
        return 1
    fi
}

# Main parallel upload function
upload_to_cloud_parallel() {
    local start_time=$(date +%s)
    step "Uploading backup files to cloud storage (parallel mode)"
    
    # Validate prerequisites
    if [ -z "$BACKUP_FILE" ] || [ ! -f "$BACKUP_FILE" ]; then
        error "Backup file not found for parallel upload"
        return 1
    fi
    
    local upload_pids=()
    
    # Start backup file upload in background
    upload_backup_file_async &
    upload_pids[0]=$!
    
    # Start checksum file upload in background
    upload_checksum_file_async &
    upload_pids[1]=$!
    
    # Wait for uploads to complete
    if ! wait_for_parallel_uploads "${upload_pids[@]}"; then
        error "Parallel upload failed"
        return 1
    fi
    
    local upload_end_time=$(date +%s)
    local upload_duration=$((upload_end_time - start_time))
    debug "Parallel backup and checksum upload completed in ${upload_duration}s"
    
    # Perform parallel verification
    if [ "${CLOUD_PARALLEL_VERIFICATION:-true}" = "true" ]; then
        local verify_start_time=$(date +%s)
        if verify_cloud_uploads_parallel; then
            local verify_end_time=$(date +%s)
            local verify_duration=$((verify_end_time - verify_start_time))
            debug "Parallel verification completed successfully in ${verify_duration}s"
            
            local total_duration=$((verify_end_time - start_time))
            info "Total parallel cloud upload and verification completed in ${total_duration}s"
            return 0
        else
            warning "Parallel verification failed"
            return 1
        fi
    else
        info "Parallel verification disabled by configuration"
        local total_duration=$((upload_end_time - start_time))
        info "Parallel cloud upload completed in ${total_duration}s"
        return 0
    fi
}

# Upload backup to cloud storage
upload_to_cloud() {
    step "Uploading backup to cloud storage"
    
    # Check if cloud backup is enabled
    if ! is_cloud_backup_enabled; then
        info "Cloud backup is disabled, skipping cloud upload"
        set_backup_status "cloud_upload" $EXIT_SUCCESS
        return $EXIT_SUCCESS
    fi

    if [ "$DRY_RUN_MODE" = "true" ]; then
        info "Dry run mode: Would upload backup to cloud storage"
        set_backup_status "cloud_upload" $EXIT_SUCCESS
        return $EXIT_SUCCESS
    fi

    if [ -z "$BACKUP_FILE" ] || [ ! -f "$BACKUP_FILE" ]; then
        warning "Backup file not found, skipping cloud upload"
        set_exit_code "error"
        set_backup_status "cloud_upload" $EXIT_ERROR
        export CLOUD_BACKUP_ERROR=true
        return $EXIT_ERROR
    fi

    if ! command -v rclone &> /dev/null; then
        warning "rclone not found, skipping cloud upload"
        set_exit_code "warning"
        set_backup_status "cloud_upload" $EXIT_WARNING
        export CLOUD_BACKUP_ERROR=true
        return $EXIT_WARNING
    fi

    if ! timeout $RCLONE_TIMEOUT_SHORT rclone listremotes 2>/dev/null | grep -q "^${RCLONE_REMOTE}:$"; then
        warning "rclone remote '${RCLONE_REMOTE}' not configured, skipping cloud upload"
        warning "Configure rclone remote with: rclone config"
        set_exit_code "warning"
        set_backup_status "cloud_upload" $EXIT_WARNING
        export CLOUD_BACKUP_ERROR=true
        return $EXIT_WARNING
    fi

    # Note: Cloud connectivity testing is now handled by the unified counting system
    # CHECK_COUNT "CLOUD_CONNECTIVITY" in proxmox-backup.sh provides comprehensive testing
    # This includes authentication, network connectivity, and path accessibility checks

    # Choose upload mode based on configuration
    local upload_mode="${CLOUD_UPLOAD_MODE:-parallel}"
    local upload_start_time=$(date +%s)
    
    if [ "$upload_mode" = "parallel" ]; then
        info "Using parallel upload mode for improved performance"
        
        # Try parallel upload first
        if upload_to_cloud_parallel; then
            debug "Parallel upload and verification completed successfully"
            success "Backup uploaded to cloud storage successfully (parallel mode)"
            set_backup_status "cloud_upload" $EXIT_SUCCESS
            export CLOUD_BACKUP_ERROR=false
            return $EXIT_SUCCESS
        else
            warning "Parallel upload failed, falling back to sequential mode"
            upload_mode="sequential"
        fi
    fi
    
    if [ "$upload_mode" = "sequential" ]; then
        info "Using sequential upload mode"
        
        debug "Uploading backup to cloud storage using rclone"
        
        # Prepare remote paths and remote file
        remote_path="${RCLONE_REMOTE}:${CLOUD_BACKUP_PATH}/"
        remote_file_path="${remote_path}$(basename "$BACKUP_FILE")"
        debug "Destination: $remote_file_path"
        
        # Upload with progress (stats every 5s)
        if ! { set -o pipefail; timeout $RCLONE_TIMEOUT_LONG rclone copy "$BACKUP_FILE" "$remote_path" --bwlimit=${RCLONE_BANDWIDTH_LIMIT} ${RCLONE_FLAGS} --stats=5s --stats-one-line 2>&1 | while read -r line; do
                debug "Progress: $line"
            done; }; then
            error "Failed to upload backup to cloud storage"
            set_exit_code "warning"
            set_backup_status "cloud_upload" $EXIT_WARNING
            export CLOUD_BACKUP_ERROR=true
            return $EXIT_WARNING
        fi
        
        # Simplified verification logic
        local backup_basename=$(basename "$BACKUP_FILE")
        if verify_cloud_backup_upload "$backup_basename"; then
            verification_success=true
        else
            verification_success=false
        fi
        
        # Upload checksum file
        if ! timeout $RCLONE_TIMEOUT_LONG rclone copy "${BACKUP_FILE}.sha256" "${RCLONE_REMOTE}:${CLOUD_BACKUP_PATH}/" ${RCLONE_FLAGS} 2>/dev/null; then
            warning "Failed to upload checksum file to cloud storage"
            set_exit_code "warning"
            set_backup_status "cloud_upload" $EXIT_WARNING
            # Continue anyway
        fi
        
        # Calculate total time for sequential mode
        local upload_end_time=$(date +%s)
        local total_duration=$((upload_end_time - upload_start_time))
        
        # Final status reporting
        if [ "$verification_success" = "true" ]; then
            info "Backup file uploaded and verified successfully in cloud storage"
            success "Backup uploaded to cloud storage successfully (sequential mode, ${total_duration}s)"
            set_backup_status "cloud_upload" $EXIT_SUCCESS
            export CLOUD_BACKUP_ERROR=false
            return $EXIT_SUCCESS
        else
            warning "Backup upload verification failed but upload command succeeded"
            warning "File may still be synchronizing in cloud storage - check manually if needed"
            info "Backup file uploaded to cloud storage (verification inconclusive)"
            success "Backup uploaded to cloud storage with verification warnings (sequential mode, ${total_duration}s)"
            set_backup_status "cloud_upload" $EXIT_WARNING
            export CLOUD_BACKUP_ERROR=false  # Don't mark as error since upload succeeded
            return $EXIT_SUCCESS  # Don't fail the entire process for verification issues
        fi
    fi
    
    # This should not be reached
    error "Unknown upload mode or unexpected error in cloud upload"
    set_backup_status "cloud_upload" $EXIT_ERROR
    export CLOUD_BACKUP_ERROR=true
    return $EXIT_ERROR
}

# Manage backup rotation for a specific location
manage_backup_rotation() {
    local location="$1"
    local backup_path="$2"
    local max_backups="$3"
    local has_errors=false
    
    step "Managing backup rotation for $location storage"
    
    # If it's cloud and cloud backup is disabled, skip rotation
    if [ "$location" = "cloud" ] && ! is_cloud_backup_enabled; then
        info "Cloud backup is disabled, skipping cloud backup rotation"
        set_backup_status "rotation_cloud" $EXIT_SUCCESS
        return $EXIT_SUCCESS
    fi
    
    # If it's secondary and secondary backup is disabled, skip rotation
    if [ "$location" = "secondary" ] && ! is_secondary_backup_enabled; then
        info "Secondary backup is disabled, skipping secondary backup rotation"
        set_backup_status "rotation_secondary" $EXIT_SUCCESS
        return $EXIT_SUCCESS
    fi
    
    # Use counts from unified counting system directly
    case "$location" in
        "primary")
            if [ "$COUNT_BACKUP_PRIMARY" -gt "$max_backups" ]; then
                local to_delete=$((COUNT_BACKUP_PRIMARY - max_backups))
                info "Found $COUNT_BACKUP_PRIMARY backups in $location storage, removing $to_delete oldest backups"
                delete_oldest_local_backups "$backup_path" "${PROXMOX_TYPE}-backup-*.tar*" "$to_delete" "has_errors"
                info "Backup count after rotation: $((COUNT_BACKUP_PRIMARY - to_delete))"
            else
                info "No backup rotation needed for $location storage (current: $COUNT_BACKUP_PRIMARY, max: $max_backups)"
            fi
            ;;
        "secondary")
            if [ "$COUNT_BACKUP_SECONDARY" -gt "$max_backups" ]; then
                local to_delete=$((COUNT_BACKUP_SECONDARY - max_backups))
                info "Found $COUNT_BACKUP_SECONDARY backups in $location storage, removing $to_delete oldest backups"
                delete_oldest_local_backups "$backup_path" "${PROXMOX_TYPE}-backup-*.tar*" "$to_delete" "has_errors"
                info "Backup count after rotation: $((COUNT_BACKUP_SECONDARY - to_delete))"
            else
                info "No backup rotation needed for $location storage (current: $COUNT_BACKUP_SECONDARY, max: $max_backups)"
            fi
            ;;
        "cloud")
            if [ "$COUNT_BACKUP_CLOUD" -gt "$max_backups" ]; then
                local to_delete=$((COUNT_BACKUP_CLOUD - max_backups))
                info "Found $COUNT_BACKUP_CLOUD backups in $location storage, removing $to_delete oldest backups"
                if ! delete_oldest_cloud_backups "$backup_path" "$to_delete" "has_errors"; then
                    warning "Cloud backup rotation encountered errors but continuing execution"
                    has_errors=true
                fi
                info "Backup count after rotation: $((COUNT_BACKUP_CLOUD - to_delete))"
            else
                info "No backup rotation needed for $location storage (current: $COUNT_BACKUP_CLOUD, max: $max_backups)"
            fi
            ;;
        *)
            error "Invalid location: $location"
            # For cloud, don't block execution
            if [ "$location" = "cloud" ]; then
                set_backup_status "rotation_cloud" $EXIT_WARNING
                return $EXIT_SUCCESS
            fi
            return $EXIT_ERROR
            ;;
    esac
    
    if [ "$has_errors" = true ]; then
        warning "Backup rotation for $location storage completed with warnings"
        case "$location" in
            "primary")
                set_backup_status "rotation_primary" $EXIT_WARNING
                ;;
            "secondary")
                set_backup_status "rotation_secondary" $EXIT_WARNING
                ;;
            "cloud")
                set_backup_status "rotation_cloud" $EXIT_WARNING
                ;;
        esac
    else
        success "Backup rotation for $location storage completed successfully"
        case "$location" in
            "primary")
                set_backup_status "rotation_primary" $EXIT_SUCCESS
                ;;
            "secondary")
                set_backup_status "rotation_secondary" $EXIT_SUCCESS
                ;;
            "cloud")
                set_backup_status "rotation_cloud" $EXIT_SUCCESS
                ;;
        esac
    fi
    
    # For cloud, ensure it never blocks main execution
    if [ "$location" = "cloud" ]; then
        return $EXIT_SUCCESS
    fi
    
    # For other locations, return appropriate code
    if [ "$has_errors" = true ]; then
        return $EXIT_WARNING
    else
        return $EXIT_SUCCESS
    fi
}

# Helper function to delete files in batch
execute_cloud_deletion_batch() {
    local files_to_delete="$1"
    local backup_dir="$2"
    local batch_num="$3"
    local total_batches="$4"
    local -n error_flag_ref="$5"
    
    local delete_count=$(wc -l < "$files_to_delete")
    info "Processing batch $batch_num of $total_batches (files 1-$delete_count)"
    
    if ! timeout $RCLONE_TIMEOUT_MEDIUM rclone --fast-list --files-from "$files_to_delete" delete "${RCLONE_REMOTE}:${backup_dir}" ${RCLONE_FLAGS} 2>/dev/null; then
        warning "Unable to delete some files from cloud (batch $batch_num)"
        error_flag_ref=true
    else
        info "Successfully deleted files from batch $batch_num"
    fi
}

# Delete oldest backups in cloud storage
delete_oldest_cloud_backups() {
    local backup_dir="$1"
    local to_delete="$2"
    local -n errors_flag="$3"
    
    debug "Preparing deletion of $to_delete oldest backups from cloud storage"
    
    local cloud_backups=$(mktemp)
    local files_to_delete=$(mktemp)
    
    # Ensure temporary files are cleaned up on error
    trap 'rm -f "$cloud_backups" "$files_to_delete"' INT TERM EXIT
    
    # Add standardized timeout to avoid blocks
    if ! timeout $RCLONE_TIMEOUT_SHORT rclone lsl --fast-list "${RCLONE_REMOTE}:${backup_dir}" 2>/dev/null | grep "${PROXMOX_TYPE}-backup.*\.tar" | grep -v "\.sha256$" | grep -v "\.metadata$" > "$cloud_backups"; then
        warning "Unable to get backup list from cloud"
        errors_flag=true
        rm -f "$cloud_backups" "$files_to_delete"
        trap - INT TERM EXIT
        return 1
    fi
    
    # Verify file contains data
    if [ ! -s "$cloud_backups" ]; then
        warning "No backups found in cloud storage"
        errors_flag=true
        rm -f "$cloud_backups" "$files_to_delete"
        trap - INT TERM EXIT
        return 1
    fi
    
    # We need the listing anyway to sort files by date for deletion
    # Just don't print the redundant message that was causing duplication
    
    # Sort by date, ensuring we use correct format
    mapfile -t to_delete_lines < <(sort -k2,2 -k3,3 "$cloud_backups" | head -n "$to_delete")
    
    for line in "${to_delete_lines[@]}"; do
        local file_to_delete="${line##* }"
        debug "  - $file_to_delete"
        
        # Add main file
        echo "$file_to_delete" >> "$files_to_delete"
        
        # Add checksum
        echo "${file_to_delete}.sha256" >> "$files_to_delete"
        
        # Add metadata if available
        # First check if .metadata file exists
        if timeout $RCLONE_TIMEOUT_SHORT rclone lsl "${RCLONE_REMOTE}:${backup_dir}/${file_to_delete}.metadata" ${RCLONE_FLAGS} &>/dev/null; then
            echo "${file_to_delete}.metadata" >> "$files_to_delete"
            # And its possible checksum
            echo "${file_to_delete}.metadata.sha256" >> "$files_to_delete"
        fi
        
        # Extract base filename to search for other related files
        local base_name=$(basename "$file_to_delete" .tar.xz)
        if [ -n "$base_name" ]; then
            # Search for other files starting with same base name
            timeout $RCLONE_TIMEOUT_SHORT rclone lsf "${RCLONE_REMOTE}:${backup_dir}" --include "${base_name}.*" ${RCLONE_FLAGS} 2>/dev/null | grep -v "^$file_to_delete$" | grep -v "^${file_to_delete}.sha256$" | grep -v "^${file_to_delete}.metadata$" | grep -v "^${file_to_delete}.metadata.sha256$" >> "$files_to_delete"
        fi
    done
    
    # Verify there are files to delete
    local delete_count=$(wc -l < "$files_to_delete")
    if [ "$delete_count" -eq 0 ]; then
        warning "No files identified for deletion"
        errors_flag=true
        rm -f "$cloud_backups" "$files_to_delete"
        trap - INT TERM EXIT
        return 1
    fi
    
    # Show how many files will be deleted
    info "Deleting $delete_count oldest files from cloud storage"
    
    # Reduce batch size to avoid timeouts
    local batch_size=20
    local batches=$(( (delete_count + batch_size - 1) / batch_size ))
    
    if [ "$batches" -gt 1 ]; then
        info "Splitting into $batches batches of maximum $batch_size files each"
        
        for ((i=1; i<=batches; i++)); do
            local start_line=$(( (i-1) * batch_size + 1 ))
            local end_line=$(( i * batch_size ))
            
            # Ensure we don't exceed total files
            if [ "$end_line" -gt "$delete_count" ]; then
                end_line="$delete_count"
            fi
            
            # Create temporary file for batch
            local batch_file=$(mktemp)
            sed -n "${start_line},${end_line}p" "$files_to_delete" > "$batch_file"
            
            execute_cloud_deletion_batch "$batch_file" "$backup_dir" "$i" "$batches" "errors_flag"
            
            rm -f "$batch_file"
            
            # Brief pause between batches to avoid API overload
            sleep 1
        done
    else
        execute_cloud_deletion_batch "$files_to_delete" "$backup_dir" "1" "1" "errors_flag"
    fi
    
    # Remove temporary files
    rm -f "$cloud_backups" "$files_to_delete"
    # Remove trap
    trap - INT TERM EXIT
    
    if [ "$errors_flag" = true ]; then
        warning "Cloud backup deletion completed with warnings"
        # Invalidate cache since files may have been deleted
        return 1
    else
        success "Cloud backup deletion completed successfully"
        # Invalidate cloud cache since we deleted files
        return 0
    fi
}

# Delete oldest backups in local storage
delete_oldest_local_backups() {
    local backup_dir="$1"
    local pattern="$2"
    local to_delete="$3"
    local -n errors_flag="$4"
    
    # Use ls with sort for portability instead of find with -printf
    # Find ONLY main backup files, excluding .sha256 and .metadata
    mapfile -t backups_to_delete < <(
        ls -1t "$backup_dir"/$pattern 2>/dev/null | grep -v "\.sha256$" | grep -v "\.metadata$" | tail -n "$to_delete"
    )
    
    for backup_file in "${backups_to_delete[@]}"; do
        # Ensure path is complete
        if [[ "$backup_file" != /* ]]; then
            backup_file="$backup_dir/$backup_file"
        fi
        
        # Remove main backup file
        debug "Removing old backup: $backup_file"
        if ! rm -f "$backup_file"; then
            warning "Failed to remove old backup: $backup_file"
            errors_flag=true
        fi
        
        # Also remove corresponding checksum file
        local checksum_file="${backup_file}.sha256"
        if [ -f "$checksum_file" ]; then
            debug "Removing associated checksum file: $checksum_file"
            if ! rm -f "$checksum_file"; then
                warning "Failed to remove checksum file: $checksum_file"
                # Don't set errors_flag to true because checksum file removal is not critical
            fi
        fi
        
        # Also remove corresponding metadata file
        local metadata_file="${backup_file}.metadata"
        if [ -f "$metadata_file" ]; then
            debug "Removing associated metadata file: $metadata_file"
            if ! rm -f "$metadata_file"; then
                warning "Failed to remove metadata file: $metadata_file"
            fi
            
            # Also remove metadata file checksum if it exists
            local metadata_checksum="${metadata_file}.sha256"
            if [ -f "$metadata_checksum" ]; then
                info "Removing associated metadata checksum file: $metadata_checksum"
                if ! rm -f "$metadata_checksum"; then
                    warning "Failed to remove metadata checksum file: $metadata_checksum"
                fi
            fi
        fi
        
        # Remove any other associated files with same base name
        local base_name=$(basename "$backup_file" .tar.xz)
        local base_path="${backup_dir}/${base_name}"
        find "$backup_dir" -maxdepth 1 -type f -name "${base_name}.*" -not -path "$backup_file" | while read -r related_file; do
            info "Removing related file: $related_file"
            if ! rm -f "$related_file"; then
                warning "Failed to remove related file: $related_file"
            fi
        done
    done
}

# Set permissions on backup directories
set_permissions() {
    step "Setting permissions on backup directories"
    
    # Check if permission setting is enabled
    if [ "$SET_BACKUP_PERMISSIONS" != "true" ]; then
        info "Permission setting is disabled (SET_BACKUP_PERMISSIONS=false), skipping"
        return $EXIT_SUCCESS
    fi
    
    # Check if backup user exists, if not, create it
    if ! id -u "${BACKUP_USER}" &>/dev/null; then
        if [ "$AUTO_INSTALL_DEPENDENCIES" = "true" ]; then
            info "Creating backup user: ${BACKUP_USER}"
            if ! useradd -r -m -d "/home/${BACKUP_USER}" -s /bin/bash "${BACKUP_USER}" 2>/dev/null; then
                warning "Failed to create backup user ${BACKUP_USER}"
                set_exit_code "warning"
            fi
        else
            warning "Backup user ${BACKUP_USER} does not exist and AUTO_INSTALL_DEPENDENCIES is disabled"
            set_exit_code "warning"
        fi
    fi
    
    # Check if backup group exists, if not, create it
    if ! getent group "${BACKUP_GROUP}" &>/dev/null; then
        if [ "$AUTO_INSTALL_DEPENDENCIES" = "true" ]; then
            info "Creating backup group: ${BACKUP_GROUP}"
            if ! groupadd "${BACKUP_GROUP}" 2>/dev/null; then
                warning "Failed to create backup group ${BACKUP_GROUP}"
                set_exit_code "warning"
            fi
        else
            warning "Backup group ${BACKUP_GROUP} does not exist and AUTO_INSTALL_DEPENDENCIES is disabled"
            set_exit_code "warning"
        fi
    fi
    
    # Set permissions on primary backup path
    if check_directory_exists "$LOCAL_BACKUP_PATH"; then
        if id -u "${BACKUP_USER}" &>/dev/null && getent group "${BACKUP_GROUP}" &>/dev/null; then
            debug "Setting ownership of $LOCAL_BACKUP_PATH to ${BACKUP_USER}:${BACKUP_GROUP}"
            if ! chown -R "${BACKUP_USER}:${BACKUP_GROUP}" "$LOCAL_BACKUP_PATH"; then
                warning "Failed to set ownership on $LOCAL_BACKUP_PATH"
                set_exit_code "warning"
            fi
            
            debug "Setting permissions on $LOCAL_BACKUP_PATH"
            if ! chmod -R u=rwX,g=rX,o= "$LOCAL_BACKUP_PATH"; then
                warning "Failed to set permissions on $LOCAL_BACKUP_PATH"
                set_exit_code "warning"
            fi
            
            # Also set permissions on the primary log path
            debug "Setting ownership of $LOCAL_LOG_PATH to ${BACKUP_USER}:${BACKUP_GROUP}"
            if ! chown -R "${BACKUP_USER}:${BACKUP_GROUP}" "$LOCAL_LOG_PATH"; then
                warning "Failed to set ownership on $LOCAL_LOG_PATH"
                set_exit_code "warning"
            fi
            
            debug "Setting permissions on $LOCAL_LOG_PATH"
            if ! chmod -R u=rwX,g=rX,o= "$LOCAL_LOG_PATH"; then
                warning "Failed to set permissions on $LOCAL_LOG_PATH"
                set_exit_code "warning"
            fi
        else
            warning "Backup user or group does not exist, skipping permission change for primary backup"
            set_exit_code "warning"
        fi
    fi
    
    # Create the secondary backup path if secondary backup is enabled
    if [ "${ENABLE_SECONDARY_BACKUP:-false}" = "true" ]; then
        if ! mkdir -p "$SECONDARY_BACKUP_PATH" "$SECONDARY_LOG_PATH" 2>/dev/null; then
            warning "Failed to create secondary backup paths: $SECONDARY_BACKUP_PATH"
            set_exit_code "warning"
        fi
    fi
    
    # Set permissions on secondary backup path if it exists and secondary backup is enabled
    if [ "${ENABLE_SECONDARY_BACKUP:-false}" = "true" ] && check_directory_exists "$SECONDARY_BACKUP_PATH"; then
        if id -u "${BACKUP_USER}" &>/dev/null && getent group "${BACKUP_GROUP}" &>/dev/null; then
            debug "Setting ownership of $SECONDARY_BACKUP_PATH to ${BACKUP_USER}:${BACKUP_GROUP}"
            if ! chown -R "${BACKUP_USER}:${BACKUP_GROUP}" "$SECONDARY_BACKUP_PATH"; then
                warning "Failed to set ownership on $SECONDARY_BACKUP_PATH"
                set_exit_code "warning"
            fi
            
            debug "Setting permissions on $SECONDARY_BACKUP_PATH"
            if ! chmod -R u=rwX,g=rX,o= "$SECONDARY_BACKUP_PATH"; then
                warning "Failed to set permissions on $SECONDARY_BACKUP_PATH"
                set_exit_code "warning"
            fi
            
            # Also set permissions on the log path
            debug "Setting ownership of $SECONDARY_LOG_PATH to ${BACKUP_USER}:${BACKUP_GROUP}"
            if ! chown -R "${BACKUP_USER}:${BACKUP_GROUP}" "$SECONDARY_LOG_PATH"; then
                warning "Failed to set ownership on $SECONDARY_LOG_PATH"
                set_exit_code "warning"
            fi
            
            debug "Setting permissions on $SECONDARY_LOG_PATH"
            if ! chmod -R u=rwX,g=rX,o= "$SECONDARY_LOG_PATH"; then
                warning "Failed to set permissions on $SECONDARY_LOG_PATH"
                set_exit_code "warning"
            fi
        else
            warning "Backup user or group does not exist, skipping permission change"
            set_exit_code "warning"
        fi
    fi
    
    success "Permissions set successfully"
    return $EXIT_SUCCESS
}
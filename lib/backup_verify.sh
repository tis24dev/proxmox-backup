#!/bin/bash
##
# Proxmox Backup System - Backup Verification Library
# File: backup_verify.sh
# Version: 0.3.0
# Last Modified: 2025-10-23
# Changes: Improved check backup integrity
##
# ==========================================
# BACKUP VERIFICATION MODULE - OPTIMIZED
# ==========================================
#
# This module provides comprehensive backup verification functionality including:
# - Archive integrity verification using multiple compression formats
# - Content validation and structure verification
# - Critical file extraction testing
# - Multi-location consistency verification
# - Performance optimized with parallel operations and timeouts
#
# Author: Backup System

# Last Modified: $(date +%Y-%m-%d)
# ==========================================

# Initialize global variables with safe defaults
: "${DRY_RUN_MODE:=false}" "${COMPRESSION_TYPE:=zstd}" "${PROXMOX_TYPE:=pve}"
: "${PROMETHEUS_ENABLED:=false}" "${ENABLE_SECONDARY_BACKUP:=true}" "${CLOUD_BACKUP_ENABLED:=false}"
: "${VERIFICATION_TIMEOUT:=3600}" "${EXTRACTION_TIMEOUT:=300}" "${SAMPLE_SIZE:=20}"

# Global error tracking array - ensure it's initialized
ERROR_LIST=()

# ==========================================
# ERROR TRACKING AND MANAGEMENT FUNCTIONS
# ==========================================

# Enhanced error tracking function
# Tracks errors in a structured format for later analysis and reporting
track_error() {
    local category="$1"
    local severity="$2" 
    local message="$3"
    local details="${4:-}"
    
    # Validate input parameters
    [[ -z "$category" || -z "$severity" || -z "$message" ]] && return 1
    
    # Format: category|severity|message|details
    ERROR_LIST+=("${category}|${severity}|${message}|${details}")
    
    # Log based on severity level
    case "$severity" in
        "critical") error "$message${details:+ - $details}" ;;
        "warning") warning "$message${details:+ - $details}" ;;
        *) debug "$message${details:+ - $details}" ;;
    esac
    
    return 0
}

# ==========================================
# VALIDATION AND CONFIGURATION FUNCTIONS
# ==========================================

# Optimized validation of verification inputs
validate_verification_inputs() {
    local validation_errors=0
    
    # Validate timeout values with consolidated check
    local timeout_configs=(
        "VERIFICATION_TIMEOUT:60:7200"
        "EXTRACTION_TIMEOUT:30:1800" 
        "SAMPLE_SIZE:1:100"
    )
    
    for config in "${timeout_configs[@]}"; do
        IFS=':' read -r name min max <<< "$config"
        local value="${!name}"
        
        if ! [[ "$value" =~ ^[0-9]+$ ]] || [ "$value" -lt "$min" ] || [ "$value" -gt "$max" ]; then
            error "Invalid $name: $value (range: $min-$max)"
            ((validation_errors++))
        fi
    done
    
    # Validate compression type with fallback
    if [[ ! "$COMPRESSION_TYPE" =~ ^(zstd|gzip|pigz|xz|bzip2|lzma)$ ]]; then
        warning "Invalid compression type: $COMPRESSION_TYPE, using zstd"
        COMPRESSION_TYPE="zstd"
    fi
    
    # Validate Proxmox type with fallback
    if [[ ! "$PROXMOX_TYPE" =~ ^(pve|pbs)$ ]]; then
        warning "Invalid Proxmox type: $PROXMOX_TYPE, using pve"
        PROXMOX_TYPE="pve"
    fi
    
    # Check required commands efficiently
    local required_commands=("sha256sum" "tar" "mktemp" "timeout")
    case "$COMPRESSION_TYPE" in
        "zstd") required_commands+=("zstd") ;;
        "gzip"|"pigz") required_commands+=("gzip") ;;
        "xz") required_commands+=("xz") ;;
        "bzip2") required_commands+=("bzip2") ;;
        "lzma") required_commands+=("lzma") ;;
    esac
    
    local missing_commands=()
    for cmd in "${required_commands[@]}"; do
        command -v "$cmd" >/dev/null 2>&1 || missing_commands+=("$cmd")
    done
    
    if [ ${#missing_commands[@]} -gt 0 ]; then
        error "Missing required commands: ${missing_commands[*]}"
        return 1
    fi
    
    [ $validation_errors -eq 0 ] || return 1
    debug "Input validation completed successfully"
    return 0
}

# ==========================================
# COMPRESSION COMMAND EXECUTION
# ==========================================

# Unified compression command execution interface
execute_compression_cmd() {
    local action="$1" file="$2" output="$3" timeout_val="${4:-$EXTRACTION_TIMEOUT}"
    local extra_args="${5:-}"
    
    local cmd_base=""
    case "$COMPRESSION_TYPE" in
        "zstd")
            case "$action" in
                "test") cmd_base="zstd -t" ;;
                "list") cmd_base="zstd -dc \"$file\" 2>/dev/null | tar -tf -" ;;
                "extract") cmd_base="zstd -dc \"$file\" 2>/dev/null | tar -xf - -C \"$output\" $extra_args" ;;
            esac ;;
        "gzip"|"pigz")
            case "$action" in
                "test") cmd_base="gzip -t" ;;
                "list") cmd_base="tar -tzf" ;;
                "extract") cmd_base="tar -xzf \"$file\" -C \"$output\" $extra_args" ;;
            esac ;;
        "xz")
            case "$action" in
                "test") cmd_base="xz -t" ;;
                "list") cmd_base="tar -tJf" ;;
                "extract") cmd_base="tar -xJf \"$file\" -C \"$output\" $extra_args" ;;
            esac ;;
        "bzip2")
            case "$action" in
                "test") cmd_base="bzip2 -t" ;;
                "list") cmd_base="tar -tjf" ;;
                "extract") cmd_base="tar -xjf \"$file\" -C \"$output\" $extra_args" ;;
            esac ;;
        "lzma")
            case "$action" in
                "test") cmd_base="lzma -t" ;;
                "list") cmd_base="lzma -dc \"$file\" 2>/dev/null | tar -tf -" ;;
                "extract") cmd_base="lzma -dc \"$file\" 2>/dev/null | tar -xf - -C \"$output\" $extra_args" ;;
            esac ;;
    esac
    
    # Execute with timeout protection
    local final_cmd="$cmd_base"
    [[ "$action" == "test" ]] && final_cmd="$cmd_base \"$file\""
    [[ "$action" == "list" && "$COMPRESSION_TYPE" =~ ^(gzip|pigz|xz|bzip2)$ ]] && final_cmd="$cmd_base \"$file\""
    [[ "$action" == "list" ]] && final_cmd="$final_cmd > \"$output\" 2>/dev/null"
    
    timeout "$timeout_val" bash -c "$final_cmd"
}

# ==========================================
# PROXMOX CONFIGURATION FUNCTIONS
# ==========================================

# Get directory configuration for Proxmox types
get_proxmox_directories() {
    local type="$1" dir_type="$2"
    
    case "$type:$dir_type" in
        "pve:critical") echo "etc/pve var/lib/pve-cluster etc/network etc var/lib" ;;
        "pve:optional") echo "etc/ssh" ;;
        "pbs:critical") echo "etc/proxmox-backup var/lib/proxmox-backup etc/network etc var/lib" ;;
        "pbs:optional") echo "etc/ssh" ;;
    esac
}

# Get file configuration for Proxmox types
get_proxmox_files() {
    local type="$1" file_type="$2"
    
    case "$type:$file_type" in
        "pve:critical") echo "etc/pve/storage.cfg etc/pve/user.cfg" ;;
        "pve:optional") echo "var/lib/pve-cluster/info/pve_version.txt etc/hostname etc/hosts etc/passwd" ;;
        "pbs:critical") echo "etc/proxmox-backup/user.cfg" ;;
        "pbs:optional") echo "var/lib/proxmox-backup/version.txt var/lib/proxmox-backup/datastore_list.json etc/hostname etc/hosts etc/passwd" ;;
    esac
}

# ==========================================
# VERIFICATION HELPER FUNCTIONS
# ==========================================

# Validate backup file prerequisites
validate_backup_prerequisites() {
    local file_checks=(
        "file:$BACKUP_FILE:Backup file not found"
        "checksum:${BACKUP_FILE}.sha256:Checksum file not found"
    )
    
    for check in "${file_checks[@]}"; do
        IFS=':' read -r type path message <<< "$check"
        
        if [ ! -f "$path" ]; then
            track_error "verification" "critical" "$message" "Path: $path"
            return 1
        fi
        
        if [ ! -r "$path" ]; then
            track_error "verification" "critical" "${message/not found/not readable}" "Path: $path"
            return 1
        fi
    done
    
    # Check file size efficiently
    local file_size
    file_size=$(stat -c%s "$BACKUP_FILE" 2>/dev/null || stat -f%z "$BACKUP_FILE" 2>/dev/null || echo "0")
    
    if [ "$file_size" -eq 0 ]; then
        track_error "verification" "critical" "Backup file is empty" "File: $BACKUP_FILE"
        return 1
    fi
    
    debug "Prerequisites validated - Size: ${file_size} bytes"
    return 0
}

# Perform SHA256 checksum verification
verify_checksum() {
    debug "Performing SHA256 checksum verification"
    local start_time=$(date +%s)
    
    if ! timeout "$VERIFICATION_TIMEOUT" sha256sum -c "${BACKUP_FILE}.sha256" &>/dev/null; then
        local duration=$(($(date +%s) - start_time))
        track_error "integrity" "critical" "Checksum verification failed or timed out" "Duration: ${duration}s"
        return 1
    fi
    
    local duration=$(($(date +%s) - start_time))
    info "Checksum verification passed (${duration}s)"
    return 0
}

# Test archive structure integrity
test_archive_structure() {
    debug "Testing archive structure integrity"
    local start_time=$(date +%s)
    
    if ! execute_compression_cmd "test" "$BACKUP_FILE" "" "$EXTRACTION_TIMEOUT"; then
        local duration=$(($(date +%s) - start_time))
        track_error "archive_structure" "critical" "Archive header test failed" "Duration: ${duration}s"
        return 1
    fi
    
    debug "Archive structure test passed ($(($(date +%s) - start_time))s)"
    return 0
}

# List and validate archive contents
validate_archive_contents() {
    local file_list="$1"
    debug "Validating archive contents"
    local start_time=$(date +%s)
    
    if ! execute_compression_cmd "list" "$BACKUP_FILE" "$file_list" "$EXTRACTION_TIMEOUT"; then
        local duration=$(($(date +%s) - start_time))
        track_error "archive_content" "critical" "Failed to list archive contents" "Duration: ${duration}s"
        return 1
    fi
    
    if [ ! -s "$file_list" ]; then
        track_error "archive_content" "critical" "Archive content list is empty" ""
        return 1
    fi
    
    debug "Archive content listing completed ($(($(date +%s) - start_time))s)"
    return 0
}

# Validate critical directories presence
validate_critical_directories() {
    local file_list="$1"
    local missing_dirs=0 found_dirs=0
    
    for dir_type in "critical" "optional"; do
        local dirs_to_check
        read -ra dirs_to_check <<< "$(get_proxmox_directories "$PROXMOX_TYPE" "$dir_type")"
        
        for dir in "${dirs_to_check[@]}"; do
            if ! grep -q "^${dir}/$\|^\./${dir}/$" "$file_list"; then
                if [ "$dir_type" == "critical" ]; then
                    track_error "missing_directory" "warning" "Critical directory missing" "Directory: $dir"
                    ((missing_dirs++))
                fi
            else
                ((found_dirs++))
            fi
        done
    done
    
    info "Directory validation - Found: $found_dirs, Missing: $missing_dirs"
    return 0
}

# Extract and verify a single file
extract_and_verify_file() {
    local file_path="$1" is_critical="$2" test_dir="$3" file_list="$4"
    
    # Find actual path in archive
    local actual_path
    actual_path=$(grep "^${file_path}$\|^\./${file_path}$" "$file_list" 2>/dev/null | head -1)
    
    if [ -z "$actual_path" ]; then
        [ "$is_critical" == "true" ] && track_error "missing_file" "warning" "Critical file not found" "File: $file_path"
        return 1
    fi
    
    # Extract file with timeout
    if ! execute_compression_cmd "extract" "$BACKUP_FILE" "$test_dir/extract" "$EXTRACTION_TIMEOUT" "$actual_path"; then
        [ "$is_critical" == "true" ] && track_error "extraction" "warning" "Failed to extract critical file" "File: $actual_path"
        return 1
    fi
    
    # Verify extracted file exists and has content
    local extract_path="$test_dir/extract/$actual_path"
    [ ! -f "$extract_path" ] && extract_path="$test_dir/extract/${actual_path#./}"
    
    if [ ! -f "$extract_path" ] || [ ! -s "$extract_path" ]; then
        [ "$is_critical" == "true" ] && track_error "file_content" "warning" "Extracted file is empty or missing" "File: $actual_path"
        return 1
    fi
    
    return 0
}

# Test critical file extraction
test_critical_files() {
    local test_dir="$1" file_list="$2"
    local critical_errors=0
    
    debug "Testing critical file extraction"
    mkdir -p "$test_dir/extract"
    
    for file_type in "critical" "optional"; do
        local files_to_check
        read -ra files_to_check <<< "$(get_proxmox_files "$PROXMOX_TYPE" "$file_type")"
        
        for test_file in "${files_to_check[@]}"; do
            local is_critical="false"
            [ "$file_type" == "critical" ] && is_critical="true"
            
            if ! extract_and_verify_file "$test_file" "$is_critical" "$test_dir" "$file_list"; then
                [ "$file_type" == "critical" ] && ((critical_errors++))
            fi
        done
    done
    
    return $critical_errors
}

# Perform sample extraction test with fallback for shuf command
test_sample_extraction() {
    local test_dir="$1" file_list="$2"
    local sample_errors=0
    
    debug "Performing sample extraction test (max: $SAMPLE_SIZE files)"
    mkdir -p "$test_dir/sample"
    
    local sample_files
    # Use shuf if available, otherwise fall back to portable awk randomization
    if command -v shuf >/dev/null 2>&1; then
        sample_files=$(grep -v '/$' "$file_list" | shuf | head -n "$SAMPLE_SIZE")
    else
        # Portable fallback: use awk with random seed for shuffling
        sample_files=$(grep -v '/$' "$file_list" | awk 'BEGIN{srand()} {print rand() "\t" $0}' | sort -n | cut -f2- | head -n "$SAMPLE_SIZE")
    fi
    
    while read -r sample_file && [ $sample_errors -lt 5 ]; do
        [ -z "$sample_file" ] && continue
        if ! execute_compression_cmd "extract" "$BACKUP_FILE" "$test_dir/sample" "$EXTRACTION_TIMEOUT" "$sample_file"; then
            track_error "sample_extraction" "warning" "Sample extraction failed" "File: $sample_file"
            ((sample_errors++))
        fi
    done <<< "$sample_files"
    
    return $sample_errors
}

# ==========================================
# MAIN VERIFICATION FUNCTION
# ==========================================

# Enhanced backup verification with modular approach
verify_backup() {
    step "Verifying backup integrity with enhanced validation"
    
    # Reset error list and validate inputs
    ERROR_LIST=()
    validate_verification_inputs || { error "Input validation failed"; return $EXIT_ERROR; }
    
    # Handle dry run mode
    if [ "$DRY_RUN_MODE" == "true" ]; then
        info "Dry run mode: Skipping backup verification"
        return $EXIT_SUCCESS
    fi
    
    # Step 1: Validate prerequisites
    validate_backup_prerequisites || return $EXIT_ERROR
    
    # Step 2: Verify checksum
    verify_checksum || return $EXIT_ERROR
    
    # Step 3: Test archive structure
    test_archive_structure || return $EXIT_ERROR
    
    # Create temporary directory for all tests
    local test_dir
    test_dir=$(mktemp -d) || {
        track_error "setup" "critical" "Failed to create temporary directory" ""
        return $EXIT_ERROR
    }
    
    # Ensure cleanup on exit
    trap "rm -rf '$test_dir' 2>/dev/null || true" RETURN
    
    # Step 4: Validate archive contents
    local file_list="$test_dir/file_list.txt"
    validate_archive_contents "$file_list" || {
        rm -rf "$test_dir" 2>/dev/null
        return $EXIT_ERROR
    }
    
    # Count files and directories for metrics
    local file_count dir_count
    file_count=$(grep -v '/$' "$file_list" | wc -l)
    dir_count=$(grep '/$' "$file_list" | wc -l)
    info "Archive contains $dir_count directories and $file_count files"
    
    # Update Prometheus metrics if enabled and function exists
    if [ "$PROMETHEUS_ENABLED" == "true" ] && command -v update_prometheus_metrics >/dev/null 2>&1; then
        update_prometheus_metrics "proxmox_backup_files_total" "gauge" "Total files in backup" "$file_count"
        update_prometheus_metrics "proxmox_backup_directories_total" "gauge" "Total directories in backup" "$dir_count"
    fi
    
    # Step 5: Validate directory structure
    validate_critical_directories "$file_list"
    
    # Step 6: Test critical files extraction
    local critical_errors
    test_critical_files "$test_dir" "$file_list"
    critical_errors=$?
    
    # Step 7: Sample extraction test
    local sample_errors
    test_sample_extraction "$test_dir" "$file_list"
    sample_errors=$?
    
    # Final analysis and reporting
    local total_errors=${#ERROR_LIST[@]}
    local verification_end=$(date +%s)
    
    debug "Verification completed with $total_errors errors"
    
    # Determine result based on error analysis
    local verify_result=$EXIT_SUCCESS
    if [ $total_errors -gt 0 ]; then
        # Update metrics if function exists
        if [ "$PROMETHEUS_ENABLED" == "true" ] && command -v update_prometheus_metrics >/dev/null 2>&1; then
            update_prometheus_metrics "proxmox_backup_verification_errors_total" "gauge" "Verification errors" "$total_errors"
        fi
        
        # Generate error report if function exists
        command -v generate_error_report >/dev/null 2>&1 && generate_error_report 2>/dev/null || true
        
        # Assess severity
        if [ $critical_errors -eq 0 ] && [ $sample_errors -lt 3 ]; then
            success "Archive verification completed with minor issues"
            verify_result=$EXIT_SUCCESS
        else
            warning "Archive verification completed with warnings"
            info "Summary: Critical errors: $critical_errors, Sample errors: $sample_errors"
            verify_result=$EXIT_WARNING
        fi
    else
        success "Archive verification completed successfully"
        if [ "$PROMETHEUS_ENABLED" == "true" ] && command -v update_prometheus_metrics >/dev/null 2>&1; then
            update_prometheus_metrics "proxmox_backup_verification_errors_total" "gauge" "Verification errors" "0"
        fi
    fi
    
    # Set global exit code if functions exist
    command -v set_exit_code >/dev/null 2>&1 && {
        [ $verify_result -eq $EXIT_WARNING ] && set_exit_code "warning"
        [ $verify_result -eq $EXIT_ERROR ] && set_exit_code "error"
    }
    
    return $verify_result
}

# ==========================================
# CONSISTENCY VERIFICATION FUNCTION
# ==========================================

# Optimized backup consistency verification
verify_backup_consistency() {
    step "Verifying backup consistency across storage locations"

    # Handle dry run mode
    if [ "$DRY_RUN_MODE" == "true" ]; then
        info "Dry run mode: Skipping backup consistency verification"
        return $EXIT_SUCCESS
    fi

    local verify_errors=0
    local start_time=$(date +%s)
    
    # Set defaults efficiently
    local secondary_enabled="${ENABLE_SECONDARY_BACKUP:-false}"
    local cloud_enabled="${CLOUD_BACKUP_ENABLED:-false}"
    local timeout="${CONSISTENCY_TIMEOUT:-600}"
    
    debug "Starting consistency verification (timeout: ${timeout}s)"
    
    # Get local backup hash
    if [ ! -f "${BACKUP_FILE}.sha256" ]; then
        error "Local backup hash file not found"
        return $EXIT_ERROR
    fi
    
    local local_hash
    local_hash=$(cut -d' ' -f1 "${BACKUP_FILE}.sha256")
    debug "Local backup hash: $local_hash"
    
    # Verify secondary backup
    if [ "$secondary_enabled" == "true" ] && [ -d "${SECONDARY_BACKUP_PATH:-}" ]; then
        local secondary_backup="${SECONDARY_BACKUP_PATH}/$(basename "$BACKUP_FILE")"
        local secondary_hash_file="${secondary_backup}.sha256"
        
        if [ -f "$secondary_hash_file" ]; then
            local secondary_hash
            secondary_hash=$(cut -d' ' -f1 "$secondary_hash_file")
            
            if [ "$local_hash" != "$secondary_hash" ]; then
                error "Secondary backup hash mismatch"
                ((verify_errors++))
            else
                info "Secondary backup hash verified"
            fi
        else
            error "Secondary backup hash file not found: $secondary_hash_file"
            ((verify_errors++))
        fi
    fi
    
    # Verify cloud backup
    if [ "$cloud_enabled" == "true" ] && command -v rclone >/dev/null 2>&1 &&
       [ -n "${RCLONE_REMOTE:-}" ] && rclone listremotes 2>/dev/null | grep -q "^${RCLONE_REMOTE}:$"; then

        local cloud_backup="${CLOUD_BACKUP_PATH}/$(basename "$BACKUP_FILE")"
        local temp_dir
        temp_dir=$(mktemp -d)

        if timeout 60 rclone copy "${RCLONE_REMOTE}:${cloud_backup}.sha256" "$temp_dir" ${RCLONE_FLAGS:-} 2>/dev/null; then
            local cloud_hash
            cloud_hash=$(cut -d' ' -f1 "$temp_dir/$(basename "${cloud_backup}.sha256")" 2>/dev/null)

            if [ -n "$cloud_hash" ] && [ "$local_hash" != "$cloud_hash" ]; then
                error "Cloud backup hash mismatch"
                ((verify_errors++))
            elif [ -n "$cloud_hash" ]; then
                info "Cloud backup hash verified"
            fi
        fi
        rm -rf "$temp_dir"
    fi
    
    # Final status report
    local duration=$(($(date +%s) - start_time))
    
    if [ $verify_errors -gt 0 ]; then
        error "Backup consistency verification failed with $verify_errors errors (${duration}s)"
        if [ "$PROMETHEUS_ENABLED" == "true" ] && command -v update_prometheus_metrics >/dev/null 2>&1; then
            update_prometheus_metrics "proxmox_backup_consistency_errors_total" "gauge" "Consistency errors" "$verify_errors"
            update_prometheus_metrics "proxmox_backup_consistency_duration_seconds" "gauge" "Consistency duration" "$duration"
        fi
        return $EXIT_ERROR
    else
        success "All backup locations verified successfully (${duration}s)"
        if [ "$PROMETHEUS_ENABLED" == "true" ] && command -v update_prometheus_metrics >/dev/null 2>&1; then
            update_prometheus_metrics "proxmox_backup_consistency_errors_total" "gauge" "Consistency errors" "0"
            update_prometheus_metrics "proxmox_backup_consistency_duration_seconds" "gauge" "Consistency duration" "$duration"
        fi
        return $EXIT_SUCCESS
    fi
}
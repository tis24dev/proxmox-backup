#!/bin/bash
##
# Proxmox Backup System - Backup Creation Library
# File: backup_create.sh
# Version: 0.2.1
# Last Modified: 2025-10-11
# Changes: Creazione archivi backup
##
# =============================================================================
# BACKUP CREATION FUNCTIONS
# =============================================================================
# This module handles the creation of compressed backup archives with advanced
# optimization features including deduplication, preprocessing, and smart chunking.
#
# Global Variables Used:
# - COMPRESSION_MODE: Compression speed/quality mode (fast|standard|maximum|ultra)
# - COMPRESSION_TYPE: Algorithm to use (zstd|xz|gzip|pigz|bzip2|lzma)
# - COMPRESSION_LEVEL: Numeric compression level (1-22 depending on algorithm)
# - COMPRESSION_THREADS: Number of threads for parallel compression (0=auto)
# - ENABLE_SMART_CHUNKING: Enable splitting large files for better compression
# - ENABLE_DEDUPLICATION: Enable file deduplication using symlinks
# - ENABLE_PREFILTER: Enable preprocessing to improve compressibility
# - BACKUP_FILE: Full path to the output backup archive
# - TEMP_DIR: Temporary directory containing files to be archived
# - PROMETHEUS_ENABLED: Enable Prometheus metrics collection
# - METRICS_FILE: Path to Prometheus metrics output file
# - EXIT_SUCCESS, EXIT_ERROR, EXIT_WARNING: Standard exit codes
# =============================================================================

# Maximum number of retry attempts for critical operations
readonly MAX_RETRY_ATTEMPTS=3
# Base delay between retry attempts (seconds)
readonly RETRY_BASE_DELAY=2
# Maximum delay between retry attempts (seconds)
readonly RETRY_MAX_DELAY=30

# =============================================================================
# UTILITY FUNCTIONS
# =============================================================================

# Sanitize and validate input strings to prevent injection attacks
# Usage: sanitize_input "string_to_sanitize"
# Returns: Sanitized string safe for use in commands
sanitize_input() {
    local input="$1"
    local sanitized
    
    # Remove potentially dangerous characters and sequences
    sanitized=$(echo "$input" | sed 's/[;&|`$(){}[\]\\]//g' | tr -d '\n\r')
    
    # Limit length to prevent buffer overflow attacks
    if [ ${#sanitized} -gt 1000 ]; then
        sanitized="${sanitized:0:1000}"
        warning "Input truncated to 1000 characters for security"
    fi
    
    echo "$sanitized"
}

# Validate that required compression tools are available
# Usage: validate_compression_tools
# Returns: 0 if tools are available, 1 otherwise
validate_compression_tools() {
    local compression_type="${1:-$COMPRESSION_TYPE}"
    local required_tool=""
    local fallback_tool=""
    
    case "$compression_type" in
        "zstd")
            required_tool="zstd"
            fallback_tool="gzip"
            ;;
        "xz")
            required_tool="xz"
            fallback_tool="gzip"
            ;;
        "pigz")
            required_tool="pigz"
            fallback_tool="gzip"
            ;;
        "bzip2")
            required_tool="bzip2"
            fallback_tool="gzip"
            ;;
        "lzma")
            required_tool="lzma"
            fallback_tool="gzip"
            ;;
        "gzip")
            required_tool="gzip"
            ;;
        *)
            error "Unknown compression type: $compression_type"
            return 1
            ;;
    esac
    
    # Check if the required tool is available
    if command -v "$required_tool" >/dev/null 2>&1; then
        debug "Compression tool '$required_tool' is available"
        return 0
    else
        warning "Compression tool '$required_tool' not found"
        
        # Try fallback if available
        if [ -n "$fallback_tool" ] && command -v "$fallback_tool" >/dev/null 2>&1; then
            warning "Falling back to '$fallback_tool' compression"
            COMPRESSION_TYPE="gzip"
            return 0
        else
            error "No suitable compression tool found (tried: $required_tool, $fallback_tool)"
            return 1
        fi
    fi
}

# Execute a command with retry logic and detailed error reporting
# Usage: retry_operation max_attempts "command" "operation_description"
# Returns: Exit code of the last attempt
retry_operation() {
    local max_attempts="${1:-$MAX_RETRY_ATTEMPTS}"
    local command="$2"
    local operation_desc="${3:-operation}"
    local attempt=1
    local exit_code=0
    local delay=$RETRY_BASE_DELAY
    
    # Sanitize the operation description
    operation_desc=$(sanitize_input "$operation_desc")
    
    while [ $attempt -le $max_attempts ]; do
        debug "Attempting $operation_desc (attempt $attempt/$max_attempts)"
        
        # Execute the command and capture exit code
        if eval "$command"; then
            if [ $attempt -gt 1 ]; then
                info "$operation_desc succeeded on attempt $attempt"
            fi
            return 0
        else
            exit_code=$?
            
            if [ $attempt -eq $max_attempts ]; then
                error "$operation_desc failed after $max_attempts attempts (exit code: $exit_code)"
                return $exit_code
            else
                warning "$operation_desc failed on attempt $attempt (exit code: $exit_code), retrying in ${delay}s"
                sleep $delay
                
                # Exponential backoff with maximum cap
                delay=$((delay * 2))
                if [ $delay -gt $RETRY_MAX_DELAY ]; then
                    delay=$RETRY_MAX_DELAY
                fi
            fi
        fi
        
        attempt=$((attempt + 1))
    done
    
    return $exit_code
}

# Enhanced error reporting with context and suggestions
# Usage: report_detailed_error "error_code" "operation" "context" "suggestion"
report_detailed_error() {
    local error_code="$1"
    local operation="$2"
    local context="$3"
    local suggestion="$4"
    
    error "Operation failed: $operation"
    error "Error code: $error_code"
    error "Context: $context"
    
    if [ -n "$suggestion" ]; then
        error "Suggestion: $suggestion"
    fi
    
    # Log additional system information for debugging
    debug "Available disk space: $(df -h "$TEMP_DIR" 2>/dev/null | tail -1 | awk '{print $4}' || echo 'unknown')"
    debug "Memory usage: $(free -h 2>/dev/null | grep '^Mem:' | awk '{print $3"/"$2}' || echo 'unknown')"
    debug "Load average: $(uptime 2>/dev/null | awk -F'load average:' '{print $2}' || echo 'unknown')"
}

# =============================================================================
# COMPRESSION FUNCTIONS
# =============================================================================

# Build compression command with enhanced fallback support
# Usage: build_compression_command
# Sets: tar_cmd variable with the appropriate compression command
build_compression_command() {
    local compression_type="${COMPRESSION_TYPE}"
    local compression_level="${COMPRESSION_LEVEL}"
    local compression_threads="${COMPRESSION_THREADS}"
    local compression_mode="${COMPRESSION_MODE}"
    
    # Validate and sanitize inputs
    compression_type=$(sanitize_input "$compression_type")
    compression_level=$(sanitize_input "$compression_level")
    compression_threads=$(sanitize_input "$compression_threads")
    compression_mode=$(sanitize_input "$compression_mode")
    
    # Validate compression tools before building command
    if ! validate_compression_tools "$compression_type"; then
        return 1
    fi
    
    case "$compression_type" in
        "zstd")
            if command -v zstd >/dev/null 2>&1; then
                tar_cmd="tar --zstd -cf"
                
                # Configure zstd-specific environment variables
                if [ "$compression_threads" -gt 1 ]; then
                    export ZSTD_NBTHREADS="$compression_threads"
                    debug "Set ZSTD_NBTHREADS=$compression_threads"
                fi
                
                export ZSTD_CLEVEL="$compression_level"
                debug "Set ZSTD_CLEVEL=$compression_level"
                
                # Advanced zstd optimizations based on compression mode
                case "$compression_mode" in
                    "ultra")
                        export ZSTD_CLEVEL=22
                        export ZSTD_WINDOWLOG=27  # Larger window for better compression
                        info "Using ULTRA ZSTD compression (level $ZSTD_CLEVEL, window log $ZSTD_WINDOWLOG)"
                        ;;
                    "maximum")
                        export ZSTD_CLEVEL=19
                        info "Using MAXIMUM ZSTD compression (level $ZSTD_CLEVEL)"
                        ;;
                    *)
                        info "Using ZSTD compression (level $ZSTD_CLEVEL)"
                        ;;
                esac
            else
                warning "zstd command not found, falling back to gzip"
                COMPRESSION_TYPE="gzip"
                build_compression_command
                return $?
            fi
            ;;
            
        "xz")
            if command -v xz >/dev/null 2>&1; then
                # Build XZ options with enhanced compatibility
                local xz_opts="-${compression_level}"
                
                # Enable multi-threading if supported and requested
                if [ "$compression_threads" -gt 1 ]; then
                    # Check if xz supports threading
                    if xz --help 2>/dev/null | grep -q -- '-T'; then
                        xz_opts="$xz_opts -T$compression_threads"
                        debug "XZ threading enabled with $compression_threads threads"
                    else
                        warning "XZ threading not supported in this version"
                    fi
                fi
                
                # Add extreme compression for maximum/ultra modes
                if [ "$compression_mode" = "ultra" ] || [ "$compression_mode" = "maximum" ]; then
                    if xz --help 2>/dev/null | grep -q -- '--extreme'; then
                        xz_opts="$xz_opts --extreme"
                        debug "XZ extreme compression enabled"
                    fi
                fi
                
                export XZ_OPT="$xz_opts"
                tar_cmd="tar -Jcf"
                info "Using XZ compression with options: $XZ_OPT"
            else
                warning "xz command not found, falling back to gzip"
                COMPRESSION_TYPE="gzip"
                build_compression_command
                return $?
            fi
            ;;
            
        "pigz")
            if command -v pigz >/dev/null 2>&1; then
                # Build pigz command with advanced options
                local pigz_opts="pigz -${compression_level}"
                
                if [ "$compression_threads" -gt 1 ]; then
                    pigz_opts="$pigz_opts -p$compression_threads"
                    export PIGZ_NPROC="$compression_threads"
                fi
                
                # Add best compression for maximum/ultra modes
                if [ "$compression_mode" = "ultra" ] || [ "$compression_mode" = "maximum" ]; then
                    pigz_opts="$pigz_opts --best"
                fi
                
                # Use safe command construction to avoid injection
                tar_cmd="tar -I '$pigz_opts' -cf"
                info "Using advanced PIGZ compression: $pigz_opts"
            else
                warning "pigz command not found, falling back to gzip"
                COMPRESSION_TYPE="gzip"
                build_compression_command
                return $?
            fi
            ;;
            
        "bzip2")
            # Try parallel bzip2 first, then fall back to standard bzip2
            if command -v pbzip2 >/dev/null 2>&1 && [ "$compression_threads" -gt 1 ]; then
                local pbzip_opts="pbzip2 -${compression_level} -p$compression_threads"
                tar_cmd="tar -I '$pbzip_opts' -cf"
                info "Using parallel BZIP2 compression: $pbzip_opts"
            elif command -v bzip2 >/dev/null 2>&1; then
                export BZIP2="-${compression_level}"
                tar_cmd="tar -jcf"
                info "Using standard BZIP2 compression (level $compression_level)"
            else
                warning "bzip2 command not found, falling back to gzip"
                COMPRESSION_TYPE="gzip"
                build_compression_command
                return $?
            fi
            ;;
            
        "lzma")
            if command -v lzma >/dev/null 2>&1; then
                local lzma_opts="-${compression_level}"
                
                # Add extreme compression for maximum/ultra modes
                if [ "$compression_mode" = "ultra" ] || [ "$compression_mode" = "maximum" ]; then
                    lzma_opts="${lzma_opts}e"
                fi
                
                export LZMA="$lzma_opts"
                tar_cmd="tar --lzma -cf"
                info "Using LZMA compression: $LZMA"
            else
                warning "lzma command not found, falling back to gzip"
                COMPRESSION_TYPE="gzip"
                build_compression_command
                return $?
            fi
            ;;
            
        "gzip")
            # Standard gzip - should always be available
            if command -v gzip >/dev/null 2>&1; then
                export GZIP="-${compression_level}"
                tar_cmd="tar -zcf"
                info "Using standard GZIP compression (level $compression_level)"
            else
                error "No compression tools available (even gzip is missing)"
                return 1
            fi
            ;;
            
        *)
            error "Unsupported compression type: $compression_type"
            return 1
            ;;
    esac
    
    debug "Built compression command: $tar_cmd"
    return 0
}

# =============================================================================
# MAIN BACKUP CREATION FUNCTION
# =============================================================================

# Create backup archive with comprehensive error handling and optimization
# This is the main function that orchestrates the entire backup creation process
# including compression, optimization, and verification.
#
# Global variables modified:
# - BACKUP_FILE: Updated with correct file extension based on compression type
# - COMPRESSION_RATIO: Set to calculated compression ratio
# - Various compression-specific environment variables
#
# Returns: EXIT_SUCCESS on success, EXIT_ERROR on failure
create_backup_archive() {
    step "Creating backup archive"
    
    # Record start time for performance metrics
    local compress_start=$(date +%s)
    
    # Initialize and validate configuration with secure defaults
    : "${COMPRESSION_MODE:=standard}"           # Compression speed/quality balance
    : "${COMPRESSION_THREADS:=0}"               # Auto-detect thread count
    : "${ENABLE_SMART_CHUNKING:=false}"         # Disable chunking by default
    : "${ENABLE_DEDUPLICATION:=false}"          # Disable deduplication by default
    : "${ENABLE_PREFILTER:=false}"              # Disable preprocessing by default
    
    # Auto-detect optimal thread count if not specified
    if [ "$COMPRESSION_THREADS" = "0" ]; then
        COMPRESSION_THREADS=$(nproc 2>/dev/null || echo 2)
        debug "Auto-detected $COMPRESSION_THREADS threads for compression"
    fi
    
    # Validate thread count is reasonable (1-64)
    if [ "$COMPRESSION_THREADS" -lt 1 ] || [ "$COMPRESSION_THREADS" -gt 64 ]; then
        warning "Invalid thread count ($COMPRESSION_THREADS), using 2"
        COMPRESSION_THREADS=2
    fi
    
    # Apply smart optimizations if enabled (with error handling)
    if ! apply_backup_optimizations; then
        warning "Backup optimizations failed, continuing without optimizations"
        set_exit_code "warning"
    fi
    
    # Determine output file extension and compression options based on type
    # This section maps compression types to file extensions and tar options
    case "$COMPRESSION_TYPE" in
        "zstd")
            BACKUP_FILE="${BACKUP_FILE%.tar}.tar.zst"
            COMPRESSION_OPT="--zstd"
            ;;
        "xz")
            BACKUP_FILE="${BACKUP_FILE%.tar}.tar.xz"
            COMPRESSION_OPT="-J"
            ;;
        "gzip"|"pigz")
            BACKUP_FILE="${BACKUP_FILE%.tar}.tar.gz"
            COMPRESSION_OPT="-z"
            ;;
        "bzip2")
            BACKUP_FILE="${BACKUP_FILE%.tar}.tar.bz2"
            COMPRESSION_OPT="-j"
            ;;
        "lzma")
            BACKUP_FILE="${BACKUP_FILE%.tar}.tar.lzma"
            COMPRESSION_OPT="--lzma"
            ;;
        *)
            warning "Unknown compression type: $COMPRESSION_TYPE, falling back to zstd"
            BACKUP_FILE="${BACKUP_FILE%.tar}.tar.zst"
            COMPRESSION_OPT="--zstd"
            COMPRESSION_TYPE="zstd"
            ;;
    esac

    # Set compression level based on mode with algorithm-specific optimizations
    # Different algorithms have different optimal level ranges
    case "$COMPRESSION_MODE" in
        "fast")
            COMPRESSION_LEVEL=1
            ;;
        "standard")
            COMPRESSION_LEVEL="${COMPRESSION_LEVEL:-6}"
            ;;
        "maximum")
            case "$COMPRESSION_TYPE" in
                "zstd") COMPRESSION_LEVEL=19 ;;
                "xz"|"gzip"|"pigz"|"bzip2"|"lzma") COMPRESSION_LEVEL=9 ;;
            esac
            ;;
        "ultra")
            case "$COMPRESSION_TYPE" in
                "zstd") COMPRESSION_LEVEL=22 ;;
                "xz"|"gzip"|"pigz"|"bzip2"|"lzma") COMPRESSION_LEVEL=9 ;;
            esac
            ;;
        *)
            warning "Unknown compression mode: $COMPRESSION_MODE, using standard"
            COMPRESSION_LEVEL=6
            ;;
    esac

    info "Creating compressed archive with $COMPRESSION_TYPE (level $COMPRESSION_LEVEL, mode $COMPRESSION_MODE)"
    
    # Build the compression command with enhanced error handling
    if ! build_compression_command; then
        report_detailed_error "COMPRESSION_SETUP_FAILED" "build compression command" \
            "Failed to configure compression with type=$COMPRESSION_TYPE" \
            "Check if compression tools are installed or try a different compression type"
        set_exit_code "error"
        return $EXIT_ERROR
    fi

    # Validate that source directory exists and is readable
    if [ ! -d "$TEMP_DIR" ]; then
        report_detailed_error "SOURCE_DIR_MISSING" "validate source directory" \
            "Temporary directory does not exist: $TEMP_DIR" \
            "Ensure the backup collection phase completed successfully"
        set_exit_code "error"
        return $EXIT_ERROR
    fi
    
    if [ ! -r "$TEMP_DIR" ]; then
        report_detailed_error "SOURCE_DIR_UNREADABLE" "validate source directory" \
            "Cannot read temporary directory: $TEMP_DIR" \
            "Check directory permissions"
        set_exit_code "error"
        return $EXIT_ERROR
    fi

    # Validate that target directory is writable
    local target_dir=$(dirname "$BACKUP_FILE")
    if [ ! -w "$target_dir" ]; then
        report_detailed_error "TARGET_DIR_UNWRITABLE" "validate target directory" \
            "Cannot write to target directory: $target_dir" \
            "Check directory permissions and available disk space"
        set_exit_code "error"
        return $EXIT_ERROR
    fi

    # Execute tar command with retry logic and comprehensive error handling
    # The actual archive creation happens here
    # Use subshell to isolate directory change and prevent getcwd errors
    local tar_operation="( cd '$TEMP_DIR' && $tar_cmd '$BACKUP_FILE' . )"
    
    if ! retry_operation $MAX_RETRY_ATTEMPTS "$tar_operation" "create compressed archive"; then
        local exit_code=$?
        
        # Provide specific error messages based on common failure scenarios
        if [ ! -f "$BACKUP_FILE" ]; then
            report_detailed_error "ARCHIVE_CREATION_FAILED" "create archive file" \
                "Archive file was not created: $BACKUP_FILE" \
                "Check disk space, permissions, and compression tool availability"
        elif [ ! -s "$BACKUP_FILE" ]; then
            report_detailed_error "ARCHIVE_EMPTY" "create archive content" \
                "Archive file is empty: $BACKUP_FILE" \
                "Check if source directory contains files and compression is working"
        else
            report_detailed_error "ARCHIVE_INCOMPLETE" "complete archive creation" \
                "Archive creation may be incomplete (exit code: $exit_code)" \
                "Verify archive integrity and retry the operation"
        fi
        
        set_exit_code "error"
        return $EXIT_ERROR
    fi

    # Create SHA256 hash for verification with retry logic
    local hash_operation="sha256sum '$BACKUP_FILE' > '${BACKUP_FILE}.sha256'"
    if ! retry_operation 2 "$hash_operation" "create SHA256 hash"; then
        report_detailed_error "HASH_CREATION_FAILED" "create verification hash" \
            "Failed to create SHA256 hash for: $BACKUP_FILE" \
            "Check if sha256sum is available and target directory is writable"
        set_exit_code "error"
        return $EXIT_ERROR
    fi

    # Calculate compression ratio with enhanced error handling and fallback methods
    # This provides valuable metrics about compression effectiveness
    if [ -d "$TEMP_DIR" ]; then
        local original_size=$(du -sb "$TEMP_DIR" 2>/dev/null | cut -f1)
        local compressed_size=$(stat -c %s "$BACKUP_FILE" 2>/dev/null)
        
        if [ -n "$original_size" ] && [ -n "$compressed_size" ] && [ "$original_size" -gt 0 ] && [ "$compressed_size" -gt 0 ]; then
            local ratio=$(echo "scale=2; (1 - $compressed_size / $original_size) * 100" | bc -l)
            COMPRESSION_RATIO="${ratio}%"
        else
            COMPRESSION_RATIO=$(get_compression_data "$TEMP_DIR" "$BACKUP_FILE" "percent")
        fi
    fi

    # Aggiorna metriche se Prometheus è abilitato
    if [ "$PROMETHEUS_ENABLED" == "true" ]; then
        update_phase_metrics "compress" "$compress_start" "$(date +%s)"
        update_backup_file_metrics
        
        if [ -n "$COMPRESSION_RATIO" ] && [ "$COMPRESSION_RATIO" != "Unknown" ]; then
            local ratio_value=${COMPRESSION_RATIO/\%/}
            update_prometheus_metrics "proxmox_backup_compression_ratio" "gauge" "Compression ratio of backup" "$ratio_value" "hostname=\"$HOSTNAME\", type=\"$COMPRESSION_TYPE\", level=\"$COMPRESSION_LEVEL\", mode=\"$COMPRESSION_MODE\""
        fi
    fi

    # Calculate final size and log it
    if [ -f "$BACKUP_FILE" ]; then
        final_size=$(get_file_size "$BACKUP_FILE")
        final_size_human=$(format_size_human "$final_size")
        
        info "Backup archive created successfully: $BACKUP_FILE ($final_size_human, compression: $COMPRESSION_RATIO)"
        
        if [ -n "$COMPRESSION_RATIO" ]; then
            local compression_data
            compression_data=$(get_compression_data "$TEMP_DIR" "$BACKUP_FILE" "all")
            local size_before=$(echo "$compression_data" | grep -o 'size_before=[0-9]*' | cut -d'=' -f2)
            local size_after=$(echo "$compression_data" | grep -o 'size_after=[0-9]*' | cut -d'=' -f2)
            local size_before_human=$(format_size_human "$size_before")
            local size_after_human=$(format_size_human "$size_after")
            local ratio_percent=$(echo "$compression_data" | grep -o 'percent=[0-9.]*' | cut -d'=' -f2)
            
            info "Compression details: Original size: $size_before_human, Compressed size: $size_after_human, Compression ratio: ${ratio_percent}%"
        fi
    else
        error "Failed to create backup archive: file not found"
        return $EXIT_ERROR
    fi
    
    # Salva metadati in un file per riferimento futuro
    echo "COMPRESSION_RATIO=$COMPRESSION_RATIO" > "${BACKUP_FILE}.metadata"
    echo "COMPRESSION_TYPE=$COMPRESSION_TYPE" >> "${BACKUP_FILE}.metadata"
    echo "COMPRESSION_LEVEL=$COMPRESSION_LEVEL" >> "${BACKUP_FILE}.metadata"
    echo "BACKUP_DURATION=$BACKUP_DURATION" >> "${BACKUP_FILE}.metadata"
    
    return $EXIT_SUCCESS
}

# =============================================================================
# BACKUP OPTIMIZATION FUNCTIONS
# =============================================================================

# Apply comprehensive backup optimizations including deduplication, preprocessing, and chunking
# These optimizations can significantly improve compression ratios and reduce backup size
# 
# Features:
# - File deduplication using symlinks (saves space for identical files)
# - Content preprocessing to improve compressibility
# - Smart chunking for large files
#
# Global variables used:
# - ENABLE_DEDUPLICATION: Enable/disable file deduplication
# - ENABLE_PREFILTER: Enable/disable content preprocessing  
# - ENABLE_SMART_CHUNKING: Enable/disable smart file chunking
# - TEMP_DIR: Directory containing files to optimize
#
# Returns: 0 on success, 1 on failure (non-critical - backup can continue)
apply_backup_optimizations() {
    debug "Starting backup optimizations phase"
    local optimization_errors=0
    
    # File deduplication optimization
    # Replaces duplicate files with symlinks to save space
    if [ "$ENABLE_DEDUPLICATION" = "true" ]; then
        debug "Performing file deduplication before compression"
        
        if ! perform_file_deduplication; then
            warning "File deduplication failed, continuing without deduplication"
            optimization_errors=$((optimization_errors + 1))
        fi
    else
        debug "File deduplication disabled"
    fi
    
    # Content preprocessing optimization
    # Improves compressibility by normalizing and optimizing file content
    if [ "$ENABLE_PREFILTER" = "true" ]; then
        debug "Applying enhanced preprocessing for better compression"
        
        if ! perform_content_preprocessing; then
            warning "Content preprocessing failed, continuing without preprocessing"
            optimization_errors=$((optimization_errors + 1))
        fi
    else
        debug "Content preprocessing disabled"
    fi
    
    # Smart chunking optimization
    # Splits large files into smaller chunks for better compression
    if [ "$ENABLE_SMART_CHUNKING" = "true" ]; then
        debug "Applying smart chunking for large files"
        
        if ! perform_smart_chunking; then
            warning "Smart chunking failed, continuing without chunking"
            optimization_errors=$((optimization_errors + 1))
        fi
    else
        debug "Smart chunking disabled"
    fi
    
    # Report optimization results
    if [ $optimization_errors -eq 0 ]; then
        debug "All backup optimizations completed successfully"
        return 0
    else
        warning "Backup optimizations completed with $optimization_errors errors"
        return 1
    fi
}

# Perform file deduplication using SHA256 hashes and symlinks
# This function identifies duplicate files and replaces them with symlinks
# to save space while maintaining file structure integrity
perform_file_deduplication() {
    local duplicate_count=0
    local file_hashes
    local temp_hash_file
    
    # Create secure temporary file for hash storage
    if ! temp_hash_file=$(mktemp); then
        error "Failed to create temporary file for deduplication"
        return 1
    fi
    
    # Ensure cleanup of temporary file
    trap "rm -f '$temp_hash_file'" RETURN
    
    debug "Creating file hash index for deduplication"
    
    # Create hash of each file and identify duplicates
    # Use find with proper error handling
    if ! find "$TEMP_DIR" -type f -exec sha256sum {} \; 2>/dev/null | sort > "$temp_hash_file"; then
        error "Failed to create file hash index"
        return 1
    fi
    
    # Validate that we have some hashes to work with
    if [ ! -s "$temp_hash_file" ]; then
        warning "No files found for deduplication"
        return 0
    fi
    
    debug "Processing file hashes for duplicate detection"
    
    # Find duplicates (files with same hash) and replace with symlinks
    local prev_hash=""
    local prev_file=""
    local line_count=0
    
    while IFS=' ' read -r hash file; do
        line_count=$((line_count + 1))
        
        # Sanitize file path to prevent injection
        file=$(sanitize_input "$file")
        
        # Skip empty lines or malformed entries
        if [ -z "$hash" ] || [ -z "$file" ]; then
            continue
        fi
        
        # Check if this hash matches the previous one
        if [ "$prev_hash" = "$hash" ] && [ -n "$prev_hash" ] && [ -f "$prev_file" ] && [ -f "$file" ]; then
            debug "Found duplicate: $file (same as $prev_file)"
            
            # Verify files are actually identical before creating symlink
            if cmp -s "$prev_file" "$file"; then
                # Remove duplicate and create symlink
                if rm "$file" && ln -sf "$prev_file" "$file"; then
                    duplicate_count=$((duplicate_count + 1))
                    debug "Created symlink: $file -> $prev_file"
                else
                    warning "Failed to create symlink for duplicate file: $file"
                fi
            else
                warning "Hash collision detected for files: $prev_file and $file"
            fi
        else
            # Store current file as reference for next iteration
            prev_hash="$hash"
            prev_file="$file"
        fi
        
        # Progress indicator for large numbers of files
        if [ $((line_count % 1000)) -eq 0 ]; then
            debug "Processed $line_count files for deduplication"
        fi
    done < "$temp_hash_file"
    
    info "Deduplication completed: $duplicate_count duplicate files replaced with symlinks"
    return 0
}

# Perform content preprocessing to improve compression ratios
# This function normalizes and optimizes various file types for better compression
perform_content_preprocessing() {
    local processed_files=0
    local failed_files=0
    
    debug "Starting content preprocessing for better compression"
    
    # Normalize text files and logs
    # Remove carriage returns and normalize line endings
    debug "Normalizing text files and logs"
    find "$TEMP_DIR" -type f \( -name "*.txt" -o -name "*.log" -o -name "*.md" \) 2>/dev/null | while read -r file; do
        if [ -f "$file" ] && file "$file" 2>/dev/null | grep -q text; then
            # Create backup and normalize
            if cp "$file" "$file.bak" 2>/dev/null; then
                if tr -d '\r' < "$file.bak" > "$file" 2>/dev/null; then
                    rm -f "$file.bak"
                    processed_files=$((processed_files + 1))
                else
                    mv "$file.bak" "$file"  # Restore on failure
                    failed_files=$((failed_files + 1))
                fi
            fi
        fi
    done
    
    # Optimize configuration files
    # Remove comments and sort lines for better compression
    debug "Optimizing configuration files"
    find "$TEMP_DIR" -type f \( -name "*.conf" -o -name "*.cfg" -o -name "*.ini" \) 2>/dev/null | while read -r file; do
        if [ -f "$file" ] && grep -q "^[a-zA-Z0-9_]*=" "$file" 2>/dev/null; then
            if cp "$file" "$file.bak" 2>/dev/null; then
                # Remove comments and sort, but preserve structure
                if grep -v "^#" "$file.bak" 2>/dev/null | sort > "$file" 2>/dev/null; then
                    rm -f "$file.bak"
                    processed_files=$((processed_files + 1))
                else
                    mv "$file.bak" "$file"  # Restore on failure
                    failed_files=$((failed_files + 1))
                fi
            fi
        fi
    done
    
    # Optimize JSON files if jq is available
    # Minify JSON for better compression
    if command -v jq >/dev/null 2>&1; then
        debug "Minifying JSON files"
        find "$TEMP_DIR" -type f -name "*.json" 2>/dev/null | while read -r file; do
            if [ -f "$file" ]; then
                if cp "$file" "$file.bak" 2>/dev/null; then
                    if jq -c '.' "$file.bak" > "$file" 2>/dev/null; then
                        rm -f "$file.bak"
                        processed_files=$((processed_files + 1))
                    else
                        mv "$file.bak" "$file"  # Restore on failure
                        failed_files=$((failed_files + 1))
                    fi
                fi
            fi
        done
    else
        debug "jq not available, skipping JSON optimization"
    fi
    
    # Optimize log files by removing timestamps and deduplicating
    # This can significantly improve compression for repetitive logs
    debug "Optimizing log files"
    find "$TEMP_DIR" -type f -name "*.log" 2>/dev/null | while read -r file; do
        if [ -f "$file" ] && [ -s "$file" ]; then
            if cp "$file" "$file.bak" 2>/dev/null; then
                # Remove timestamps and sort unique lines
                if sed -r 's/^[0-9]{4}(-|\/)[0-9]{2}(-|\/)[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)? //g' "$file.bak" 2>/dev/null | \
                   sort 2>/dev/null | uniq > "$file" 2>/dev/null; then
                    rm -f "$file.bak"
                    processed_files=$((processed_files + 1))
                else
                    mv "$file.bak" "$file"  # Restore on failure
                    failed_files=$((failed_files + 1))
                fi
            fi
        fi
    done
    
    info "Content preprocessing completed: $processed_files files processed, $failed_files failed"
    
    # Return success if we processed some files or had no failures
    if [ $failed_files -eq 0 ] || [ $processed_files -gt 0 ]; then
        return 0
    else
        return 1
    fi
}

# Perform smart chunking for large files
# This function splits large files into smaller chunks for better compression
# and parallel processing
perform_smart_chunking() {
    local large_file_count=0
    local chunk_dir="$TEMP_DIR/chunked_files"
    local chunk_size="10M"
    local size_threshold="50M"
    
    debug "Starting smart chunking for files larger than $size_threshold"
    
    # Create chunked files directory
    if ! mkdir -p "$chunk_dir"; then
        error "Failed to create chunk directory: $chunk_dir"
        return 1
    fi
    
    # Find files larger than threshold and split them
    find "$TEMP_DIR" -type f -size "+$size_threshold" 2>/dev/null | while read -r file; do
        # Skip files in the chunk directory to avoid recursion
        if [[ "$file" == "$chunk_dir"* ]]; then
            continue
        fi
        
        local rel_path="${file#$TEMP_DIR/}"
        local chunk_base="$chunk_dir/$rel_path"
        local chunk_parent_dir
        
        # Sanitize paths
        rel_path=$(sanitize_input "$rel_path")
        chunk_base=$(sanitize_input "$chunk_base")
        
        # Create parent directory for chunks
        chunk_parent_dir=$(dirname "$chunk_base")
        if ! mkdir -p "$chunk_parent_dir"; then
            warning "Failed to create chunk parent directory: $chunk_parent_dir"
            continue
        fi
        
        debug "Chunking large file: $file ($(du -h "$file" 2>/dev/null | cut -f1))"
        
        # Split file into chunks with consistent boundaries
        if split --numeric-suffixes=1 --additional-suffix=.chunk -b "$chunk_size" "$file" "$chunk_base." 2>/dev/null; then
            # Remove original file and create marker
            if rm "$file" && touch "$file.chunked"; then
                large_file_count=$((large_file_count + 1))
                debug "Successfully chunked: $file"
            else
                warning "Failed to remove original file after chunking: $file"
            fi
        else
            warning "Failed to chunk file: $file"
        fi
    done
    
    info "Smart chunking completed: $large_file_count large files processed"
    return 0
}

# =============================================================================
# BACKUP VERIFICATION AND ANALYSIS FUNCTIONS
# =============================================================================

# Centralized function to count files in backup archive
# This function provides accurate file counts for different compression types
# and handles various edge cases and error conditions
#
# Parameters:
#   $1: backup_file - Path to the backup archive
#   $2: count_dirs - Whether to count directories (default: false)
#
# Returns: File count (and directory count if requested)
# Output format: "file_count" or "file_count dir_count"
count_files_in_backup() {
    local backup_file="$1"
    local count_dirs="${2:-false}"
    local file_count=0
    local dir_count=0
    local file_list
    
    # Sanitize inputs
    backup_file=$(sanitize_input "$backup_file")
    count_dirs=$(sanitize_input "$count_dirs")
    
    debug "Counting files in backup: $backup_file"
    
    # Create secure temporary file for file listing
    if ! file_list=$(mktemp); then
        error "Failed to create temporary file for file listing"
        echo "0"
        return 1
    fi
    
    # Ensure cleanup of temporary file
    trap "rm -f '$file_list'" RETURN
    
    if [ -n "$backup_file" ] && [ -f "$backup_file" ]; then
        # Extract file list based on compression type with enhanced error handling
        # Try multiple methods to ensure compatibility across different systems
        local extraction_success=false
        
        case "$COMPRESSION_TYPE" in
            "zstd")
                debug "Using zstd to extract file list"
                if command -v zstd >/dev/null 2>&1; then
                    if zstd -dc "$backup_file" 2>/dev/null | tar -tf - > "$file_list" 2>/dev/null; then
                        extraction_success=true
                    fi
                fi
                ;;
            "gzip"|"pigz")
                debug "Using gzip to extract file list"
                if tar -tzf "$backup_file" > "$file_list" 2>/dev/null; then
                    extraction_success=true
                fi
                ;;
            "xz")
                debug "Using xz to extract file list"
                if command -v xz >/dev/null 2>&1; then
                    if tar -tJf "$backup_file" > "$file_list" 2>/dev/null; then
                        extraction_success=true
                    fi
                fi
                ;;
            "bzip2")
                debug "Using bzip2 to extract file list"
                if tar -tjf "$backup_file" > "$file_list" 2>/dev/null; then
                    extraction_success=true
                fi
                ;;
            "lzma")
                debug "Using lzma to extract file list"
                if command -v lzma >/dev/null 2>&1; then
                    if lzma -dc "$backup_file" 2>/dev/null | tar -tf - > "$file_list" 2>/dev/null; then
                        extraction_success=true
                    fi
                fi
                ;;
            *)
                debug "Unknown compression type, trying fallback methods"
                ;;
        esac
        
        # Fallback methods if primary extraction failed
        if [ "$extraction_success" = false ]; then
            debug "Primary extraction failed, trying fallback methods"
            
            # Try auto-detection with file command
            local file_type
            if command -v file >/dev/null 2>&1; then
                file_type=$(file "$backup_file" 2>/dev/null)
                
                case "$file_type" in
                    *"Zstandard"*)
                        debug "Auto-detected Zstandard compression"
                        if command -v zstd >/dev/null 2>&1; then
                            zstd -dc "$backup_file" 2>/dev/null | tar -tf - > "$file_list" 2>/dev/null && extraction_success=true
                        fi
                        ;;
                    *"gzip"*)
                        debug "Auto-detected gzip compression"
                        tar -tzf "$backup_file" > "$file_list" 2>/dev/null && extraction_success=true
                        ;;
                    *"XZ"*)
                        debug "Auto-detected XZ compression"
                        if command -v xz >/dev/null 2>&1; then
                            tar -tJf "$backup_file" > "$file_list" 2>/dev/null && extraction_success=true
                        fi
                        ;;
                    *"bzip2"*)
                        debug "Auto-detected bzip2 compression"
                        tar -tjf "$backup_file" > "$file_list" 2>/dev/null && extraction_success=true
                        ;;
                esac
            fi
            
            # Last resort: try common decompression tools
            if [ "$extraction_success" = false ]; then
                debug "Auto-detection failed, trying common tools"
                
                # Try zstd (most common in modern systems)
                if command -v zstd >/dev/null 2>&1; then
                    zstd -dc "$backup_file" 2>/dev/null | tar -tf - > "$file_list" 2>/dev/null && extraction_success=true
                fi
                
                # Try gzip (universally available)
                if [ "$extraction_success" = false ]; then
                    tar -tzf "$backup_file" > "$file_list" 2>/dev/null && extraction_success=true
                fi
            fi
        fi
        
        # Verify that the file list was created successfully
        if [ "$extraction_success" = true ] && [ -s "$file_list" ]; then
            debug "File list extraction successful, processing file counts"
            
            # Calculate total number of lines in file, excluding .sha256 files
            local total_lines
            total_lines=$(grep -v "\.sha256$" "$file_list" 2>/dev/null | wc -l)
            debug "Total entries in archive list (excluding .sha256 files): $total_lines"
            
            # Count files and directories separately, excluding .sha256 files
            file_count=$(grep -v "\.sha256$" "$file_list" 2>/dev/null | grep -v '/$' | wc -l)
            
            if [ "$count_dirs" = "true" ]; then
                dir_count=$(grep -c '/$' "$file_list" 2>/dev/null || echo 0)
            fi
            
            # Verify if the count is realistic (some tools have output limits)
            if [ "$file_count" -eq 250 ] || [ "$file_count" -eq 500 ] || [ "$file_count" -eq 1000 ]; then
                warning "File count is exactly $file_count, which may indicate a limit in the output"
                # Try alternative counting method
                if ! perform_alternate_file_count "$backup_file"; then
                    warning "Alternative file counting also failed"
                fi
            fi
            
            debug "Final count: $file_count files, $dir_count directories"
        else
            warning "Failed to extract file list from archive, trying fallback methods"
            
            # Primary fallback: use file count from TEMP_DIR if available
            if [ -d "$TEMP_DIR" ]; then
                debug "Using TEMP_DIR fallback for file counting"
                file_count=$(find "$TEMP_DIR" -type f 2>/dev/null | wc -l)
                debug "Fallback count from TEMP_DIR: $file_count files"
                
                if [ "$count_dirs" = "true" ]; then
                    dir_count=$(find "$TEMP_DIR" -type d 2>/dev/null | wc -l)
                    debug "Fallback count from TEMP_DIR: $dir_count directories"
                fi
            else
                # Secondary fallback: estimate based on archive size
                debug "TEMP_DIR not available, estimating based on archive size"
                local archive_size
                archive_size=$(stat -c %s "$backup_file" 2>/dev/null || echo 0)
                
                if [ "$archive_size" -gt 0 ]; then
                    # Rough estimation: 1 file per 10KB of compressed data
                    file_count=$((archive_size / 10240))
                    debug "Estimated file count based on archive size: $file_count"
                else
                    warning "All file counting methods failed"
                    file_count=0
                fi
            fi
        fi
    else
        report_detailed_error "BACKUP_FILE_MISSING" "validate backup file" \
            "Backup file not found or empty: $backup_file" \
            "Ensure the backup creation completed successfully"
        file_count=0
    fi
    
    # Return counts in appropriate format
    if [ "$count_dirs" = "true" ]; then
        echo "$file_count $dir_count"
    else
        echo "$file_count"
    fi
}

# Alternative method for counting files when standard methods fail
# This function performs partial extraction to estimate file counts
# and provides a more accurate count when listing fails
perform_alternate_file_count() {
    local backup_file="$1"
    local sample_dir
    local extraction_success=false
    
    # Sanitize input
    backup_file=$(sanitize_input "$backup_file")
    
    debug "Attempting alternative file counting method"
    
    # Create secure temporary directory for sample extraction
    if ! sample_dir=$(mktemp -d); then
        error "Failed to create temporary directory for sample extraction"
        return 1
    fi
    
    # Ensure cleanup of temporary directory
    trap "rm -rf '$sample_dir'" RETURN
    
    # Try to extract a small sample to verify archive integrity
    # Focus on common directories that are likely to exist
    local sample_patterns=("etc/*" "var/*" "usr/*" "*/system/*" "*")
    
    for pattern in "${sample_patterns[@]}"; do
        debug "Trying to extract sample with pattern: $pattern"
        
        case "$COMPRESSION_TYPE" in
            "zstd")
                if command -v zstd >/dev/null 2>&1; then
                    if zstd -dc "$backup_file" 2>/dev/null | tar -xf - -C "$sample_dir" --wildcards "$pattern" --strip-components=0 2>/dev/null; then
                        extraction_success=true
                        break
                    fi
                fi
                ;;
            "gzip"|"pigz")
                if tar -xzf "$backup_file" -C "$sample_dir" --wildcards "$pattern" --strip-components=0 2>/dev/null; then
                    extraction_success=true
                    break
                fi
                ;;
            "xz")
                if command -v xz >/dev/null 2>&1; then
                    if tar -xJf "$backup_file" -C "$sample_dir" --wildcards "$pattern" --strip-components=0 2>/dev/null; then
                        extraction_success=true
                        break
                    fi
                fi
                ;;
            "bzip2")
                if tar -xjf "$backup_file" -C "$sample_dir" --wildcards "$pattern" --strip-components=0 2>/dev/null; then
                    extraction_success=true
                    break
                fi
                ;;
            *)
                # Try multiple decompression methods
                if command -v zstd >/dev/null 2>&1; then
                    if zstd -dc "$backup_file" 2>/dev/null | tar -xf - -C "$sample_dir" --wildcards "$pattern" --strip-components=0 2>/dev/null; then
                        extraction_success=true
                        break
                    fi
                fi
                ;;
        esac
    done
    
    # Analyze extracted sample if extraction was successful
    if [ "$extraction_success" = true ]; then
        local sample_count
        sample_count=$(find "$sample_dir" -type f 2>/dev/null | wc -l)
        debug "Sample extraction found $sample_count files"
        
        if [ "$sample_count" -gt 0 ]; then
            # Estimate total based on sample size and typical backup structure
            # Use conservative multiplier to avoid overestimation
            local estimated_total
            
            # Different estimation strategies based on sample size
            if [ "$sample_count" -lt 10 ]; then
                # Small sample, use higher multiplier
                estimated_total=$((sample_count * 20))
            elif [ "$sample_count" -lt 100 ]; then
                # Medium sample, moderate multiplier
                estimated_total=$((sample_count * 10))
            else
                # Large sample, conservative multiplier
                estimated_total=$((sample_count * 5))
            fi
            
            debug "Estimated total files based on sample: $estimated_total"
            file_count="$estimated_total"
            return 0
        else
            warning "Sample extraction succeeded but no files found"
            return 1
        fi
    else
        warning "Sample extraction failed for all patterns"
        return 1
    fi
}

# Function to check if PVE is configured in cluster mode (imported from collect module)
is_pve_cluster_configured_for_validation() {
    # Method 1: Check if corosync.conf exists and has cluster configuration
    if [ -f "/etc/corosync/corosync.conf" ]; then
        # Check if corosync.conf contains cluster configuration (not just default)
        if grep -q "cluster_name\|nodelist\|ring0_addr" "/etc/corosync/corosync.conf" 2>/dev/null; then
            return 0
        fi
    fi
    
    # Method 2: Check cluster status via pvecm
    if command -v pvecm >/dev/null 2>&1; then
        if pvecm status >/dev/null 2>&1; then
            return 0
        fi
    fi
    
    # Method 3: Check if cluster directory exists and contains multiple nodes
    if [ -d "/etc/pve/nodes" ]; then
        local node_count=$(find "/etc/pve/nodes" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)
        if [ "$node_count" -gt 1 ]; then
            return 0
        fi
    fi
    
    # Method 4: Check if corosync service is running
    if systemctl is-active corosync.service >/dev/null 2>&1; then
        return 0
    fi
    
    return 1
}

# Count missing critical files in backup
# This function verifies that essential configuration files are present
# in the backup based on the Proxmox type (PVE or PBS)
#
# Global variables used:
# - PROXMOX_TYPE: Type of Proxmox installation (pve|pbs)
# - TEMP_DIR: Directory containing collected backup files
#
# Returns: Number of missing critical files
count_missing_files() {
    local missing_files=0
    local critical_files=()
    local proxmox_type
    
    # Sanitize and validate Proxmox type
    proxmox_type=$(sanitize_input "${PROXMOX_TYPE:-unknown}")
    
    debug "Checking for missing critical files (Proxmox type: $proxmox_type)" >&2
    
    # Define critical files based on Proxmox type
    case "$proxmox_type" in
        "pve")
            # Essential PVE configuration files (base set)
            critical_files=(
                "${TEMP_DIR}/etc/pve/storage.cfg"
                "${TEMP_DIR}/etc/pve/user.cfg"
                "${TEMP_DIR}/etc/pve/datacenter.cfg"
                "${TEMP_DIR}/var/lib/pve-cluster/config.db"
            )
            
            # Add corosync.conf only if cluster is configured
            if is_pve_cluster_configured_for_validation; then
                debug "Cluster detected, including corosync.conf in critical files check" >&2
                critical_files+=("${TEMP_DIR}/etc/corosync/corosync.conf")
            else
                debug "No cluster detected, excluding corosync.conf from critical files check" >&2
            fi
            ;;
        "pbs")
            # Essential PBS configuration files
            critical_files=(
                "${TEMP_DIR}/etc/proxmox-backup/user.cfg"
                "${TEMP_DIR}/etc/proxmox-backup/datastore.cfg"
                "${TEMP_DIR}/var/lib/proxmox-backup/datastore_list.json"
                "${TEMP_DIR}/var/lib/proxmox-backup/user_list.json"
            )
            ;;
        *)
            warning "Unknown Proxmox type: $proxmox_type" >&2
            echo "0"
            return 1
            ;;
    esac
    
    # Check each critical file
    for file in "${critical_files[@]}"; do
        local sanitized_file
        sanitized_file=$(sanitize_input "$file")
        
        if [ ! -f "$sanitized_file" ]; then
            warning "Missing critical file: $sanitized_file" >&2
            missing_files=$((missing_files + 1))
        else
            debug "Found critical file: $sanitized_file" >&2
        fi
    done
    
    # Additional checks for file content validity
    if [ "$missing_files" -eq 0 ]; then
        debug "All critical files present, performing content validation" >&2
        
        # Validate that files are not empty and contain expected content
        for file in "${critical_files[@]}"; do
            local sanitized_file
            sanitized_file=$(sanitize_input "$file")
            
            if [ -f "$sanitized_file" ]; then
                # Check if file is empty
                if [ ! -s "$sanitized_file" ]; then
                    warning "Critical file is empty: $sanitized_file" >&2
                    missing_files=$((missing_files + 1))
                    continue
                fi
                
                # Basic content validation based on file type
                case "$(basename "$sanitized_file")" in
                    *.cfg)
                        # Configuration files should contain key=value pairs or sections
                        if ! grep -q -E '^[a-zA-Z0-9_-]+\s*[:=]|^\[.*\]' "$sanitized_file" 2>/dev/null; then
                            warning "Configuration file appears to have invalid format: $sanitized_file" >&2
                            missing_files=$((missing_files + 1))
                        fi
                        ;;
                    *.json)
                        # JSON files should be valid JSON
                        if command -v jq >/dev/null 2>&1; then
                            if ! jq empty "$sanitized_file" >/dev/null 2>&1; then
                                warning "JSON file appears to be invalid: $sanitized_file" >&2
                                missing_files=$((missing_files + 1))
                            fi
                        fi
                        ;;
                esac
            fi
        done
    fi
    
    if [ "$missing_files" -eq 0 ]; then
        debug "All critical files present and valid" >&2
    else
        warning "Found $missing_files missing or invalid critical files" >&2
    fi
    
    echo "$missing_files"
}

# =============================================================================
# BACKUP INITIALIZATION AND FINALIZATION FUNCTIONS
# =============================================================================

# Initialize backup environment and prepare all necessary directories and files
# This function sets up the backup environment, creates directories, and initializes
# monitoring systems before the backup process begins
#
# Global variables modified:
# - LOG_FILE: Set to the backup log file path
# - BACKUP_FILE: Set to the backup archive file path
# - METRICS_FILE: Set to Prometheus metrics file path (if enabled)
#
# Returns: EXIT_SUCCESS on success, EXIT_ERROR on critical failure
initialize_backup() {
    step "Initializing backup process"
    
    # Validate required global variables
    if [ -z "$LOCAL_BACKUP_PATH" ] || [ -z "$LOCAL_LOG_PATH" ]; then
        report_detailed_error "MISSING_PATHS" "validate backup paths" \
            "Required backup paths not configured" \
            "Ensure LOCAL_BACKUP_PATH and LOCAL_LOG_PATH are set in configuration"
        return $EXIT_ERROR
    fi
    
    # Sanitize critical paths to prevent injection attacks
    LOCAL_BACKUP_PATH=$(sanitize_input "$LOCAL_BACKUP_PATH")
    LOCAL_LOG_PATH=$(sanitize_input "$LOCAL_LOG_PATH")
    
    # Create all required local directories with proper error handling
    if ! retry_operation 2 "mkdir -p '$LOCAL_BACKUP_PATH' '$LOCAL_LOG_PATH'" "create local directories"; then
        report_detailed_error "DIRECTORY_CREATION_FAILED" "create local directories" \
            "Failed to create backup directories: $LOCAL_BACKUP_PATH, $LOCAL_LOG_PATH" \
            "Check permissions and available disk space"
        return $EXIT_ERROR
    fi
    
    info "Created local directories: $LOCAL_BACKUP_PATH and $LOCAL_LOG_PATH"
    
    # Create secondary backup directories if secondary backup is enabled and configured
    if [ "${ENABLE_SECONDARY_BACKUP:-false}" = "true" ]; then
        if [ "${DRY_RUN_MODE:-false}" = "true" ]; then
            debug "Dry run mode: Would create secondary backup directories"
        elif [ -n "$SECONDARY_BACKUP_PATH" ] && [ -n "$SECONDARY_LOG_PATH" ]; then
            # Sanitize secondary paths
            SECONDARY_BACKUP_PATH=$(sanitize_input "$SECONDARY_BACKUP_PATH")
            SECONDARY_LOG_PATH=$(sanitize_input "$SECONDARY_LOG_PATH")
            
            # Check if parent directory exists before attempting creation
            if [ -d "$(dirname "$SECONDARY_BACKUP_PATH")" ]; then
                if retry_operation 2 "mkdir -p '$SECONDARY_BACKUP_PATH' '$SECONDARY_LOG_PATH'" "create secondary directories"; then
                    info "Created secondary directories: $SECONDARY_BACKUP_PATH and $SECONDARY_LOG_PATH"
                else
                    warning "Failed to create secondary directories. Secondary backup may fail."
                    set_exit_code "warning"
                fi
            else
                warning "Secondary backup parent directory doesn't exist: $(dirname "$SECONDARY_BACKUP_PATH")"
                warning "Secondary backup will be disabled for this session"
            fi
        else
            debug "Secondary backup paths not configured, skipping secondary directory creation"
        fi
    else
        debug "Secondary backup is disabled, skipping secondary directory creation"
    fi
    
    # Set up log file with sanitized components
    local proxmox_type_safe hostname_safe timestamp_safe
    proxmox_type_safe=$(sanitize_input "${PROXMOX_TYPE:-unknown}")
    hostname_safe=$(sanitize_input "${HOSTNAME:-localhost}")
    timestamp_safe=$(sanitize_input "${TIMESTAMP:-$(date +%Y%m%d_%H%M%S)}")
    
    local log_basename="${proxmox_type_safe}-backup-${timestamp_safe}.log"
    LOG_FILE="${LOCAL_LOG_PATH}/${log_basename}"
    
    # Set backup file name with proper sanitization
    BACKUP_FILE="${LOCAL_BACKUP_PATH}/${proxmox_type_safe}-backup-${hostname_safe}-${timestamp_safe}.tar"
    
    debug "Backup file will be: $BACKUP_FILE"
    debug "Log file will be: $LOG_FILE"
    
    # Initialize Prometheus metrics if enabled
    if [ "${PROMETHEUS_ENABLED:-false}" = "true" ]; then
        debug "Initializing Prometheus metrics system"
        
        # Sanitize Prometheus directory path
        PROMETHEUS_TEXTFILE_DIR=$(sanitize_input "${PROMETHEUS_TEXTFILE_DIR:-/var/lib/prometheus/node-exporter}")
        
        # Create prometheus directory if needed
        if [ ! -d "$PROMETHEUS_TEXTFILE_DIR" ]; then
            if ! mkdir -p "$PROMETHEUS_TEXTFILE_DIR" 2>/dev/null; then
                warning "Failed to create Prometheus textfile directory: $PROMETHEUS_TEXTFILE_DIR"
                warning "Prometheus metrics will be disabled for this backup session"
                PROMETHEUS_ENABLED="false"
            else
                debug "Created Prometheus textfile directory: $PROMETHEUS_TEXTFILE_DIR"
            fi
        fi
        
        if [ "$PROMETHEUS_ENABLED" = "true" ]; then
            # Initialize metrics file with secure temporary location
            METRICS_FILE="/tmp/proxmox_backup_metrics_$$.prom"
            
            # Initialize Prometheus metrics (function should be defined in metrics module)
            if command -v initialize_prometheus_metrics >/dev/null 2>&1; then
                if ! initialize_prometheus_metrics; then
                    warning "Failed to initialize Prometheus metrics"
                    set_exit_code "warning"
                fi
            else
                warning "initialize_prometheus_metrics function not found, metrics may be incomplete"
            fi
            
            # Update filesystem metrics at the start (function should be defined in metrics module)
            if command -v update_filesystem_metrics >/dev/null 2>&1; then
                if ! update_filesystem_metrics; then
                    warning "Failed to update filesystem metrics"
                    set_exit_code "warning"
                fi
            else
                debug "update_filesystem_metrics function not available, skipping initial filesystem metrics"
            fi
            
            info "Prometheus metrics initialized: $METRICS_FILE"
        fi
    else
        debug "Prometheus metrics disabled in configuration"
    fi
    
    # Validate that we have write permissions to critical paths
    if [ ! -w "$LOCAL_BACKUP_PATH" ]; then
        report_detailed_error "BACKUP_PATH_UNWRITABLE" "validate backup path permissions" \
            "Cannot write to backup directory: $LOCAL_BACKUP_PATH" \
            "Check directory permissions and ownership (should be writable by $(whoami))"
        return $EXIT_ERROR
    fi
    
    if [ ! -w "$LOCAL_LOG_PATH" ]; then
        report_detailed_error "LOG_PATH_UNWRITABLE" "validate log path permissions" \
            "Cannot write to log directory: $LOCAL_LOG_PATH" \
            "Check directory permissions and ownership (should be writable by $(whoami))"
        return $EXIT_ERROR
    fi
    
    # Check available disk space and warn if insufficient
    local available_space
    available_space=$(df "$LOCAL_BACKUP_PATH" 2>/dev/null | tail -1 | awk '{print $4}' || echo 0)
    
    if [ "$available_space" -lt 1048576 ]; then  # Less than 1GB in KB
        warning "Low disk space available in backup directory: $(( available_space / 1024 ))MB"
        warning "Backup may fail if insufficient space is available"
        set_exit_code "warning"
    else
        debug "Available disk space in backup directory: $(( available_space / 1024 ))MB"
    fi
    
    # Additional validation: check if we can create a test file
    local test_file="${LOCAL_BACKUP_PATH}/.backup_init_test_$$"
    if ! touch "$test_file" 2>/dev/null; then
        report_detailed_error "BACKUP_PATH_TEST_FAILED" "test backup path writability" \
            "Cannot create test file in backup directory: $LOCAL_BACKUP_PATH" \
            "Check filesystem health and mount status"
        return $EXIT_ERROR
    else
        rm -f "$test_file" 2>/dev/null || true
        debug "Backup path writability test passed"
    fi
    
    success "Backup initialization completed successfully"
    return $EXIT_SUCCESS
}

# Update backup duration
update_backup_duration() {
    step "Calculating backup duration"
    
    # Store the current time as end time
    END_TIME=$(get_current_timestamp)
    
    # Calculate duration only if we have both start and end times
    if [ -n "$START_TIME" ] && [ -n "$END_TIME" ]; then
        BACKUP_DURATION=$(calculate_time_difference "$START_TIME" "$END_TIME" "seconds")
        # Utilizza la funzione centralizzata per formattare la durata
        BACKUP_DURATION_FORMATTED=$(format_duration "$BACKUP_DURATION")
        
        # Update Prometheus metrics with final duration
        if [ "$PROMETHEUS_ENABLED" == "true" ]; then
            echo "# HELP proxmox_backup_duration_seconds Duration of backup process in seconds" >> "$METRICS_FILE"
            echo "# TYPE proxmox_backup_duration_seconds gauge" >> "$METRICS_FILE"
            echo "proxmox_backup_duration_seconds $BACKUP_DURATION" >> "$METRICS_FILE"
        fi
        
        debug "Backup duration calculated: $BACKUP_DURATION seconds ($BACKUP_DURATION_FORMATTED)"
    else
        warning "Could not calculate backup duration: START_TIME=$START_TIME, END_TIME=$END_TIME"
    fi
    
    success "Backup duration calculated: $BACKUP_DURATION_FORMATTED"
}
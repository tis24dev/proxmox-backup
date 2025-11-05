#!/bin/bash
##
# Proxmox Backup System - Backup Collection Library
# File: backup_collect.sh
# Version: 0.7.2
# Last Modified: 2025-11-05
# Changes: Fix verbose level rsync
##
# Functions for backup data collection

# Global counters for monitoring
BACKUP_FILES_PROCESSED=0
BACKUP_FILES_FAILED=0
BACKUP_DIRS_CREATED=0
BACKUP_OPERATION_START_TIME=0

# Unified error handling function (Suggerimento 4)
handle_collection_error() {
    local operation="$1"
    local file_path="$2"
    local error_level="${3:-warning}"
    local additional_info="${4:-}"
    
    local error_msg="Failed to collect $operation"
    if [ -n "$file_path" ]; then
        error_msg="$error_msg: $file_path"
    fi
    if [ -n "$additional_info" ]; then
        error_msg="$error_msg ($additional_info)"
    fi
    
    case "$error_level" in
        "critical"|"error")
            error "$error_msg"
            set_exit_code "error"
            increment_file_counter "failed"
            return 1
            ;;
        "warning")
            warning "$error_msg"
            set_exit_code "warning"
            increment_file_counter "failed"
            return 0
            ;;
        "debug")
            debug "$error_msg"
            return 0
            ;;
        *)
            warning "$error_msg"
            set_exit_code "warning"
            increment_file_counter "failed"
            return 0
            ;;
    esac
}

# Helper function to safely copy files/directories with unified error handling
safe_copy() {
    local source="$1"
    local destination="$2"
    local operation_name="$3"
    local error_level="${4:-warning}"
    local copy_options="${5:--p}"
    
    if [ ! -e "$source" ]; then
        debug "$operation_name not found: $source (skipping)"
        return 0
    fi
    
    # Create destination directory if needed
    local dest_dir=$(dirname "$destination")
    if [ ! -d "$dest_dir" ]; then
        mkdir -p "$dest_dir" && increment_file_counter "dirs"
    fi
    
    # Perform copy operation
    if [ -d "$source" ]; then
        # Ensure destination exists so dotfiles and empty directories copy correctly
        if [ ! -d "$destination" ]; then
            mkdir -p "$destination"
        fi

        if cp -a $copy_options "$source"/. "$destination/" 2>/dev/null; then
            debug "Successfully collected $operation_name: $source"
            increment_file_counter "processed"
            return 0
        else
            handle_collection_error "$operation_name" "$source" "$error_level"
            return $?
        fi
    else
        if cp $copy_options "$source" "$destination" 2>/dev/null; then
            debug "Successfully collected $operation_name: $source"
            increment_file_counter "processed"
            return 0
        else
            handle_collection_error "$operation_name" "$source" "$error_level"
            return $?
        fi
    fi
}

# Helper function to safely execute commands and save output
safe_command_output() {
    local command="$1"
    local output_file="$2"
    local operation_name="$3"
    local error_level="${4:-warning}"
    
    if ! command -v "${command%% *}" >/dev/null 2>&1; then
        debug "Command not available: ${command%% *} (skipping $operation_name)"
        return 0
    fi
    
    if eval "$command" > "$output_file" 2>&1; then
        debug "Successfully collected $operation_name via command: $command"
        increment_file_counter "processed"
        return 0
    else
        handle_collection_error "$operation_name" "command: $command" "$error_level"
        return $?
    fi
}

# Function to log operation metrics 
log_operation_metrics() {
    local operation="$1"
    local start_time="$2"
    local end_time="$3"
    local files_processed="${4:-0}"
    local files_failed="${5:-0}"
    
    local duration=$((end_time - start_time))
    
    info "Operation: $operation completed in ${duration}s"
    info "Files processed: $files_processed, Failed: $files_failed"
    
    # Update Prometheus metrics if enabled
    if [ "$PROMETHEUS_ENABLED" == "true" ]; then
        echo "backup_operation_duration_seconds{operation=\"$operation\"} $duration" >> "$METRICS_FILE"
        echo "backup_files_processed_total{operation=\"$operation\"} $files_processed" >> "$METRICS_FILE"
        echo "backup_files_failed_total{operation=\"$operation\"} $files_failed" >> "$METRICS_FILE"
    fi
}

# Function to increment file counters
increment_file_counter() {
    local counter_type="$1"
    case "$counter_type" in
        "processed")
            BACKUP_FILES_PROCESSED=$((BACKUP_FILES_PROCESSED + 1))
            ;;
        "failed")
            BACKUP_FILES_FAILED=$((BACKUP_FILES_FAILED + 1))
            ;;
        "dirs")
            BACKUP_DIRS_CREATED=$((BACKUP_DIRS_CREATED + 1))
            ;;
    esac
}

# Function to reset counters
reset_backup_counters() {
    BACKUP_FILES_PROCESSED=0
    BACKUP_FILES_FAILED=0
    BACKUP_DIRS_CREATED=0
}

# Collect Proxmox configuration based on type
perform_backup() {
    debug "Starting backup process"
    
    if [ "$DRY_RUN_MODE" == "true" ]; then
        info "Dry run mode: Would perform backup operations now"
        return $EXIT_SUCCESS
    fi
    
    info "Starting backup process"
    
    # Reset counters at the start
    reset_backup_counters
    
    # Start of setup phase for metrics
    local setup_start=$(date +%s)
    
    # Set backup file name now that we know the Proxmox type
    BACKUP_FILE="${LOCAL_BACKUP_PATH}/${PROXMOX_TYPE}-backup-${HOSTNAME}-${TIMESTAMP}.tar"
    
    # Setup complete
    local setup_end=$(date +%s)
    
    # Start of collection phase for metrics
    local collect_start=$(date +%s)
    
    # Collect appropriate configuration based on Proxmox type
    if [ "$PROXMOX_TYPE" == "pve" ]; then
        # Call function and handle different exit codes properly
        if collect_pve_configs; then
            info "PVE configurations collected successfully"
        else
            local pve_result=$?
            if [ "$pve_result" -eq "$EXIT_WARNING" ]; then
                warning "PVE configurations collected with warnings (datastore issues are non-critical)"
                set_exit_code "warning"
            else
                error "Failed to collect PVE configurations"
                set_exit_code "error"
                return $EXIT_ERROR
            fi
        fi
    elif [ "$PROXMOX_TYPE" == "pbs" ]; then
        # Call function and handle different exit codes properly
        if collect_pbs_configs; then
            info "PBS configurations collected successfully"
        else
            local pbs_result=$?
            if [ "$pbs_result" -eq "$EXIT_WARNING" ]; then
                warning "PBS configurations collected with warnings (datastore issues are non-critical)"
                set_exit_code "warning"
            else
                error "Failed to collect PBS configurations"
                set_exit_code "error"
                return $EXIT_ERROR
            fi
        fi
    else
        error "Unknown Proxmox type: $PROXMOX_TYPE"
        set_exit_code "error"
        return $EXIT_ERROR
    fi
    
    # Collect common system information
    if ! collect_system_info; then
        error "Failed to collect system information"
        set_exit_code "warning"
        return $EXIT_WARNING
    fi
    
    # End of collection phase
    local collect_end=$(date +%s)
    
    # Start of archive creation phase
    local archive_start=$(date +%s)
    
    # Create the backup archive
    if ! create_backup_archive; then
        error "Failed to create backup archive"
        set_exit_code "error"
        return $EXIT_ERROR
    fi
    
    # End of archive creation phase
    local archive_end=$(date +%s)
    
    # Start of verification phase
    local verify_start=$(date +%s)
    
    # Verify the backup
    if ! verify_backup; then
        error "Failed to verify backup"
        set_exit_code "error"
        set_backup_status "verify" $EXIT_ERROR
        return $EXIT_ERROR
    else
        set_backup_status "verify" $EXIT_SUCCESS
    fi
    
    # End of verification phase
    local verify_end=$(date +%s)
    
    # Update phase metrics if Prometheus is enabled
    if [ "$PROMETHEUS_ENABLED" == "true" ]; then
        update_phase_metrics "setup" "$setup_start" "$setup_end"
        update_phase_metrics "collect" "$collect_start" "$collect_end"
        update_phase_metrics "compress" "$archive_start" "$archive_end"
        update_phase_metrics "verify" "$verify_start" "$verify_end"
    fi
    
    # Log final metrics
    local total_duration=$((verify_end - setup_start))
    info "Total backup duration: ${total_duration}s"
    info "Total files processed: $BACKUP_FILES_PROCESSED"
    info "Total files failed: $BACKUP_FILES_FAILED"
    info "Total directories created: $BACKUP_DIRS_CREATED"
    
    # Log operation metrics for the entire backup process
    log_operation_metrics "complete_backup" "$setup_start" "$verify_end" "$BACKUP_FILES_PROCESSED" "$BACKUP_FILES_FAILED"
    
    info "Backup created successfully: $BACKUP_FILE"
    success "Backup process completed successfully"
    return $EXIT_SUCCESS
}

# Collect critical system files function
collect_critical_files() {
    if [ "$BACKUP_CRITICAL_FILES" != "true" ]; then
        debug "Critical file backup disabled, skipping"
        return 0
    fi

    step "Collecting critical system files"
    
    # Prohibited patterns - define them at the beginning to use in exclusions
    local prohibited_patterns=(".cursor" ".cursor-server" ".vscode" "node_modules")
    
    # Create pattern string for grep
    local grep_exclude=""
    for pattern in "${prohibited_patterns[@]}"; do
        if [ -z "$grep_exclude" ]; then
            grep_exclude="$pattern"
        else
            grep_exclude="$grep_exclude\|$pattern"
        fi
    done
    
    # -------------------------------------------------------------------------
    # 1. First copy only specific files (not entire directories)
    # -------------------------------------------------------------------------
    local specific_files=(

    )
    
    for file in "${specific_files[@]}"; do
        if [ -f "$file" ]; then
            # Verify that the file does not contain prohibited patterns
            if ! echo "$file" | grep -q "$grep_exclude"; then
            local target_dir="$TEMP_DIR/$(dirname "${file#/}")"
            mkdir -p "$target_dir"
            debug "Copying specific file: $file"
            cp -p "$file" "$TEMP_DIR/$file" 2>/dev/null || true
            else
                debug "Skipped file with prohibited pattern: $file"
            fi
        fi
    done
    
    # -------------------------------------------------------------------------
    # 2. Then copy only selected directories with strict exclusions
    # -------------------------------------------------------------------------
    # Directories to copy selectively
    local specific_dirs=(
        "/etc/apt"
    )
    
    # Directories/patterns to exclude absolutely (will never be copied)
    local absolute_excludes=(

    )
    
    # Add prohibited patterns to absolute exclusions
    for pattern in "${prohibited_patterns[@]}"; do
        absolute_excludes+=("*$pattern*")
    done
    
    # Prepare exclusion file
    local exclude_file=$(mktemp)
    for pattern in "${absolute_excludes[@]}"; do
        echo "$pattern" >> "$exclude_file"
    done
    
    # Copy selected directories
    for dir in "${specific_dirs[@]}"; do
        if [ -d "$dir" ]; then
            debug "Copying directory: $dir (with exclusions)"
            mkdir -p "$TEMP_DIR/$dir"
            
            # Create find arguments to exclude prohibited directories completely
            local find_exclude_args=""
            for pattern in "${prohibited_patterns[@]}"; do
                find_exclude_args="$find_exclude_args -path '*/$pattern*' -prune -o"
            done
            
            # Use find to copy only files, with exclusion patterns and pruning of prohibited directories
            eval find "$dir" $find_exclude_args -type f 2>/dev/null | grep -v -f "$exclude_file" | while read -r file; do
                # Additional verification against prohibited patterns
                if ! echo "$file" | grep -q "$grep_exclude"; then
                local target_file="$TEMP_DIR/$file"
                local target_dir=$(dirname "$target_file")
                mkdir -p "$target_dir"
                cp -p "$file" "$target_file" 2>/dev/null || true
                else
                    debug "Skipped file with prohibited pattern: $file"
                fi
            done
        fi
    done
    
    # Cleanup
    rm -f "$exclude_file"
    
    success "Critical system files collected successfully"
    return 0
}

# Collect common system information
collect_system_info() {
    step "Collecting system information"
    
    # Create system information directory
    mkdir -p "$TEMP_DIR/var/lib/proxmox-backup-info"
    
    # Backup networking configuration
    info "Collecting network configuration"
    mkdir -p "$TEMP_DIR/etc/network"
    
    if [ -f "/etc/network/interfaces" ]; then
        cp "/etc/network/interfaces" "$TEMP_DIR/etc/network/interfaces"
    else
        debug "Network interfaces file not found, skipping"
    fi
    
    # Backup network interfaces status
    if command -v ip &> /dev/null; then
        ip addr > "$TEMP_DIR/var/lib/proxmox-backup-info/ip_addr.txt"
        ip route > "$TEMP_DIR/var/lib/proxmox-backup-info/ip_route.txt"
        ip -s link > "$TEMP_DIR/var/lib/proxmox-backup-info/ip_link.txt"
    fi
    
    # Backup firewall configuration
    if command -v iptables-save &> /dev/null; then
        iptables-save > "$TEMP_DIR/var/lib/proxmox-backup-info/iptables.txt"
    fi
    
    if command -v ip6tables-save &> /dev/null; then
        ip6tables-save > "$TEMP_DIR/var/lib/proxmox-backup-info/ip6tables.txt"
    fi
    
    # System information
    if command -v uname &> /dev/null; then
        uname -a > "$TEMP_DIR/var/lib/proxmox-backup-info/uname.txt"
    fi
    
    if [ -f "/etc/os-release" ]; then
        cp "/etc/os-release" "$TEMP_DIR/var/lib/proxmox-backup-info/os-release.txt"
    fi
    
    # Hardware information
    if command -v lspci &> /dev/null; then
        lspci -v > "$TEMP_DIR/var/lib/proxmox-backup-info/lspci.txt" 2>&1
    fi
    
    if command -v lsblk &> /dev/null; then
        lsblk -f > "$TEMP_DIR/var/lib/proxmox-backup-info/lsblk.txt" 2>&1
    fi
    
    if command -v lscpu &> /dev/null; then
        lscpu > "$TEMP_DIR/var/lib/proxmox-backup-info/lscpu.txt" 2>&1
    fi
    
    if command -v free &> /dev/null; then
        free -h > "$TEMP_DIR/var/lib/proxmox-backup-info/memory.txt" 2>&1
    fi
    
    if command -v df &> /dev/null; then
        df -h > "$TEMP_DIR/var/lib/proxmox-backup-info/disk_space.txt" 2>&1
    fi
    
    # Package information
    if [ "$BACKUP_INSTALLED_PACKAGES" == "true" ] && command -v dpkg &> /dev/null; then
        info "Collecting installed packages information"
        mkdir -p "$TEMP_DIR/var/lib/proxmox-backup-info/packages"
        dpkg -l > "$TEMP_DIR/var/lib/proxmox-backup-info/packages/dpkg_list.txt" 2>&1
    fi
    
    # Service status
    if command -v systemctl &> /dev/null; then
        systemctl list-units --type=service --all > "$TEMP_DIR/var/lib/proxmox-backup-info/services.txt" 2>&1
    fi
    
    # Storage information
    if [ "$BACKUP_ZFS_CONFIG" == "true" ] && command -v zfs &> /dev/null; then
        info "Collecting ZFS information"
        mkdir -p "$TEMP_DIR/var/lib/proxmox-backup-info/zfs"
        zfs list > "$TEMP_DIR/var/lib/proxmox-backup-info/zfs/zfs_list.txt" 2>&1
        zpool list > "$TEMP_DIR/var/lib/proxmox-backup-info/zfs/zpool_list.txt" 2>&1
        zpool status > "$TEMP_DIR/var/lib/proxmox-backup-info/zfs/zpool_status.txt" 2>&1
        zfs get all > "$TEMP_DIR/var/lib/proxmox-backup-info/zfs/zfs_get_all.txt" 2>&1
    fi
    
    # Backup custom files from configuration
    collect_custom_files
    
    # Backup critical system files
    collect_critical_files
    
    # Backup user scripts in /usr/local
    if [ "$BACKUP_SCRIPT_DIR" == "true" ]; then
        debug "Collecting script directory contents"
        
        fi
        
        debug "Backing up script repository: $BASE_DIR"
        
        # Create the destination directory
        local target_dir_base="$(basename "$BASE_DIR")"
        local target_dir="${TEMP_DIR}/script-repository/${target_dir_base}"
        mkdir -p "$target_dir"
        
        # Find all files and directories to copy, excluding log and backup directories
        # NOTE: Using subshell to prevent 'find' from changing our working directory
        (
            find "$BASE_DIR" -type f -o -type d | grep -v "$BASE_DIR/log" | grep -v "$BASE_DIR/backup" | while read item; do
                # Skip the root directory
                if [ "$item" == "$BASE_DIR" ]; then
                    continue
                fi

                # Calculate the relative path
                local rel_path="${item#$BASE_DIR/}"
                local dest_path="${target_dir}/${rel_path}"

                if [ -d "$item" ]; then
                    # It's a directory, create it
                    if [ "$rel_path" != "log" ] && [ "$rel_path" != "backup" ]; then
                        mkdir -p "$dest_path"
                        debug "Created directory: $dest_path"
                    fi
                elif [ -f "$item" ]; then
                    # It's a file, copy it
                    local dest_dir="$(dirname "$dest_path")"
                    mkdir -p "$dest_dir"
                    cp -p "$item" "$dest_path" 2>/dev/null
                    if [ $? -eq 0 ]; then
                        debug "Copied file: $item -> $dest_path"
                    else
                        warning "Failed to copy file: $item"
                    fi
                fi
            done
        )
        
        success "Successfully backed up script repository: $BASE_DIR"
        
        # Backup /usr/local/bin (keep this part for backward compatibility)
        debug "Collecting custom scripts from /usr/local"
        
        # Backup /usr/local/bin
        if [ -d "/usr/local/bin" ]; then
            if [ "$(ls -A /usr/local/bin/ 2>/dev/null)" ]; then
                mkdir -p "$TEMP_DIR/usr/local/bin"
                debug "Copying files from /usr/local/bin to $TEMP_DIR/usr/local/bin"
                
                # Use cp instead of rsync
                # NOTE: Using subshell to prevent 'find' from changing our working directory
                (find /usr/local/bin -type f -exec cp {} "$TEMP_DIR/usr/local/bin/" \; 2>/dev/null)
                if [ $? -ne 0 ]; then
                    warning "Failed to backup /usr/local/bin, directory might be inaccessible"
                    set_exit_code "warning"
                else
                    info "Successfully backed up /usr/local/bin"
                fi
            else
                debug "Directory /usr/local/bin is empty, skipping"
            fi
        else
            debug "Directory /usr/local/bin does not exist, skipping"
        fi
        
        # Backup /usr/local/sbin
        if [ -d "/usr/local/sbin" ]; then
            if [ "$(ls -A /usr/local/sbin/ 2>/dev/null)" ]; then
                mkdir -p "$TEMP_DIR/usr/local/sbin"
                debug "Copying files from /usr/local/sbin to $TEMP_DIR/usr/local/sbin"
                
                # Use cp instead of rsync
                # NOTE: Using subshell to prevent 'find' from changing our working directory
                (find /usr/local/sbin -type f -exec cp -v {} "$TEMP_DIR/usr/local/sbin/" \; 2>/dev/null)
                if [ $? -ne 0 ]; then
                    warning "Failed to backup /usr/local/sbin, directory might be inaccessible"
                    set_exit_code "warning"
                else
                    info "Successfully backed up /usr/local/sbin"
                fi
            else
                debug "Directory /usr/local/sbin is empty, skipping"
            fi
        else
            debug "Directory /usr/local/sbin does not exist, skipping"
        fi
    
    # Backup crontabs
    if [ "$BACKUP_CRONTABS" == "true" ]; then
        debug "Collecting crontab information"
        
        # Backup system crontab
        if [ -f "/etc/crontab" ]; then
            mkdir -p "$TEMP_DIR/etc"
            if ! cp "/etc/crontab" "$TEMP_DIR/etc/crontab" 2>&1; then
                warning "Failed to backup /etc/crontab"
                set_exit_code "warning"
            else
                debug "Successfully backed up /etc/crontab"
            fi
        fi
        
        # Backup user crontabs
        if [ -d "/var/spool/cron/crontabs" ]; then
            mkdir -p "$TEMP_DIR/var/spool/cron/crontabs"
            # Find all user crontabs
            # NOTE: Using subshell to prevent 'find' from changing our working directory
            (
                find /var/spool/cron/crontabs -type f 2>/dev/null | while read -r crontab_file; do
                    username=$(basename "$crontab_file")
                    debug "Collecting crontab for user: $username"
                    if ! cp "$crontab_file" "$TEMP_DIR/var/spool/cron/crontabs/$username" 2>&1; then
                        warning "Failed to backup crontab for user $username"
                        set_exit_code "warning"
                    else
                        debug "Successfully backed up crontab for user $username"
                    fi
                done
            )
        fi
    fi
    
    # System service configuration
    collect_system_service_configs

    # Backup SSL certificates and SSH keys
    collect_security_configs

    # Create backup metadata for selective restore support
    create_backup_metadata

    success "System information collected successfully"

    # NOTE: No longer needed - subshells preserve working directory automatically
    # Working directory remains unchanged after all find operations
    debug "Working directory preserved after system info collection: $(pwd)"

    return $EXIT_SUCCESS
}

# Create backup metadata file for version detection and selective restore
create_backup_metadata() {
    local metadata_file="$TEMP_DIR/var/lib/proxmox-backup-info/backup_metadata.txt"

    debug "Creating backup metadata file"

    cat > "$metadata_file" <<EOF
# Proxmox Backup Metadata
# This file enables selective restore functionality in newer restore scripts
VERSION=${SCRIPT_VERSION}
BACKUP_TYPE=${PROXMOX_TYPE}
TIMESTAMP=${TIMESTAMP}
HOSTNAME=${HOSTNAME}
SUPPORTS_SELECTIVE_RESTORE=true
BACKUP_FEATURES=selective_restore,category_mapping,version_detection,auto_directory_creation
EOF

    if [ -f "$metadata_file" ]; then
        debug "Backup metadata created successfully"
        return 0
    else
        warning "Failed to create backup metadata file"
        return 1
    fi
}

# Collect custom files from configuration
collect_custom_files() {
    if [ -n "$CUSTOM_BACKUP_PATHS" ]; then
        step "Collecting custom files from configuration"

        # Prohibited patterns - define them at the beginning to use in exclusions
        local prohibited_patterns=(".cursor" ".cursor-server" ".vscode" "node_modules")
        
        # Create pattern string for grep
        local grep_exclude=""
        for pattern in "${prohibited_patterns[@]}"; do
            if [ -z "$grep_exclude" ]; then
                grep_exclude="$pattern"
            else
                grep_exclude="$grep_exclude\|$pattern"
            fi
        done

        # Create an array of excluded paths from BACKUP_BLACKLIST
        local blacklist_paths=()
        local blacklist_dir_prune=()
        local blacklist_single_files=()
        local blacklist_patterns=()
        if [ -n "$BACKUP_BLACKLIST" ]; then
            # Extract paths between quotes or separated by spaces
            while read -r line; do
                # Skip empty lines or comments
                [[ -z "$line" || "$line" == \#* ]] && continue
                
                # Extract path between quotes if present
                if [[ "$line" =~ \"([^\"]*)\" ]]; then
                    path="${BASH_REMATCH[1]}"
                    blacklist_paths+=("$path")
                elif [[ "$line" =~ \'([^\']*)\' ]]; then
                    path="${BASH_REMATCH[1]}"
                    blacklist_paths+=("$path")
                else
                    # If there are no quotes, add the entire line
                    blacklist_paths+=("$line")
                fi
            done <<< "$BACKUP_BLACKLIST"
            
            info "Blacklist paths: ${#blacklist_paths[@]} paths configured"
            for path in "${blacklist_paths[@]}"; do
                # Skip empty paths
                [ -z "$path" ] && continue
                debug "Blacklisted path: $path"

                # Expand variables to classify the entry
                local expanded_path
                expanded_path=$(eval echo "$path")

                # Keep track of wildcard-based patterns for later checks
                if [[ "$expanded_path" == *"*"* || "$expanded_path" == *"?"* || "$expanded_path" == *"["* ]]; then
                    blacklist_patterns+=("$expanded_path")
                    continue
                fi

                # Separate directory paths we can prune directly in find
                if [ -d "$expanded_path" ] || [[ "$expanded_path" == */ ]]; then
                    blacklist_dir_prune+=("${expanded_path%/}")
                    continue
                fi

                # Track single files so we can skip them later
                blacklist_single_files+=("$expanded_path")
            done
        fi
        
        # Extract custom paths using the same logic
        local custom_paths=()
        while read -r line; do
            # Skip empty lines or comments
            [[ -z "$line" || "$line" == \#* ]] && continue
            
            # Extract path between quotes if present
            if [[ "$line" =~ \"([^\"]*)\" ]]; then
                path="${BASH_REMATCH[1]}"
            elif [[ "$line" =~ \'([^\']*)\' ]]; then
                path="${BASH_REMATCH[1]}"
            else
                # If there are no quotes, add the entire line
                path="$line"
            fi
            
            # Filter rclone paths if cloud backup is disabled
            if [ "${ENABLE_CLOUD_BACKUP:-true}" != "true" ]; then
                if [[ "$path" == *"rclone"* ]]; then
                    debug "Skipping rclone path (cloud backup disabled): $path"
                    continue
                fi
            fi
            
            custom_paths+=("$path")
        done <<< "$CUSTOM_BACKUP_PATHS"
        
        info "Custom paths to process: ${#custom_paths[@]} paths configured"
        
        # Process each custom path
        for path in "${custom_paths[@]}"; do
            # Skip empty paths
            [ -z "$path" ] && continue
            
            debug "Processing path: $path"
            
            # Get the absolute path (resolve symlinks etc)
            local abs_path=$(readlink -f "$path")
            debug "Absolute path resolved to: $abs_path"
            
            # Verify that the path does not contain prohibited patterns
            if echo "$abs_path" | grep -q "$grep_exclude"; then
                info "Skipping path with prohibited pattern: $abs_path"
                continue
            fi
            
            # Process files and directories, checking against blacklist
            if [ -d "$abs_path" ]; then
                info "Path is a directory, processing contents recursively: $abs_path"
                
                # First, create a list of directories to exclude completely
                # this will allow us to avoid processing prohibited directories completely
                local find_exclude_args=""
                for pattern in "${prohibited_patterns[@]}"; do
                    local quoted_pattern
                    printf -v quoted_pattern "%q" "*/$pattern*"
                    find_exclude_args="$find_exclude_args -path $quoted_pattern -prune -o"
                done

                # Incorporate blacklisted directories into prune arguments
                for prune_path in "${blacklist_dir_prune[@]}"; do
                    # Skip if blank after trimming
                    [ -z "$prune_path" ] && continue
                    local quoted_prune
                    printf -v quoted_prune "%q" "$prune_path"
                    find_exclude_args="$find_exclude_args -path $quoted_prune -prune -o"
                done
                
                # For directories, walk through all files and directories
                # Using find with prune to avoid going into prohibited directories at all
                eval find "$abs_path" $find_exclude_args -type f -o -type d | while read item; do
                    # Skip the same base path
                    [ "$item" == "$abs_path" ] && continue
                    
                    # Check if this item should be blacklisted
                    local skip_item=false
                    for prune_path in "${blacklist_dir_prune[@]}"; do
                        if [[ "$item" == "$prune_path" || "$item" == "$prune_path/"* ]]; then
                            debug "Skipping blacklisted item (directory prune match): $item (matches: $prune_path)"
                            skip_item=true
                            break
                        fi
                    done

                    if [ "$skip_item" = false ]; then
                        for single_path in "${blacklist_single_files[@]}"; do
                            if [[ "$item" == "$single_path" ]]; then
                                debug "Skipping blacklisted item (single file match): $item"
                                skip_item=true
                                break
                            fi
                        done
                    fi

                    if [ "$skip_item" = false ]; then
                        for pattern in "${blacklist_patterns[@]}"; do
                            if [[ "$pattern" == *"/.*" ]]; then
                                base_path="${pattern%/.*}"
                                if [[ "$item" == "$base_path/".* ]]; then
                                    debug "Skipping blacklisted item (hidden file pattern): $item (matches: $pattern)"
                                    skip_item=true
                                    break
                                fi
                            else
                                case "$item" in
                                    $pattern*)
                                        debug "Skipping blacklisted item (wildcard pattern): $item (matches: $pattern)"
                                        skip_item=true
                                        break
                                        ;;
                                esac
                            fi
                        done
                    fi

                    [ "$skip_item" = true ] && continue
                    
                    # Verify that the element does not contain prohibited patterns
                    # This should be rarer now that we use prune in find
                    if echo "$item" | grep -q "$grep_exclude"; then
                        debug "Skipping item with prohibited pattern: $item"
                        continue
                    fi
                    
                    # Create parent dirs and copy the item
                    if [ -f "$item" ]; then
                        local rel_path="${item#/}"  # Remove leading slash
                        local target_file="$TEMP_DIR/$rel_path"
                        local target_dir="$(dirname "$target_file")"
                        
                        # Create parent directory
                        mkdir -p "$target_dir" || {
                            warning "Failed to create directory: $target_dir"
                            continue
                        }
                        
                        # Copy the file
                        cp -a "$item" "$target_file" 2>/dev/null || {
                            warning "Failed to copy file: $item"
                            continue
                        }
                        
                        debug "Copied: $item -> $target_file"
                    elif [ -d "$item" ] && [ "$item" != "$abs_path" ]; then
                        # For directories other than the root dir, just create them
                        local rel_path="${item#/}"  # Remove leading slash
                        local target_dir="$TEMP_DIR/$rel_path"
                        
                        mkdir -p "$target_dir" || {
                            warning "Failed to create directory: $target_dir"
                            continue
                        }
                        
                        debug "Created directory: $target_dir"
                    fi
                done
            else
                # It's a file, check against blacklist
                local skip_item=false
                for single_path in "${blacklist_single_files[@]}"; do
                    if [[ "$abs_path" == "$single_path" ]]; then
                        info "Skipping blacklisted file: $abs_path"
                        skip_item=true
                        break
                    fi
                done

                if [ "$skip_item" = false ]; then
                    for pattern in "${blacklist_patterns[@]}"; do
                        if [[ "$pattern" == *"/.*" ]]; then
                            local base_path="${pattern%/.*}"
                            if [[ "$abs_path" == "$base_path/".* ]]; then
                                info "Skipping blacklisted file (hidden pattern): $abs_path"
                                skip_item=true
                                break
                            fi
                        else
                            case "$abs_path" in
                                $pattern*)
                                    info "Skipping blacklisted file (pattern match): $abs_path"
                                    skip_item=true
                                    break
                                    ;;
                            esac
                        fi
                    done
                fi
                
                [ "$skip_item" = true ] && continue
                
                # Process single file
                if [ ! -e "$abs_path" ]; then
                    warning "File not found: $abs_path"
                    set_exit_code "warning"
                    continue
                fi
                
                # Determine relative path in temp directory
                local rel_path="${abs_path#/}"  # Remove leading slash
                local target_file="$TEMP_DIR/$rel_path"
                local target_dir="$(dirname "$target_file")"
                
                # Create target parent directory
                mkdir -p "$target_dir" || {
                    error "Failed to create target directory: $target_dir"
                    set_exit_code "error"
                    continue
                }
                
                # Copy the file
                debug "Copying file: $abs_path -> $target_file"
                if ! cp -a "$abs_path" "$target_file" 2>&1; then
                    warning "Failed to copy file: $abs_path"
                    set_exit_code "warning"
                else
                    debug "Successfully copied file: $abs_path"
                fi
            fi
        done
        
        success "Custom files collected successfully"
    else
        debug "No custom backup paths configured, skipping"
    fi
}

# Collect system service configurations
collect_system_service_configs() {
    debug "Backing up system service configuration"
    
    for dir in cron.d cron.daily cron.weekly logrotate.d systemd/system; do
        if [ -d "/etc/$dir" ]; then
            # Check if the directory contains files
            if [ "$(ls -A /etc/$dir/ 2>/dev/null)" ]; then
                mkdir -p "$TEMP_DIR/etc/$dir"
                if ! rsync -a /etc/$dir/ "$TEMP_DIR/etc/$dir/" > /dev/null 2>&1; then
                    debug "Failed to backup /etc/$dir, directory might be empty or inaccessible"
                else
                    debug "Successfully backed up /etc/$dir"
                fi
            else
                debug "Directory /etc/$dir is empty, skipping"
            fi
        else
            debug "Directory /etc/$dir does not exist, skipping"
        fi
    done
    
    # Additional critical system files
    debug "Backing up additional critical system files"
    
    # Critical system configuration files
    for file in fstab resolv.conf timezone hostname hosts passwd; do
        if [ -f "/etc/$file" ]; then
            mkdir -p "$TEMP_DIR/etc"
            if ! cp "/etc/$file" "$TEMP_DIR/etc/$file" 2>&1; then
                debug "Failed to backup /etc/$file, file might be empty or inaccessible"
            else
                debug "Successfully backed up /etc/$file"
            fi
        else
            debug "File /etc/$file not found, skipping"
        fi
    done
}

# Collect security configurations
collect_security_configs() {
    # Prohibited patterns - define them at the beginning to use in exclusions
    local prohibited_patterns=(".cursor" ".cursor-server" ".vscode" "node_modules")
    
    # Create pattern string for grep
    local grep_exclude=""
    for pattern in "${prohibited_patterns[@]}"; do
        if [ -z "$grep_exclude" ]; then
            grep_exclude="$pattern"
        else
            grep_exclude="$grep_exclude\|$pattern"
        fi
    done
    
    # Create find arguments to exclude prohibited directories completely
    local find_exclude_args=""
    for pattern in "${prohibited_patterns[@]}"; do
        find_exclude_args="$find_exclude_args -path '*/$pattern*' -prune -o"
    done

    # System SSL certificate configuration
    if [ -d "/etc/ssl" ]; then
        debug "Backing up SSL certificates"
        mkdir -p "$TEMP_DIR/etc/ssl"
        # Check if there are files to copy (excluding the private directory)
        if [ "$(find /etc/ssl -type f -not -path "*/private/*" 2>/dev/null | wc -l)" -gt 0 ]; then
            if ! rsync -a --exclude='private' /etc/ssl/ "$TEMP_DIR/etc/ssl/" > /dev/null 2>&1; then
                debug "Some SSL certificates could not be copied, they might be inaccessible"
            else
                debug "Successfully backed up SSL certificates"
            fi
        else
            debug "No SSL certificates found to backup (excluding private)"
        fi
    else
        debug "Directory /etc/ssl does not exist, skipping SSL certificate backup"
    fi
    
    # SSH keys
    debug "Backing up SSH keys"
    
    # Create ssh directory
    mkdir -p "$TEMP_DIR/etc/ssh"
    
    # Copy SSH host keys
    if [ -d "/etc/ssh" ]; then
        if [ "$(find /etc/ssh -name "ssh_host_*" -type f 2>/dev/null | wc -l)" -gt 0 ]; then
            if ! rsync -a --include="ssh_host_*.pub" --exclude="*" /etc/ssh/ "$TEMP_DIR/etc/ssh/" > /dev/null 2>&1; then
                debug "Some SSH host keys could not be copied, they might be inaccessible"
            else
                debug "Successfully backed up SSH host keys"
            fi
        else
            debug "No SSH host keys found, skipping"
        fi
    else
        debug "Directory /etc/ssh does not exist, skipping SSH host keys backup"
    fi
    
    # Root keys
    if [ -d "/root/.ssh" ]; then
        # Check if there are files to copy and that do not contain prohibited patterns
        if [ "$(ls -A /root/.ssh/ 2>/dev/null | grep -v "$grep_exclude" | wc -l)" -gt 0 ]; then
            mkdir -p "$TEMP_DIR/root/.ssh"
            # Use find to copy only files that do not contain prohibited patterns
            eval find "/root/.ssh" $find_exclude_args -type f 2>/dev/null | grep -v "$grep_exclude" | while read -r file; do
                local rel_path="${file#/root/.ssh/}"
                cp -p "$file" "$TEMP_DIR/root/.ssh/$rel_path" 2>/dev/null || {
                    debug "Failed to copy SSH key: $file"
                }
            done
            debug "Successfully backed up root SSH keys (excluding prohibited patterns)"
        else
            debug "Directory /root/.ssh is empty or contains only prohibited patterns, skipping"
        fi
    else
        debug "Directory /root/.ssh does not exist, skipping"
    fi
    
    # Keys of other users
    if [ -d "/home" ]; then
        # Use find with prune to avoid scanning prohibited directories
        eval find /home $find_exclude_args -type d -name .ssh 2>/dev/null | grep -v "$grep_exclude" | while read ssh_dir; do
            username=$(echo "$ssh_dir" | cut -d '/' -f3)
            if [ -n "$username" ]; then
                # Check if there are files to copy that do not contain prohibited patterns
                if [ "$(find "$ssh_dir" -type f 2>/dev/null | grep -v "$grep_exclude" | wc -l)" -gt 0 ]; then
                    target_dir="$TEMP_DIR/home/$username/.ssh"
                    mkdir -p "$target_dir"
                    
                    # Use find to copy only files that do not contain prohibited patterns
                    find "$ssh_dir" -type f 2>/dev/null | grep -v "$grep_exclude" | while read -r file; do
                        local rel_path="${file#$ssh_dir/}"
                        cp -p "$file" "$target_dir/$rel_path" 2>/dev/null || {
                            debug "Failed to copy SSH key for user $username: $file"
                        }
                    done
                    debug "Successfully backed up SSH keys for user $username (excluding prohibited patterns)"
                else
                    debug "SSH directory for user $username is empty or contains only prohibited patterns, skipping"
                fi
            fi
        done
    fi
}

# Create temporary directory for collecting files
setup_temp_dir() {
    step "Setting up temporary directory for backup"

    # Try to create a temporary directory
    TEMP_DIR=$(mktemp -d) || {
        local fallback_dir="/tmp/proxmox-backup-${PROXMOX_TYPE}-${TIMESTAMP}"
        warning "Failed to create temporary directory using mktemp, trying fallback location: $fallback_dir"

        mkdir -p "$fallback_dir" || {
            error "Failed to create temporary directory"
            exit 1
        }

        TEMP_DIR="$fallback_dir"
    }

    # Create security marker file to verify ownership during cleanup
    # This marker proves the directory was created by this script instance
    local marker_file="${TEMP_DIR}/.proxmox-backup-marker"
    echo "Created by PID $$ on $(date -u +"%Y-%m-%d %H:%M:%S UTC")" > "$marker_file" || {
        error "Failed to create security marker file: $marker_file"
        exit 1
    }
    chmod 600 "$marker_file" 2>/dev/null || true

    debug "Created temporary directory with security marker: $TEMP_DIR"

    # Handle cleanup on script exit
    # trap 'cleanup' EXIT
    
    success "Temporary directory created: $TEMP_DIR"
}

# Main function for data collection
collect_backup_data() {
    step "Starting backup data collection"
    
    # Setup temporary directory
    setup_temp_dir
    
    # Initialize backup environment
    initialize_backup
    
    # Perform the actual backup collection
    if ! perform_backup; then
        error "Failed to collect backup data"
        return $EXIT_ERROR
    fi
    
    success "Backup data collection completed successfully"
    return $EXIT_SUCCESS
}

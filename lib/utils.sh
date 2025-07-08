#!/bin/bash
# Centralized utility functions for common operations

# ======= Functions for disk space management =======

# Gets free space on disk in bytes
get_free_space() {
    local path="$1"
    
    if [ ! -d "$path" ]; then
        echo "0"
        return 1
    fi
    
    df -B1 --output=avail "$path" 2>/dev/null | tail -n1
}

# Gets complete disk information
get_disk_info() {
    local path="$1"
    local format="${2:-json}"  # 'json' or 'text'
    
    if [ ! -d "$path" ]; then
        if [ "$format" = "json" ]; then
            echo '{"total":0,"used":0,"free":0,"percent":0}'
        else
            echo "total=0 used=0 free=0 percent=0"
        fi
        return 1
    fi
    
    local disk_info=$(df -B1 "$path" 2>/dev/null)
    if [ $? -ne 0 ]; then
        if [ "$format" = "json" ]; then
            echo '{"total":0,"used":0,"free":0,"percent":0}'
        else
            echo "total=0 used=0 free=0 percent=0"
        fi
        return 1
    fi
    
    local total=$(echo "$disk_info" | awk 'NR==2 {print $2}')
    local used=$(echo "$disk_info" | awk 'NR==2 {print $3}')
    local free=$(echo "$disk_info" | awk 'NR==2 {print $4}')
    local percent=$(echo "$disk_info" | awk 'NR==2 {gsub(/%/,""); print $5}')
    
    if [ "$format" = "json" ]; then
        echo "{\"total\":$total,\"used\":$used,\"free\":$free,\"percent\":$percent}"
    else
        echo "total=$total used=$used free=$free percent=$percent"
    fi
}

# ======= Functions for file and directory operations =======

# Counts files in a directory matching a pattern
count_files_in_dir() {
    local dir="$1"
    local pattern="$2"
    local exclude_pattern="${3:-}"
    local max_depth="${4:-1}"
    
    if [ ! -d "$dir" ]; then
        echo "0"
        return 1
    fi
    
    local cmd="find \"$dir\" -maxdepth $max_depth -type f -name \"$pattern\""
    if [ -n "$exclude_pattern" ]; then
        cmd="$cmd -not -name \"$exclude_pattern\""
    fi
    cmd="$cmd | wc -l"
    
    eval $cmd
}

# Finds the oldest file in a directory
find_oldest_file() {
    local dir="$1"
    local pattern="$2"
    local exclude_pattern="${3:-}"
    local max_depth="${4:-1}"
    
    if [ ! -d "$dir" ]; then
        echo ""
        return 1
    fi
    
    local cmd="find \"$dir\" -maxdepth $max_depth -type f -name \"$pattern\""
    if [ -n "$exclude_pattern" ]; then
        cmd="$cmd -not -name \"$exclude_pattern\""
    fi
    cmd="$cmd -printf \"%T@ %p\\n\" | sort -n | head -1 | cut -d' ' -f2-"
    
    eval $cmd
}

# Finds the newest file in a directory
find_newest_file() {
    local dir="$1"
    local pattern="$2"
    local exclude_pattern="${3:-}"
    local max_depth="${4:-1}"
    
    if [ ! -d "$dir" ]; then
        echo ""
        return 1
    fi
    
    local cmd="find \"$dir\" -maxdepth $max_depth -type f -name \"$pattern\""
    if [ -n "$exclude_pattern" ]; then
        cmd="$cmd -not -name \"$exclude_pattern\""
    fi
    cmd="$cmd -printf \"%T@ %p\\n\" | sort -nr | head -1 | cut -d' ' -f2-"
    
    eval $cmd
}

# Gets the age of a file in days
get_file_age() {
    local file_path="$1"
    
    if [ ! -f "$file_path" ]; then
        echo "0"
        return 1
    fi
    
    local file_time=$(stat -c %Y "$file_path" 2>/dev/null)
    if [ -z "$file_time" ]; then
        echo "0"
        return 1
    fi
    
    local current_time=$(date +%s)
    local age_seconds=$((current_time - file_time))
    local age_days=$((age_seconds / 86400))
    
    echo "$age_days"
}

# Gets timestamps of all files matching a pattern
get_file_timestamps() {
    local dir="$1"
    local pattern="$2"
    local exclude_pattern="${3:-}"
    local max_depth="${4:-1}"
    
    if [ ! -d "$dir" ]; then
        return 1
    fi
    
    local cmd="find \"$dir\" -maxdepth $max_depth -type f -name \"$pattern\""
    if [ -n "$exclude_pattern" ]; then
        cmd="$cmd -not -name \"$exclude_pattern\""
    fi
    cmd="$cmd -printf \"%T@ %p\\n\""
    
    eval $cmd
}

# Gets the size of a directory
get_dir_size() {
    local dir="$1"
    local pattern="${2:-*}"
    local exclude_pattern="${3:-}"
    local format="${4:-bytes}"  # 'bytes' or 'human'
    
    if [ ! -d "$dir" ]; then
        if [ "$format" = "human" ]; then
            echo "0B"
        else
            echo "0"
        fi
        return 1
    fi
    
    # Directly uses du, which is more reliable for large directories
    local total_size
    if [ -z "$exclude_pattern" ]; then
        # If there's no exclusion pattern, uses du on the entire directory
        total_size=$(du -sb "$dir" 2>/dev/null | cut -f1)
    else
        # Otherwise, uses find to filter files and then du
        # Creates a temporary file
        local temp_file=$(mktemp)
        
        # Constructs the find command with exclusion
        find "$dir" -type f -name "$pattern" -not -name "$exclude_pattern" -exec du -bc {} \; 2>/dev/null > "$temp_file" || true
        
        # Extracts the total size
        total_size=$(grep "total$" "$temp_file" | awk '{print $1}')
        
        # Cleans up the temporary file
        rm -f "$temp_file"
    fi
    
    # Checks if the result is a valid number
    if [ -z "$total_size" ] || ! [[ "$total_size" =~ ^[0-9]+$ ]]; then
        # If it fails, tries a second strategy with find
        total_size=$(find "$dir" -type f -exec du -cb {} \; 2>/dev/null | grep total$ | awk '{sum+=$1} END {print sum}')
        
        # If it still fails, returns 0
        if [ -z "$total_size" ] || ! [[ "$total_size" =~ ^[0-9]+$ ]]; then
            if [ "$format" = "human" ]; then
                echo "0B"
            else
                echo "0"
            fi
            return 1
        fi
    fi
    
    if [ "$format" = "human" ]; then
        format_size_human "$total_size"
    else
        echo "$total_size"
    fi
}

# ======= Functions for temporary file management =======

# Creates a temporary file and returns the path
create_temp_file() {
    local prefix="${1:-proxmox-backup}"
    local temp_file
    
    temp_file=$(mktemp "/tmp/${prefix}.XXXXXX" 2>/dev/null)
    if [ $? -ne 0 ] || [ -z "$temp_file" ]; then
        error "Impossible to create temporary file"
        return 1
    fi
    
    echo "$temp_file"
}

# Safely cleans up a temporary file
cleanup_temp_file() {
    local temp_file="$1"
    
    if [ -f "$temp_file" ]; then
        rm -f "$temp_file" 2>/dev/null
    fi
}

# ======= Functions for file statistics =======

# Gets the permissions of a file in numeric format
get_file_permissions() {
    local file_path="$1"
    
    if [ ! -e "$file_path" ]; then
        echo "000"
        return 1
    fi
    
    stat -c '%a' "$file_path" 2>/dev/null || echo "000"
}

# Gets the owner of a file
get_file_owner() {
    local file_path="$1"
    
    if [ ! -e "$file_path" ]; then
        echo "unknown"
        return 1
    fi
    
    stat -c '%U' "$file_path" 2>/dev/null || echo "unknown"
}

# Gets the group of a file
get_file_group() {
    local file_path="$1"
    
    if [ ! -e "$file_path" ]; then
        echo "unknown"
        return 1
    fi
    
    stat -c '%G' "$file_path" 2>/dev/null || echo "unknown"
}

# Gets the modification timestamp of a file
get_file_timestamp() {
    local file_path="$1"
    
    if [ ! -e "$file_path" ]; then
        echo "0"
        return 1
    fi
    
    stat -c '%Y' "$file_path" 2>/dev/null || echo "0"
}

# ======= Functions for date and time management =======

# Formats a timestamp in readable format
format_timestamp() {
    local timestamp="$1"
    local format="${2:-%Y-%m-%d %H:%M:%S}"
    
    if [ -z "$timestamp" ] || ! [[ "$timestamp" =~ ^[0-9]+$ ]]; then
        echo "Unknown"
        return 1
    fi
    
    date -d "@$timestamp" "+$format" 2>/dev/null || date -r "$timestamp" "+$format" 2>/dev/null || echo "Unknown"
}

# Gets the current timestamp
get_current_timestamp() {
    date +%s
}

# Calculates the difference between two timestamps
calculate_time_difference() {
    local start_time="$1"
    local end_time="${2:-$(date +%s)}"
    local format="${3:-seconds}"  # 'seconds', 'human', or 'formatted'
    
    if [ -z "$start_time" ] || [ -z "$end_time" ]; then
        if [ "$format" = "seconds" ]; then
            echo "0"
        else
            echo "0s"
        fi
        return 1
    fi
    
    local diff=$((end_time - start_time))
    
    case "$format" in
        "human")
            format_duration_human "$diff"
            ;;
        "formatted")
            format_duration "$diff"
            ;;
        *)
            echo "$diff"
            ;;
    esac
}

# Function to manage backup status variables
set_backup_status() {
    local operation=$1
    local status=$2
    
    case $operation in
        # Primary backup
        "primary")
            export EXIT_BACKUP_PRIMARY=$status
            ;;
        "verify")
            export EXIT_BACKUP_VERIFY=$status
            ;;
        "rotation_primary")
            export EXIT_BACKUP_ROTATION_PRIMARY=$status
            ;;
        # Secondary backup
        "secondary_copy")
            export EXIT_SECONDARY_COPY=$status
            ;;
        "rotation_secondary")
            export EXIT_BACKUP_ROTATION_SECONDARY=$status
            ;;
        # Cloud backup
        "cloud_upload")
            export EXIT_CLOUD_UPLOAD=$status
            ;;
        "rotation_cloud")
            export EXIT_BACKUP_ROTATION_CLOUD=$status
            ;;
        # Log management
        "log_creation")
            export EXIT_LOG_CREATION=$status
            ;;
        "log_rotation_primary")
            export EXIT_LOG_ROTATION_PRIMARY=$status
            ;;
        "log_secondary_copy")
            export EXIT_LOG_SECONDARY_COPY=$status
            ;;
        "log_rotation_secondary")
            export EXIT_LOG_ROTATION_SECONDARY=$status
            ;;
        "log_cloud_upload")
            export EXIT_LOG_CLOUD_UPLOAD=$status
            ;;
        "log_rotation_cloud")
            export EXIT_LOG_ROTATION_CLOUD=$status
            ;;
        *)
            warning "Unknown backup operation: $operation"
            return 1
            ;;
    esac
    
    # Status logging
    case $status in
        $EXIT_SUCCESS)
            debug "Set $operation status to SUCCESS"
            ;;
        $EXIT_WARNING)
            debug "Set $operation status to WARNING"
            ;;
        $EXIT_ERROR)
            debug "Set $operation status to ERROR"
            ;;
        *)
            warning "Unknown status value: $status for operation: $operation"
            return 1
            ;;
    esac
    
    return 0
}

# Centralized function to get compression data
get_compression_data() {
    local uncompressed_path="$1"  # Temporary directory with uncompressed data
    local compressed_file="$2"    # Compressed backup file
    local format="${3:-all}"     # 'all', 'ratio', 'percent', 'decimal', 'human'

    # Initial function debug
    trace "DEBUG COMPRESSION_DATA: Starting get_compression_data with parameters:"
    trace "DEBUG COMPRESSION_DATA: uncompressed_path=$uncompressed_path"
    trace "DEBUG COMPRESSION_DATA: compressed_file=$compressed_file"
    trace "DEBUG COMPRESSION_DATA: format=$format"

    # Use default values if not specified
    [ -z "$uncompressed_path" ] && uncompressed_path="$TEMP_DIR"
    [ -z "$compressed_file" ] && compressed_file="$BACKUP_FILE"
    
    trace "DEBUG COMPRESSION_DATA: Values after defaults:"
    trace "DEBUG COMPRESSION_DATA: uncompressed_path=$uncompressed_path"
    trace "DEBUG COMPRESSION_DATA: compressed_file=$compressed_file"

    # Extract compression type from filename
    local detected_type="xz"  # Default to xz
    if [[ "$compressed_file" == *.zst ]]; then
        detected_type="zstd"
    elif [[ "$compressed_file" == *.gz ]]; then
        detected_type="gzip"
    elif [[ "$compressed_file" == *.bz2 ]]; then
        detected_type="bzip2"
    elif [[ "$compressed_file" == *.lzma ]]; then
        detected_type="lzma"
    elif [[ "$compressed_file" == *.xz ]]; then
        detected_type="xz"
    fi
    
    trace "DEBUG COMPRESSION_DATA: detected compression type: $detected_type"
    
    # Update global COMPRESSION_TYPE variable if different
    if [ "$detected_type" != "$COMPRESSION_TYPE" ]; then
        debug "Updated detected compression type: $detected_type (was: $COMPRESSION_TYPE)"
        COMPRESSION_TYPE="$detected_type"
    fi

    # Verify we have valid data to calculate compression
    trace "DEBUG COMPRESSION_DATA: Verifying path and file..."
    trace "DEBUG COMPRESSION_DATA: Directory exists? $([ -d "$uncompressed_path" ] && echo 'YES' || echo 'NO')"
    trace "DEBUG COMPRESSION_DATA: Compressed file exists? $([ -f "$compressed_file" ] && echo 'YES' || echo 'NO')"
    
    if [ ! -d "$uncompressed_path" ] || [ ! -f "$compressed_file" ]; then
        trace "DEBUG COMPRESSION_DATA: Invalid path or file, using estimate"
        # Use an estimate based on compression type
        case "$COMPRESSION_TYPE" in
            "zstd")
                local ratio_est="~65%"
                ;;
            "xz")
                local ratio_est="~75%"
                ;;
            "gzip"|"pigz")
                local ratio_est="~60%"
                ;;
            "bzip2")
                local ratio_est="~70%"
                ;;
            "lzma")
                local ratio_est="~75%"
                ;;
            *)
                local ratio_est="~70%"  # Default value also for unknown
                ;;
        esac
        
        trace "DEBUG COMPRESSION_DATA: Using type-based estimate: $ratio_est"
        
        if [ "$format" = "all" ]; then
            echo "ratio=$ratio_est percent=${ratio_est/\~/} decimal=0.${ratio_est/\~/} size_before=0 size_after=0"
        else
            echo "$ratio_est"
        fi
        return 0  # Return 0 even if we're using an estimate
    fi

    # Trace sizes using different methods
    trace "DEBUG COMPRESSION_DATA: Calculating sizes with different methods:"
    trace "DEBUG COMPRESSION_DATA: Dir size (du): $(du -sb "$uncompressed_path" 2>/dev/null | cut -f1 || echo 'failed')"
    trace "DEBUG COMPRESSION_DATA: Dir size (find): $(find "$uncompressed_path" -type f -exec du -cb {} \; 2>/dev/null | grep total$ | awk '{sum+=$1} END {print sum}' || echo 'failed')"
    trace "DEBUG COMPRESSION_DATA: File size (stat): $(stat -c %s "$compressed_file" 2>/dev/null || echo 'failed')"

    # Calculate sizes using centralized functions
    local uncompressed_size=$(get_dir_size "$uncompressed_path" "*" "" "bytes")
    local compressed_size=$(get_file_size "$compressed_file")
    
    trace "DEBUG COMPRESSION_DATA: uncompressed_size from get_dir_size: $uncompressed_size"
    trace "DEBUG COMPRESSION_DATA: compressed_size from get_file_size: $compressed_size"

    # Verify values are valid
    if [ -z "$uncompressed_size" ] || [ -z "$compressed_size" ] || [ "$uncompressed_size" -eq 0 ]; then
        trace "DEBUG COMPRESSION_DATA: Invalid sizes, using estimate for $COMPRESSION_TYPE"
        # Use an estimate based on compression type
        case "$COMPRESSION_TYPE" in
            "zstd")
                local ratio_est="~65%"
                ;;
            "xz")
                local ratio_est="~75%"
                ;;
            "gzip"|"pigz")
                local ratio_est="~60%"
                ;;
            "bzip2")
                local ratio_est="~70%"
                ;;
            "lzma")
                local ratio_est="~75%"
                ;;
            *)
                local ratio_est="~70%"  # Default value also for unknown
                ;;
        esac
        
        trace "DEBUG COMPRESSION_DATA: Returning estimate: $ratio_est"
        
        if [ "$format" = "all" ]; then
            echo "ratio=$ratio_est percent=${ratio_est/\~/} decimal=0.${ratio_est/\~/} size_before=0 size_after=0"
        else
            echo "$ratio_est"
        fi
        return 0
    fi

    trace "DEBUG COMPRESSION_DATA: Valid sizes, calculating actual ratio"
    
    # Calculate different compression formats
    local ratio_percent=$(calculate_compression_ratio "$uncompressed_size" "$compressed_size" "percent")
    local ratio_decimal=$(calculate_compression_ratio "$uncompressed_size" "$compressed_size" "decimal")
    local ratio_human=$(calculate_compression_ratio "$uncompressed_size" "$compressed_size" "human")
    
    trace "DEBUG COMPRESSION_DATA: ratio_percent: $ratio_percent"
    trace "DEBUG COMPRESSION_DATA: ratio_decimal: $ratio_decimal"
    trace "DEBUG COMPRESSION_DATA: ratio_human: $ratio_human"

    # Return the requested format
    case "$format" in
        "percent") 
            trace "DEBUG COMPRESSION_DATA: Returning percent format: $ratio_percent"
            echo "$ratio_percent" 
            ;;
        "decimal") 
            trace "DEBUG COMPRESSION_DATA: Returning decimal format: $ratio_decimal"
            echo "$ratio_decimal" 
            ;;
        "human") 
            trace "DEBUG COMPRESSION_DATA: Returning human format: $ratio_human"
            echo "$ratio_human" 
            ;;
        "all") 
            local result="ratio=$ratio_percent percent=${ratio_percent/\%/} decimal=$ratio_decimal size_before=$uncompressed_size size_after=$compressed_size"
            trace "DEBUG COMPRESSION_DATA: Returning all format: $result"
            echo "$result" 
            ;;
        *) 
            trace "DEBUG COMPRESSION_DATA: Returning default format (percent): $ratio_percent"
            echo "$ratio_percent" 
            ;;
    esac

    return 0
}

# FUNCTION FOR SERVER UNIQUE IDENTIFICATION
# Generates a unique 16-digit numeric ID for each installation
# Uses multiple system characteristics to ensure uniqueness and stability
# The ID is saved to a persistent file with protection against tampering
get_server_id() {
    [[ -n "${SERVER_ID:-}" ]] && return 0
    
    # Define persistent storage for server ID with protection
    local server_id_file="${SCRIPT_DIR}/../config/.server_identity"
    local server_id_dir="$(dirname "$server_id_file")"
    
    # Create config directory if it doesn't exist
    if [ ! -d "$server_id_dir" ]; then
        debug "Creating config directory: $server_id_dir"
        
        # Try to create the directory with proper error handling
        if mkdir -p "$server_id_dir" 2>/dev/null; then
            debug "Config directory created successfully: $server_id_dir"
            
            # Set appropriate permissions for the config directory
            chmod 755 "$server_id_dir" 2>/dev/null || {
                warning "Failed to set permissions on config directory"
            }
        else
            warning "Failed to create config directory: $server_id_dir"
            warning "Using fallback location for server ID file"
            server_id_file="/tmp/.proxmox_backup_identity"
            
            # Ensure fallback directory exists
            local fallback_dir="$(dirname "$server_id_file")"
            if [ ! -d "$fallback_dir" ]; then
                warning "Fallback directory does not exist: $fallback_dir"
                return 1
            fi
        fi
    else
        debug "Config directory already exists: $server_id_dir"
    fi
    
    # Try to load existing server ID from protected file
    if [ -f "$server_id_file" ] && [ -r "$server_id_file" ]; then
        local stored_data=$(cat "$server_id_file" 2>/dev/null)
        local decoded_id=$(decode_protected_server_id "$stored_data")
        
        # Validate decoded ID format
        if [ ${#decoded_id} -eq 16 ] && [[ "$decoded_id" =~ ^[0-9]{16}$ ]]; then
            SERVER_ID="$decoded_id"
            debug "Loaded existing server ID from protected file"
            return 0
        else
            warning "Invalid or corrupted server ID found in file, regenerating..."
            rm -f "$server_id_file" 2>/dev/null || true
        fi
    fi
    
    debug "Generating new server ID..."
    
    # Collect multiple system identifiers for maximum uniqueness
    local system_data=""
    
    # 1. Machine ID (most stable identifier)
    if [ -f "/etc/machine-id" ]; then
        system_data+=$(cat /etc/machine-id 2>/dev/null || echo "")
    elif [ -f "/var/lib/dbus/machine-id" ]; then
        system_data+=$(cat /var/lib/dbus/machine-id 2>/dev/null || echo "")
    fi
    
    # 2. All MAC addresses (sorted for consistency)
    local mac_addresses=$(ip link show 2>/dev/null | awk '/ether/ {print $2}' | sort | tr '\n' ':' | sed 's/:$//')
    system_data+="$mac_addresses"
    
    # 3. Hostname as additional identifier
    system_data+=$(hostname 2>/dev/null || echo "unknown")
    
    # 4. System UUID if available
    if [ -f "/sys/class/dmi/id/product_uuid" ]; then
        system_data+=$(cat /sys/class/dmi/id/product_uuid 2>/dev/null || echo "")
    fi
    
    # 5. Boot ID for additional entropy (but not the current one, use a fixed seed)
    # Instead of boot_id which changes every boot, use a more stable identifier
    if [ -f "/proc/version" ]; then
        system_data+=$(cat /proc/version 2>/dev/null | head -c 100 || echo "")
    fi
    
    # Fallback: if no system data collected, use current timestamp and process info
    if [ -z "$system_data" ]; then
        system_data="fallback-$(date +%s)-$$-$(hostname)"
        warning "Using fallback method for server ID generation"
    fi
    
    # Generate SHA256 hash of all collected data
    local hash=$(echo -n "$system_data" | sha256sum | cut -d' ' -f1)
    
    # Convert hash to numeric ID using mathematical approach
    # Take first 64 bits (16 hex chars) and convert to decimal
    local hex_part=$(echo "$hash" | cut -c1-16)
    
    # Convert hex to decimal using proper mathematical conversion
    # Use bc for arbitrary precision arithmetic
    local decimal_id=""
    if command -v bc >/dev/null 2>&1; then
        # Convert hex to decimal using bc
        decimal_id=$(echo "ibase=16; ${hex_part^^}" | bc 2>/dev/null || echo "")
    fi
    
    # Fallback method if bc is not available
    if [ -z "$decimal_id" ]; then
        # Use printf for hex to decimal conversion (limited precision)
        decimal_id=$(printf "%d" "0x$hex_part" 2>/dev/null || echo "")
    fi
    
    # Final fallback: character-by-character conversion
    if [ -z "$decimal_id" ]; then
        decimal_id=""
        for (( i=0; i<${#hex_part}; i++ )); do
            local hex_char="${hex_part:$i:1}"
            case "${hex_char,,}" in
                0) decimal_id+="0" ;;
                1) decimal_id+="1" ;;
                2) decimal_id+="2" ;;
                3) decimal_id+="3" ;;
                4) decimal_id+="4" ;;
                5) decimal_id+="5" ;;
                6) decimal_id+="6" ;;
                7) decimal_id+="7" ;;
                8) decimal_id+="8" ;;
                9) decimal_id+="9" ;;
                a) decimal_id+="10" ;;
                b) decimal_id+="11" ;;
                c) decimal_id+="12" ;;
                d) decimal_id+="13" ;;
                e) decimal_id+="14" ;;
                f) decimal_id+="15" ;;
            esac
        done
    fi
    
    # Ensure we have a valid numeric result
    if [ -z "$decimal_id" ] || ! [[ "$decimal_id" =~ ^[0-9]+$ ]]; then
        # Ultimate fallback: use hash characters as numbers
        decimal_id=$(echo "$hex_part" | sed 's/[a-f]/9/gi' | sed 's/[^0-9]//g')
        if [ ${#decimal_id} -lt 16 ]; then
            decimal_id="${decimal_id}$(date +%s)000000"
        fi
    fi
    
    # Ensure exactly 16 digits
    if [ ${#decimal_id} -gt 16 ]; then
        SERVER_ID=$(echo "$decimal_id" | cut -c1-16)
    else
        SERVER_ID=$(printf "%016d" "$decimal_id" 2>/dev/null || echo "$decimal_id" | head -c 16)
    fi
    
    # Final validation: ensure SERVER_ID is exactly 16 numeric digits
    if [ ${#SERVER_ID} -ne 16 ] || ! [[ "$SERVER_ID" =~ ^[0-9]{16}$ ]]; then
        # Emergency fallback: create ID from timestamp and hash
        local timestamp=$(date +%s)
        local hash_suffix=$(echo "$hash" | sed 's/[a-f]/9/gi' | sed 's/[^0-9]//g' | cut -c1-10)
        SERVER_ID="${timestamp}${hash_suffix}000000"
        SERVER_ID=$(echo "$SERVER_ID" | cut -c1-16)
        SERVER_ID=$(printf "%016d" "$SERVER_ID" 2>/dev/null || echo "$SERVER_ID")
    fi
    
    # Save the generated ID to protected file
    debug "Attempting to save server ID to: $server_id_file"
    local protected_data=$(encode_protected_server_id "$SERVER_ID")
    
    # Verify the directory exists and is writable before attempting to save
    local file_dir="$(dirname "$server_id_file")"
    if [ ! -d "$file_dir" ]; then
        warning "Directory does not exist: $file_dir"
        warning "Server ID may change between executions"
        return 0
    fi
    
    if [ ! -w "$file_dir" ]; then
        warning "Directory is not writable: $file_dir"
        warning "Server ID may change between executions"
        return 0
    fi
    
    # Try to save the protected data
    if echo "$protected_data" > "$server_id_file" 2>/dev/null; then
        debug "Server ID saved to protected file: $server_id_file"
        
        # Set restrictive permissions and hide the file
        if chmod 600 "$server_id_file" 2>/dev/null; then
            debug "File permissions set to 600"
        else
            warning "Failed to set file permissions on: $server_id_file"
        fi
        
        # Try to set immutable attribute if chattr is available
        if command -v chattr >/dev/null 2>&1; then
            if chattr +i "$server_id_file" 2>/dev/null; then
                debug "Immutable attribute set on file"
            else
                warning "Failed to set immutable attribute on: $server_id_file"
            fi
        else
            debug "chattr not available, skipping immutable attribute"
        fi
        
        success "Server ID successfully saved and protected"
    else
        warning "Failed to save server ID to file: $server_id_file"
        warning "Check directory permissions and disk space"
        warning "Server ID may change between executions"
    fi
    
    debug "Generated server ID: $SERVER_ID (based on: machine-id, MAC addresses, hostname, system UUID)"
}

# Function to encode server ID with protection against tampering
encode_protected_server_id() {
    local server_id="$1"
    
    # Generate a system-specific key for encoding
    local system_key=$(generate_system_key)
    
    # Create timestamp for integrity check
    local timestamp=$(date +%s)
    
    # Combine ID with timestamp and system info for integrity
    local data_to_encode="${server_id}:${timestamp}:${system_key:0:8}"
    
    # Calculate checksum
    local checksum=$(echo -n "$data_to_encode" | sha256sum | cut -c1-8)
    
    # Final data with checksum
    local final_data="${data_to_encode}:${checksum}"
    
    # Encode with base64 and add some obfuscation
    local encoded=$(echo -n "$final_data" | base64 -w 0)
    
    # Add header and footer to make it look like a config file
    echo "# Proxmox Backup System Configuration"
    echo "# Generated: $(date)"
    echo "# DO NOT MODIFY THIS FILE MANUALLY"
    echo "SYSTEM_CONFIG_DATA=\"$encoded\""
    echo "# End of configuration"
}

# Function to decode protected server ID
decode_protected_server_id() {
    local file_content="$1"
    
    # Extract the encoded data from the config-like format
    local encoded=$(echo "$file_content" | grep "SYSTEM_CONFIG_DATA=" | cut -d'"' -f2)
    
    if [ -z "$encoded" ]; then
        debug "No valid encoded data found in file"
        return 1
    fi
    
    # Decode from base64
    local decoded_data=$(echo "$encoded" | base64 -d 2>/dev/null)
    
    if [ -z "$decoded_data" ]; then
        debug "Failed to decode base64 data"
        return 1
    fi
    
    # Split the decoded data
    IFS=':' read -r server_id timestamp system_key checksum <<< "$decoded_data"
    
    # Verify checksum
    local data_to_verify="${server_id}:${timestamp}:${system_key}"
    local expected_checksum=$(echo -n "$data_to_verify" | sha256sum | cut -c1-8)
    
    if [ "$checksum" != "$expected_checksum" ]; then
        debug "Checksum verification failed - file may have been tampered with"
        return 1
    fi
    
    # Verify system key matches current system
    local current_system_key=$(generate_system_key)
    if [ "${system_key}" != "${current_system_key:0:8}" ]; then
        debug "System key mismatch - file may be from different system"
        return 1
    fi
    
    # Additional validation of server ID format
    if [ ${#server_id} -ne 16 ] || ! [[ "$server_id" =~ ^[0-9]{16}$ ]]; then
        debug "Invalid server ID format in decoded data"
        return 1
    fi
    
    echo "$server_id"
    return 0
}

# Function to generate a system-specific key for encoding
generate_system_key() {
    local key_data=""
    
    # Use machine ID as primary component
    if [ -f "/etc/machine-id" ]; then
        key_data+=$(cat /etc/machine-id 2>/dev/null | head -c 16)
    elif [ -f "/var/lib/dbus/machine-id" ]; then
        key_data+=$(cat /var/lib/dbus/machine-id 2>/dev/null | head -c 16)
    fi
    
    # Add hostname
    key_data+=$(hostname 2>/dev/null | head -c 8)
    
    # Add first MAC address
    key_data+=$(ip link show 2>/dev/null | awk '/ether/ {print $2; exit}' | tr -d ':')
    
    # Generate hash of the key data
    echo -n "$key_data" | sha256sum | cut -c1-16
}

# Test function to verify server ID stability
test_server_id_stability() {
    local test_iterations="${1:-5}"
    local temp_server_id=""
    
    info "Testing server ID stability over $test_iterations iterations..."
    
    # Store original SERVER_ID
    local original_server_id="$SERVER_ID"
    
    # Test multiple generations
    for i in $(seq 1 $test_iterations); do
        # Clear SERVER_ID to force regeneration
        unset SERVER_ID
        
        # Generate new ID
        get_server_id
        
        if [ -z "$temp_server_id" ]; then
            temp_server_id="$SERVER_ID"
            debug "Iteration $i: Generated ID $SERVER_ID"
        else
            if [ "$temp_server_id" != "$SERVER_ID" ]; then
                error "Server ID instability detected! Previous: $temp_server_id, Current: $SERVER_ID"
                return 1
            fi
            debug "Iteration $i: ID stable ($SERVER_ID)"
        fi
    done
    
    # Restore original SERVER_ID
    SERVER_ID="$original_server_id"
    
    # Validate final ID format
    if [ ${#SERVER_ID} -ne 16 ] || ! [[ "$SERVER_ID" =~ ^[0-9]{16}$ ]]; then
        error "Invalid server ID format: $SERVER_ID (length: ${#SERVER_ID})"
        return 1
    fi
    
    success "Server ID stability test passed: $SERVER_ID"
    return 0
}

# Function to display server identification information
show_server_info() {
    step "Server Identification Information"
    
    get_server_id
    
    info "Server Unique ID: $SERVER_ID"
    info "Hostname: $(hostname 2>/dev/null || echo 'unknown')"
    
    # Show server ID file location (now protected)
    local server_id_file="${SCRIPT_DIR}/../config/.server_identity"
    if [ -f "$server_id_file" ]; then
        info "Server ID file: $server_id_file (protected format)"
        info "File created: $(stat -c %y "$server_id_file" 2>/dev/null | cut -d'.' -f1 || echo 'unknown')"
        info "File protection: $(stat -c %a "$server_id_file" 2>/dev/null || echo 'unknown') permissions"
        # Check if file has immutable attribute
        if command -v lsattr >/dev/null 2>&1; then
            local attrs=$(lsattr "$server_id_file" 2>/dev/null | cut -c1-16)
            if [[ "$attrs" == *"i"* ]]; then
                info "File attributes: immutable (protected against modification)"
            else
                info "File attributes: standard"
            fi
        fi
    else
        warning "Server ID file not found: $server_id_file"
    fi
    
    # Show machine ID if available
    if [ -f "/etc/machine-id" ]; then
        info "Machine ID: $(cat /etc/machine-id 2>/dev/null | head -c 8)..."
    elif [ -f "/var/lib/dbus/machine-id" ]; then
        info "Machine ID: $(cat /var/lib/dbus/machine-id 2>/dev/null | head -c 8)..."
    fi
    
    # Show MAC addresses
    local mac_count=$(ip link show 2>/dev/null | awk '/ether/ {print $2}' | wc -l)
    info "Network interfaces with MAC: $mac_count"
    
    # Show system UUID if available
    if [ -f "/sys/class/dmi/id/product_uuid" ]; then
        local uuid=$(cat /sys/class/dmi/id/product_uuid 2>/dev/null)
        if [ -n "$uuid" ]; then
            info "System UUID: ${uuid:0:8}..."
        fi
    fi
    
    # Test stability
    if test_server_id_stability 3; then
        success "Server ID is stable and valid"
    else
        warning "Server ID stability test failed"
    fi
}

# Function to reset/regenerate server ID
reset_server_id() {
    step "Resetting Server ID"
    
    local server_id_file="${SCRIPT_DIR}/../config/.server_identity"
    local old_id="${SERVER_ID:-unknown}"
    
    # Remove existing server ID file (may need to remove immutable attribute first)
    if [ -f "$server_id_file" ]; then
        info "Removing existing protected server ID file: $server_id_file"
        
        # Try to remove immutable attribute if set
        if command -v chattr >/dev/null 2>&1; then
            chattr -i "$server_id_file" 2>/dev/null || true
        fi
        
        if rm -f "$server_id_file" 2>/dev/null; then
            success "Protected server ID file removed successfully"
        else
            error "Failed to remove protected server ID file"
            return 1
        fi
    else
        info "No existing protected server ID file found"
    fi
    
    # Clear current SERVER_ID variable
    unset SERVER_ID
    
    # Generate new server ID
    info "Generating new server ID..."
    get_server_id
    
    if [ -n "$SERVER_ID" ]; then
        success "New server ID generated: $SERVER_ID"
        if [ "$old_id" != "unknown" ] && [ "$old_id" != "$SERVER_ID" ]; then
            info "Server ID changed from: $old_id"
            warning "You may need to re-register with Telegram bot if using centralized configuration"
        fi
        return 0
    else
        error "Failed to generate new server ID"
        return 1
    fi
}

# Function to validate server ID
validate_server_id() {
    step "Validating Server ID"
    
    get_server_id
    
    # Check format
    if [ ${#SERVER_ID} -ne 16 ] || ! [[ "$SERVER_ID" =~ ^[0-9]{16}$ ]]; then
        error "Invalid server ID format: $SERVER_ID (length: ${#SERVER_ID})"
        return 1
    fi
    
    # Check protected file consistency
    local server_id_file="${SCRIPT_DIR}/../config/.server_identity"
    if [ -f "$server_id_file" ]; then
        local stored_data=$(cat "$server_id_file" 2>/dev/null)
        local file_id=$(decode_protected_server_id "$stored_data")
        
        if [ -z "$file_id" ]; then
            error "Failed to decode protected server ID file"
            return 1
        fi
        
        if [ "$file_id" != "$SERVER_ID" ]; then
            warning "Server ID mismatch between memory ($SERVER_ID) and protected file ($file_id)"
            return 1
        fi
        
        info "Protected file integrity verified"
    else
        warning "Protected server ID file not found: $server_id_file"
        return 1
    fi
    
    # Test stability
    if test_server_id_stability 3; then
        success "Server ID validation passed: $SERVER_ID"
        return 0
    else
        error "Server ID stability test failed"
        return 1
    fi
}

telegram_configure() {
    step "Loading Telegram Configuration"

    if [[ "${TELEGRAM_ENABLED:-false}" != "true" ]]; then
        info "Telegram disabled by configuration"
        export TELEGRAM_SERVER_STATUS="DISABLED"
        return 0
    fi

    local result_code=0

    if [[ "${BOT_TELEGRAM_TYPE:-personal}" == "personal" ]]; then
        info "Personal configuration set"
        export TELEGRAM_SERVER_STATUS="PERSONAL"

        if [[ -n "${TELEGRAM_BOT_TOKEN:-}" && -n "${TELEGRAM_CHAT_ID:-}" ]]; then
            success "Parameters configured"
            result_code=0
        else
            error "Parameters not configured (BOT_TOKEN or CHAT_ID missing)"
            result_code=1
        fi

        return $result_code
    fi

    info "Centralized configuration set"

    get_server_id
    if [[ -z "$SERVER_ID" ]]; then
        error "Error calculating identification code"
        export TELEGRAM_SERVER_STATUS="NO_ID"
        return 2
    fi

    info "Calculated identification code: $SERVER_ID"

    TELEGRAM_SERVER_API_HOST="${TELEGRAM_SERVER_API_HOST:-https://bot.tis24.it}"
    local api_url="${TELEGRAM_SERVER_API_HOST}/api/get-chat-id?server_id=${SERVER_ID}"

    # Use a more robust approach to acquire response and HTTP code
    local http_code response_body
    
    # Create a temporary file for response output
    local temp_resp_file=$(mktemp)
    local temp_header_file=$(mktemp)
    
    # Use curl with separate output for body and headers
    curl -s --max-time 5 -D "$temp_header_file" -o "$temp_resp_file" "$api_url"
    
    # Get HTTP code from headers
    http_code=$(grep -i "^HTTP" "$temp_header_file" | tail -n 1 | awk '{print $2}')
    # If unable to get HTTP code, set it to "000"
    [[ -z "$http_code" ]] && http_code="000"
    
    # Save HTTP code globally for use in notifications
    export TELEGRAM_SERVER_STATUS="$http_code"
    
    # Read response body from temporary file
    response_body=$(cat "$temp_resp_file")
    
    # Clean up temporary files
    rm -f "$temp_resp_file" "$temp_header_file"

    case "$http_code" in
        200)
            # Additional checks on response format
            if ! echo "$response_body" | grep -q "chat_id" || ! echo "$response_body" | grep -q "bot_token"; then
                error "Invalid server response: unrecognized format"
                debug "Response: $response_body"
                return 2
            fi
            
            TELEGRAM_CHAT_ID=$(echo "$response_body" | jq -r .chat_id 2>/dev/null)
            TELEGRAM_BOT_TOKEN=$(echo "$response_body" | jq -r .bot_token 2>/dev/null)

            if [[ -z "$TELEGRAM_CHAT_ID" || -z "$TELEGRAM_BOT_TOKEN" || "$TELEGRAM_CHAT_ID" == "null" || "$TELEGRAM_BOT_TOKEN" == "null" ]]; then
                error "Parameters received but incomplete"
                debug "chat_id: $TELEGRAM_CHAT_ID, bot_token: $TELEGRAM_BOT_TOKEN"
                return 1
            fi

            info "Configuration downloaded from remote server"
            success "200: Parameters configured"
            return 0
            ;;
        403)
            warning "403 First communication with Bot: Start the BOT @ProxmoxAN_bot and communicate your ID $SERVER_ID"
            return 1
            ;;
        409)
            warning "409 Missing registration in Bot: Start the BOT @ProxmoxAN_bot and communicate your ID $SERVER_ID"
            return 1
            ;;
        422)
            error "422 Invalid ID: Invalid ID (e.g. 'UNKNOWN') – check failed"
            return 2
            ;;
        000)
            warning "000 Bot communication timeout: Timeout or network error contacting Telegram server ($api_url) [HTTP 000]"
            debug "Response: $response_body"
            return 2
            ;;
        *)
            error "Unexpected response from Telegram server: Unknown error (HTTP $http_code)"
            debug "Response: $response_body"
            return 2
            ;;
    esac
}

# Configure Telegram if needed based on settings
setup_telegram_if_needed() {
    # Check if Telegram is enabled and in centralized mode
    if [ "${TELEGRAM_ENABLED:-false}" = "true" ] && [ "${BOT_TELEGRAM_TYPE:-personal}" = "centralized" ]; then
        debug "Centralized Telegram configuration required"
        # Ensure SERVER_ID is set
        get_server_id
        # Configure centralized Telegram
        if telegram_configure; then
            debug "Centralized Telegram configuration completed successfully"
            return 0
        else
            warning "Centralized Telegram configuration failed - server unreachable or not registered"
            # Temporarily disable Telegram to avoid using values in .env
            TELEGRAM_ENABLED="false"
            return 1
        fi
    elif [ "${TELEGRAM_ENABLED:-false}" = "true" ]; then
        debug "Using personal Telegram configuration"
        return 0
    else
        debug "Telegram not enabled, no configuration needed"
        return 0
    fi
}

# New function to determine status emojis based on precise rules
get_status_emoji() {
    local type="$1"    # "backup", "log", or "email"
    local location="$2"  # "primary", "secondary", "cloud", or "email"

    # Debug: log received parameters
    debug "get_status_emoji called with type=$type, location=$location"

    # Emoji definitions
    local EMOJI_SUCCESS="✅"
    local EMOJI_WARNING="⚠️"
    local EMOJI_ERROR="❌"
    local EMOJI_DISABLED="➖"

    # Specific handling for email
    if [ "$type" = "email" ] && [ "$location" = "email" ]; then
        debug "Handling email case"
        debug "EMAIL_ENABLED=${EMAIL_ENABLED:-false}"
        debug "EXIT_EMAIL_NOTIFICATION=${EXIT_EMAIL_NOTIFICATION:-$EXIT_ERROR}"
        
        if [ "${EMAIL_ENABLED:-false}" != "true" ]; then
            declare -g EMOJI_EMAIL="$EMOJI_DISABLED"
            debug "Email disabled, EMOJI_EMAIL=$EMOJI_EMAIL"
        else
            case "${EXIT_EMAIL_NOTIFICATION:-$EXIT_ERROR}" in
                $EXIT_SUCCESS)
                    declare -g EMOJI_EMAIL="$EMOJI_SUCCESS"
                    debug "Email success, EMOJI_EMAIL=$EMOJI_EMAIL"
                    ;;
                $EXIT_WARNING)
                    declare -g EMOJI_EMAIL="$EMOJI_WARNING"
                    debug "Email warning, EMOJI_EMAIL=$EMOJI_EMAIL"
                    ;;
                *)
                    declare -g EMOJI_EMAIL="$EMOJI_ERROR"
                    debug "Email error, EMOJI_EMAIL=$EMOJI_EMAIL"
                    ;;
            esac
        fi
        
        # Debug: verify EMOJI_EMAIL has been set
        debug "Final value EMOJI_EMAIL=$EMOJI_EMAIL"
        return 0
    fi

    # Create summary log only if enabled
    if [ "$ENABLE_EMOJI_LOG" = "true" ]; then
        # At each function call, create the log file overwriting any existing file
        echo "STATUS VARIABLES SUMMARY" > "$EMOJI_LOG_FILE"
        echo "=========================" >> "$EMOJI_LOG_FILE"
        echo "" >> "$EMOJI_LOG_FILE"

        # EMAIL
        echo "EMAIL" >> "$EMOJI_LOG_FILE"
        echo "EMAIL_ENABLED = ${EMAIL_ENABLED:-not defined}" >> "$EMOJI_LOG_FILE"
        echo "EMAIL_FROM = ${EMAIL_FROM:-not defined}" >> "$EMOJI_LOG_FILE"
        echo "EMAIL_RECIPIENT = ${EMAIL_RECIPIENT:-not defined}" >> "$EMOJI_LOG_FILE"
        echo "EXIT_EMAIL_NOTIFICATION = ${EXIT_EMAIL_NOTIFICATION:-not defined}" >> "$EMOJI_LOG_FILE"

        # Calculate email emoji based on operation outcome
        if [ "${EMAIL_ENABLED:-false}" != "true" ]; then
            EMOJI_EMAIL="$EMOJI_DISABLED"
        else
            case "${EXIT_EMAIL_NOTIFICATION:-$EXIT_ERROR}" in
                $EXIT_SUCCESS)
                    EMOJI_EMAIL="$EMOJI_SUCCESS"
                    ;;
                $EXIT_WARNING)
                    EMOJI_EMAIL="$EMOJI_WARNING"
                    ;;
                *)
                    EMOJI_EMAIL="$EMOJI_ERROR"
                    ;;
            esac
        fi
        echo "EMOJI_EMAIL = $EMOJI_EMAIL" >> "$EMOJI_LOG_FILE"
        echo "-------------------------------------------" >> "$EMOJI_LOG_FILE"
        echo "" >> "$EMOJI_LOG_FILE"

        # PRIMARY BACKUP
        echo "-------------------------------------------" >> "$EMOJI_LOG_FILE"
        echo "PRIMARY BACKUP" >> "$EMOJI_LOG_FILE"
        echo "EXIT_BACKUP_PRIMARY = ${EXIT_BACKUP_PRIMARY:-not defined}" >> "$EMOJI_LOG_FILE"
        echo "EXIT_BACKUP_VERIFY = ${EXIT_BACKUP_VERIFY:-not defined}" >> "$EMOJI_LOG_FILE"
        echo "EXIT_BACKUP_ROTATION_PRIMARY = ${EXIT_BACKUP_ROTATION_PRIMARY:-not defined}" >> "$EMOJI_LOG_FILE"

        # Calculate primary backup emoji
        local backup_primary_ok=$([ "${EXIT_BACKUP_PRIMARY:-$EXIT_ERROR}" = "$EXIT_SUCCESS" ] && echo "TRUE" || echo "FALSE")
        local backup_verify_ok=$([ "${EXIT_BACKUP_VERIFY:-$EXIT_ERROR}" = "$EXIT_SUCCESS" ] && echo "TRUE" || echo "FALSE")
        local rotation_primary_ok=$([ "${EXIT_BACKUP_ROTATION_PRIMARY:-$EXIT_ERROR}" = "$EXIT_SUCCESS" ] && echo "TRUE" || echo "FALSE")

        if [ "$backup_primary_ok" = "TRUE" ] && [ "$backup_verify_ok" = "TRUE" ]; then
            if [ "$rotation_primary_ok" = "TRUE" ]; then
                EMOJI_BACKUP_PRIMARIO="$EMOJI_SUCCESS"
            else
                EMOJI_BACKUP_PRIMARIO="$EMOJI_WARNING"
            fi
        else
            EMOJI_BACKUP_PRIMARIO="$EMOJI_ERROR"
        fi
        echo "EMOJI_BACKUP_PRIMARIO = $EMOJI_BACKUP_PRIMARIO" >> "$EMOJI_LOG_FILE"
        echo "-------------------------------------------" >> "$EMOJI_LOG_FILE"
        echo "" >> "$EMOJI_LOG_FILE"

        # SECONDARY BACKUP
        echo "SECONDARY BACKUP" >> "$EMOJI_LOG_FILE"
        echo "ENABLE_SECONDARY_BACKUP = ${ENABLE_SECONDARY_BACKUP:-not defined}" >> "$EMOJI_LOG_FILE"
        echo "EXIT_SECONDARY_COPY = ${EXIT_SECONDARY_COPY:-not defined}" >> "$EMOJI_LOG_FILE"
        echo "EXIT_BACKUP_ROTATION_SECONDARY = ${EXIT_BACKUP_ROTATION_SECONDARY:-not defined}" >> "$EMOJI_LOG_FILE"

        # Calculate secondary backup emoji
        local secondary_enabled=$([ "${ENABLE_SECONDARY_BACKUP:-true}" = "true" ] && echo "TRUE" || echo "FALSE")
        
        # NEW LOGIC: If primary backup failed, secondary must also be ERROR
        if [ "$EMOJI_BACKUP_PRIMARIO" = "$EMOJI_ERROR" ]; then
            EMOJI_BACKUP_SECONDARIO="$EMOJI_ERROR"
        elif [ "$secondary_enabled" = "FALSE" ]; then
            EMOJI_BACKUP_SECONDARIO="$EMOJI_DISABLED"
        else
            local secondary_copy_ok=$([ "${EXIT_SECONDARY_COPY:-$EXIT_ERROR}" = "$EXIT_SUCCESS" ] && echo "TRUE" || echo "FALSE")
            local rotation_secondary_ok=$([ "${EXIT_BACKUP_ROTATION_SECONDARY:-$EXIT_ERROR}" = "$EXIT_SUCCESS" ] && echo "TRUE" || echo "FALSE")
            if [ "$secondary_copy_ok" = "TRUE" ]; then
                if [ "$rotation_secondary_ok" = "TRUE" ]; then
                    EMOJI_BACKUP_SECONDARIO="$EMOJI_SUCCESS"
                else
                    EMOJI_BACKUP_SECONDARIO="$EMOJI_WARNING"
                fi
            else
                EMOJI_BACKUP_SECONDARIO="$EMOJI_ERROR"
            fi
        fi
        echo "EMOJI_BACKUP_SECONDARIO = $EMOJI_BACKUP_SECONDARIO" >> "$EMOJI_LOG_FILE"
        echo "-------------------------------------------" >> "$EMOJI_LOG_FILE"
        echo "" >> "$EMOJI_LOG_FILE"

        # BACKUP CLOUD
        echo "BACKUP CLOUD" >> "$EMOJI_LOG_FILE"
        echo "ENABLE_CLOUD_BACKUP = ${ENABLE_CLOUD_BACKUP:-not defined}" >> "$EMOJI_LOG_FILE"
        echo "COUNT_CLOUD_CONNECTION_ERROR = ${COUNT_CLOUD_CONNECTION_ERROR:-not defined}" >> "$EMOJI_LOG_FILE"
        echo "COUNT_CLOUD_CONNECTIVITY_STATUS = ${COUNT_CLOUD_CONNECTIVITY_STATUS:-not defined}" >> "$EMOJI_LOG_FILE"
        echo "EXIT_CLOUD_UPLOAD = ${EXIT_CLOUD_UPLOAD:-not defined}" >> "$EMOJI_LOG_FILE"
        echo "EXIT_BACKUP_ROTATION_CLOUD = ${EXIT_BACKUP_ROTATION_CLOUD:-not defined}" >> "$EMOJI_LOG_FILE"

        # Calculate cloud backup emoji - NEW LOGIC ORDER:
        # 1. Check if primary backup failed
        # 2. Check if cloud backup is enabled
        # 3. Check connection errors
        # 4. Check specific operations
        if [ "$EMOJI_BACKUP_PRIMARIO" = "$EMOJI_ERROR" ]; then
            EMOJI_BACKUP_CLOUD="$EMOJI_ERROR"
        else
            local cloud_enabled=$([ "${ENABLE_CLOUD_BACKUP:-true}" = "true" ] && echo "TRUE" || echo "FALSE")
            if [ "$cloud_enabled" = "FALSE" ]; then
                EMOJI_BACKUP_CLOUD="$EMOJI_DISABLED"
            elif [ "${COUNT_CLOUD_CONNECTION_ERROR:-false}" = "true" ]; then
                EMOJI_BACKUP_CLOUD="$EMOJI_ERROR"
            else
                local cloud_upload_ok=$([ "${EXIT_CLOUD_UPLOAD:-$EXIT_ERROR}" = "$EXIT_SUCCESS" ] && echo "TRUE" || echo "FALSE")
                local rotation_cloud_ok=$([ "${EXIT_BACKUP_ROTATION_CLOUD:-$EXIT_ERROR}" = "$EXIT_SUCCESS" ] && echo "TRUE" || echo "FALSE")
                if [ "$cloud_upload_ok" = "TRUE" ]; then
                    if [ "$rotation_cloud_ok" = "TRUE" ]; then
                        EMOJI_BACKUP_CLOUD="$EMOJI_SUCCESS"
                    else
                        EMOJI_BACKUP_CLOUD="$EMOJI_WARNING"
                    fi
                else
                    EMOJI_BACKUP_CLOUD="$EMOJI_ERROR"
                fi
            fi
        fi
        echo "EMOJI_BACKUP_CLOUD = $EMOJI_BACKUP_CLOUD" >> "$EMOJI_LOG_FILE"
        echo "-------------------------------------------" >> "$EMOJI_LOG_FILE"
        echo "" >> "$EMOJI_LOG_FILE"

        # PRIMARY LOG
        echo "PRIMARY LOG" >> "$EMOJI_LOG_FILE"
        echo "ENABLE_LOG_MANAGEMENT = ${ENABLE_LOG_MANAGEMENT:-not defined}" >> "$EMOJI_LOG_FILE"
        echo "EXIT_LOG_CREATION = ${EXIT_LOG_CREATION:-not defined}" >> "$EMOJI_LOG_FILE"
        echo "EXIT_LOG_ROTATION_PRIMARY = ${EXIT_LOG_ROTATION_PRIMARY:-not defined}" >> "$EMOJI_LOG_FILE"

        # Calculate primary log emoji - First check if log management is enabled
        if [ "${ENABLE_LOG_MANAGEMENT:-true}" != "true" ]; then
            EMOJI_LOG_PRIMARIO="$EMOJI_DISABLED"
        else
            local log_primary_ok=$([ "${EXIT_LOG_CREATION:-$EXIT_ERROR}" = "$EXIT_SUCCESS" ] && echo "TRUE" || echo "FALSE")
            local log_rotation_primary_ok=$([ "${EXIT_LOG_ROTATION_PRIMARY:-$EXIT_ERROR}" = "$EXIT_SUCCESS" ] && echo "TRUE" || echo "FALSE")
            if [ "$log_primary_ok" = "TRUE" ]; then
                if [ "$log_rotation_primary_ok" = "TRUE" ]; then
                    EMOJI_LOG_PRIMARIO="$EMOJI_SUCCESS"
                else
                    EMOJI_LOG_PRIMARIO="$EMOJI_WARNING"
                fi
            else
                EMOJI_LOG_PRIMARIO="$EMOJI_ERROR"
            fi
        fi
        echo "EMOJI_LOG_PRIMARIO = $EMOJI_LOG_PRIMARIO" >> "$EMOJI_LOG_FILE"
        echo "-------------------------------------------" >> "$EMOJI_LOG_FILE"
        echo "" >> "$EMOJI_LOG_FILE"

        # SECONDARY LOG
        echo "SECONDARY LOG" >> "$EMOJI_LOG_FILE"
        echo "ENABLE_LOG_MANAGEMENT = ${ENABLE_LOG_MANAGEMENT:-not defined}" >> "$EMOJI_LOG_FILE"
        echo "ENABLE_SECONDARY_BACKUP = ${ENABLE_SECONDARY_BACKUP:-not defined}" >> "$EMOJI_LOG_FILE"
        echo "EXIT_LOG_SECONDARY_COPY = ${EXIT_LOG_SECONDARY_COPY:-not defined}" >> "$EMOJI_LOG_FILE"
        echo "EXIT_LOG_ROTATION_SECONDARY = ${EXIT_LOG_ROTATION_SECONDARY:-not defined}" >> "$EMOJI_LOG_FILE"

        # Calculate secondary log emoji - First check if log management is enabled
        if [ "${ENABLE_LOG_MANAGEMENT:-true}" != "true" ]; then
            EMOJI_LOG_SECONDARIO="$EMOJI_DISABLED"
        else
            local secondary_enabled=$([ "${ENABLE_SECONDARY_BACKUP:-true}" = "true" ] && echo "TRUE" || echo "FALSE")
            if [ "$secondary_enabled" = "FALSE" ]; then
                EMOJI_LOG_SECONDARIO="$EMOJI_DISABLED"
            else
                local log_secondary_copy_ok=$([ "${EXIT_LOG_SECONDARY_COPY:-$EXIT_ERROR}" = "$EXIT_SUCCESS" ] && echo "TRUE" || echo "FALSE")
                local log_rotation_secondary_ok=$([ "${EXIT_LOG_ROTATION_SECONDARY:-$EXIT_ERROR}" = "$EXIT_SUCCESS" ] && echo "TRUE" || echo "FALSE")
                if [ "$log_secondary_copy_ok" = "TRUE" ]; then
                    if [ "$log_rotation_secondary_ok" = "TRUE" ]; then
                        EMOJI_LOG_SECONDARIO="$EMOJI_SUCCESS"
                    else
                        EMOJI_LOG_SECONDARIO="$EMOJI_WARNING"
                    fi
                else
                    EMOJI_LOG_SECONDARIO="$EMOJI_ERROR"
                fi
            fi
        fi
        echo "EMOJI_LOG_SECONDARIO = $EMOJI_LOG_SECONDARIO" >> "$EMOJI_LOG_FILE"
        echo "-------------------------------------------" >> "$EMOJI_LOG_FILE"
        echo "" >> "$EMOJI_LOG_FILE"

        # LOG CLOUD
        echo "LOG CLOUD" >> "$EMOJI_LOG_FILE"
        echo "ENABLE_LOG_MANAGEMENT = ${ENABLE_LOG_MANAGEMENT:-not defined}" >> "$EMOJI_LOG_FILE"
        echo "ENABLE_CLOUD_BACKUP = ${ENABLE_CLOUD_BACKUP:-not defined}" >> "$EMOJI_LOG_FILE"
        echo "COUNT_CLOUD_CONNECTION_ERROR = ${COUNT_CLOUD_CONNECTION_ERROR:-not defined}" >> "$EMOJI_LOG_FILE"
        echo "COUNT_CLOUD_CONNECTIVITY_STATUS = ${COUNT_CLOUD_CONNECTIVITY_STATUS:-not defined}" >> "$EMOJI_LOG_FILE"
        echo "EXIT_LOG_CLOUD_UPLOAD = ${EXIT_LOG_CLOUD_UPLOAD:-not defined}" >> "$EMOJI_LOG_FILE"
        echo "EXIT_LOG_ROTATION_CLOUD = ${EXIT_LOG_ROTATION_CLOUD:-not defined}" >> "$EMOJI_LOG_FILE"

        # Calculate cloud log emoji - CORRECTED LOGIC ORDER:
        # 1. Check if log management is enabled
        # 2. Check if cloud backup is enabled
        # 3. Check connection errors
        # 4. Check specific operations
        if [ "${ENABLE_LOG_MANAGEMENT:-true}" != "true" ]; then
            EMOJI_LOG_CLOUD="$EMOJI_DISABLED"
        else
            local cloud_enabled=$([ "${ENABLE_CLOUD_BACKUP:-true}" = "true" ] && echo "TRUE" || echo "FALSE")
            if [ "$cloud_enabled" = "FALSE" ]; then
                EMOJI_LOG_CLOUD="$EMOJI_DISABLED"
            elif [ "${COUNT_CLOUD_CONNECTION_ERROR:-false}" = "true" ]; then
                EMOJI_LOG_CLOUD="$EMOJI_ERROR"
            else
                local log_cloud_upload_ok=$([ "${EXIT_LOG_CLOUD_UPLOAD:-$EXIT_ERROR}" = "$EXIT_SUCCESS" ] && echo "TRUE" || echo "FALSE")
                local log_rotation_cloud_ok=$([ "${EXIT_LOG_ROTATION_CLOUD:-$EXIT_ERROR}" = "$EXIT_SUCCESS" ] && echo "TRUE" || echo "FALSE")
                if [ "$log_cloud_upload_ok" = "TRUE" ]; then
                    if [ "$log_rotation_cloud_ok" = "TRUE" ]; then
                        EMOJI_LOG_CLOUD="$EMOJI_SUCCESS"
                    else
                        EMOJI_LOG_CLOUD="$EMOJI_WARNING"
                    fi
                else
                    EMOJI_LOG_CLOUD="$EMOJI_ERROR"
                fi
            fi
        fi
        echo "EMOJI_LOG_CLOUD = $EMOJI_LOG_CLOUD" >> "$EMOJI_LOG_FILE"
        echo "-------------------------------------------" >> "$EMOJI_LOG_FILE"
        echo "" >> "$EMOJI_LOG_FILE"
    else
        # If logging is disabled, calculate only emojis without writing the file
        # EMAIL - based on operation outcome
        if [ "${EMAIL_ENABLED:-false}" != "true" ]; then
            EMOJI_EMAIL="$EMOJI_DISABLED"
        else
            case "${EXIT_EMAIL_NOTIFICATION:-$EXIT_ERROR}" in
                $EXIT_SUCCESS)
                    EMOJI_EMAIL="$EMOJI_SUCCESS"
                    ;;
                $EXIT_WARNING)
                    EMOJI_EMAIL="$EMOJI_WARNING"
                    ;;
                *)
                    EMOJI_EMAIL="$EMOJI_ERROR"
                    ;;
            esac
        fi

        # PRIMARY BACKUP
        local backup_primary_ok=$([ "${EXIT_BACKUP_PRIMARY:-$EXIT_ERROR}" = "$EXIT_SUCCESS" ] && echo "TRUE" || echo "FALSE")
        local backup_verify_ok=$([ "${EXIT_BACKUP_VERIFY:-$EXIT_ERROR}" = "$EXIT_SUCCESS" ] && echo "TRUE" || echo "FALSE")
        local rotation_primary_ok=$([ "${EXIT_BACKUP_ROTATION_PRIMARY:-$EXIT_ERROR}" = "$EXIT_SUCCESS" ] && echo "TRUE" || echo "FALSE")
        if [ "$backup_primary_ok" = "TRUE" ] && [ "$backup_verify_ok" = "TRUE" ]; then
            if [ "$rotation_primary_ok" = "TRUE" ]; then
                EMOJI_BACKUP_PRIMARIO="$EMOJI_SUCCESS"
            else
                EMOJI_BACKUP_PRIMARIO="$EMOJI_WARNING"
            fi
        else
            EMOJI_BACKUP_PRIMARIO="$EMOJI_ERROR"
        fi

        # SECONDARY BACKUP
        local secondary_enabled=$([ "${ENABLE_SECONDARY_BACKUP:-true}" = "true" ] && echo "TRUE" || echo "FALSE")
        
        # NEW LOGIC: If primary backup failed, secondary must also be ERROR
        if [ "$EMOJI_BACKUP_PRIMARIO" = "$EMOJI_ERROR" ]; then
            EMOJI_BACKUP_SECONDARIO="$EMOJI_ERROR"
        elif [ "$secondary_enabled" = "FALSE" ]; then
            EMOJI_BACKUP_SECONDARIO="$EMOJI_DISABLED"
        else
            local secondary_copy_ok=$([ "${EXIT_SECONDARY_COPY:-$EXIT_ERROR}" = "$EXIT_SUCCESS" ] && echo "TRUE" || echo "FALSE")
            local rotation_secondary_ok=$([ "${EXIT_BACKUP_ROTATION_SECONDARY:-$EXIT_ERROR}" = "$EXIT_SUCCESS" ] && echo "TRUE" || echo "FALSE")
            if [ "$secondary_copy_ok" = "TRUE" ]; then
                if [ "$rotation_secondary_ok" = "TRUE" ]; then
                    EMOJI_BACKUP_SECONDARIO="$EMOJI_SUCCESS"
                else
                    EMOJI_BACKUP_SECONDARIO="$EMOJI_WARNING"
                fi
            else
                EMOJI_BACKUP_SECONDARIO="$EMOJI_ERROR"
            fi
        fi

        # BACKUP CLOUD
        # NEW LOGIC ORDER:
        # 1. Check if primary backup failed
        # 2. Check if cloud backup is enabled
        # 3. Check connection errors
        # 4. Check specific operations
        if [ "$EMOJI_BACKUP_PRIMARIO" = "$EMOJI_ERROR" ]; then
            EMOJI_BACKUP_CLOUD="$EMOJI_ERROR"
        else
            local cloud_enabled=$([ "${ENABLE_CLOUD_BACKUP:-true}" = "true" ] && echo "TRUE" || echo "FALSE")
            if [ "$cloud_enabled" = "FALSE" ]; then
                EMOJI_BACKUP_CLOUD="$EMOJI_DISABLED"
            elif [ "${COUNT_CLOUD_CONNECTION_ERROR:-false}" = "true" ]; then
                EMOJI_BACKUP_CLOUD="$EMOJI_ERROR"
            else
                local cloud_upload_ok=$([ "${EXIT_CLOUD_UPLOAD:-$EXIT_ERROR}" = "$EXIT_SUCCESS" ] && echo "TRUE" || echo "FALSE")
                local rotation_cloud_ok=$([ "${EXIT_BACKUP_ROTATION_CLOUD:-$EXIT_ERROR}" = "$EXIT_SUCCESS" ] && echo "TRUE" || echo "FALSE")
                if [ "$cloud_upload_ok" = "TRUE" ]; then
                    if [ "$rotation_cloud_ok" = "TRUE" ]; then
                        EMOJI_BACKUP_CLOUD="$EMOJI_SUCCESS"
                    else
                        EMOJI_BACKUP_CLOUD="$EMOJI_WARNING"
                    fi
                else
                    EMOJI_BACKUP_CLOUD="$EMOJI_ERROR"
                fi
            fi
        fi

        # PRIMARY LOG
        if [ "${ENABLE_LOG_MANAGEMENT:-true}" != "true" ]; then
            EMOJI_LOG_PRIMARIO="$EMOJI_DISABLED"
        else
            local log_primary_ok=$([ "${EXIT_LOG_CREATION:-$EXIT_ERROR}" = "$EXIT_SUCCESS" ] && echo "TRUE" || echo "FALSE")
            local log_rotation_primary_ok=$([ "${EXIT_LOG_ROTATION_PRIMARY:-$EXIT_ERROR}" = "$EXIT_SUCCESS" ] && echo "TRUE" || echo "FALSE")
            if [ "$log_primary_ok" = "TRUE" ]; then
                if [ "$log_rotation_primary_ok" = "TRUE" ]; then
                    EMOJI_LOG_PRIMARIO="$EMOJI_SUCCESS"
                else
                    EMOJI_LOG_PRIMARIO="$EMOJI_WARNING"
                fi
            else
                EMOJI_LOG_PRIMARIO="$EMOJI_ERROR"
            fi
        fi

        # SECONDARY LOG
        if [ "${ENABLE_LOG_MANAGEMENT:-true}" != "true" ]; then
            EMOJI_LOG_SECONDARIO="$EMOJI_DISABLED"
        else
            local secondary_enabled=$([ "${ENABLE_SECONDARY_BACKUP:-true}" = "true" ] && echo "TRUE" || echo "FALSE")
            if [ "$secondary_enabled" = "FALSE" ]; then
                EMOJI_LOG_SECONDARIO="$EMOJI_DISABLED"
            else
                local log_secondary_copy_ok=$([ "${EXIT_LOG_SECONDARY_COPY:-$EXIT_ERROR}" = "$EXIT_SUCCESS" ] && echo "TRUE" || echo "FALSE")
                local log_rotation_secondary_ok=$([ "${EXIT_LOG_ROTATION_SECONDARY:-$EXIT_ERROR}" = "$EXIT_SUCCESS" ] && echo "TRUE" || echo "FALSE")
                if [ "$log_secondary_copy_ok" = "TRUE" ]; then
                    if [ "$log_rotation_secondary_ok" = "TRUE" ]; then
                        EMOJI_LOG_SECONDARIO="$EMOJI_SUCCESS"
                    else
                        EMOJI_LOG_SECONDARIO="$EMOJI_WARNING"
                    fi
                else
                    EMOJI_LOG_SECONDARIO="$EMOJI_ERROR"
                fi
            fi
        fi

        # LOG CLOUD
        # CORRECTED LOGIC ORDER:
        # 1. Check if log management is enabled
        # 2. Check if cloud backup is enabled
        # 3. Check connection errors
        # 4. Check specific operations
        if [ "${ENABLE_LOG_MANAGEMENT:-true}" != "true" ]; then
            EMOJI_LOG_CLOUD="$EMOJI_DISABLED"
        else
            local cloud_enabled=$([ "${ENABLE_CLOUD_BACKUP:-true}" = "true" ] && echo "TRUE" || echo "FALSE")
            if [ "$cloud_enabled" = "FALSE" ]; then
                EMOJI_LOG_CLOUD="$EMOJI_DISABLED"
            elif [ "${COUNT_CLOUD_CONNECTION_ERROR:-false}" = "true" ]; then
                EMOJI_LOG_CLOUD="$EMOJI_ERROR"
            else
                local log_cloud_upload_ok=$([ "${EXIT_LOG_CLOUD_UPLOAD:-$EXIT_ERROR}" = "$EXIT_SUCCESS" ] && echo "TRUE" || echo "FALSE")
                local log_rotation_cloud_ok=$([ "${EXIT_LOG_ROTATION_CLOUD:-$EXIT_ERROR}" = "$EXIT_SUCCESS" ] && echo "TRUE" || echo "FALSE")
                if [ "$log_cloud_upload_ok" = "TRUE" ]; then
                    if [ "$log_rotation_cloud_ok" = "TRUE" ]; then
                        EMOJI_LOG_CLOUD="$EMOJI_SUCCESS"
                    else
                        EMOJI_LOG_CLOUD="$EMOJI_WARNING"
                    fi
                else
                    EMOJI_LOG_CLOUD="$EMOJI_ERROR"
                fi
            fi
        fi
    fi

    # Return the requested emoji based on parameters
    if [ "$type" = "backup" ]; then
        case "$location" in
            "primary") echo "$EMOJI_BACKUP_PRIMARIO" ;;
            "secondary") echo "$EMOJI_BACKUP_SECONDARIO" ;;
            "cloud") echo "$EMOJI_BACKUP_CLOUD" ;;
            "email") echo "$EMOJI_EMAIL" ;;
            *) echo "$EMOJI_ERROR" ;;
        esac
    elif [ "$type" = "log" ]; then
        case "$location" in
            "primary") echo "$EMOJI_LOG_PRIMARIO" ;;
            "secondary") echo "$EMOJI_LOG_SECONDARIO" ;;
            "cloud") echo "$EMOJI_LOG_CLOUD" ;;
            *) echo "$EMOJI_ERROR" ;;
        esac
    else
        echo "$EMOJI_ERROR"
    fi
}

# Global variable to track cloud connection errors
COUNT_CLOUD_CONNECTION_ERROR="false"


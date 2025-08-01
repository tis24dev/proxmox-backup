#!/bin/bash
# Functions for backup data collection

# ======= CENTRALIZED DATASTORE DETECTION =======

# Centralized function to detect all available datastores from both PBS and PVE systems
detect_all_datastores() {
    step "Auto-detecting datastores from PBS and PVE systems"
    
    local datastores_found=()
    local system_types_detected=()
    
    # Check if auto-detection is enabled
    if [ "${AUTO_DETECT_DATASTORES:-true}" != "true" ]; then
        info "Auto-detection disabled, using manual configuration only"
        
        # Use manual PBS_DATASTORE_PATH if configured
        if [ -n "${PBS_DATASTORE_PATH:-}" ]; then
            info "Using manual PBS_DATASTORE_PATH: $PBS_DATASTORE_PATH"
            datastores_found+=("MANUAL|pbs_manual|$PBS_DATASTORE_PATH|Manual PBS configuration")
        fi
        
        # Check for standard directories as fallback
        local standard_paths=(
            "/var/lib/proxmox-backup/datastore"
            "/var/lib/vz/dump"
            "/mnt/pve"
        )
        
        for std_path in "${standard_paths[@]}"; do
            if [ -d "$std_path" ]; then
                info "Found standard directory: $std_path"
                if [[ "$std_path" =~ proxmox-backup ]]; then
                    datastores_found+=("MANUAL|pbs_standard|$std_path|Standard PBS location")
                else
                    datastores_found+=("MANUAL|pve_standard|$std_path|Standard PVE location")
                fi
            fi
        done
        
        if [ ${#datastores_found[@]} -eq 0 ]; then
            warning "No manual datastores configured - using default fallback"
            datastores_found+=("FALLBACK|default|/var/lib/proxmox-backup/datastore|Default fallback")
        fi
        
        # Export results and exit early
        info "Manual mode: Total datastores configured: ${#datastores_found[@]}"
        for datastore in "${datastores_found[@]}"; do
            IFS='|' read -r sys_type name path comment <<< "$datastore"
            info "  [$sys_type] $name: $path ($comment)"
        done
        printf '%s\n' "${datastores_found[@]}"
        return 0
    fi
    
    # Detect PBS datastores
    if command -v proxmox-backup-manager >/dev/null 2>&1; then
        info "PBS system detected - scanning for PBS datastores"
        system_types_detected+=("PBS")
        
        local pbs_datastores_json
        pbs_datastores_json=$(proxmox-backup-manager datastore list --output-format=json 2>/dev/null)
        
        if [ $? -eq 0 ] && [ -n "$pbs_datastores_json" ]; then
            local pbs_count=0
            while IFS= read -r datastore_info; do
                if [ -n "$datastore_info" ]; then
                    local name=$(echo "$datastore_info" | jq -r '.name' 2>/dev/null)
                    local path=$(echo "$datastore_info" | jq -r '.path' 2>/dev/null)
                    local comment=$(echo "$datastore_info" | jq -r '.comment // "No comment"' 2>/dev/null)
                    
                    if [ -n "$path" ] && [ "$path" != "null" ]; then
                        datastores_found+=("PBS|$name|$path|$comment")
                        pbs_count=$((pbs_count + 1))
                        debug "Found PBS datastore: $name -> $path"
                    fi
                fi
            done < <(echo "$pbs_datastores_json" | jq -c '.[]' 2>/dev/null)
            
            if [ $pbs_count -gt 0 ]; then
                success "Found $pbs_count PBS datastore(s)"
            else
                info "No PBS datastores found via API"
            fi
        else
            # Fallback: read from PBS configuration file
            if [ -f "/etc/proxmox-backup/datastore.cfg" ]; then
                debug "Falling back to PBS configuration file"
                while IFS= read -r line; do
                    if [[ "$line" =~ ^datastore:[[:space:]]*([^[:space:]]+) ]]; then
                        local ds_name="${BASH_REMATCH[1]}"
                        local ds_path=""
                        local ds_comment=""
                        
                        # Read following lines for path and comment
                        while IFS= read -r subline; do
                            [[ "$subline" =~ ^[[:space:]]*$ ]] && break
                            [[ "$subline" =~ ^datastore: ]] && break
                            
                            if [[ "$subline" =~ ^[[:space:]]*path[[:space:]]+(.+)$ ]]; then
                                ds_path="${BASH_REMATCH[1]}"
                            elif [[ "$subline" =~ ^[[:space:]]*comment[[:space:]]+(.+)$ ]]; then
                                ds_comment="${BASH_REMATCH[1]}"
                            fi
                        done
                        
                        if [ -n "$ds_path" ]; then
                            datastores_found+=("PBS|$ds_name|$ds_path|${ds_comment:-No comment}")
                            debug "Found PBS datastore from config: $ds_name -> $ds_path"
                        fi
                    fi
                done < "/etc/proxmox-backup/datastore.cfg"
            fi
        fi
    fi
    
    # Detect PVE datastores
    if command -v pvesm >/dev/null 2>&1; then
        info "PVE system detected - scanning for PVE storage"
        system_types_detected+=("PVE")
        
        local pve_storage_json
        # Try first with JSON output format (newer versions)
        if pvesm status --noborder --output-format=json >/dev/null 2>&1; then
            info "Using JSON output format for pvesm status"
            pve_storage_json=$(pvesm status --noborder --output-format=json 2>/dev/null)
        else
            info "JSON output not supported, parsing standard output format"
            # Fallback to standard output and convert to JSON-like format
            local pve_storage_raw
            pve_storage_raw=$(pvesm status 2>/dev/null)
            
            if [ $? -eq 0 ] && [ -n "$pve_storage_raw" ]; then
                # Convert standard output to JSON-like format for compatibility
                # Skip header line and process each storage entry
                pve_storage_json=""
                while IFS= read -r line; do
                    # Skip header and empty lines
                    if [[ "$line" =~ ^Name.*Type.*Status ]] || [[ -z "$line" ]]; then
                        continue
                    fi
                    
                    # Parse the line (Name Type Status Total Used Available %)
                    local storage_info=($line)
                    if [ ${#storage_info[@]} -ge 3 ]; then
                        local storage_name="${storage_info[0]}"
                        local storage_type="${storage_info[1]}"
                        local storage_status="${storage_info[2]}"
                        
                        # Only process active storage
                        if [ "$storage_status" = "active" ]; then
                            # Create a simple JSON-like entry for compatibility
                            if [ -n "$pve_storage_json" ]; then
                                pve_storage_json="$pve_storage_json"$'\n'
                            fi
                            pve_storage_json="${pve_storage_json}{\"storage\":\"$storage_name\",\"type\":\"$storage_type\",\"status\":\"$storage_status\"}"
                        fi
                    fi
                done <<< "$pve_storage_raw"
            else
                warning "Failed to get storage status from pvesm"
                pve_storage_json=""
            fi
        fi
        
        if [ $? -eq 0 ] && [ -n "$pve_storage_json" ]; then
            local pve_count=0
            while IFS= read -r storage_info; do
                if [ -n "$storage_info" ]; then
                    local storage
                    local type
                    local path=""
                    local content="unknown"
                    
                    # Try to parse as JSON first, then as simple format
                    if command -v jq >/dev/null 2>&1 && echo "$storage_info" | jq -e . >/dev/null 2>&1; then
                        # JSON format
                        storage=$(echo "$storage_info" | jq -r '.storage' 2>/dev/null)
                        type=$(echo "$storage_info" | jq -r '.type' 2>/dev/null)
                        path=$(echo "$storage_info" | jq -r '.path // empty' 2>/dev/null)
                        content=$(echo "$storage_info" | jq -r '.content // "unknown"' 2>/dev/null)
                    else
                        # Simple format from fallback conversion
                        if [[ "$storage_info" =~ \"storage\":\"([^\"]+)\".*\"type\":\"([^\"]+)\" ]]; then
                            storage="${BASH_REMATCH[1]}"
                            type="${BASH_REMATCH[2]}"
                            
                            # Try to determine path based on storage type and name
                            case "$type" in
                                "dir")
                                    # For directory storage, try to get path from config
                                    if [ -f "/etc/pve/storage.cfg" ]; then
                                        path=$(grep -A 10 "^$type: $storage" /etc/pve/storage.cfg | grep "path" | head -1 | awk '{print $2}' 2>/dev/null)
                                    fi
                                    # Default paths for common storage names
                                    if [ -z "$path" ]; then
                                        case "$storage" in
                                            "local") path="/var/lib/vz" ;;
                                            "backup_ext"|"backup_usb") path="/mnt/pve/$storage" ;;
                                            *) path="/mnt/pve/$storage" ;;
                                        esac
                                    fi
                                    ;;
                                "zfspool")
                                    path="/dev/zvol/$storage"
                                    ;;
                                *)
                                    path=""
                                    ;;
                            esac
                            content="mixed"
                        fi
                    fi
                    
                    # Only include storage types that are relevant for backups
                    if [[ "$type" =~ ^(dir|nfs|cifs|glusterfs|zfs|lvm|lvmthin)$ ]] && [ -n "$path" ] && [ "$path" != "null" ] && [ "$path" != "empty" ]; then
                        datastores_found+=("PVE|$storage|$path|$type ($content)")
                        pve_count=$((pve_count + 1))
                        debug "Found PVE storage: $storage ($type) -> $path"
                    fi
                fi
            done < <(echo "$pve_storage_json" | grep -v '^$')
            
            if [ $pve_count -gt 0 ]; then
                success "Found $pve_count PVE storage location(s)"
            else
                info "No PVE storage locations found"
            fi
        else
            warning "Failed to get PVE storage information"
        fi
    fi
    
    # Fallback to manual configuration if no datastores were auto-detected
    if [ ${#datastores_found[@]} -eq 0 ]; then
        warning "No datastores auto-detected from PBS or PVE systems"
        
        # Check for manual PBS_DATASTORE_PATH configuration
        if [ -n "${PBS_DATASTORE_PATH:-}" ]; then
            info "Using manual PBS_DATASTORE_PATH: $PBS_DATASTORE_PATH"
            datastores_found+=("MANUAL|pbs_manual|$PBS_DATASTORE_PATH|Manual configuration")
        fi
        
        # Check for standard PVE backup directories
        local standard_pve_paths=(
            "/var/lib/vz/dump"
            "/mnt/pve"
        )
        
        for std_path in "${standard_pve_paths[@]}"; do
            if [ -d "$std_path" ]; then
                info "Found standard PVE directory: $std_path"
                datastores_found+=("MANUAL|pve_standard|$std_path|Standard PVE location")
            fi
        done
        
        if [ ${#datastores_found[@]} -eq 0 ]; then
            # CRITICAL: Ensure this only generates WARNING (exit code 1), never ERROR (exit code 2)
            warning "No datastores found - neither auto-detected nor in custom paths. Using default fallback."
            warning "This is expected behavior when no Proxmox datastores are available."
            
            # Set warning exit code explicitly to ensure we never generate critical error
            set_exit_code "warning"
            
            # Use default fallback to ensure backup can still proceed
            datastores_found+=("FALLBACK|default|/var/lib/proxmox-backup/datastore|Default fallback")
            
            info "Using fallback datastore path: /var/lib/proxmox-backup/datastore"
            info "You can configure a custom path in the env file using PBS_DATASTORE_PATH"
        fi
    fi
    
    # Summary output
    if [ ${#system_types_detected[@]} -gt 0 ]; then
        info "Detected system types: ${system_types_detected[*]}"
    fi
    
    info "Total datastores detected: ${#datastores_found[@]}"
    for datastore in "${datastores_found[@]}"; do
        IFS='|' read -r sys_type name path comment <<< "$datastore"
        info "  [$sys_type] $name: $path ($comment)"
    done
    
    # Export results for use by other functions
    printf '%s\n' "${datastores_found[@]}"
    return 0
}

# Helper function to get datastore paths from the detection results
get_datastore_paths() {
    local filter_type="${1:-}"  # Optional: filter by system type (PBS, PVE, MANUAL, FALLBACK)
    
    while IFS='|' read -r sys_type name path comment; do
        if [ -z "$filter_type" ] || [ "$sys_type" = "$filter_type" ]; then
            echo "$path"
        fi
    done < <(detect_all_datastores)
}

# Helper function to get datastore info for a specific system type
get_datastores_by_type() {
    local system_type="$1"
    
    while IFS='|' read -r sys_type name path comment; do
        if [ "$sys_type" = "$system_type" ]; then
            echo "$sys_type|$name|$path|$comment"
        fi
    done < <(detect_all_datastores)
}

# Helper function to update backup.env with auto-detected datastores for compatibility
update_env_with_detected_datastores() {
    local env_file="$1"
    local backup_env_path="${env_file:-${BASE_DIR}/env/backup.env}"
    
    if [ ! -f "$backup_env_path" ]; then
        warning "backup.env file not found: $backup_env_path"
        return 1
    fi
    
    # Get detected PBS datastores
    local pbs_datastores
    mapfile -t pbs_datastores < <(get_datastores_by_type "PBS")
    
    if [ ${#pbs_datastores[@]} -gt 0 ]; then
        # Use the first PBS datastore as primary
        local primary_datastore="${pbs_datastores[0]}"
        IFS='|' read -r sys_type ds_name ds_path ds_comment <<< "$primary_datastore"
        
        info "Updating PBS_DATASTORE_PATH in backup.env with auto-detected path: $ds_path"
        
        # Create backup of original file
        cp "$backup_env_path" "$backup_env_path.autodetect.bak"
        
        # Update or add PBS_DATASTORE_PATH
        if grep -q "^PBS_DATASTORE_PATH=" "$backup_env_path"; then
            # Update existing line
            sed -i "s|^PBS_DATASTORE_PATH=.*|PBS_DATASTORE_PATH=\"$ds_path\"  # Auto-detected: $ds_name ($ds_comment)|" "$backup_env_path"
        else
            # Add new line
            echo "" >> "$backup_env_path"
            echo "# Auto-detected PBS datastore path" >> "$backup_env_path"
            echo "PBS_DATASTORE_PATH=\"$ds_path\"  # Auto-detected: $ds_name ($ds_comment)" >> "$backup_env_path"
        fi
        
        success "Updated PBS_DATASTORE_PATH with auto-detected value"
        
        # If multiple datastores found, add them as comments
        if [ ${#pbs_datastores[@]} -gt 1 ]; then
            echo "" >> "$backup_env_path"
            echo "# Additional PBS datastores detected:" >> "$backup_env_path"
            for ((i=1; i<${#pbs_datastores[@]}; i++)); do
                IFS='|' read -r sys_type ds_name ds_path ds_comment <<< "${pbs_datastores[i]}"
                echo "# PBS_DATASTORE_PATH_${i}=\"$ds_path\"  # $ds_name ($ds_comment)" >> "$backup_env_path"
            done
        fi
    else
        debug "No PBS datastores detected for backup.env update"
    fi
}

# ======= CLUSTER DETECTION FUNCTIONS =======

# Function to check if PVE is configured in cluster mode
is_pve_cluster_configured() {
    debug "Checking if PVE is configured in cluster mode"
    
    # Method 1: Check if corosync.conf exists and has cluster configuration
    if [ -f "${COROSYNC_CONFIG_PATH}/corosync.conf" ]; then
        # Check if corosync.conf contains cluster configuration (not just default)
        if grep -q "cluster_name\|nodelist\|ring0_addr" "${COROSYNC_CONFIG_PATH}/corosync.conf" 2>/dev/null; then
            debug "Found active cluster configuration in corosync.conf"
            return 0
        fi
    fi
    
    # Method 2: Check cluster status via pvecm
    if command -v pvecm >/dev/null 2>&1; then
        if pvecm status >/dev/null 2>&1; then
            debug "Cluster is active according to pvecm status"
            return 0
        fi
    fi
    
    # Method 3: Check if cluster directory exists and contains nodes
    if [ -d "${PVE_CONFIG_PATH}/nodes" ]; then
        local node_count=$(find "${PVE_CONFIG_PATH}/nodes" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)
        if [ "$node_count" -gt 1 ]; then
            debug "Found $node_count nodes in cluster configuration"
            return 0
        fi
    fi
    
    # Method 4: Check if cluster.conf or corosync is running
    if systemctl is-active corosync.service >/dev/null 2>&1; then
        debug "Corosync service is running, indicating cluster configuration"
        return 0
    fi
    
    debug "No cluster configuration detected"
    return 1
}

# Function to check if Ceph is configured and available in PVE
is_ceph_configured() {
    debug "Checking if Ceph is configured in PVE system"
    
    # Method 1: Check if Ceph configuration directory exists and contains valid configuration
    if [ -d "${CEPH_CONFIG_PATH}" ]; then
        # Check if ceph.conf exists and contains actual configuration
        if [ -f "${CEPH_CONFIG_PATH}/ceph.conf" ]; then
            # Check if ceph.conf contains actual cluster configuration (not just default/empty)
            if grep -q "fsid\|mon_host\|mon_initial_members" "${CEPH_CONFIG_PATH}/ceph.conf" 2>/dev/null; then
                debug "Found valid Ceph configuration in ${CEPH_CONFIG_PATH}/ceph.conf"
                return 0
            fi
        fi
        
        # Check if there are any keyring files indicating Ceph setup
        if find "${CEPH_CONFIG_PATH}" -name "*.keyring" -type f 2>/dev/null | grep -q .; then
            debug "Found Ceph keyring files in ${CEPH_CONFIG_PATH}"
            return 0
        fi
    fi
    
    # Method 2: Check if any Ceph services are running
    local ceph_services=("ceph-mon" "ceph-osd" "ceph-mds" "ceph-mgr")
    for service in "${ceph_services[@]}"; do
        if systemctl is-active "${service}*" >/dev/null 2>&1; then
            debug "Found running Ceph service: $service"
            return 0
        fi
    done
    
    # Method 3: Check if PVE has Ceph storage configured
    if command -v pvesm >/dev/null 2>&1; then
        # Check if any storage is configured with Ceph types
        if pvesm status 2>/dev/null | grep -q -E "(cephfs|rbd)"; then
            debug "Found Ceph storage configured in PVE storage"
            return 0
        fi
    fi
    
    # Method 4: Check if ceph command is available and can connect to cluster
    if command -v ceph >/dev/null 2>&1; then
        # Try to get cluster status - if it succeeds, Ceph is properly configured
        if timeout 5 ceph status >/dev/null 2>&1; then
            debug "Ceph cluster is accessible and responding"
            return 0
        fi
    fi
    
    # Method 5: Check for Ceph processes
    if pgrep -f "ceph-" >/dev/null 2>&1; then
        debug "Found running Ceph processes"
        return 0
    fi
    
    debug "No Ceph configuration detected in PVE system"
    return 1
}

# ======= ORIGINAL FUNCTIONS (UPDATED) =======

# Collect PVE-specific configuration
collect_pve_configs() {
    step "Collecting PVE configuration files with enhanced features"
    
    local operation_start=$(date +%s)
    local local_files_processed=0
    local local_files_failed=0
    
    # Create directories preserving original structure with configurable paths
    mkdir -p "$TEMP_DIR${PVE_CONFIG_PATH}" && increment_file_counter "dirs"
    mkdir -p "$TEMP_DIR${PVE_CLUSTER_PATH}" && increment_file_counter "dirs"
    mkdir -p "$TEMP_DIR${COROSYNC_CONFIG_PATH}" && increment_file_counter "dirs"
    mkdir -p "$TEMP_DIR/etc/pve/firewall" && increment_file_counter "dirs"
    mkdir -p "$TEMP_DIR/etc/pve/nodes" && increment_file_counter "dirs"
    
    # Suggerimento 1: Gestione configurabile dei file sensibili
    
    # Collect cluster configuration (configurable)
    if [ "${BACKUP_CLUSTER_CONFIG:-true}" == "true" ]; then
        info "Collecting PVE cluster configuration"
        safe_copy "${PVE_CONFIG_PATH}" "$TEMP_DIR${PVE_CONFIG_PATH}" "PVE cluster configuration"
        
        # Collect cluster configuration database
        safe_copy "${PVE_CLUSTER_PATH}/config.db" "$TEMP_DIR${PVE_CLUSTER_PATH}/config.db" "PVE cluster database"
    else
        info "PVE cluster configuration backup disabled"
    fi
    
    # Collect Corosync configuration (configurable and cluster-aware)
    if [ "${BACKUP_COROSYNC_CONFIG:-true}" == "true" ]; then
        if is_pve_cluster_configured; then
            if [ -f "${COROSYNC_CONFIG_PATH}/corosync.conf" ]; then
                info "Collecting Corosync configuration"
                safe_copy "${COROSYNC_CONFIG_PATH}/corosync.conf" "$TEMP_DIR${COROSYNC_CONFIG_PATH}/corosync.conf" "Corosync configuration"
            else
                info "Corosync configuration file not found despite cluster detection - skipping"
            fi
        else
            info "PVE cluster not configured (single node) - skipping Corosync configuration"
        fi
    else
        info "Corosync configuration backup disabled"
    fi
    
    # Collect firewall rules (configurable)
    if [ "${BACKUP_PVE_FIREWALL:-true}" == "true" ]; then
        if [ -d "${PVE_CONFIG_PATH}/firewall" ] && [ "$(ls -A "${PVE_CONFIG_PATH}/firewall" 2>/dev/null)" ]; then
            info "Collecting PVE firewall rules"
            safe_copy "${PVE_CONFIG_PATH}/firewall" "$TEMP_DIR${PVE_CONFIG_PATH}/firewall" "PVE firewall rules" "debug" "-r"
        elif [ -f "${PVE_CONFIG_PATH}/firewall" ]; then
            info "Collecting PVE firewall rules"
            safe_copy "${PVE_CONFIG_PATH}/firewall" "$TEMP_DIR${PVE_CONFIG_PATH}/firewall" "PVE firewall rules" "debug" "-r"
        else
            info "PVE firewall configuration not found (no rules configured) - skipping"
        fi
    else
        info "PVE firewall rules backup disabled"
    fi
    
    # Collect VM and Container configurations (configurable)
    if [ "${BACKUP_VM_CONFIGS:-true}" == "true" ]; then
        info "Collecting VM and container configurations"
        
        if [ -d "${PVE_CONFIG_PATH}/nodes" ]; then
            # Find all qemu VM configurations
            find "${PVE_CONFIG_PATH}/nodes" -path "*/qemu-server/*.conf" 2>/dev/null | while read vm_conf; do
                local target_dir="$TEMP_DIR/$(dirname "$vm_conf")"
                mkdir -p "$target_dir"
                safe_copy "$vm_conf" "$target_dir/$(basename "$vm_conf")" "VM configuration $(basename "$vm_conf")"
            done
            
            # Find all LXC container configurations
            find "${PVE_CONFIG_PATH}/nodes" -path "*/lxc/*.conf" 2>/dev/null | while read ct_conf; do
                local target_dir="$TEMP_DIR/$(dirname "$ct_conf")"
                mkdir -p "$target_dir"
                safe_copy "$ct_conf" "$target_dir/$(basename "$ct_conf")" "Container configuration $(basename "$ct_conf")"
            done
        else
            debug "PVE nodes directory not found: ${PVE_CONFIG_PATH}/nodes"
        fi
    else
        info "VM/Container configurations backup disabled"
    fi
    
    # Collect VZDump backup configuration (configurable)
    if [ "${BACKUP_VZDUMP_CONFIG:-true}" == "true" ]; then
        info "Collecting VZDump backup configuration"
        safe_copy "${VZDUMP_CONFIG_PATH}" "$TEMP_DIR/etc/vzdump.conf" "VZDump configuration"
    else
        info "VZDump configuration backup disabled"
    fi
    
    # Collect PVE version and system information
    mkdir -p "$TEMP_DIR${PVE_CLUSTER_PATH}/info"
    safe_command_output "pveversion" "$TEMP_DIR${PVE_CLUSTER_PATH}/info/pve_version.txt" "PVE version information"
    
    # Collect storage configuration
    # Use a compatibility approach for pvesm status command
    local storage_status_file="$TEMP_DIR${PVE_CLUSTER_PATH}/info/storage_status.json"
    if pvesm status --noborder --output-format=json >/dev/null 2>&1; then
        # Modern version with JSON support
        safe_command_output "pvesm status --noborder --output-format=json" "$storage_status_file" "storage status"
    else
        # Legacy version - convert standard output to JSON format
        info "Converting legacy pvesm status output to JSON format"
        if pvesm status >/dev/null 2>&1; then
            local temp_storage_file=$(mktemp)
            if pvesm status > "$temp_storage_file" 2>&1; then
                # Convert to JSON format
                {
                    echo "["
                    local first_entry=true
                    while IFS= read -r line; do
                        # Skip header and empty lines
                        if [[ "$line" =~ ^Name.*Type.*Status ]] || [[ -z "$line" ]]; then
                            continue
                        fi
                        
                        # Parse storage line
                        local storage_info=($line)
                        if [ ${#storage_info[@]} -ge 7 ]; then
                            local name="${storage_info[0]}"
                            local type="${storage_info[1]}"
                            local status="${storage_info[2]}"
                            local total="${storage_info[3]}"
                            local used="${storage_info[4]}"
                            local available="${storage_info[5]}"
                            local percent="${storage_info[6]}"
                            
                            # Add comma for subsequent entries
                            if [ "$first_entry" = false ]; then
                                echo ","
                            fi
                            first_entry=false
                            
                            # Create JSON entry
                            echo "  {"
                            echo "    \"storage\": \"$name\","
                            echo "    \"type\": \"$type\","
                            echo "    \"status\": \"$status\","
                            echo "    \"total\": \"$total\","
                            echo "    \"used\": \"$used\","
                            echo "    \"available\": \"$available\","
                            echo "    \"percent\": \"$percent\""
                            echo "  }"
                        fi
                    done < "$temp_storage_file"
                    echo "]"
                } > "$storage_status_file"
                
                debug "Successfully converted legacy pvesm status output to JSON"
                increment_file_counter "processed"
            else
                handle_collection_error "storage status" "command: pvesm status" "warning"
            fi
            rm -f "$temp_storage_file"
        else
            handle_collection_error "storage status" "command: pvesm status" "warning"
        fi
    fi
    
    # Collect datastore information using centralized detection
    if [ "${AUTO_DETECT_DATASTORES:-true}" == "true" ]; then
        info "Collecting PVE datastore information using auto-detection"
        mkdir -p "$TEMP_DIR${PVE_CLUSTER_PATH}/info/datastores"
        
        # Get detected PVE datastores
        local detected_pve_datastores
        mapfile -t detected_pve_datastores < <(get_datastores_by_type "PVE")
        
        if [ ${#detected_pve_datastores[@]} -gt 0 ]; then
            info "Found ${#detected_pve_datastores[@]} PVE datastore(s) via auto-detection"
            
            # Create summary of detected datastores
            local datastores_summary="$TEMP_DIR${PVE_CLUSTER_PATH}/info/datastores/detected_datastores.txt"
            {
                echo "# PVE Datastores detected on $(date)"
                echo "# Format: TYPE|NAME|PATH|COMMENT"
                echo ""
                for datastore_info in "${detected_pve_datastores[@]}"; do
                    echo "$datastore_info"
                done
                echo ""
                echo "# Total PVE datastores detected: ${#detected_pve_datastores[@]}"
            } > "$datastores_summary"
            
            # Process each detected PVE datastore for metadata collection
            for datastore_info in "${detected_pve_datastores[@]}"; do
                IFS='|' read -r sys_type ds_name ds_path ds_comment <<< "$datastore_info"
                
                debug "Processing PVE datastore: $ds_name -> $ds_path"
                
                # Create metadata for this datastore if accessible
                if [ -d "$ds_path" ]; then
                    local ds_metadata_dir="$TEMP_DIR${PVE_CLUSTER_PATH}/info/datastores/$ds_name"
                    mkdir -p "$ds_metadata_dir"
                    
                    # Collect basic information about the datastore
                    {
                        echo "# Datastore: $ds_name"
                        echo "# Path: $ds_path"
                        echo "# Type: $ds_comment"
                        echo "# Scanned on: $(date)"
                        echo ""
                        
                        # Directory structure (first 2 levels only for performance)
                        echo "## Directory Structure (max 2 levels):"
                        find "$ds_path" -maxdepth 2 -type d 2>/dev/null | head -20 || echo "# Error accessing directory structure"
                        echo ""
                        
                        # Disk usage summary
                        echo "## Disk Usage:"
                        du -sh "$ds_path" 2>/dev/null || echo "# Error getting disk usage"
                        echo ""
                        
                        # File type summary (sample)
                        echo "## File Types (sample):"
                        find "$ds_path" -maxdepth 3 -type f -name "*" 2>/dev/null | head -10 | while read file; do
                            echo "$(stat -c '%y %s %n' "$file" 2>/dev/null)" || true
                        done
                        
                    } > "$ds_metadata_dir/metadata.txt"
                    
                    # Detailed backup file analysis (similar to PBS .pxar analysis)
                    if [ "${BACKUP_PVE_BACKUP_FILES:-true}" == "true" ]; then
                        info "Analyzing PVE backup files in datastore: $ds_name"
                        mkdir -p "$ds_metadata_dir/backup_analysis"
                        
                        # PVE backup file patterns
                        local pve_backup_patterns=(
                            "*.vma"           # VM backups
                            "*.vma.gz"        # Compressed VM backups  
                            "*.vma.lz4"       # LZ4 compressed VM backups
                            "*.vma.zst"       # Zstandard compressed VM backups
                            "*.tar"           # Container backups
                            "*.tar.gz"        # Compressed container backups
                            "*.tar.lz4"       # LZ4 compressed container backups
                            "*.tar.zst"       # Zstandard compressed container backups
                            "*.log"           # Backup logs
                            "*.notes"         # Backup notes
                        )
                        
                        # Scan for each backup type
                        for pattern in "${pve_backup_patterns[@]}"; do
                            local pattern_clean="${pattern//\*/}"
                            local backup_list_file="$ds_metadata_dir/backup_analysis/${ds_name}_${pattern_clean}_list.txt"
                            
                            # Find backup files matching pattern
                            {
                                echo "# PVE backup files matching pattern: $pattern"
                                echo "# Datastore: $ds_name ($ds_path)"
                                echo "# Generated on: $(date)"
                                echo "# Format: permissions size date name"
                                echo ""
                                
                                local found_backups=0
                                while IFS= read -r backup_file; do
                                    if [ -f "$backup_file" ]; then
                                        ls -lh "$backup_file" 2>/dev/null && found_backups=$((found_backups + 1))
                                    fi
                                done < <(find "$ds_path" -name "$pattern" -type f 2>/dev/null)
                                
                                if [ "$found_backups" -eq 0 ]; then
                                    echo "# No backup files found matching pattern: $pattern"
                                else
                                    echo ""
                                    echo "# Total files found: $found_backups"
                                fi
                            } > "$backup_list_file"
                            
                            # Count found files for reporting
                            local count_backups=$(grep -v '^#' "$backup_list_file" | grep -v '^$' | wc -l)
                            if [ "$count_backups" -gt 0 ]; then
                                info "Found $count_backups backup files ($pattern_clean) in datastore: $ds_name"
                                increment_file_counter "processed"
                            fi
                        done
                        
                        # Create summary of all backup files
                        local backup_summary="$ds_metadata_dir/backup_analysis/${ds_name}_backup_summary.txt"
                        {
                            echo "# PVE Backup Files Summary for datastore: $ds_name"
                            echo "# Path: $ds_path"
                            echo "# Generated on: $(date)"
                            echo ""
                            
                            local total_backup_files=0
                            local total_backup_size=0
                            
                            for pattern in "${pve_backup_patterns[@]}"; do
                                echo "## Files matching pattern: $pattern"
                                local pattern_count=0
                                local pattern_size=0
                                
                                while IFS= read -r backup_file; do
                                    if [ -f "$backup_file" ]; then
                                        local file_size=$(stat -c%s "$backup_file" 2>/dev/null || echo "0")
                                        pattern_count=$((pattern_count + 1))
                                        pattern_size=$((pattern_size + file_size))
                                        total_backup_files=$((total_backup_files + 1))
                                        total_backup_size=$((total_backup_size + file_size))
                                    fi
                                done < <(find "$ds_path" -name "$pattern" -type f 2>/dev/null)
                                
                                if [ "$pattern_count" -gt 0 ]; then
                                    echo "  Files: $pattern_count"
                                    echo "  Total size: $(numfmt --to=iec $pattern_size 2>/dev/null || echo "${pattern_size} bytes")"
                                else
                                    echo "  No files found"
                                fi
                                echo ""
                            done
                            
                            echo "## Overall Summary"
                            echo "Total backup files: $total_backup_files"
                            echo "Total backup size: $(numfmt --to=iec $total_backup_size 2>/dev/null || echo "${total_backup_size} bytes")"
                            
                        } > "$backup_summary"
                        
                        # Optional: Copy small backup files (similar to PBS small .pxar)
                        if [ "${BACKUP_SMALL_PVE_BACKUPS:-false}" == "true" ] && [ -n "${MAX_PVE_BACKUP_SIZE:-}" ]; then
                            info "Looking for small PVE backup files in datastore $ds_name (max size: ${MAX_PVE_BACKUP_SIZE})"
                            
                            local small_backups_dir="$TEMP_DIR/var/lib/pve-cluster/small_backups/$ds_name"
                            mkdir -p "$small_backups_dir"
                            
                            local copied_count=0
                            for pattern in "${pve_backup_patterns[@]}"; do
                                while IFS= read -r small_backup; do
                                    if safe_copy "$small_backup" "$small_backups_dir/$(basename "$small_backup")" "small PVE backup $(basename "$small_backup")" "debug"; then
                                        copied_count=$((copied_count + 1))
                                    fi
                                done < <(find "$ds_path" -name "$pattern" -type f -size -${MAX_PVE_BACKUP_SIZE} 2>/dev/null)
                            done
                            
                            if [ $copied_count -gt 0 ]; then
                                info "Copied $copied_count small PVE backup files from datastore $ds_name"
                            fi
                        fi
                        
                        # Optional: Copy backup files matching specific pattern (similar to PBS pattern matching)
                        if [ -n "${PVE_BACKUP_INCLUDE_PATTERN:-}" ]; then
                            info "Searching for PVE backup files matching pattern: $PVE_BACKUP_INCLUDE_PATTERN in datastore $ds_name"
                            
                            local selected_backups_dir="$TEMP_DIR/var/lib/pve-cluster/selected_backups/$ds_name"
                            mkdir -p "$selected_backups_dir"
                            
                            local pattern_count=0
                            for pattern in "${pve_backup_patterns[@]}"; do
                                while IFS= read -r pattern_backup; do
                                    if safe_copy "$pattern_backup" "$selected_backups_dir/$(basename "$pattern_backup")" "pattern PVE backup $(basename "$pattern_backup")" "debug"; then
                                        pattern_count=$((pattern_count + 1))
                                    fi
                                done < <(find "$ds_path" -name "$pattern" -type f -path "*${PVE_BACKUP_INCLUDE_PATTERN}*" 2>/dev/null)
                            done
                            
                            if [ $pattern_count -gt 0 ]; then
                                info "Copied $pattern_count PVE backup files matching pattern from datastore $ds_name"
                            fi
                        fi
                        
                        success "Completed detailed backup file analysis for PVE datastore: $ds_name"
                    else
                        debug "PVE backup file analysis disabled for datastore: $ds_name"
                    fi
                    
                    increment_file_counter "processed"
                    debug "Created metadata for PVE datastore: $ds_name"
                else
                    debug "PVE datastore not accessible: $ds_name ($ds_path)"
                fi
            done
            
            success "Collected PVE datastore metadata for ${#detected_pve_datastores[@]} datastores"
        else
            info "No PVE datastores detected via auto-detection"
        fi
    else
        debug "Auto-detection disabled, skipping PVE datastore detection"
    fi
    
    # Collect user management information
    safe_command_output "pveum user list --output-format=json" "$TEMP_DIR${PVE_CLUSTER_PATH}/info/user_list.json" "user list"
    safe_command_output "pveum group list --output-format=json" "$TEMP_DIR${PVE_CLUSTER_PATH}/info/group_list.json" "group list"
    safe_command_output "pveum role list --output-format=json" "$TEMP_DIR${PVE_CLUSTER_PATH}/info/role_list.json" "role list"
    
    # Collect node status
    safe_command_output "pvesh get /nodes --output-format=json" "$TEMP_DIR${PVE_CLUSTER_PATH}/info/nodes_status.json" "node status"
    
    # Suggerimento 3: Raccolta informazioni sui job
    if [ "${BACKUP_PVE_JOBS:-true}" == "true" ]; then
        info "Collecting PVE backup job information"
        mkdir -p "$TEMP_DIR${PVE_CLUSTER_PATH}/info/jobs"
        
        # Collect backup job configurations
        safe_command_output "pvesh get /cluster/backup --output-format=json" "$TEMP_DIR${PVE_CLUSTER_PATH}/info/jobs/backup_jobs.json" "backup jobs"
        
        # Collect backup job status/history
        safe_command_output "pvesh get /nodes/localhost/tasks --output-format=json --typefilter=vzdump" "$TEMP_DIR${PVE_CLUSTER_PATH}/info/jobs/backup_history.json" "backup job history"
        
        # Collect storage backup schedules
        if [ -f "/etc/cron.d/vzdump" ]; then
            safe_copy "/etc/cron.d/vzdump" "$TEMP_DIR/etc/cron.d/vzdump" "VZDump cron schedule"
        fi
    else
        info "PVE backup job collection disabled"
    fi
    
    # Collect scheduled tasks and cron jobs
    if [ "${BACKUP_PVE_SCHEDULES:-true}" == "true" ]; then
        info "Collecting PVE scheduled tasks"
        mkdir -p "$TEMP_DIR${PVE_CLUSTER_PATH}/info/schedules"
        
        # Collect crontab information
        safe_command_output "crontab -l" "$TEMP_DIR${PVE_CLUSTER_PATH}/info/schedules/root_crontab.txt" "root crontab" "debug"
        
        # Collect system cron jobs
        if [ -d "/etc/cron.d" ]; then
            mkdir -p "$TEMP_DIR/etc/cron.d"
            find /etc/cron.d -name "*pve*" -o -name "*proxmox*" -o -name "*vzdump*" 2>/dev/null | while read cron_file; do
                safe_copy "$cron_file" "$TEMP_DIR$cron_file" "cron job $(basename "$cron_file")"
            done
        fi
        
        # Collect systemd timers related to PVE
        safe_command_output "systemctl list-timers --all --no-pager | grep -E '(pve|proxmox|vzdump)'" "$TEMP_DIR${PVE_CLUSTER_PATH}/info/schedules/systemd_timers.txt" "systemd timers" "debug"
    else
        info "PVE scheduled tasks collection disabled"
    fi
    
    # Collect replication job information
    if [ "${BACKUP_PVE_REPLICATION:-true}" == "true" ]; then
        info "Collecting PVE replication information"
        mkdir -p "$TEMP_DIR${PVE_CLUSTER_PATH}/info/replication"
        
        # Collect replication jobs
        safe_command_output "pvesh get /cluster/replication --output-format=json" "$TEMP_DIR${PVE_CLUSTER_PATH}/info/replication/replication_jobs.json" "replication jobs"
        
        # Collect replication status
        safe_command_output "pvesh get /nodes/localhost/replication --output-format=json" "$TEMP_DIR${PVE_CLUSTER_PATH}/info/replication/replication_status.json" "replication status"
    else
        info "PVE replication information collection disabled"
    fi
    
    # Collect Ceph configuration if available and enabled
    if [ "${BACKUP_CEPH_CONFIG:-true}" == "true" ]; then
        if is_ceph_configured; then
            info "Collecting Ceph configuration"
            mkdir -p "$TEMP_DIR${PVE_CLUSTER_PATH}/info/ceph"
            
            # Collect Ceph configuration files
            if [ -d "${CEPH_CONFIG_PATH}" ]; then
                safe_copy "${CEPH_CONFIG_PATH}" "$TEMP_DIR${CEPH_CONFIG_PATH}" "Ceph configuration files" "warning" "-r"
            fi
            
            # Collect Ceph status information
            safe_command_output "ceph -s" "$TEMP_DIR${PVE_CLUSTER_PATH}/info/ceph/ceph_status.txt" "Ceph status"
            safe_command_output "ceph osd df" "$TEMP_DIR${PVE_CLUSTER_PATH}/info/ceph/ceph_osd_df.txt" "Ceph OSD DF"
            safe_command_output "ceph osd tree" "$TEMP_DIR${PVE_CLUSTER_PATH}/info/ceph/ceph_osd_tree.txt" "Ceph OSD tree"
            safe_command_output "ceph mon stat" "$TEMP_DIR${PVE_CLUSTER_PATH}/info/ceph/ceph_mon_stat.txt" "Ceph mon stat"
            safe_command_output "ceph pg stat" "$TEMP_DIR${PVE_CLUSTER_PATH}/info/ceph/ceph_pg_stat.txt" "Ceph PG stat"
            safe_command_output "ceph health detail" "$TEMP_DIR${PVE_CLUSTER_PATH}/info/ceph/ceph_health.txt" "Ceph health"
        else
            info "Ceph not configured in PVE system - skipping Ceph configuration collection"
        fi
    else
        info "Ceph configuration collection disabled"
    fi
    
    # Log metrics for PVE collection
    local operation_end=$(date +%s)
    log_operation_metrics "pve_config_collection" "$operation_start" "$operation_end" "$BACKUP_FILES_PROCESSED" "$BACKUP_FILES_FAILED"
    
    success "PVE configuration collected successfully with enhanced features"
    return $EXIT_SUCCESS
}

# Collect PBS-specific configuration
collect_pbs_configs() {
    step "Collecting PBS configuration files with enhanced error handling"
    
    local operation_start=$(date +%s)
    local local_files_processed=0
    local local_files_failed=0
    
    # Create necessary directories preserving original structure
    mkdir -p "$TEMP_DIR/etc/proxmox-backup" && increment_file_counter "dirs"
    mkdir -p "$TEMP_DIR/var/lib/proxmox-backup" && increment_file_counter "dirs"
    
    # Collect configuration files using original paths with unified error handling
    if [ -d "/etc/proxmox-backup" ]; then
        info "Collecting /etc/proxmox-backup configuration files"
        safe_copy "/etc/proxmox-backup" "$TEMP_DIR/etc/proxmox-backup" "PBS configuration files" "warning" "-r"
        
        # Specific handling for remote.cfg when disabled (Suggerimento 1: gestione file sensibili)
        if [ "${BACKUP_REMOTE_CFG:-true}" == "false" ] && [ -f "$TEMP_DIR/etc/proxmox-backup/remote.cfg" ]; then
            info "Removing remote.cfg from backup as per configuration"
            rm -f "$TEMP_DIR/etc/proxmox-backup/remote.cfg"
        fi
    else
        handle_collection_error "PBS configuration directory" "/etc/proxmox-backup" "warning" "directory not found"
    fi
    
    # Collect PBS information using commands with unified error handling
    info "Collecting PBS system information"
    safe_command_output "proxmox-backup-manager version" "$TEMP_DIR/var/lib/proxmox-backup/version.txt" "PBS version information"
    safe_command_output "proxmox-backup-manager datastore list --output-format=json" "$TEMP_DIR/var/lib/proxmox-backup/datastore_list.json" "datastore list"
    safe_command_output "proxmox-backup-manager user list --output-format=json" "$TEMP_DIR/var/lib/proxmox-backup/user_list.json" "user list"
    safe_command_output "proxmox-backup-manager acl list --output-format=json" "$TEMP_DIR/var/lib/proxmox-backup/acl_list.json" "ACL list"
    safe_command_output "proxmox-backup-manager remote list --output-format=json" "$TEMP_DIR/var/lib/proxmox-backup/remote_list.json" "remote list"
    
    # Collect job information (equivalent to PVE job collection)
    info "Collecting PBS job configurations"
    safe_command_output "proxmox-backup-manager sync-job list --output-format=json" "$TEMP_DIR/var/lib/proxmox-backup/sync_jobs.json" "sync jobs"
    safe_command_output "proxmox-backup-manager verify-job list --output-format=json" "$TEMP_DIR/var/lib/proxmox-backup/verify_jobs.json" "verification jobs"
    safe_command_output "proxmox-backup-manager prune-job list --output-format=json" "$TEMP_DIR/var/lib/proxmox-backup/prune_jobs.json" "prune jobs"
    safe_command_output "proxmox-backup-manager cert info" "$TEMP_DIR/var/lib/proxmox-backup/cert_info.txt" "certificate information"
    
    # Selective backup of critical .pxar files with enhanced error handling
    local pxar_success=true
    if [ "${BACKUP_PXAR_FILES:-false}" == "true" ]; then
        info "Collecting .pxar file metadata with enhanced processing using auto-detection"
        
        # Directory where to save the list and metadata
        mkdir -p "$TEMP_DIR/var/lib/proxmox-backup/pxar_metadata"
        
        # Use centralized datastore detection instead of manual path
        local detected_datastores
        mapfile -t detected_datastores < <(get_datastores_by_type "PBS")
        
        if [ ${#detected_datastores[@]} -eq 0 ]; then
            # Fallback to manual configuration if no PBS datastores detected
            warning "No PBS datastores auto-detected, checking manual configuration"
            if [ -n "${PBS_DATASTORE_PATH:-}" ]; then
                info "Using manual PBS_DATASTORE_PATH: $PBS_DATASTORE_PATH"
                detected_datastores=("PBS|manual|$PBS_DATASTORE_PATH|Manual configuration")
            else
                info "Using default fallback path"
                detected_datastores=("PBS|fallback|/var/lib/proxmox-backup/datastore|Default fallback")
            fi
        else
            info "Found ${#detected_datastores[@]} PBS datastore(s) via auto-detection"
        fi
        
        # Process each detected PBS datastore
        for datastore_info in "${detected_datastores[@]}"; do
            IFS='|' read -r sys_type ds_name datastore_base_path ds_comment <<< "$datastore_info"
            
            info "Processing PBS datastore: $ds_name -> $datastore_base_path"
            
            # Create a list of all .pxar files for this datastore
            if [ -d "$datastore_base_path" ]; then
                # Create the file with datastore subdirectories list
                local datastore_file="$TEMP_DIR/var/lib/proxmox-backup/pxar_metadata/${ds_name}_subdirs.txt"
                
                # Write the list directly to file using safe method
                if ! {
                    echo "# Datastore subdirectories in $datastore_base_path generated on $(date)"
                    echo "# Datastore: $ds_name ($ds_comment)"
                    ls -1 "$datastore_base_path/" 2>/dev/null || echo "# Error reading datastore subdirectories"
                } > "$datastore_file"; then
                    handle_collection_error "datastore subdirectories list creation" "$datastore_file" "warning"
                    pxar_success=false
                    continue
                fi
                
                # Check that the file was created correctly
                if [ ! -f "$datastore_file" ] || [ -L "$datastore_file" ]; then
                    handle_collection_error "datastore subdirectories file validation" "$datastore_file" "warning" "not a regular file"
                    touch "$datastore_file"
                    echo "# Error creating datastore subdirectories list" > "$datastore_file"
                    pxar_success=false
                    continue
                fi
                
                # Read datastore subdirectories list for processing
                local datastore_list=$(grep -v '^#' "$datastore_file" 2>/dev/null)
                
                # For each subdirectory in the datastore, create a list of .pxar files
                for subdir in $datastore_list; do
                    local subdir_path="$datastore_base_path/$subdir"
                    if [ -d "$subdir_path" ]; then
                        debug "Scanning datastore subdirectory: $ds_name/$subdir"
                        
                        # Save information about .pxar files but not the files themselves
                        local pxar_list_file="$TEMP_DIR/var/lib/proxmox-backup/pxar_metadata/${ds_name}_${subdir}_pxar_list.txt"
                        
                        # Enhanced method with error handling
                        if ! {
                            echo "# List of .pxar files in $subdir_path generated on $(date)"
                            echo "# Datastore: $ds_name, Subdirectory: $subdir"
                            echo "# Format: permissions size date name"
                            
                            # Find .pxar files and write them one by one to file
                            found_pxar=0
                            while IFS= read -r pxar_file; do
                                if [ -f "$pxar_file" ]; then
                                    ls -lh "$pxar_file" 2>/dev/null && found_pxar=$((found_pxar + 1))
                                fi
                            done < <(find "$subdir_path" -name "*.pxar" -type f 2>/dev/null)
                            
                            # If no files were found, add a note
                            if [ "$found_pxar" -eq 0 ]; then
                                echo "# No .pxar files found"
                            else
                                echo "# Total: $found_pxar files"
                            fi
                        } > "$pxar_list_file"; then
                            handle_collection_error ".pxar file list creation" "$pxar_list_file" "warning"
                            pxar_success=false
                            continue
                        fi
                        
                        # Check that the file was created correctly
                        if [ ! -f "$pxar_list_file" ] || [ -L "$pxar_list_file" ]; then
                            handle_collection_error ".pxar file list validation" "$pxar_list_file" "warning" "not a regular file"
                            touch "$pxar_list_file"
                            echo "# Error creating list" > "$pxar_list_file"
                            pxar_success=false
                            continue
                        fi
                        
                        # Verify count of found files
                        local count_pxar=$(grep -v '^#' "$pxar_list_file" | wc -l)
                        if [ "$count_pxar" -eq 0 ]; then
                            debug "No .pxar files found in datastore: $ds_name/$subdir"
                        else
                            info "Found $count_pxar .pxar files in datastore: $ds_name/$subdir"
                            increment_file_counter "processed"
                        fi
                        
                        # If backup of small .pxar files is enabled
                        if [ "${BACKUP_SMALL_PXAR:-false}" == "true" ] && [ -n "${MAX_PXAR_SIZE:-}" ]; then
                            debug "Looking for small .pxar files in datastore $ds_name/$subdir (max size: ${MAX_PXAR_SIZE})"
                            
                            # Destination directory for small .pxar files
                            local small_pxar_dir="$TEMP_DIR/var/lib/proxmox-backup/small_pxar/${ds_name}/${subdir}"
                            mkdir -p "$small_pxar_dir"
                            
                            # Find and copy only .pxar files under maximum size with error handling
                            local copied_count=0
                            while IFS= read -r small_pxar; do
                                if safe_copy "$small_pxar" "$small_pxar_dir/$(basename "$small_pxar")" "small .pxar file $(basename "$small_pxar")" "debug"; then
                                    copied_count=$((copied_count + 1))
                                fi
                            done < <(find "$subdir_path" -name "*.pxar" -type f -size -${MAX_PXAR_SIZE} 2>/dev/null)
                            
                            if [ $copied_count -gt 0 ]; then
                                info "Copied $copied_count small .pxar files from datastore $ds_name/$subdir"
                            fi
                        fi
                        
                        # If a pattern of .pxar files to include is specified
                        if [ -n "${PXAR_INCLUDE_PATTERN:-}" ]; then
                            debug "Searching for .pxar files matching pattern: $PXAR_INCLUDE_PATTERN in datastore $ds_name/$subdir"
                            
                            # Destination directory for selected .pxar files
                            local selected_pxar_dir="$TEMP_DIR/var/lib/proxmox-backup/selected_pxar/${ds_name}/${subdir}"
                            mkdir -p "$selected_pxar_dir"
                            
                            # Find and copy only .pxar files that match the pattern with error handling
                            local pattern_count=0
                            while IFS= read -r pattern_pxar; do
                                if safe_copy "$pattern_pxar" "$selected_pxar_dir/$(basename "$pattern_pxar")" "pattern .pxar file $(basename "$pattern_pxar")" "debug"; then
                                    pattern_count=$((pattern_count + 1))
                                fi
                            done < <(find "$subdir_path" -name "*.pxar" -type f -path "*${PXAR_INCLUDE_PATTERN}*" 2>/dev/null)
                            
                            if [ $pattern_count -gt 0 ]; then
                                info "Copied $pattern_count .pxar files matching pattern from datastore $ds_name/$subdir"
                            fi
                        fi
                    else
                        debug "Datastore subdirectory not accessible: $subdir_path"
                    fi
                done
                
            else
                handle_collection_error "datastore base directory" "$datastore_base_path" "warning" "directory not found for datastore: $ds_name"
                pxar_success=false
            fi
        done
        
        if [ "$pxar_success" = true ]; then
            success "Collected .pxar file metadata successfully using auto-detection"
        else
            warning "Collected .pxar file metadata with some errors"
        fi
    else
        debug "Backup of .pxar files is disabled"
        pxar_success=true  # Consider as success if the feature is disabled
    fi
    
    # Log metrics for PBS collection
    local operation_end=$(date +%s)
    log_operation_metrics "pbs_config_collection" "$operation_start" "$operation_end" "$BACKUP_FILES_PROCESSED" "$BACKUP_FILES_FAILED"
    
    # Report success only if all essential parts have succeeded (Suggerimento 4: gestione errori unificata)
    if [ "$pxar_success" = true ]; then
        success "PBS configuration collected successfully with enhanced error handling"
        return $EXIT_SUCCESS
    else
        warning "PBS configuration collected with warnings about .pxar files"
        return $EXIT_WARNING
    fi
}

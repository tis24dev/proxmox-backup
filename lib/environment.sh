#!/bin/bash
# ==========================================
# PROXMOX BACKUP ENVIRONMENT SETUP MODULE
# ==========================================
#
# This module provides environment setup and verification functions for
# the Proxmox backup system. It handles environment file validation,
# Proxmox type detection, directory structure setup, and configuration
# variable validation.
#
# Features:
# - Secure environment file loading with ownership/permission checks
# - Automatic Proxmox type detection (PVE/PBS) with version checking
# - Directory structure creation with fallback mechanisms
# - Comprehensive boolean variable validation
# - Unified error and warning handling
# - Integration with metrics and notification systems
#
# Dependencies:
# - stat: For file ownership and permission checking
# - mktemp: For secure temporary directory creation
# - pveversion: For PVE version detection (optional)
# - proxmox-backup-manager: For PBS version detection (optional)
#
# Global Variables Used:
# - ENV_FILE: Path to environment configuration file
# - PROXMOX_TYPE: Detected Proxmox type (pve/pbs)
# - PROXMOX_VERSION: Detected Proxmox version
# - LOCAL_BACKUP_PATH, SECONDARY_BACKUP_PATH: Backup storage paths
# - LOCAL_LOG_PATH, SECONDARY_LOG_PATH: Log storage paths
# - TEMP_DIR: Temporary directory for operations
# - Various boolean configuration variables
#
# Exit Codes:
# - 0: Success
# - 1: Error (EXIT_ERROR)
#
# Author: Proxmox Backup System

# Last Modified: $(date +%Y-%m-%d)
# ==========================================

# Check environment file
check_env_file() {
    step "Checking environment file: $ENV_FILE"
    
    if [ ! -f "$ENV_FILE" ]; then
        error "Environment file not found: $ENV_FILE"
        set_exit_code "error"
        exit $EXIT_ERROR
    fi
    
    # Check file ownership
    owner=$(stat -c '%U' "$ENV_FILE")
    if [ "$owner" != "root" ]; then
        error "Environment file must be owned by root (currently: $owner)"
        set_exit_code "error"
        exit $EXIT_ERROR
    fi
    
    # Check file permissions
    perms=$(stat -c '%a' "$ENV_FILE")
    if [ "$perms" != "400" ]; then
        error "Environment file must have 400 permissions (currently: $perms)"
        set_exit_code "error"
        exit $EXIT_ERROR
    fi
    
    # Source the environment file
    source "$ENV_FILE"
    debug "Environment file loaded successfully"
    success "Environment file loaded successfully"
}

# Debug function to log system state when detection fails
log_detection_failure_debug() {
    local detection_timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local debug_log="/tmp/proxmox_detection_debug_$(date +%s).log"
    
    {
        echo "=== Proxmox Detection Failure Debug - $detection_timestamp ==="
        echo "Current PATH: $PATH"
        echo "Current USER: $(whoami)"
        echo "Current PWD: $(pwd)"
        echo "Shell: $SHELL"
        echo ""
        
        echo "=== Command availability check ==="
        echo "which pveversion: $(which pveversion 2>/dev/null || echo 'NOT FOUND')"
        echo "which proxmox-backup-manager: $(which proxmox-backup-manager 2>/dev/null || echo 'NOT FOUND')"
        echo "command -v pveversion: $(command -v pveversion 2>/dev/null || echo 'NOT FOUND')"
        echo "command -v proxmox-backup-manager: $(command -v proxmox-backup-manager 2>/dev/null || echo 'NOT FOUND')"
        echo ""
        
        echo "=== File existence check ==="
        echo "/usr/bin/pveversion exists: $([ -f /usr/bin/pveversion ] && echo 'YES' || echo 'NO')"
        echo "/usr/bin/pveversion executable: $([ -x /usr/bin/pveversion ] && echo 'YES' || echo 'NO')"
        echo "/usr/sbin/pveversion exists: $([ -f /usr/sbin/pveversion ] && echo 'YES' || echo 'NO')"
        echo "/usr/sbin/pveversion executable: $([ -x /usr/sbin/pveversion ] && echo 'YES' || echo 'NO')"
        echo "/usr/bin/proxmox-backup-manager exists: $([ -f /usr/bin/proxmox-backup-manager ] && echo 'YES' || echo 'NO')"
        echo "/usr/bin/proxmox-backup-manager executable: $([ -x /usr/bin/proxmox-backup-manager ] && echo 'YES' || echo 'NO')"
        echo ""
        
        echo "=== Directory existence check ==="
        echo "/etc/pve exists: $([ -d /etc/pve ] && echo 'YES' || echo 'NO')"
        echo "/var/lib/pve-cluster exists: $([ -d /var/lib/pve-cluster ] && echo 'YES' || echo 'NO')"
        echo "/etc/proxmox-backup exists: $([ -d /etc/proxmox-backup ] && echo 'YES' || echo 'NO')"
        echo "/var/lib/proxmox-backup exists: $([ -d /var/lib/proxmox-backup ] && echo 'YES' || echo 'NO')"
        echo ""
        
        echo "=== Version file check ==="
        echo "/etc/pve/pve.version exists: $([ -f /etc/pve/pve.version ] && echo 'YES' || echo 'NO')"
        echo "/etc/pve/pve.version readable: $([ -r /etc/pve/pve.version ] && echo 'YES' || echo 'NO')"
        if [ -f /etc/pve/pve.version ]; then
            echo "/etc/pve/pve.version content: $(cat /etc/pve/pve.version 2>/dev/null || echo 'UNREADABLE')"
        fi
        echo ""
        
        echo "=== APT source files check ==="
        echo "/etc/apt/sources.list.d/pbs.list exists: $([ -f /etc/apt/sources.list.d/pbs.list ] && echo 'YES' || echo 'NO')"
        echo "/etc/apt/sources.list.d/proxmox.list exists: $([ -f /etc/apt/sources.list.d/proxmox.list ] && echo 'YES' || echo 'NO')"
        if [ -f /etc/apt/sources.list.d/pbs.list ]; then
            echo "/etc/apt/sources.list.d/pbs.list content: $(cat /etc/apt/sources.list.d/pbs.list 2>/dev/null || echo 'UNREADABLE')"
        fi
        if [ -f /etc/apt/sources.list.d/proxmox.list ]; then
            echo "/etc/apt/sources.list.d/proxmox.list content: $(cat /etc/apt/sources.list.d/proxmox.list 2>/dev/null || echo 'UNREADABLE')"
        fi
        echo ""
        
        echo "=== System info ==="
        echo "Load average: $(uptime 2>/dev/null || echo 'UNKNOWN')"
        echo "Memory usage: $(free -m 2>/dev/null | grep '^Mem:' | awk '{print $3"MB/"$2"MB"}' || echo 'UNKNOWN')"
        echo "Disk space /: $(df -h / 2>/dev/null | tail -1 | awk '{print $4" available"}' || echo 'UNKNOWN')"
        echo "=== End Debug ==="
    } > "$debug_log"
    
    error "Proxmox detection failed. Debug info saved to: $debug_log"
    # Also log to stderr for immediate visibility
    cat "$debug_log" >&2
}

# Proxmox detection with optimized logic
check_proxmox_type() {
    step "Detecting Proxmox installation type"
    
    # Initialize variables
    PROXMOX_VERSION=""
    PROXMOX_TYPE=""
    
    # Ensure proper PATH for crontab execution
    # Common paths where Proxmox binaries are located
    local additional_paths="/usr/bin:/usr/sbin:/bin:/sbin"
    if [[ ":$PATH:" != *":$additional_paths:"* ]]; then
        export PATH="$PATH:$additional_paths"
        debug "Extended PATH for Proxmox detection: $PATH"
    fi
    
    # Primary detection methods with multiple fallbacks
    debug "Starting Proxmox type detection with multiple methods"
    
    # Method 1: Check for pveversion command
    local pve_detected=false
    if command -v pveversion >/dev/null 2>&1; then
        debug "Found pveversion command via which"
        pve_detected=true
    elif [ -x "/usr/bin/pveversion" ]; then
        debug "Found pveversion at /usr/bin/pveversion"
        pve_detected=true
    elif [ -x "/usr/sbin/pveversion" ]; then
        debug "Found pveversion at /usr/sbin/pveversion"
        pve_detected=true
    fi
    
    if [ "$pve_detected" = true ]; then
        # Proxmox Virtual Environment detected
        PROXMOX_TYPE="pve"
        # Try multiple methods to get version
        if command -v pveversion >/dev/null 2>&1; then
            # Parse version from format: "pve-manager/X.Y.Z (running ..."
            PROXMOX_VERSION=$(timeout 10 pveversion 2>/dev/null | head -n1 | grep -oP 'pve-manager/\K[0-9]+\.[0-9]+(\.[0-9]+)?(\-[0-9]+)?' 2>/dev/null || echo "unknown")
        elif [ -x "/usr/bin/pveversion" ]; then
            PROXMOX_VERSION=$(timeout 10 /usr/bin/pveversion 2>/dev/null | head -n1 | grep -oP 'pve-manager/\K[0-9]+\.[0-9]+(\.[0-9]+)?(\-[0-9]+)?' 2>/dev/null || echo "unknown")
        else
            PROXMOX_VERSION="unknown"
        fi
        success "Detected Proxmox Virtual Environment (PVE) version $PROXMOX_VERSION"
        
        # Version compatibility check
        if validate_proxmox_version "$PROXMOX_VERSION" "PVE"; then
            if version_compare "$PROXMOX_VERSION" "<" "6.0"; then
                warning "Running on an older version of PVE ($PROXMOX_VERSION). Some features may not work correctly."
            fi
        fi
        
    else
        # Method 2: Check for proxmox-backup-manager command
        local pbs_detected=false
        if command -v proxmox-backup-manager >/dev/null 2>&1; then
            debug "Found proxmox-backup-manager command via which"
            pbs_detected=true
        elif [ -x "/usr/bin/proxmox-backup-manager" ]; then
            debug "Found proxmox-backup-manager at /usr/bin/proxmox-backup-manager"
            pbs_detected=true
        elif [ -x "/usr/sbin/proxmox-backup-manager" ]; then
            debug "Found proxmox-backup-manager at /usr/sbin/proxmox-backup-manager"
            pbs_detected=true
        fi
        
        if [ "$pbs_detected" = true ]; then
            # Proxmox Backup Server detected
            PROXMOX_TYPE="pbs"
            # Try multiple methods to get version
            if command -v proxmox-backup-manager >/dev/null 2>&1; then
                PROXMOX_VERSION=$(timeout 10 proxmox-backup-manager version 2>/dev/null | grep -oP 'version: \K.*' 2>/dev/null || echo "unknown")
            elif [ -x "/usr/bin/proxmox-backup-manager" ]; then
                PROXMOX_VERSION=$(timeout 10 /usr/bin/proxmox-backup-manager version 2>/dev/null | grep -oP 'version: \K.*' 2>/dev/null || echo "unknown")
            else
                PROXMOX_VERSION="unknown"
            fi
            success "Detected Proxmox Backup Server (PBS) version $PROXMOX_VERSION"
            
            # Version compatibility check
            if validate_proxmox_version "$PROXMOX_VERSION" "PBS"; then
                if version_compare "$PROXMOX_VERSION" "<" "2.0"; then
                    warning "Running on an older version of PBS ($PROXMOX_VERSION). Some features may not work correctly."
                fi
            fi
            
        else
            # Method 3: Fallback detection methods
            debug "Command-based detection failed, trying file-based detection"
            if [ -f "/etc/pve/pve.version" ] && [ -r "/etc/pve/pve.version" ]; then
                PROXMOX_TYPE="pve"
                PROXMOX_VERSION=$(cat /etc/pve/pve.version 2>/dev/null | grep -oP 'pve\-manager\/\K[0-9\.\-]+' 2>/dev/null || echo "unknown")
                warning "Detected PVE from /etc/pve/pve.version (version $PROXMOX_VERSION)"
                
            elif [ -f "/etc/apt/sources.list.d/pbs.list" ] || [ -f "/etc/apt/sources.list.d/proxmox.list" ]; then
                # Check content of sources files to be more specific
                if grep -q "pbs" /etc/apt/sources.list.d/pbs.list 2>/dev/null || \
                   grep -q "proxmox-backup" /etc/apt/sources.list.d/proxmox.list 2>/dev/null; then
                    PROXMOX_TYPE="pbs"
                    PROXMOX_VERSION="unknown"
                    warning "Detected PBS from source list, but couldn't determine version"
                elif grep -q "pve" /etc/apt/sources.list.d/proxmox.list 2>/dev/null; then
                    PROXMOX_TYPE="pve"
                    PROXMOX_VERSION="unknown"
                    warning "Detected PVE from source list, but couldn't determine version"
                fi
                
            # Method 4: Final fallback - check for typical PVE/PBS directories
            elif [ -d "/etc/pve" ] && [ -d "/var/lib/pve-cluster" ]; then
                PROXMOX_TYPE="pve"
                PROXMOX_VERSION="unknown"
                warning "Detected PVE from directory structure, but couldn't determine version"
                
            elif [ -d "/etc/proxmox-backup" ] || [ -d "/var/lib/proxmox-backup" ]; then
                PROXMOX_TYPE="pbs"
                PROXMOX_VERSION="unknown"
                warning "Detected PBS from directory structure, but couldn't determine version"
                
            else
                error "No Proxmox installation detected. This script requires PVE or PBS."
                error "Please ensure you're running this on a Proxmox system."
                error "Debug info: PATH=$PATH"
                error "Commands checked: pveversion, proxmox-backup-manager"
                error "Files checked: /etc/pve/pve.version, /etc/apt/sources.list.d/pbs.list"
                error "Directories checked: /etc/pve, /var/lib/pve-cluster, /etc/proxmox-backup"
                log_detection_failure_debug
                exit 1
            fi
        fi
    fi
    
    # Validate detection result
    if [ -z "$PROXMOX_TYPE" ] || [ "$PROXMOX_TYPE" = "unknown" ]; then
        error "Failed to detect Proxmox type. Detection returned: '$PROXMOX_TYPE'"
        error "This should not happen. Please check system configuration."
        exit 1
    fi
    
    # Export version information for Prometheus metrics
    if [ "${PROMETHEUS_ENABLED:-false}" == "true" ] && [ -n "$METRICS_FILE" ]; then
        {
            echo "# HELP proxmox_version Version of proxmox installation"
            echo "# TYPE proxmox_version gauge"
            echo "proxmox_version{type=\"$PROXMOX_TYPE\",version=\"$PROXMOX_VERSION\"} 1"
        } >> "$METRICS_FILE"
    fi
    
    # Log final detection result
    debug "Proxmox detection completed: Type=$PROXMOX_TYPE, Version=$PROXMOX_VERSION"
    info "Successfully detected: $PROXMOX_TYPE ($PROXMOX_VERSION)"
}

# Helper function to validate Proxmox version format
validate_proxmox_version() {
    local version="$1"
    local type="$2"
    
    if [ "$version" == "unknown" ] || [ -z "$version" ]; then
        return 1
    fi
    
    # Basic version format validation (x.y or x.y.z or x.y-z)
    if [[ "$version" =~ ^[0-9]+\.[0-9]+([.-][0-9]+)*$ ]]; then
        return 0
    else
        warning "Invalid version format detected for $type: $version"
        return 1
    fi
}

# Helper function to compare version numbers
version_compare() {
    local version1="$1"
    local operator="$2"
    local version2="$3"
    
    # Simple version comparison (works for most cases)
    if [ "$operator" == "<" ]; then
        [ "$(printf '%s\n' "$version1" "$version2" | sort -V | head -n1)" == "$version1" ] && [ "$version1" != "$version2" ]
    elif [ "$operator" == ">" ]; then
        [ "$(printf '%s\n' "$version1" "$version2" | sort -V | tail -n1)" == "$version1" ] && [ "$version1" != "$version2" ]
    elif [ "$operator" == "==" ]; then
        [ "$version1" == "$version2" ]
    else
        return 1
    fi
}

# Check required variables
check_required_variables() {
    local missing_vars=()
    
    # Compression variables
    : "${COMPRESSION_TYPE:=zstd}"      # Default to zstd if not defined
    : "${COMPRESSION_LEVEL:=3}"        # Default to 3 if not defined
    : "${COMPRESSION_MODE:=standard}"  # Default to standard if not defined
    : "${COMPRESSION_THREADS:=0}"      # Default to 0 (auto) if not defined
    : "${ENABLE_SMART_CHUNKING:=false}" # Default to false if not defined
    : "${ENABLE_DEDUPLICATION:=false}"  # Default to false if not defined
    : "${ENABLE_PREFILTER:=false}"      # Default to false if not defined
    
    # Other required variables
    : "${AUTO_INSTALL_DEPENDENCIES:=false}"
    : "${BACKUP_NETWORK_CONFIG:=true}"
    : "${BACKUP_CRONTABS:=true}"
    : "${BACKUP_ZFS_CONFIG:=true}"
    : "${BACKUP_INSTALLED_PACKAGES:=true}"
    : "${BACKUP_SCRIPT_DIR:=true}"
    : "${BACKUP_CRITICAL_FILES:=true}"
    
    # Check if any variable is empty after default assignment
    for var in COMPRESSION_TYPE COMPRESSION_LEVEL COMPRESSION_MODE COMPRESSION_THREADS \
              ENABLE_SMART_CHUNKING ENABLE_DEDUPLICATION ENABLE_PREFILTER \
              AUTO_INSTALL_DEPENDENCIES BACKUP_NETWORK_CONFIG BACKUP_CRONTABS \
              BACKUP_ZFS_CONFIG BACKUP_INSTALLED_PACKAGES BACKUP_SCRIPT_DIR BACKUP_CRITICAL_FILES; do
        if [ -z "${!var}" ]; then
            missing_vars+=("$var")
        fi
    done
    
    if [ ${#missing_vars[@]} -gt 0 ]; then
        error "The following required variables are not defined in the env file:"
        for var in "${missing_vars[@]}"; do
            error "- $var"
        done
        exit $EXIT_ERROR
    fi
    
    info "All required variables are defined correctly"
    return $EXIT_SUCCESS
}

# Setup directory structure
setup_dirs() {
    step "Setting up directory structure"
    
    # Create all required local directories
    mkdir -p "$LOCAL_BACKUP_PATH" "$LOCAL_LOG_PATH" || {
        error "Failed to create local directories. Check permissions."
        exit 1
    }
    
    # Create secondary backup directories if secondary backup is enabled and parent directory exists
    if [ "${ENABLE_SECONDARY_BACKUP:-true}" = "true" ]; then
        if [ -n "$SECONDARY_BACKUP_PATH" ] && [ -d "$(dirname "$SECONDARY_BACKUP_PATH")" ]; then
            mkdir -p "$SECONDARY_BACKUP_PATH" "$SECONDARY_LOG_PATH" || {
                warning "Failed to create secondary directories. Secondary backup may fail."
            }
        elif [ -n "$SECONDARY_BACKUP_PATH" ]; then
            warning "Secondary backup parent directory doesn't exist. Secondary backup may fail."
        else
            debug "Secondary backup path not configured, skipping secondary directory creation"
        fi
    else
        debug "Secondary backup is disabled, skipping secondary directory creation"
    fi
    
    # Set up temporary directory using a predictable naming pattern
    TEMP_DIR="/tmp/proxmox-backup-${PROXMOX_TYPE:-unknown}-${TIMESTAMP}-$$"
    export TEMP_DIR
    debug "Creating temporary directory: $TEMP_DIR"
    
    mkdir -p "$TEMP_DIR" || {
        error "Failed to create temporary directory: $TEMP_DIR"
        exit 1
    }
    
    debug "Created temporary directory: $TEMP_DIR"
    
    success "Directory structure setup completed"
}

# Set default values for various configuration options
initialize_defaults() {
    # Set default values for booleans
    : "${DEBUG_LEVEL:=standard}"
    
    # Security Settings
    : "${ABORT_ON_SECURITY_ISSUES:=false}"
    : "${AUTO_UPDATE_HASHES:=false}"
    : "${REMOVE_UNAUTHORIZED_FILES:=false}"
    : "${CHECK_NETWORK_SECURITY:=false}"
    : "${CHECK_FIREWALL:=false}"
    : "${CHECK_OPEN_PORTS:=false}"
    
    # Backup options
    : "${BACKUP_CRONTABS:=true}"
    : "${BACKUP_NETWORK_CONFIG:=true}"
    : "${BACKUP_ZFS_CONFIG:=true}"
    : "${BACKUP_INSTALLED_PACKAGES:=true}"
    : "${BACKUP_SCRIPT_DIR:=true}"
    : "${BACKUP_CRITICAL_FILES:=true}"
    
    # Additional configuration defaults
    : "${SECONDARY_BACKUP_REQUIRED:=false}"
    : "${CLOUD_BACKUP_REQUIRED:=false}"
    : "${CHECK_ONLY_MODE:=false}"
    : "${DRY_RUN_MODE:=false}"
    : "${PROMETHEUS_ENABLED:=false}"
    : "${TELEGRAM_ENABLED:=false}"
    : "${EMAIL_ENABLED:=false}"
    : "${SMTP_USE_TLS:=true}"
    : "${SET_BACKUP_PERMISSIONS:=true}"
    : "${MULTI_STORAGE_PARALLEL:=false}"
    
    debug "Default values initialized successfully"
}

# Validate boolean values
validate_boolean_vars() {
    debug "Validating boolean configuration values"
    
    local -a boolean_vars=(
        ABORT_ON_SECURITY_ISSUES AUTO_UPDATE_HASHES REMOVE_UNAUTHORIZED_FILES 
        CHECK_NETWORK_SECURITY CHECK_FIREWALL CHECK_OPEN_PORTS 
        SECONDARY_BACKUP_REQUIRED CLOUD_BACKUP_REQUIRED 
        AUTO_INSTALL_DEPENDENCIES CHECK_ONLY_MODE DRY_RUN_MODE 
        PROMETHEUS_ENABLED TELEGRAM_ENABLED EMAIL_ENABLED SMTP_USE_TLS 
        ENABLE_SMART_CHUNKING ENABLE_DEDUPLICATION ENABLE_PREFILTER 
        SET_BACKUP_PERMISSIONS MULTI_STORAGE_PARALLEL
        BACKUP_CRONTABS BACKUP_NETWORK_CONFIG BACKUP_ZFS_CONFIG 
        BACKUP_INSTALLED_PACKAGES BACKUP_SCRIPT_DIR BACKUP_CRITICAL_FILES
    )
    
    local invalid_vars=()
    
    # Validate each boolean variable
    for var in "${boolean_vars[@]}"; do
        local value="${!var}"
        if [[ ! "$value" =~ ^(true|false)$ ]]; then
            invalid_vars+=("$var=$value")
        fi
    done
    
    # Report validation results
    if [ ${#invalid_vars[@]} -gt 0 ]; then
        error "Invalid boolean values found:"
        for var in "${invalid_vars[@]}"; do
            error "  - $var (must be 'true' or 'false')"
        done
        return $EXIT_ERROR
    fi
    
    debug "All boolean variables validated successfully"
    return $EXIT_SUCCESS
}

# ==========================================
# INITIALIZATION ERROR MANAGEMENT
# ==========================================

# Function to handle errors during environment initialization
handle_init_error() {
    local error_code=$1
    local error_message=$2
    local error_context=$3

    # Error logging
    echo -e "${RED}[ERROR] ${error_message}${RESET}"
    if [ -n "${error_context}" ]; then
        echo -e "${YELLOW}Context: ${error_context}${RESET}"
    fi

    # Log to file if LOG_FILE is defined
    if [ -n "${LOG_FILE:-}" ]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] ${error_message}" >> "$LOG_FILE"
        if [ -n "${error_context}" ]; then
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] Context: ${error_context}" >> "$LOG_FILE"
        fi
    fi

    # Error notification if notify function is available
    if declare -F notify >/dev/null; then
        notify "ERROR" "${error_message}" "${error_context}"
    fi

    # Update metrics if update_metrics function is available
    if declare -F update_metrics >/dev/null; then
        update_metrics "error_count" 1
    fi

    return $error_code
}

# Function to handle warnings uniformly
handle_warning() {
    local warning_message=$1
    local warning_context=$2

    # Warning logging
    echo -e "${YELLOW}[WARNING] ${warning_message}${RESET}"
    if [ -n "${warning_context}" ]; then
        echo -e "${YELLOW}Context: ${warning_context}${RESET}"
    fi

    # Log to file if LOG_FILE is defined
    if [ -n "${LOG_FILE:-}" ]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [WARNING] ${warning_message}" >> "$LOG_FILE"
        if [ -n "${warning_context}" ]; then
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] Context: ${warning_context}" >> "$LOG_FILE"
        fi
    fi

    # Warning notification if notify function is available
    if declare -F notify >/dev/null; then
        notify "WARNING" "${warning_message}" "${warning_context}"
    fi

    # Update metrics if update_metrics function is available
    if declare -F update_metrics >/dev/null; then
        update_metrics "warning_count" 1
    fi
}

# Function to check command result
check_command() {
    local exit_code=$1
    local error_message=$2
    local error_context=$3

    if [ $exit_code -ne 0 ]; then
        handle_init_error $exit_code "$error_message" "$error_context"
        return $exit_code
    fi
    return 0
}

# Function to handle cleanup on error
cleanup_on_error() {
    local exit_code=$1
    local error_message=$2

    # Set the global EXIT_CODE if a specific code is provided
    if [ -n "$exit_code" ]; then
        EXIT_CODE=$exit_code
    fi

    # Cleanup temporary files
    if [ -n "${METRICS_FILE:-}" ] && [ -f "$METRICS_FILE" ]; then
        rm -f "$METRICS_FILE"
    fi

    # Final log
    echo -e "${RED}[FATAL] Script terminated with error: ${error_message}${RESET}"
    if [ -n "${LOG_FILE:-}" ]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [FATAL] Script terminated with error: ${error_message}" >> "$LOG_FILE"
    fi

    return $EXIT_CODE
}

# Test function to verify module loading and functionality
# This function serves as a comprehensive health check to ensure the environment
# module has been loaded correctly and all functions are available
#
# Returns:
#   0: Module loaded successfully
#   1: Module loading failed
environment_test() {
    local test_passed=0
    local test_failed=0
    
    echo -e "${BLUE}[TEST] Running environment module tests...${RESET}"
    
    # Test 1: Check if all required functions are defined
    local required_functions=(
        "check_env_file" "check_proxmox_type" "check_required_variables"
        "setup_dirs" "initialize_defaults" "validate_boolean_vars"
        "handle_init_error" "handle_warning" "check_command" "cleanup_on_error"
        "validate_proxmox_version" "version_compare"
    )
    
    for func in "${required_functions[@]}"; do
        if declare -F "$func" >/dev/null; then
            echo -e "${GREEN}  ✓ Function $func is defined${RESET}"
            ((test_passed++))
        else
            echo -e "${RED}  ✗ Function $func is missing${RESET}"
            ((test_failed++))
        fi
    done
    
    # Test 2: Test version comparison function
    if version_compare "7.0" ">" "6.0"; then
        echo -e "${GREEN}  ✓ Version comparison works correctly${RESET}"
        ((test_passed++))
    else
        echo -e "${RED}  ✗ Version comparison failed${RESET}"
        ((test_failed++))
    fi
    
    # Test 3: Test version validation function
    if validate_proxmox_version "7.2-1" "PVE"; then
        echo -e "${GREEN}  ✓ Version validation works correctly${RESET}"
        ((test_passed++))
    else
        echo -e "${RED}  ✗ Version validation failed${RESET}"
        ((test_failed++))
    fi
    
    # Test 4: Test boolean validation with mock data
    local test_var="true"
    if [[ "$test_var" =~ ^(true|false)$ ]]; then
        echo -e "${GREEN}  ✓ Boolean validation regex works correctly${RESET}"
        ((test_passed++))
    else
        echo -e "${RED}  ✗ Boolean validation regex failed${RESET}"
        ((test_failed++))
    fi
    
    # Summary
    echo -e "${BLUE}[TEST] Test Results: ${GREEN}$test_passed passed${RESET}, ${RED}$test_failed failed${RESET}"
    
    if [ $test_failed -eq 0 ]; then
        echo -e "${GREEN}[INFO] Environment module loaded successfully - All tests passed${RESET}"
        return 0
    else
        echo -e "${RED}[ERROR] Environment module has issues - $test_failed tests failed${RESET}"
        return 1
    fi
}
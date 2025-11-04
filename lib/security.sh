#!/bin/bash
##
# Proxmox Backup System - Security Library
# File: security.sh
# Version: 0.7.0
# Last Modified: 2025-11-03
# Changes: Removed dependency installation and updates and moved in install.sh
##
# Basic security functions for backup

# Cache for command -v to avoid redundant calls
declare -A COMMAND_CACHE

# Function to check if a command exists (with cache)
command_exists() {
    local cmd="$1"
    if [[ -z "${COMMAND_CACHE[$cmd]:-}" ]]; then
        if command -v "$cmd" &> /dev/null; then
            COMMAND_CACHE[$cmd]="true"
        else
            COMMAND_CACHE[$cmd]="false"
        fi
    fi
    [[ "${COMMAND_CACHE[$cmd]}" == "true" ]]
}

# Function to invalidate command cache
clear_command_cache() {
    local cmd="$1"
    if [[ -n "$cmd" ]]; then
        # Clear specific command
        unset COMMAND_CACHE["$cmd"]
        debug "Cleared cache for command: $cmd"
    else
        # Clear entire cache
        COMMAND_CACHE=()
        debug "Cleared entire command cache"
    fi
}

# Function to force refresh of command cache
refresh_command_cache() {
    local cmd="$1"
    clear_command_cache "$cmd"
    command_exists "$cmd"  # This will rebuild the cache
}

# Merge detailed security-check output into the primary log file
append_security_log_to_main() {
    local src_file="$1"

    if [ "${ENABLE_LOG_MANAGEMENT:-true}" != "true" ] || [ -z "${LOG_FILE:-}" ]; then
        return 0
    fi

    if [ -z "$src_file" ] || [ ! -f "$src_file" ]; then
        return 0
    fi

    local sanitized
    sanitized=$(mktemp "/tmp/proxmox-security-log-XXXX.log" 2>/dev/null) || {
        debug "Unable to create temporary file for security log merge"
        return 0
    }

    if ! sed -r "s/\x1B\[[0-9;]*[[:alpha:]]//g" "$src_file" > "$sanitized" 2>/dev/null; then
        debug "Failed to sanitize security-check output"
        rm -f "$sanitized"
        return 0
    fi

    local current_level=${CURRENT_LOG_LEVEL:-2}
    while IFS= read -r line; do
        [ -n "$line" ] || continue

        local tag priority
        tag=$(printf '%s\n' "$line" | sed -n 's/^[^[]*\[\([^]]*\)\].*/\1/p' | head -n1)

        case "$tag" in
            ERROR)   priority=0 ;;
            WARNING) priority=1 ;;
            DEBUG)   priority=3 ;;
            TRACE)   priority=4 ;;
            STEP|SUCCESS|INFO|SKIP) priority=2 ;;
            *)       priority=2 ;;
        esac

        if [ "$priority" -le "$current_level" ]; then
            printf '%s\n' "$line" >> "$LOG_FILE"
        fi
    done < "$sanitized"

    rm -f "$sanitized"
    return 0
}

# Function to detect available package manager
# Verify script security
verify_script_security() {
    step "Verifying script security"
    local security_status=$EXIT_SUCCESS

    # Check if the security script exists
    local security_script="${SCRIPT_DIR}/security-check.sh"
    if [[ ! -f "$security_script" ]]; then
        error "Security check script not found: $security_script"
        if [[ "${ABORT_ON_SECURITY_ISSUES:-false}" == "true" ]]; then
            return $EXIT_ERROR
        fi
        return $EXIT_SUCCESS
    fi

    # Create temporary file to capture security check output
    local tmp_log
    tmp_log=$(mktemp) || {
        error "Failed to create temporary file for security check output"
        return $EXIT_ERROR
    }

    # Decide whether to run full check or script check only
    debug "Running security check (FULL_SECURITY_CHECK=${FULL_SECURITY_CHECK:-false})"
    local check_result=0

    set +e
    if [ -t 1 ]; then
        if [[ "${FULL_SECURITY_CHECK:-false}" == "true" ]]; then
            FORCE_COLORS=1 bash "$security_script" 2>&1 | tee "$tmp_log"
            check_result=${PIPESTATUS[0]}
        else
            FORCE_COLORS=1 bash "$security_script" --script-check 2>&1 | tee "$tmp_log"
            check_result=${PIPESTATUS[0]}
        fi
    else
        if [[ "${FULL_SECURITY_CHECK:-false}" == "true" ]]; then
            bash "$security_script" >"$tmp_log" 2>&1
            check_result=$?
        else
            bash "$security_script" --script-check >"$tmp_log" 2>&1
            check_result=$?
        fi
    fi
    set -e

    local expected_footer="[STEP] Calculating final exit code"
    local footer_present="false"
    if [[ -s "$tmp_log" ]]; then
        if perl -pe 's/\e\[[0-9;]*[[:alpha:]]//g' "$tmp_log" | grep -Fq "$expected_footer"; then
            footer_present="true"
        fi
    fi

    # Handle security check result
    case $check_result in
        0)
            debug "Security check passed successfully"
            success "Script security verification completed successfully"
            ;;
        1)
            if [[ "$footer_present" != "true" ]]; then
                warning "Security Check script crashed unexpectedly"
            fi
            warning "Security check completed with warnings"
            if [[ "${ABORT_ON_SECURITY_ISSUES:-false}" == "true" ]]; then
                error "Aborting due to security issues (ABORT_ON_SECURITY_ISSUES=true)"
                append_security_log_to_main "$tmp_log"
                rm -f "$tmp_log"
                return $EXIT_ERROR
            else
                warning "Continuing despite security warnings (ABORT_ON_SECURITY_ISSUES=false)"
                set_exit_code "warning"
            fi
            ;;
        2)
            if [[ "$footer_present" != "true" ]]; then
                error "Security Check script crashed unexpectedly"
            fi
            error "Security check failed"
            if [[ "${ABORT_ON_SECURITY_ISSUES:-false}" == "true" ]]; then
                error "Aborting due to security issues (ABORT_ON_SECURITY_ISSUES=true)"
                append_security_log_to_main "$tmp_log"
                rm -f "$tmp_log"
                return $EXIT_ERROR
            else
                warning "Continuing despite security errors (ABORT_ON_SECURITY_ISSUES=false)"
                set_exit_code "warning"
            fi
            ;;
    esac

    append_security_log_to_main "$tmp_log"
    rm -f "$tmp_log"

    return $security_status
}

# System dependencies check
check_dependencies() {
    step "Checking dependencies"

    # Check bash version
    local bash_version
    bash_version=$(bash --version | head -n1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    debug "Bash version: $bash_version"

    if ! check_version "$bash_version" "${MIN_BASH_VERSION:-4.0.0}"; then
        error "Bash version is too old. Required: ${MIN_BASH_VERSION:-4.0.0}, Current: $bash_version"
        set_exit_code "error"
        return $EXIT_ERROR
    fi

    # Check required packages (hardcoded list - managed by install.sh)
    local REQUIRED_PACKAGES="tar gzip zstd pigz jq curl rclone gpg rsync"
    local missing_packages=()
    local pkg
    for pkg in $REQUIRED_PACKAGES; do
        if ! command_exists "$pkg"; then
            missing_packages+=("$pkg")
            warning "Required package not found: $pkg"
        else
            debug "Found required package: $pkg"
        fi
    done
    
    # Handle missing packages
    if [[ ${#missing_packages[@]} -gt 0 ]]; then
        for pkg in "${missing_packages[@]}"; do
            error "Missing required package: $pkg"
        done
        error "Please run install.sh to install/update all dependencies"
        error "Command: sudo ${BASE_DIR}/install.sh"
        set_exit_code "error"
        return $EXIT_ERROR
    fi
    
    # Verify compression tools
    if ! check_compression_tools; then
        error "Compression tools check failed"
        set_exit_code "error"
        return $EXIT_ERROR
    fi
    
    success "All dependencies are satisfied"
}

# Install missing packages
# Improved version comparison function
check_version() {
    local version="$1"
    local required_version="$2"
    
    # Input validation
    if [[ -z "$version" || -z "$required_version" ]]; then
        debug "Invalid version parameters: version='$version', required='$required_version'"
        return 1
    fi
    
    # Normalize versions by removing non-numeric characters except dots
    version=$(echo "$version" | sed 's/[^0-9.]//g')
    required_version=$(echo "$required_version" | sed 's/[^0-9.]//g')
    
    # Use sort -V for semantic version comparison
    if [[ "$version" == "$required_version" ]]; then
        return 0
    fi
    
    # Check if current version is greater than or equal to required
    local older_version
    older_version=$(printf '%s\n%s\n' "$version" "$required_version" | sort -V | head -n1)
    
    if [[ "$older_version" == "$required_version" ]]; then
        return 0  # version >= required_version
    else
        return 1  # version < required_version
    fi
}

# Compression tools checking - FIXED to avoid infinite recursion
check_compression_tools() {
    local tools_missing=false
    local required_tools=()  # Array instead of string
    local compression_type="${COMPRESSION_TYPE:-gzip}"

    case "$compression_type" in
        "zstd")
            if ! command_exists "zstd"; then
                warning "Required compression tool not found: zstd"
                required_tools+=("zstd")
                tools_missing=true
            fi
            ;;
        "gzip")
            if ! command_exists "gzip"; then
                warning "Required compression tool not found: gzip"
                required_tools+=("gzip")
                tools_missing=true
            fi
            ;;
        "pigz")
            if ! command_exists "pigz"; then
                warning "Required compression tool not found: pigz"
                info "Will use gzip as fallback"
                if ! command_exists "gzip"; then
                    warning "Fallback compression tool not found: gzip"
                    required_tools+=("pigz" "gzip")
                    tools_missing=true
                fi
            fi
            ;;
        "xz")
            if ! command_exists "xz"; then
                warning "Required compression tool not found: xz"
                required_tools+=("xz")
                tools_missing=true
            fi
            ;;
        "bzip2")
            if ! command_exists "bzip2"; then
                warning "Required compression tool not found: bzip2"
                required_tools+=("bzip2")
                tools_missing=true
            fi
            ;;
        "lzma")
            if ! command_exists "lzma"; then
                warning "Required compression tool not found: lzma"
                required_tools+=("lzma")
                tools_missing=true
            fi
            ;;
    esac

    if [[ "${ENABLE_SMART_CHUNKING:-false}" == "true" ]] && ! command_exists "split"; then
        warning "Smart chunking requested but split not found"
        tools_missing=true
        required_tools+=("split")
    fi

    if [[ "${ENABLE_PREFILTER:-false}" == "true" ]]; then
        local cmd
        for cmd in file tr; do
            if ! command_exists "$cmd"; then
                warning "Preprocessing requested but $cmd not found"
                tools_missing=true
                required_tools+=("$cmd")
            fi
        done
    fi

    # Handle missing tools
    if [[ "$tools_missing" == "true" ]]; then
        for tool in "${required_tools[@]}"; do
            error "Missing compression tool: $tool"
        done
        error "Please run install.sh to install/update all dependencies"
        error "Command: sudo ${BASE_DIR}/install.sh"
        return $EXIT_ERROR
    fi

    return $EXIT_SUCCESS
}

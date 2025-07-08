#!/bin/bash
#
# Script to verify backup security
# This script verifies permissions and ownership of files and folders
#

set -e

# Base directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(dirname "$SCRIPT_DIR")"

# Load configuration file
if [ -f "$BASE_DIR/env/backup.env" ]; then
    source "$BASE_DIR/env/backup.env"
    echo "Security Check Script Version: $SCRIPT_VERSION"
else
    echo "Configuration file not found: $BASE_DIR/env/backup.env"
    exit 1
fi

# Check if script is called from proxmox-backup.sh
CALLED_FROM_BACKUP=0
if [[ "$0" != "${BASH_SOURCE[0]}" ]] || ps -o command= -p $PPID | grep -q "proxmox-backup.sh"; then
    CALLED_FROM_BACKUP=1
fi

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Check if script is running under cron or if output is not a terminal
# Disable colors if we're not in a terminal (e.g. cron)
USE_COLORS=1
if [ ! -t 1 ]; then
    # Output is not a terminal (likely cron or redirect)
    USE_COLORS=0
fi
# Allow forcing color disabling via ENV
if [[ "${DISABLE_COLORS}" == "1" || "${DISABLE_COLORS}" == "true" ]]; then
    USE_COLORS=0
fi

# Global variables for security levels
SCRIPT_SEC_LEVEL=0
BACKUP_SEC_LEVEL=0

# Standard logging functions
log_step() {
    if [ "$USE_COLORS" -eq 1 ]; then
        echo -e "${CYAN}[STEP]${NC} $1"
    else
        echo "[STEP] $1"
    fi
}

log_info() {
    # If called from proxmox-backup.sh, treat as debug (don't show unless DEBUG_LEVEL is verbose)
    if [ "$CALLED_FROM_BACKUP" -eq 1 ] && [[ "${DEBUG_LEVEL:-standard}" != "verbose" ]]; then
        return 0
    fi
    
    if [ "$USE_COLORS" -eq 1 ]; then
        echo -e "${BLUE}[INFO]${NC} $1"
    else
        echo "[INFO] $1"
    fi
}

log_success() {
    if [ "$USE_COLORS" -eq 1 ]; then
        echo -e "${GREEN}[SUCCESS]${NC} $1"
    else
        echo "[SUCCESS] $1"
    fi
}

log_warning() {
    BACKUP_SEC_LEVEL=$(( BACKUP_SEC_LEVEL<1 ? 1 : BACKUP_SEC_LEVEL ))
    if [ "$USE_COLORS" -eq 1 ]; then
        echo -e "${YELLOW}[WARNING]${NC} $1"
    else
        echo "[WARNING] $1"
    fi
}

log_error() {
    BACKUP_SEC_LEVEL=2
    if [ "$USE_COLORS" -eq 1 ]; then
        echo -e "${RED}[ERROR]${NC} $1"
    else
        echo "[ERROR] $1"
    fi
}

# Timestamped logging functions for script control
# Color date and time with same color as message type
ts_step() {
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    if [ "$USE_COLORS" -eq 1 ]; then
        echo -e "${CYAN}${timestamp} [STEP]${NC} $1"
    else
        echo "${timestamp} [STEP] $1"
    fi
}

ts_info() {
    # If called from proxmox-backup.sh, treat as debug (don't show unless DEBUG_LEVEL is verbose)
    if [ "$CALLED_FROM_BACKUP" -eq 1 ] && [[ "${DEBUG_LEVEL:-standard}" != "verbose" ]]; then
        return 0
    fi
    
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    if [ "$USE_COLORS" -eq 1 ]; then
        echo -e "${BLUE}${timestamp} [INFO]${NC} $1"
    else
        echo "${timestamp} [INFO] $1"
    fi
}

ts_success() {
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    if [ "$USE_COLORS" -eq 1 ]; then
        echo -e "${GREEN}${timestamp} [SUCCESS]${NC} $1"
    else
        echo "${timestamp} [SUCCESS] $1"
    fi
}

ts_warning() {
    SCRIPT_SEC_LEVEL=$(( SCRIPT_SEC_LEVEL<1 ? 1 : SCRIPT_SEC_LEVEL ))
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    if [ "$USE_COLORS" -eq 1 ]; then
        echo -e "${YELLOW}${timestamp} [WARNING]${NC} $1"
    else
        echo "${timestamp} [WARNING] $1"
    fi
}

ts_error() {
    SCRIPT_SEC_LEVEL=2
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    if [ "$USE_COLORS" -eq 1 ]; then
        echo -e "${RED}${timestamp} [ERROR]${NC} $1"
    else
        echo "${timestamp} [ERROR] $1"
    fi
}

# Support functions
echo_info() {
    if [ "$USE_COLORS" -eq 1 ]; then
        echo -e "${GREEN}INFO:${NC} $1"
    else
        echo "INFO: $1"
    fi
}

# Verify script security
# Verify script security
check_script_security() {
    ts_step "Verifying script security"
    
    # Verify main file
    ts_info "Checking permissions of main file proxmox-backup.sh"
    local script="$BASE_DIR/script/proxmox-backup.sh"
    local expected_perm=700
    local actual_perm=$(stat -c '%a' "$script")
    
    if [ "$actual_perm" != "$expected_perm" ]; then
        ts_warning "Incorrect permissions on main script: $actual_perm (should be $expected_perm)"
    else
        ts_success "Correct permissions on main file: $actual_perm"
    fi
    
    # Verify script owner
    local script_owner=$(stat -c '%U' "$script")
    if [ "$script_owner" != "root" ]; then
        ts_error "Script not owned by root (current: $script_owner)"
        if [ "${ABORT_ON_SECURITY_ISSUES:-false}" == "true" ]; then
            exit 2
        fi
    else
        ts_success "Correct main script owner: $script_owner"
    fi
    
    # Verify MD5 hash
    ts_info "Checking MD5 hash integrity of scripts"
    local hash_file="${script}.md5"
    if [ -f "$hash_file" ]; then
        local stored_hash=$(cat "$hash_file")
        local current_hash=$(md5sum "$script" | awk '{print $1}')
        
        if [ "$stored_hash" != "$current_hash" ]; then
            ts_warning "Script hash mismatch detected"
            ts_warning "Stored hash: $stored_hash"
            ts_warning "Current hash: $current_hash"
            ts_warning "Auto-updating script hash"
            echo "$current_hash" > "$hash_file"
            
            # Check recent modifications
            ts_info "Checking recent script modifications"
            local mod_time_epoch=$(stat -c %Y "$script")
            local now_epoch=$(date +%s)
            local diff=$((now_epoch - mod_time_epoch))
            
            if [ "$diff" -lt 3600 ]; then
                ts_warning "Script was modified recently (less than 1 hour ago)"
                ts_warning "Timestamp: $(date -d "@$mod_time_epoch" '+%Y-%m-%d %H:%M:%S')"
                
                if [ "${ABORT_ON_SECURITY_ISSUES:-false}" != "true" ]; then
                    ts_warning "Automatic continuation despite recent modification (ABORT_ON_SECURITY_ISSUES=false)"
                else
                    ts_error "Aborting due to security issues"
                    exit 2
                fi
            else
                ts_success "Script was not modified recently"
            fi
        else
            ts_success "Main script MD5 hash verified correctly"
        fi
    else
        ts_warning "Hash file missing for main script"
        ts_info "Creating initial hash file"
        echo "$current_hash" > "$hash_file"
        chmod 600 "$hash_file"
        chown root:root "$hash_file"
    fi
    
    # Check other critical scripts
    ts_info "Checking other critical scripts"
    local other_scripts=(
        "$BASE_DIR/secure_account/setup_gdrive.sh"
    )
    
    for other_script in "${other_scripts[@]}"; do
        if [ -f "$other_script" ]; then
            ts_info "Verifying script: $other_script"
            local script_perm=$(stat -c '%a' "$other_script")
            if [ "$script_perm" != "700" ]; then
                ts_warning "Incorrect permissions on $other_script: $script_perm (should be 700)"
            else
                ts_success "Correct permissions on $other_script: $script_perm"
            fi
        else
            ts_warning "Critical script not found: $other_script"
        fi
    done
    
    # Final summary
    if [ "$SCRIPT_SEC_LEVEL" -eq 0 ]; then
        ts_success "Script security verification completed successfully"
    elif [ "$SCRIPT_SEC_LEVEL" -eq 1 ]; then
        ts_warning "Script security verification completed with warnings"
    else
        ts_error "Script security verification completed with errors"
    fi
}

check_dependencies() {
    log_step "Checking required dependencies"
    
    local dependencies=("iptables" "netstat" "ss")
    local missing=0
    local missing_deps=()
    
    for dep in "${dependencies[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            log_warning "Missing dependency: $dep"
            missing=$((missing + 1))
            missing_deps+=("$dep")
        else
            log_info "Dependency present: $dep"
        fi
    done
    
    if [ $missing -gt 0 ]; then
        log_warning "$missing dependencies missing. Install with:"
        echo "apt-get update && apt-get install -y iptables net-tools iproute2"
        
        # Check if automatic installation is enabled
        if [ "${AUTO_INSTALL_DEPENDENCIES:-false}" == "true" ]; then
            log_info "AUTO_INSTALL_DEPENDENCIES enabled - Automatic installation in progress..."
            log_info "Updating package list..."
            if apt-get update 2>&1 | while IFS= read -r line; do log_info "APT: $line"; done; then
                log_info "Installing packages: iptables net-tools iproute2"
                if apt-get install -y iptables net-tools iproute2 2>&1 | while IFS= read -r line; do log_info "APT: $line"; done; then
                    log_success "Dependencies installed automatically successfully!"
                    
                    # Re-check dependencies after installation
                    local still_missing=0
                    for dep in "${missing_deps[@]}"; do
                        if ! command -v "$dep" &> /dev/null; then
                            log_error "Dependency $dep still missing after installation"
                            still_missing=$((still_missing + 1))
                        else
                            log_success "Dependency $dep now available"
                        fi
                    done
                    
                    if [ $still_missing -gt 0 ]; then
                        log_error "Error: $still_missing dependencies still missing after automatic installation"
                        if [ "${ABORT_ON_SECURITY_ISSUES:-false}" == "true" ]; then
                            exit 1
                        fi
                    fi
                else
                    log_error "Error during automatic dependency installation!"
                    if [ "${ABORT_ON_SECURITY_ISSUES:-false}" == "true" ]; then
                        exit 1
                    else
                        log_warning "Continuing despite missing dependencies (ABORT_ON_SECURITY_ISSUES=false)"
                    fi
                fi
            else
                log_error "Error during package list update!"
                if [ "${ABORT_ON_SECURITY_ISSUES:-false}" == "true" ]; then
                    exit 1
                else
                    log_warning "Continuing despite update failure (ABORT_ON_SECURITY_ISSUES=false)"
                fi
            fi
        else
            # Manual installation - ask for confirmation only if not in automatic mode
            if [ -t 0 ]; then  # Only if stdin is a terminal (not in cron)
                read -p "Do you want to install missing dependencies? (y/n): " -n 1 -r
                echo
                if [[ $REPLY =~ ^[Yy]$ ]]; then
                    log_info "Installing dependencies..."
                    log_info "Updating package list..."
                    if apt-get update 2>&1 | while IFS= read -r line; do log_info "APT: $line"; done; then
                        log_info "Installing packages: iptables net-tools iproute2"
                        if apt-get install -y iptables net-tools iproute2 2>&1 | while IFS= read -r line; do log_info "APT: $line"; done; then
                            log_success "Dependencies installed successfully!"
                        else
                            log_error "Error during dependency installation!"
                            exit 1
                        fi
                    else
                        log_error "Error during package list update!"
                        exit 1
                    fi
                else
                    log_warning "Dependency installation skipped. Some checks may not work correctly."
                fi
            else
                # We're in non-interactive mode (e.g. cron)
                log_warning "Non-interactive mode: dependency installation skipped"
                log_warning "Some checks may not work correctly"
                if [ "${ABORT_ON_SECURITY_ISSUES:-false}" == "true" ]; then
                    log_error "ABORT_ON_SECURITY_ISSUES=true: terminating due to missing dependencies"
                    exit 1
                fi
            fi
        fi
    else
        log_success "All dependencies are present!"
    fi
}

check_directory_structure() {
    log_step "Checking directory structure"
    
    local dirs=("$BASE_DIR/backup" "$BASE_DIR/env" "$BASE_DIR/log" "$BASE_DIR/script" "$BASE_DIR/secure_account")
    local missing=0
    local created=0
    
    for dir in "${dirs[@]}"; do
        if [ ! -d "$dir" ]; then
            log_warning "Missing directory: $dir"
            missing=$((missing + 1))
            
            # Try to create directory
            if mkdir -p "$dir" 2>/dev/null; then
                # Set appropriate permissions
                chmod 755 "$dir"
                chown root:root "$dir"
                log_success "Directory created automatically: $dir"
                created=$((created + 1))
            else
                log_error "Cannot create directory: $dir"
                log_error "Check permissions or create manually with: mkdir -p $dir"
            fi
        else
            log_info "Directory present: $dir"
        fi
    done
    
    if [ $missing -gt 0 ]; then
        if [ $created -eq $missing ]; then
            log_success "All $created missing directories were created automatically!"
        elif [ $created -gt 0 ]; then
            log_warning "$created directories created automatically, $((missing - created)) remain to be created manually"
        else
            log_warning "No directories created automatically. Create manually with:"
            echo "mkdir -p $BASE_DIR/{backup,env,log,script,secure_account}"
        fi
    else
        log_success "Directory structure is correct!"
    fi
}

check_critical_files() {
    log_step "Checking critical files"
    
    declare -A files=(
        ["$BASE_DIR/script/proxmox-backup.sh"]="700:root:root"
		["$BASE_DIR/config/.server_identity"]="600:root:root"
		["$BASE_DIR/script/server-id-manager.sh"]="700:root:root"
        ["$BASE_DIR/script/fix-permissions.sh"]="700:root:root"
        ["$BASE_DIR/env/backup.env"]="400:root:root"
        ["$BASE_DIR/secure_account/pbs1.json"]="400:root:root"
        ["$BASE_DIR/secure_account/setup_gdrive.sh"]="700:root:root"
		["$BASE_DIR/lib/backup_collect.sh"]="400:root:root"
		["$BASE_DIR/lib/backup_collect_pbspve.sh"]="400:root:root"
        ["$BASE_DIR/lib/backup_create.sh"]="400:root:root"
		["$BASE_DIR/lib/backup_manager.sh"]="400:root:root"
        ["$BASE_DIR/lib/backup_verify.sh"]="400:root:root"
        ["$BASE_DIR/lib/core.sh"]="400:root:root"
        ["$BASE_DIR/lib/environment.sh"]="400:root:root"
        ["$BASE_DIR/lib/log.sh"]="400:root:root"
        ["$BASE_DIR/lib/metrics.sh"]="400:root:root"
        ["$BASE_DIR/lib/notify.sh"]="400:root:root"
        ["$BASE_DIR/lib/security.sh"]="400:root:root"
        ["$BASE_DIR/lib/storage.sh"]="400:root:root"
        ["$BASE_DIR/lib/utils.sh"]="400:root:root"
        ["$BASE_DIR/lib/utils_counting.sh"]="400:root:root"
        ["$BASE_DIR/lib/metrics_collect.sh"]="400:root:root"
    )
    
    local missing=0
    local wrong_perms=0
    
    for file in "${!files[@]}"; do
        if [ ! -f "$file" ]; then
            log_error "Critical file missing: $file"
            missing=$((missing + 1))
            continue
        fi
        
        IFS=':' read -r expected_perm expected_owner expected_group <<< "${files[$file]}"
        
        local file_perm=$(stat -c '%a' "$file")
        if [ "$file_perm" != "$expected_perm" ]; then
            log_warning "Incorrect permissions on $file. Expected: $expected_perm, Found: $file_perm"
            wrong_perms=$((wrong_perms + 1))
        fi
        
        local file_owner=$(stat -c '%U' "$file")
        if [ "$file_owner" != "$expected_owner" ]; then
            log_warning "Incorrect owner on $file. Expected: $expected_owner, Found: $file_owner"
            wrong_perms=$((wrong_perms + 1))
        fi
        
        local file_group=$(stat -c '%G' "$file")
        if [ "$file_group" != "$expected_group" ]; then
            log_warning "Incorrect group on $file. Expected: $expected_group, Found: $file_group"
            wrong_perms=$((wrong_perms + 1))
        fi
        
        if [ "$file_perm" == "$expected_perm" ] && [ "$file_owner" == "$expected_owner" ] && [ "$file_group" == "$expected_group" ]; then
            log_info "File OK: $file"
        fi
    done
    
    if [ $missing -gt 0 ]; then
        log_warning "$missing critical files missing."
    else
        log_success "All critical files are present!"
    fi
    
    if [ $wrong_perms -gt 0 ]; then
        log_warning "$wrong_perms incorrect permissions or owners. Fix with chmod and chown."
    else
        log_success "All permissions and owners are correct!"
    fi
}

check_unauthorized_files() {
    log_step "Checking for unauthorized files"
    
    local secure_dirs=("$BASE_DIR/script" "$BASE_DIR/secure_account" "$BASE_DIR/lib")
    local authorized_files=("proxmox-backup.sh" "security-check.sh" "fix-permissions.sh" "gdrive.conf" "get_gdrive_token.sh" "setup_gdrive.sh" "README.md" "pbs1.json" "backup_collect.sh" "backup_create.sh" "backup_manager.sh" "backup_verify.sh" "core.sh" "environment.sh" "log.sh" "metrics.sh" "notify.sh" "security.sh" "storage.sh" "utils.sh" "server-id-manager.sh" "utils_counting.sh" "metrics_collect.sh" "backup_collect_pbspve.sh")
    local unauthorized=0
    
    for dir in "${secure_dirs[@]}"; do
        if [ ! -d "$dir" ]; then
            log_warning "Directory $dir does not exist, skipping check"
            continue
        fi
        
        local found_files=$(find "$dir" -type f -printf "%f\n")
        
        for file in $found_files; do
            if [[ "$file" == *.md5 ]]; then
                continue
            fi
            
            local is_authorized=0
            for auth_file in "${authorized_files[@]}"; do
                if [ "$file" == "$auth_file" ]; then
                    is_authorized=1
                    break
                fi
            done
            
            if [ $is_authorized -eq 0 ]; then
                log_warning "Unauthorized file found: $dir/$file"
                unauthorized=$((unauthorized + 1))
            fi
        done
    done
    
    if [ $unauthorized -gt 0 ]; then
        log_warning "Found $unauthorized unauthorized files in sensitive directories"
    else
        log_success "No unauthorized files found!"
    fi
}

check_network_security() {
    if [ "$CHECK_NETWORK_SECURITY" != "true" ]; then
        log_info "Network checks disabled in settings"
        return
    fi

    log_step "Checking network security"
    
    if [ "$CHECK_FIREWALL" = "true" ]; then
        if ! command -v iptables &> /dev/null; then
            log_warning "iptables not installed, cannot check firewall"
        else
            local iptables_rules=$(iptables -L -n | grep -v "Chain" | grep -v "target" | grep -v "^$" | wc -l)
            if [ "$iptables_rules" -eq 0 ]; then
                log_warning "No active firewall rules with iptables!"
            else
                log_info "Found $iptables_rules active firewall rules"
            fi
        fi
    else
        log_info "Firewall check disabled in settings"
    fi
    
    if [ "$CHECK_OPEN_PORTS" = "true" ]; then
        if command -v ss &> /dev/null; then
            log_info "Checking open network ports..."
            local open_ports=$(ss -tuln | grep LISTEN | grep -v "127.0.0.1" | grep -v "::1" | grep -v "fe80")
            
            if [ -n "$open_ports" ]; then
                log_warning "Publicly accessible ports:"
                echo "$open_ports"
                
                if echo "$open_ports" | grep -q ":22 "; then
                    log_warning "SSH open on standard port (22), it's recommended to use a non-standard port"
                fi
            else
                log_info "No ports open to the outside"
            fi
        else
            log_warning "Command 'ss' not available, cannot check open ports"
        fi
    else
        log_info "Open ports check disabled in settings"
    fi
}

check_suspicious_processes() {
    log_info "Checking for suspicious processes"
    
    local kernel_processes=(
        "kworker" "kthreadd" "kswapd" "rcu_" "migration" "watchdog" "watchdogd" 
        "ksoftirqd" "khugepaged" "kcompactd" "khubd" "kdevtmpfs" "netns" 
        "writeback" "crypto" "bioset" "kblockd" "ata_sff" "md" "edac-poller" 
        "devfreq_wq" "jbd2" "ext4-rsv-conver" "ipv6_addrconf" "scsi_eh" 
        "kdmflush" "kcryptd" "ttm" "tls" "rpcio" "xprtiod" "charger_manager" 
        "kstrp" "md_bio_submit" "blkcg_punt_bio" "tmp_dev_wq" "acpi_thermal_pm" 
        "ipv6_mc" "kthrotld" "zswap-shrink"
        "khungtaskd" "oom_reaper" "ksmd" "kauditd" "cpuhp" "idle_inject" "irq/" 
        "pool_workqueue" "spl_" "ecryptfs-" "txg_" "mmp" "dp_"
        "z_"
    )
    
    local suspicious_names=("ncat " "cryptominer" "miner" "xmrig" "kdevtmpfsi" "kinsing")
    local legitimate_processes_with_brackets=("sshd:" "systemd" "cron" "rsyslogd" "dbus-daemon")
    local found=0
    
    for proc in "${suspicious_names[@]}"; do
        local matches=$(ps aux | grep -v grep | grep "$proc" | grep -v "check_suspicious_processes")
        if [ -n "$matches" ]; then
            log_warning "Potentially suspicious process found: \"$proc\""
            # Only show detailed process information in debug mode
            if [[ "${DEBUG_LEVEL:-standard}" == "advanced" ]] || [[ "${DEBUG_LEVEL:-standard}" == "extreme" ]]; then
                echo "$matches"
            else
                log_info "Use --debug-level advanced to see detailed process information"
            fi
            found=$((found + 1))
        fi
    done
    
    ps aux | grep -v grep | grep -E '\[.*\]' | while read line; do
        local process_name=$(echo "$line" | awk '{print $11}' | tr -d '[]')
        local full_command=$(echo "$line" | awk '{$1=$2=$3=$4=$5=$6=$7=$8=$9=$10=""; print $0}' | sed 's/^[ \t]*//')
        local is_legitimate=0
        local vsz=$(echo "$line" | awk '{print $5}')
        local state=$(echo "$line" | awk '{print $8}')
        local user=$(echo "$line" | awk '{print $1}')
        
        # Check if it's a legitimate Proxmox Backup zombie process
        if [[ "$process_name" == "proxmox-backup-"* && "$state" == "Z" && "$vsz" -eq 0 && ("$user" == "root" || "$user" == "backup") ]]; then
            is_legitimate=1
            # Legitimate Proxmox Backup zombie process ignored: $process_name (user: $user)
        # Check standard kernel processes with VSZ=0
        elif [[ "$vsz" -eq 0 && "$user" == "root" && ("$state" == "S" || "$state" == "S<" || "$state" == "I" || "$state" == "SN") ]]; then
            is_legitimate=1
        else
            for kernel_proc in "${kernel_processes[@]}"; do
                if [[ "$process_name" == "$kernel_proc"* ]]; then
                    is_legitimate=1
                    break
                fi
            done
            
            if [[ $is_legitimate -eq 0 ]]; then
                for legit_proc in "${legitimate_processes_with_brackets[@]}"; do
                    if [[ "$full_command" == *"$legit_proc"* ]]; then
                        is_legitimate=1
                        break
                    fi
                done
            fi
        fi
        
        if [ $is_legitimate -eq 0 ]; then
            log_warning "Possible suspicious kernel process: $process_name"
            # Only show detailed process information in debug mode
            if [[ "${DEBUG_LEVEL:-standard}" == "advanced" ]] || [[ "${DEBUG_LEVEL:-standard}" == "extreme" ]]; then
                echo "$line"
            else
                log_info "Use --debug-level advanced to see detailed process information"
            fi
            found=$((found + 1))
        fi
    done
    
    local unusual_ports=$(netstat -tulpn 2>/dev/null | grep -E ':(6666|6665|1337|31337|4444|5555|4242|6324|8888)' | grep -v "127.0.0.1")
    if [ -n "$unusual_ports" ]; then
        log_warning "Found processes on suspicious ports:"
        # Only show detailed port information in debug mode
        if [[ "${DEBUG_LEVEL:-standard}" == "advanced" ]] || [[ "${DEBUG_LEVEL:-standard}" == "extreme" ]]; then
            echo "$unusual_ports"
        else
            log_info "Use --debug-level advanced to see detailed port information"
        fi
        found=$((found + 1))
    fi
    
    if [ $found -eq 0 ]; then
        log_info "No suspicious processes found"
    else
        log_warning "Found $found potential suspicious processes!"
    fi
}

update_script_hashes() {
    log_step "Updating MD5 hashes of scripts" 
    
    local script_files=(
        "$BASE_DIR/script/proxmox-backup.sh"
        "$BASE_DIR/script/fix-permissions.sh"
		"$BASE_DIR/script/server-id-manager.sh"
        "$BASE_DIR/script/security-check.sh"
        "$BASE_DIR/secure_account/setup_gdrive.sh"
        "$BASE_DIR/secure_account/pbs1.json"
        "$BASE_DIR/lib/backup_collect.sh"
        "$BASE_DIR/lib/backup_collect_pbspve.sh"
        "$BASE_DIR/lib/backup_create.sh"
        "$BASE_DIR/lib/backup_verify.sh"
        "$BASE_DIR/lib/core.sh"
        "$BASE_DIR/lib/environment.sh"
        "$BASE_DIR/lib/metrics.sh"
        "$BASE_DIR/lib/notify.sh"
        "$BASE_DIR/lib/security.sh"
        "$BASE_DIR/lib/storage.sh"
        "$BASE_DIR/lib/log.sh"
        "$BASE_DIR/lib/utils_counting.sh"
        "$BASE_DIR/lib/metrics_collect.sh"
    )
    
    for script in "${script_files[@]}"; do
        if [ ! -f "$script" ]; then
            log_warning "Script not found: $script"
            continue
        fi
        
        local hash_file="${script}.md5"
        local current_hash=$(md5sum "$script" | awk '{print $1}')
        
        if [ -f "$hash_file" ]; then
            local stored_hash=$(cat "$hash_file")
            if [ "$current_hash" != "$stored_hash" ]; then
                log_warning "Script $script has been modified!"
                log_info "Original hash: $stored_hash"
                log_info "Current hash: $current_hash"
                
                if [ "$AUTO_UPDATE_HASHES" = "true" ]; then
                    echo "$current_hash" > "$hash_file"
                    log_info "Hash automatically updated for $script"
                else
                    read -p "Update hash? (y/n): " -n 1 -r
                    echo
                    if [[ $REPLY =~ ^[Yy]$ ]]; then
                        echo "$current_hash" > "$hash_file"
                        log_info "Hash updated for $script"
                    else
                        log_warning "Hash not updated. Script may have been tampered with!"
                    fi
                fi
            else
                log_info "Hash OK for $script"
            fi
        else
            echo "$current_hash" > "$hash_file"
            chmod 600 "$hash_file"
            chown root:root "$hash_file"
            log_info "Created initial hash file for $script"
        fi
    done
    log_success "MD5 hash update completed"
}

# Calculate final exit code based on security levels
calculate_final_exit_code() {
    local final_code=0
    
    # If at least one of the two is 2 (error), final code should be 2
    # unless ABORT_ON_SECURITY_ISSUES is false
    if [ "$SCRIPT_SEC_LEVEL" -eq 2 ] || [ "$BACKUP_SEC_LEVEL" -eq 2 ]; then
        if [ "${ABORT_ON_SECURITY_ISSUES:-false}" != "true" ]; then
            final_code=1  # With ABORT_ON_SECURITY_ISSUES=false, errors become warnings
        else
            final_code=2  # With ABORT_ON_SECURITY_ISSUES=true, keep errors
        fi
    # If at least one of the two is 1 (warning), final code should be 1
    elif [ "$SCRIPT_SEC_LEVEL" -eq 1 ] || [ "$BACKUP_SEC_LEVEL" -eq 1 ]; then
        final_code=1
    # Otherwise, both are 0, so final code is 0
    else
        final_code=0
    fi
    
    # Log final exit code
    if [ "$final_code" -eq 0 ]; then
        echo -e "${GREEN}$(date '+%Y-%m-%d %H:%M:%S') [INFO]${NC} Final exit code: 0 (All OK)"
    elif [ "$final_code" -eq 1 ]; then
        echo -e "${YELLOW}$(date '+%Y-%m-%d %H:%M:%S') [WARNING]${NC} Final exit code: 1 (Warning)"
    else
        echo -e "${RED}$(date '+%Y-%m-%d %H:%M:%S') [ERROR]${NC} Final exit code: 2 (Critical error)"
    fi
    
    return $final_code
}

# Main function
main() {
    # Initialize security levels
    SCRIPT_SEC_LEVEL=0
    BACKUP_SEC_LEVEL=0

    # Check if --script-check or --update-hashes was passed
    case "${1:-}" in
        "--script-check")
            check_script_security
            calculate_final_exit_code
            return $?
            ;;
        "--update-hashes")
            update_script_hashes
            return $?
            ;;
    esac

    # Full execution
    check_script_security
    echo ""

    # Show colored header
    local script_color=$GREEN
    if [ "$SCRIPT_SEC_LEVEL" -eq 2 ]; then
        script_color=$RED
    elif [ "$SCRIPT_SEC_LEVEL" -eq 1 ]; then
        script_color=$YELLOW
    fi
    echo -e "${script_color}==============================================================="
    echo -e "      PROXMOX SCRIPT SECURITY VERIFICATION"
    echo -e "===============================================================${NC}"
    echo ""

    check_dependencies
    check_directory_structure
    check_critical_files
    check_unauthorized_files
    check_network_security
    check_suspicious_processes
    update_script_hashes

    # Show colored footer
    local backup_color=$GREEN
    if [ "$BACKUP_SEC_LEVEL" -eq 2 ]; then
        backup_color=$RED
    elif [ "$BACKUP_SEC_LEVEL" -eq 1 ]; then
        backup_color=$YELLOW
    fi
    echo ""
    echo -e "${backup_color}==============================================================="
    echo -e "      BACKUP VERIFICATION COMPLETED"
    echo -e "===============================================================${NC}"
    echo ""

    # Calculate and return final exit code
    echo -e "${CYAN}$(date '+%Y-%m-%d %H:%M:%S') [STEP]${NC} Calculating final exit code"
    calculate_final_exit_code
    return $?
}

# Execute only if script is called directly (not if sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
    exit $?
fi

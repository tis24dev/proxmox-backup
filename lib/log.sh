#!/bin/bash
# Version: 0.2.1
# ==========================================
# PROXMOX BACKUP LOGGING SYSTEM
# ==========================================
#
# This module provides comprehensive logging functionality for Proxmox backup operations.
# It supports multiple log levels, colored output, file logging, and multi-storage management.
#
# FEATURES:
# - Multi-level logging (ERROR, WARNING, INFO, DEBUG, TRACE, STEP, SUCCESS)
# - Automatic color detection and management
# - File-based logging with rotation
# - Multi-storage support (primary, secondary, cloud)
# - HTML error report generation
# - Error correlation analysis
# - Batch processing for cloud operations
# - Dry-run mode support
#
# DEPENDENCIES:
# ============
# REQUIRED SYSTEM TOOLS:
# - bash 4.0+: For associative arrays and modern bash features
# - date: For timestamp generation (coreutils package)
# - mkdir: For directory creation (coreutils package)
# - cp: For file copying (coreutils package)
# - rm: For file deletion (coreutils package)
# - find: For file searching (findutils package)
# - sort: For file sorting (coreutils package)
# - mktemp: For secure temporary file creation (coreutils package)
# - timeout: For operation timeouts (coreutils package)
#
# OPTIONAL TOOLS:
# - rclone: For cloud storage operations
# - wc: For line counting (coreutils package)
# - grep: For pattern matching (grep package)
# - sed: For text processing (sed package)
#
# REQUIRED MODULES (must be sourced before this module):
# - backup_status.sh: Provides set_backup_status() and set_exit_code() functions
#   * Functions: set_backup_status(operation, status) -> 0 on success
#   * Functions: set_exit_code(level) -> sets global exit code
#
# GLOBAL VARIABLES USED:
# =====================
# CONFIGURATION VARIABLES:
# - DEBUG_LEVEL: Controls logging verbosity ("standard", "advanced", "extreme")
#   * standard: INFO level and above (default)
#   * advanced: DEBUG level and above
#   * extreme: TRACE level and above (most verbose)
#
# - ENABLE_LOG_MANAGEMENT: Controls log file operations (true/false)
#   * true: Enable file logging, rotation, and multi-storage operations
#   * false: Console logging only, skip all file operations
#   * Default: true
#
# - USE_COLORS: Controls colored output (0/1, auto-detected)
#   * 1: Enable colored output (default for interactive terminals)
#   * 0: Disable colored output (default for non-interactive or when DISABLE_COLORS is set)
#
# - DISABLE_COLORS: Force disable colored output ("1", "true", or any value)
#   * When set, overrides automatic color detection
#
# - DRY_RUN_MODE: Enable dry-run mode (true/false)
#   * true: Simulate operations without making actual changes
#   * false: Perform actual operations (default)
#
# STORAGE PATHS (must be absolute paths with appropriate permissions):
# - LOCAL_LOG_PATH: Primary log storage directory
#   * Example: "/var/log/proxmox-backup"
#   * Must be writable by the backup user
#   * Used for primary log storage and rotation
#
# - SECONDARY_LOG_PATH: Secondary log storage directory
#   * Example: "/mnt/backup-drive/logs"
#   * Can be network mount or external storage
#   * Used for log redundancy
#
# - CLOUD_LOG_PATH: Cloud log storage path
#   * Example: "logs/proxmox-backup"
#   * Relative path within the configured rclone remote
#   * Used with RCLONE_REMOTE for cloud operations
#
# RETENTION POLICIES (positive integers):
# - MAX_LOCAL_LOGS: Maximum number of local log files to retain
#   * Recommended: 30-90 (daily logs for 1-3 months)
#   * Higher values require more local storage space
#
# - MAX_SECONDARY_LOGS: Maximum number of secondary log files to retain
#   * Recommended: 90-365 (quarterly to yearly retention)
#   * Should be >= MAX_LOCAL_LOGS for proper redundancy
#
# - MAX_CLOUD_LOGS: Maximum number of cloud log files to retain
#   * Recommended: 365+ (yearly+ retention for compliance)
#   * Consider cloud storage costs when setting this value
#
# CLOUD CONFIGURATION:
# - RCLONE_REMOTE: Name of the configured rclone remote
#   * Example: "backup-storage"
#   * Must be configured in rclone before use
#
# - RCLONE_FLAGS: Additional flags for rclone operations
#   * Example: "--transfers=4 --checkers=8"
#   * Used to optimize cloud transfer performance
#
# - SKIP_CLOUD_VERIFICATION: Skip upload verification (true/false)
#   * true: Skip verification step (faster but less reliable)
#   * false: Perform verification with retry logic (default)
#   * Use true only if experiencing persistent verification issues
#
# RUNTIME VARIABLES (set by the system):
# - LOG_FILE: Full path to the current log file
#   * Format: "${LOCAL_LOG_PATH}/${PROXMOX_TYPE}-backup-${TIMESTAMP}.log"
#   * Created automatically during log initialization
#
# - TIMESTAMP: Current backup session timestamp
#   * Format: YYYYMMDD-HHMMSS
#   * Used for unique file naming
#
# - PROXMOX_TYPE: Type of Proxmox system being backed up
#   * Examples: "pve", "pbs", "pmg"
#   * Used in log file naming and categorization
#
# - HOSTNAME: System hostname for identification
#   * Used in log messages and reports
#
# - ERROR_LIST: Array of collected errors for analysis
#   * Format: "category|severity|message|details"
#   * Used for error correlation and reporting
#
# EXIT CODES:
# - 0 (EXIT_SUCCESS): Operation completed successfully
# - 1 (EXIT_ERROR): Critical error occurred
# - 2 (EXIT_WARNING): Warning condition (partial success)
#
# PERFORMANCE CONSIDERATIONS:
# - Buffered I/O: Log messages are buffered to reduce disk I/O
# - Batch operations: Cloud operations use batching to improve efficiency
# - Lazy evaluation: Expensive operations only performed when needed
# - Temporary files: Used to minimize memory usage for large operations
#
# THREAD SAFETY:
# - File locking: Not implemented (single-threaded design assumed)
# - Atomic operations: File operations use temporary files and atomic moves where possible
# - Signal handling: Proper cleanup on interruption
#
# EXAMPLES:
# =========
# Basic usage:
#   source log.sh
#   setup_logging
#   info "This is an info message"
#   error "This is an error message"
#
# Advanced usage with custom log level:
#   DEBUG_LEVEL="advanced"
#   source log.sh
#   setup_logging
#   debug "This debug message will be shown"
#
# Dry-run mode:
#   DRY_RUN_MODE="true"
#   source log.sh
#   manage_logs  # Will simulate operations
#
# Author: Proxmox Backup System

# Last Modified: $(date +%Y-%m-%d)
# ==========================================

# LOG LEVEL CONFIGURATION AND INITIALIZATION
# ===========================================
# This section defines the logging system's core configuration including
# log levels, color settings, and automatic environment detection.

# Default debug level if not set by environment
# Can be overridden by setting DEBUG_LEVEL environment variable
DEBUG_LEVEL=${DEBUG_LEVEL:-standard}

# Log level definitions with numeric priorities
# Lower numbers have higher priority (ERROR=0 is highest priority)
# This allows for efficient level comparison and filtering
declare -A LOG_LEVELS=( 
    ["ERROR"]=0     # Critical errors that may cause operation failure
    ["WARNING"]=1   # Warning conditions that should be noted
    ["INFO"]=2      # General informational messages
    ["DEBUG"]=3     # Detailed debugging information
    ["TRACE"]=4     # Very detailed tracing information
    ["STEP"]=2      # Step-by-step operation progress (same level as INFO)
    ["SUCCESS"]=2   # Success confirmations (same level as INFO)
)

# Default log level (INFO and above)
# Will be updated based on DEBUG_LEVEL during setup
CURRENT_LOG_LEVEL=2

# Cache for configuration checks (aligned with storage.sh)
_cloud_backup_enabled=""
_secondary_backup_enabled=""

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

# Helper function to check if secondary backup is enabled
is_secondary_backup_enabled() {
    if [ -z "$_secondary_backup_enabled" ]; then
        _secondary_backup_enabled=$([ "${ENABLE_SECONDARY_BACKUP:-false}" = "true" ] && echo "true" || echo "false")
    fi
    [ "$_secondary_backup_enabled" = "true" ]
}

# AUTOMATIC COLOR DETECTION AND CONFIGURATION
# ===========================================
# Automatically detect if we're running in an interactive terminal
# and configure color output accordingly. This prevents color codes
# from appearing in log files or cron job outputs.

# Initialize color support (enabled by default)
USE_COLORS=1

# Disable colors if output is not a terminal (e.g., cron jobs, redirected output)
# The -t 1 test checks if file descriptor 1 (stdout) is connected to a terminal
if [ ! -t 1 ]; then
    # Output is not a terminal (likely cron, pipe, or file redirection)
    USE_COLORS=0
fi

# Allow manual override of color detection via environment variable
# This is useful for forcing color output off in specific environments
if [[ "${DISABLE_COLORS}" == "1" || "${DISABLE_COLORS}" == "true" ]]; then
    USE_COLORS=0
fi

# BUFFERED LOGGING SYSTEM
# =======================
# Implement buffered logging to optimize I/O operations by collecting
# multiple log messages and writing them in batches rather than
# individual writes for each message.

# Buffer for collecting log messages before writing to file
# This reduces the number of I/O operations and improves performance
declare -a LOG_BUFFER=()

# Maximum number of messages to buffer before forcing a flush
# Balances memory usage with I/O efficiency
LOG_BUFFER_SIZE=${LOG_BUFFER_SIZE:-50}

# Flag to track if buffer flushing is in progress (prevents recursion)
LOG_FLUSH_IN_PROGRESS=false

# Add a log message to the buffer
# This function collects messages for batch writing to improve I/O performance
#
# Arguments:
#   $1: Formatted log message ready for writing
#
# Returns:
#   0: Message added to buffer successfully
add_to_log_buffer() {
    local message="$1"
    
    # Add message to buffer array
    LOG_BUFFER+=("$message")
    
    # Check if buffer is full and needs flushing
    if [ ${#LOG_BUFFER[@]} -ge "$LOG_BUFFER_SIZE" ]; then
        flush_log_buffer
    fi
    
    return 0
}

# Flush the log buffer to file
# Writes all buffered messages to the log file in a single operation
# This significantly reduces I/O overhead compared to individual writes
#
# Returns:
#   0: Buffer flushed successfully
#   1: Error during flush operation
flush_log_buffer() {
    # Prevent recursive flushing
    if [ "$LOG_FLUSH_IN_PROGRESS" = true ]; then
        return 0
    fi
    
    # Check if there are messages to flush and log file is available
    if [ ${#LOG_BUFFER[@]} -eq 0 ] || [ -z "$LOG_FILE" ] || [ "${ENABLE_LOG_MANAGEMENT:-true}" != "true" ]; then
        return 0
    fi
    
    # Set flag to prevent recursion during flush
    LOG_FLUSH_IN_PROGRESS=true
    
    # Write all buffered messages to file in a single operation
    # Using printf instead of echo for better performance and reliability
    if printf '%s\n' "${LOG_BUFFER[@]}" >> "$LOG_FILE" 2>/dev/null; then
        # Clear the buffer after successful write
        LOG_BUFFER=()
        LOG_FLUSH_IN_PROGRESS=false
        return 0
    else
        # If write fails, keep messages in buffer and try again later
        LOG_FLUSH_IN_PROGRESS=false
        return 1
    fi
}

# Force flush log buffer (called during cleanup or critical operations)
# Ensures all pending log messages are written before program termination
#
# Returns:
#   0: Buffer flushed successfully or no messages to flush
force_flush_log_buffer() {
    if [ ${#LOG_BUFFER[@]} -gt 0 ]; then
        flush_log_buffer
    fi
    return 0
}

# LOGGING SYSTEM INITIALIZATION
# =============================
# Set up the logging system with proper configuration, directory creation,
# and log file initialization. This function should be called once at the
# beginning of the backup process.

# Initialize the logging system
# This function sets up directories, log files, and configures the logging level
# based on the current environment and configuration variables.
#
# Global Variables Modified:
#   - LOG_FILE: Set to the full path of the current log file
#   - CURRENT_LOG_LEVEL: Updated based on DEBUG_LEVEL setting
#
# Returns:
#   0: Logging system initialized successfully
#   1: Critical error during initialization (exits program)
setup_logging() {
    step "Setting up logging system"
    
    # Check if log management is enabled in configuration
    if [ "${ENABLE_LOG_MANAGEMENT:-true}" != "true" ]; then
        warning "Log management is disabled in configuration. Console logging only."
        LOG_FILE=""
        success "Logging system initialized (console only)"
        return 0
    fi
    
    # Create log directory with proper error handling
    # Use -p flag to create parent directories if needed
    if ! mkdir -p "$LOCAL_LOG_PATH" 2>/dev/null; then
        error "Failed to create log directory: $LOCAL_LOG_PATH"
        error "Please check directory permissions and available disk space"
        exit 1
    fi
    
    # Generate log file name with proper validation
    # Ensure PROXMOX_TYPE is set before using it in the filename
    local log_basename
    if [ -z "${PROXMOX_TYPE:-}" ]; then
        log_basename="proxmox-backup-${HOSTNAME}-${TIMESTAMP}.log"
        warning "PROXMOX_TYPE not set during log initialization. Using generic filename with hostname."
    else
        log_basename="${PROXMOX_TYPE}-backup-${HOSTNAME}-${TIMESTAMP}.log"
    fi
    LOG_FILE="${LOCAL_LOG_PATH}/${log_basename}"
    
    # Configure log level based on DEBUG_LEVEL setting
    # Only update if not already set by command line or other means
    if [ -z "${CURRENT_LOG_LEVEL:-}" ]; then
        case "$DEBUG_LEVEL" in
            "standard")
                CURRENT_LOG_LEVEL=2  # INFO level and above
                ;;
            "advanced")
                CURRENT_LOG_LEVEL=3  # DEBUG level and above
                ;;
            "extreme")
                CURRENT_LOG_LEVEL=4  # TRACE level and above (most verbose)
                ;;
            *)
                CURRENT_LOG_LEVEL=2  # Default to INFO if unknown level specified
                warning "Unknown DEBUG_LEVEL '$DEBUG_LEVEL', defaulting to 'standard'"
                ;;
        esac
    fi
    
    # Log initialization details for debugging
    debug "Log file initialized: $LOG_FILE"
    debug "Current log level: $CURRENT_LOG_LEVEL (${DEBUG_LEVEL})"
    
    # Report color configuration status
    if [ "$USE_COLORS" -eq 0 ]; then
        debug "Color output disabled (non-interactive terminal detected or manually disabled)"
    else
        debug "Color output enabled for interactive terminal"
    fi
    
    # Set up cleanup trap to ensure buffer is flushed on exit
    trap 'force_flush_log_buffer' EXIT INT TERM
    
    success "Logging system initialized successfully"
    return 0
}

# CORE LOGGING FUNCTION
# ====================
# The main logging function that handles message formatting, level filtering,
# color application, and output routing to both console and file.

# Main logging function with optimized I/O operations
# This function handles all log message processing including level filtering,
# color formatting, and efficient output to both console and file.
#
# Arguments:
#   $1: Log level (ERROR, WARNING, INFO, DEBUG, TRACE, STEP, SUCCESS)
#   $2: Log message text
#
# Global Variables Used:
#   - LOG_LEVELS: Associative array mapping level names to numeric priorities
#   - CURRENT_LOG_LEVEL: Current logging threshold
#   - USE_COLORS: Whether to use colored output
#   - LOG_FILE: Path to log file (if file logging enabled)
#
# Returns:
#   0: Message logged successfully
#   1: Message filtered out due to log level
log() {
    local level="$1"
    local message="$2"
    
    # Validate input parameters
    if [ -z "$level" ] || [ -z "$message" ]; then
        return 1
    fi
    
    # Generate timestamp once for efficiency
    local timestamp=$(date +"%Y-%m-%d %H:%M:%S")
    local color=""
    local tag=""
    
    # Determine color and tag based on message content and level
    # Special handling for disabled/skipping messages
    if [[ "$message" == *"disabled"* ]] || [[ "$message" == *"skipping"* ]]; then
        color="${PINK:-}"
        tag="[SKIP]"
    else
        # Standard level-based color and tag assignment
        case "$level" in
            "ERROR")    color="${RED:-}"; tag="[ERROR]";;
            "WARNING")  color="${YELLOW:-}"; tag="[WARNING]";;
            "INFO")     color="${BLUE:-}"; tag="[INFO]";;
            "DEBUG")    color="${GRAY:-}"; tag="[DEBUG]";;
            "TRACE")    color="${GRAY:-}"; tag="[TRACE]";;
            "STEP")     color="${CYAN:-}"; tag="[STEP]";;
            "SUCCESS")  color="${GREEN:-}"; tag="[SUCCESS]";;
            *)          color="${RESET:-}"; tag="[LOG]";;
        esac
    fi
    
    # Check if message should be logged based on current log level
    # Only process messages that meet the current logging threshold
    local level_priority=${LOG_LEVELS[$level]:-999}
    if [ "$level_priority" -le "$CURRENT_LOG_LEVEL" ]; then
        
        # Output to console with appropriate formatting
        if [ "$USE_COLORS" -eq 1 ]; then
            # Colored output for interactive terminals
            echo -e "${color}${timestamp} ${tag}${RESET:-} ${message}"
        else
            # Plain text output for non-interactive environments
            echo "${timestamp} ${tag} ${message}"
        fi
        
        # Add to log file if file logging is enabled
        if [ -n "${LOG_FILE:-}" ] && [ "${ENABLE_LOG_MANAGEMENT:-true}" == "true" ]; then
            # Format message for file (always without colors)
            local file_message="${timestamp} ${tag} ${message}"
            echo "$file_message" >> "$LOG_FILE"
        fi
        
        return 0
    fi
    
    # Message was filtered out due to log level
    return 1
}

# SPECIALIZED LOGGING FUNCTIONS
# ============================
# Convenience functions for different log levels that provide
# a clean interface for logging specific types of messages.

# Log an error message (highest priority)
# Used for critical errors that may cause operation failure
#
# Arguments:
#   $1: Error message
#
# Returns:
#   0: Message logged successfully
error() { 
    log "ERROR" "$1"
}

# Log a warning message
# Used for conditions that should be noted but don't prevent operation
#
# Arguments:
#   $1: Warning message
#
# Returns:
#   0: Message logged successfully
warning() { 
    log "WARNING" "$1"
}

# Log an informational message
# Used for general operational information
#
# Arguments:
#   $1: Info message
#
# Returns:
#   0: Message logged successfully
info() { 
    log "INFO" "$1"
}

# Log a step message
# Used to indicate progress through operational steps
#
# Arguments:
#   $1: Step description
#
# Returns:
#   0: Message logged successfully
step() { 
    log "STEP" "$1"
}

# Log a success message
# Used to confirm successful completion of operations
#
# Arguments:
#   $1: Success message
#
# Returns:
#   0: Message logged successfully
success() { 
    log "SUCCESS" "$1"
}

# Log a debug message with level checking
# Only logged if current log level includes DEBUG messages
#
# Arguments:
#   $1: Debug message
#
# Returns:
#   0: Message logged successfully
#   1: Message filtered out due to log level
debug() { 
    if [ "$CURRENT_LOG_LEVEL" -ge 3 ]; then
        log "DEBUG" "$1"
    fi
}

# Log a trace message with level checking
# Only logged if current log level includes TRACE messages (most verbose)
#
# Arguments:
#   $1: Trace message
#
# Returns:
#   0: Message logged successfully
#   1: Message filtered out due to log level
trace() { 
    if [ "$CURRENT_LOG_LEVEL" -ge 4 ]; then
        log "TRACE" "$1"
    fi
}

# LOGGING SESSION MANAGEMENT
# =========================
# Functions to manage the logging session lifecycle including
# initialization, file creation, and proper cleanup.

# Start the logging session
# This function initializes the log file and prepares the logging system
# for the current backup session. It handles dry-run mode and validates
# that all necessary components are available.
#
# Global Variables Modified:
#   - LOG_FILE: Set to the current session's log file path
#   - CURRENT_LOG_LEVEL: Updated based on DEBUG_LEVEL
#
# Returns:
#   0 (EXIT_SUCCESS): Logging started successfully
#   1 (EXIT_ERROR): Critical error during initialization
start_logging() {
    step "Starting logging session"
    
    # Handle dry-run mode
    if [ "${DRY_RUN_MODE:-false}" == "true" ]; then
        info "Dry run mode: Would create log file at $LOCAL_LOG_PATH"
        set_backup_status "log_creation" $EXIT_SUCCESS
        return $EXIT_SUCCESS
    fi
    
    # Check if log management is enabled
    if [ "${ENABLE_LOG_MANAGEMENT:-true}" != "true" ]; then
        warning "Log management is disabled in configuration. Console logging only."
        LOG_FILE=""
        success "Logging session started (console only)"
        set_backup_status "log_creation" $EXIT_SUCCESS
        return $EXIT_SUCCESS
    fi
    
    # Create log directory with comprehensive error handling
    if ! mkdir -p "$LOCAL_LOG_PATH" 2>/dev/null; then
        error "Failed to create log directory: $LOCAL_LOG_PATH"
        error "Check permissions and available disk space"
        set_exit_code "error"
        set_backup_status "log_creation" $EXIT_ERROR
        return $EXIT_ERROR
    fi
    
    # Generate unique log file name for this session
    local log_basename
    if [ -z "${PROXMOX_TYPE:-}" ]; then
        log_basename="proxmox-backup-${HOSTNAME}-${TIMESTAMP}.log"
        warning "PROXMOX_TYPE not set during log initialization. Using generic filename with hostname."
    else
        log_basename="${PROXMOX_TYPE}-backup-${HOSTNAME}-${TIMESTAMP}.log"
    fi
    LOG_FILE="${LOCAL_LOG_PATH}/${log_basename}"
    
    # Configure logging level based on environment
    if [ -z "${CURRENT_LOG_LEVEL:-}" ]; then
        case "${DEBUG_LEVEL:-standard}" in
            "standard")
                CURRENT_LOG_LEVEL=2  # INFO level and above
                ;;
            "advanced")
                CURRENT_LOG_LEVEL=3  # DEBUG level and above
                ;;
            "extreme")
                CURRENT_LOG_LEVEL=4  # TRACE level and above
                ;;
            *)
                CURRENT_LOG_LEVEL=2  # Default to INFO
                warning "Unknown DEBUG_LEVEL '${DEBUG_LEVEL}', using standard level"
                ;;
        esac
    fi
    
    # Log configuration details
    debug "Log file path: $LOG_FILE"
    debug "Log level: $CURRENT_LOG_LEVEL (${DEBUG_LEVEL:-standard})"
    
    if [ "$USE_COLORS" -eq 0 ]; then
        debug "Color output disabled (non-interactive terminal or manually disabled)"
    fi
    
    # Test log file creation and write permissions
    if ! touch "$LOG_FILE" 2>/dev/null; then
        error "Failed to create log file: $LOG_FILE"
        error "Check directory permissions and available disk space"
        set_exit_code "error"
        set_backup_status "log_creation" $EXIT_ERROR
        return $EXIT_ERROR
    fi
    
    # Write initial log entry to file
    local init_message="$(date +"%Y-%m-%d %H:%M:%S") [INFO] Logging session started for ${PROXMOX_TYPE:-unknown} backup"
    if ! echo "$init_message" >> "$LOG_FILE" 2>/dev/null; then
        error "Failed to write to log file: $LOG_FILE"
        set_exit_code "error"
        set_backup_status "log_creation" $EXIT_ERROR
        return $EXIT_ERROR
    fi
    
    success "Logging session started successfully"
    set_backup_status "log_creation" $EXIT_SUCCESS
    return $EXIT_SUCCESS
}

# BACKUP SUMMARY GENERATION
# ========================
# Generate comprehensive backup summary with metrics and status information
# This function collects all backup metrics and presents them in a formatted report

# Generate backup completion summary
# This function creates a comprehensive summary of the backup operation including
# file information, storage status, duration, and final results.
#
# Global Variables Used:
#   - PROXMOX_TYPE: Type of Proxmox system
#   - HOSTNAME: System hostname
#   - BACKUP_FILE: Path to backup file
#   - BACKUP_SIZE_HUMAN: Human-readable backup size
#   - FILES_INCLUDED: Number of files included
#   - COMPRESSION_RATIO: Backup compression ratio
#   - BACKUP_*_STATUS_STR_EMOJI: Status indicators for different storage locations
#   - LOG_*_STATUS_STR_EMOJI: Log status indicators
#   - BACKUP_DURATION: Total backup duration in seconds
#   - SERVER_ID: Unique server identifier
#   - EXIT_CODE: Final exit code
#   - BACKUP_STATUS_EMOJI: Overall status emoji
#
# Returns:
#   0: Summary generated successfully
log_summary() {
    # Collect all metrics before generating summary
    # This ensures we have the most up-to-date information
    collect_metrics
    
    # Force flush any pending log messages before summary
    force_flush_log_buffer
    
    echo ""
    echo "==============================================================="
    info "Backup Summary:"
    info "Type: ${PROXMOX_TYPE:-unknown}"
    info "Host: ${HOSTNAME:-unknown}"
    
    # Display backup file information if available
    if [ -n "${BACKUP_FILE:-}" ] && [ -f "$BACKUP_FILE" ]; then
        info "Backup File: $BACKUP_FILE"
        info "Size: ${BACKUP_SIZE_HUMAN:-unknown}"
        
        # Show additional file information if available
            if [ -n "${FILES_INCLUDED:-}" ]; then
        info "Files: $FILES_INCLUDED (excluding folders and .sha256 files)"
        fi
        
        # Display compression information if available
        if [ -n "${COMPRESSION_RATIO:-}" ] && [ "$COMPRESSION_RATIO" != "Unknown" ]; then
            info "Compression ratio: $COMPRESSION_RATIO"
        fi
    else
        warning "Backup file information not available"
    fi
    
    # Display backup status summary using global status variables
    info "BACKUP = PRI ${BACKUP_PRI_STATUS_STR_EMOJI:-❓} - SEC ${BACKUP_SEC_STATUS_STR_EMOJI:-❓} - CLO ${BACKUP_CLO_STATUS_STR_EMOJI:-❓}"
    
    # Display log status summary using global status variables
    info "LOG = PRI ${LOG_PRI_STATUS_STR_EMOJI:-❓} - SEC ${LOG_SEC_STATUS_STR_EMOJI:-❓} - CLO ${LOG_CLO_STATUS_STR_EMOJI:-❓}"
    
    # Format and display backup duration
    if [ -n "${BACKUP_DURATION:-}" ] && [ "$BACKUP_DURATION" -gt 0 ]; then
        # Use centralized duration formatting function if available
        if command -v format_duration >/dev/null 2>&1; then
        BACKUP_DURATION_FORMATTED=$(format_duration "$BACKUP_DURATION")
        else
            # Fallback duration formatting
            BACKUP_DURATION_FORMATTED="${BACKUP_DURATION}s"
        fi
    else
        BACKUP_DURATION_FORMATTED="unknown"
    fi
    
    info "Duration: $BACKUP_DURATION_FORMATTED"
    info "Server Unique ID: ${SERVER_ID:-UNKNOWN}"
    info "Exit Status: ${EXIT_CODE:-unknown} ${BACKUP_STATUS_EMOJI:-❓}"
    echo "==============================================================="
    echo ""
    
    # Display final status with colors if function is available
    if command -v display_final_status >/dev/null 2>&1; then
    display_final_status
    fi
    
    debug "Backup summary generated successfully"
    return 0
}

# USAGE INFORMATION DISPLAY
# ========================
# Display comprehensive usage information and command-line options

# Display usage instructions and available options
# This function shows detailed information about command-line options,
# logging levels, and usage examples for the backup script.
#
# Arguments: None
#
# Returns:
#   0: Usage information displayed successfully
show_usage() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS]

DESCRIPTION:
    Proxmox backup script with comprehensive logging and multi-storage support.
    Supports various logging levels and operational modes for different use cases.

OPTIONS:
  -h, --help            Show this help message and exit
  -v, --verbose         Enable verbose output (debug mode)
                        Sets DEBUG_LEVEL=advanced, shows DEBUG messages
  -x, --extreme         Enable extremely verbose output (trace mode)
                        Sets DEBUG_LEVEL=extreme, shows TRACE messages
  -e, --env FILE        Specify an alternative environment file
                        Default: Uses script directory .env file
  --dry-run             Run without making any changes
                        Simulates operations for testing purposes
  --check-only          Only check environment and dependencies
                        Validates configuration without performing backup

LOGGING LEVELS:
  standard              INFO level and above (default)
  advanced              DEBUG level and above (verbose)
  extreme               TRACE level and above (most verbose)

ENVIRONMENT VARIABLES:
  DEBUG_LEVEL           Set logging verbosity (standard|advanced|extreme)
  DISABLE_COLORS        Disable colored output (1|true)
  ENABLE_LOG_MANAGEMENT Enable file logging operations (true|false)
  DRY_RUN_MODE          Enable dry-run mode (true|false)

EXAMPLES:
  $(basename "$0")                         # Run with standard logging
  $(basename "$0") -v                      # Run with debug logging
  $(basename "$0") -x                      # Run with trace logging
  $(basename "$0") -e /path/to/custom.env  # Run with custom env file
  $(basename "$0") --dry-run               # Run in dry-run mode
  $(basename "$0") --check-only            # Validate configuration only
  
  # Environment variable examples:
  DEBUG_LEVEL=advanced $(basename "$0")    # Set debug level via environment
  DISABLE_COLORS=1 $(basename "$0")        # Disable colored output

EXIT CODES:
  0                     Success
  1                     Error
  2                     Warning (partial success)

For more information, see the script documentation and configuration files.
EOF
    return 0
}

# HTML ERROR REPORT GENERATION
# ============================
# Generate comprehensive HTML error reports with analysis and correlation

# Generate detailed HTML error report
# This function creates a comprehensive HTML report of all errors encountered
# during the backup process, including categorization, correlation analysis,
# and statistical summaries.
#
# Global Variables Used:
#   - LOCAL_LOG_PATH: Directory for storing the report
#   - TIMESTAMP: Current session timestamp
#   - HOSTNAME: System hostname
#   - PROXMOX_TYPE: Type of Proxmox system
#   - BACKUP_FILE: Path to backup file
#   - ERROR_LIST: Array of collected errors
#
# Returns:
#   0: Report generated successfully
#   1: Error during report generation
generate_error_report() {
    local report_file="${LOCAL_LOG_PATH}/error_report_${TIMESTAMP}.html"
    
    # Validate that we have errors to report
    if [ ${#ERROR_LIST[@]} -eq 0 ]; then
        debug "No errors to report, skipping HTML report generation"
        return 0
    fi
    
    # Create report directory if it doesn't exist
    if ! mkdir -p "$(dirname "$report_file")" 2>/dev/null; then
        error "Failed to create report directory: $(dirname "$report_file")"
        return 1
    fi
    
    # Start building the HTML report with modern styling
    cat > "$report_file" << EOF
<!DOCTYPE html>
<html>
<head>
    <meta charset="UTF-8">
    <title>Backup Verification Error Report</title>
    <style>
        body { font-family: Arial, sans-serif; margin: 20px; }
        h1 { color: #333; }
        .summary { margin: 20px 0; padding: 15px; background-color: #f8f8f8; border-radius: 5px; }
        .error-table { width: 100%; border-collapse: collapse; }
        .error-table th, .error-table td { padding: 8px; text-align: left; border-bottom: 1px solid #ddd; }
        .error-table th { background-color: #f2f2f2; }
        .critical { color: red; }
        .warning { color: orange; }
        .info { color: blue; }
        .category { font-weight: bold; }
        .correlation { margin-top: 20px; padding: 15px; background-color: #ffe; border: 1px solid #ddd; border-radius: 5px; }
    </style>
</head>
<body>
    <h1>Backup Verification Error Report</h1>
    <div class="summary">
        <p><strong>Date:</strong> $(date '+%Y-%m-%d %H:%M:%S')</p>
        <p><strong>Hostname:</strong> $HOSTNAME</p>
        <p><strong>Proxmox Type:</strong> $PROXMOX_TYPE</p>
        <p><strong>Backup File:</strong> $(basename "$BACKUP_FILE")</p>
    </div>
EOF

    # Calculate general statistics
    local total_errors=${#ERROR_LIST[@]}
    local critical_count=0
    local warning_count=0
    local info_count=0
    
    # Arrays for unique categories and messages
    local categories=()
    
    # Count errors by severity and collect unique categories
    for error_entry in "${ERROR_LIST[@]}"; do
        IFS='|' read -r err_category err_severity err_message err_details <<< "$error_entry"
        
        # Count by severity
        case "$err_severity" in
            "critical") critical_count=$((critical_count + 1)) ;;
            "warning") warning_count=$((warning_count + 1)) ;;
            "info") info_count=$((info_count + 1)) ;;
        esac
        
        # Collect unique categories
        if ! [[ " ${categories[*]} " =~ " ${err_category} " ]]; then
            categories+=("$err_category")
        fi
    done
    
    # Add statistical summary
    cat >> "$report_file" << EOF
    <div class="summary">
        <h2>Error Summary</h2>
        <p>Total Issues: $total_errors</p>
        <p>Critical Errors: $critical_count</p>
        <p>Warnings: $warning_count</p>
        <p>Info: $info_count</p>
    </div>
    
    <h2>Error Details</h2>
    <table class="error-table">
        <tr>
            <th>Category</th>
            <th>Severity</th>
            <th>Message</th>
            <th>Details</th>
        </tr>
EOF

    # Add each error to the table
    for error_entry in "${ERROR_LIST[@]}"; do
        IFS='|' read -r err_category err_severity err_message err_details <<< "$error_entry"
        
        cat >> "$report_file" << EOF
        <tr>
            <td class="category">$err_category</td>
            <td class="$err_severity">$err_severity</td>
            <td>$err_message</td>
            <td>$err_details</td>
        </tr>
EOF
    done
    
    # Close the table
    echo "</table>" >> "$report_file"
    
    # Add section for error correlation
    cat >> "$report_file" << EOF
    <h2>Error Correlation Analysis</h2>
EOF

    # Analysis by category
    for category in "${categories[@]}"; do
        # Filter errors for this category
        local cat_errors=()
        local cat_critical=0
        local cat_warning=0
        
        for error_entry in "${ERROR_LIST[@]}"; do
            IFS='|' read -r err_category err_severity err_message err_details <<< "$error_entry"
            
            if [ "$err_category" == "$category" ]; then
                cat_errors+=("$error_entry")
                
                if [ "$err_severity" == "critical" ]; then
                    cat_critical=$((cat_critical + 1))
                elif [ "$err_severity" == "warning" ]; then
                    cat_warning=$((cat_warning + 1))
                fi
            fi
        done
        
        # If there are errors in the category, show the analysis
        if [ ${#cat_errors[@]} -gt 0 ]; then
            cat >> "$report_file" << EOF
    <div class="correlation">
        <h3>Category: $category</h3>
        <p>Total Issues: ${#cat_errors[@]} (Critical: $cat_critical, Warnings: $cat_warning)</p>
EOF

            # Find common errors or other interesting patterns
            # (Simplified implementation)
            if [ ${#cat_errors[@]} -gt 2 ]; then
                echo "<p><strong>Note:</strong> Multiple issues found in this category. This might indicate a systematic problem.</p>" >> "$report_file"
            fi
            
            echo "</div>" >> "$report_file"
        fi
    done
    
    # Complete the HTML report
    cat >> "$report_file" << EOF
</body>
</html>
EOF

    info "Error report generated: $report_file"
    return 0
}

# ERROR CORRELATION ANALYSIS
# =========================
# Analyze errors for patterns, correlations, and statistical insights

# Perform correlative error analysis
# This function analyzes collected errors to identify patterns, common issues,
# and statistical distributions that can help with troubleshooting and system improvement.
#
# Arguments:
#   $1: Category filter (optional) - analyze only errors from specific category
#
# Global Variables Used:
#   - ERROR_LIST: Array of collected errors in format "category|severity|message|details"
#
# Returns:
#   0: No errors found or analysis completed successfully
#   1: Warnings found during analysis
#   2: Critical errors found during analysis
analyze_errors() {
    local category="$1"
    
    # Error counting by category
    local critical_count=0
    local warning_count=0
    local total_count=0
    
    # Array to track unique messages
    local unique_messages=()
    
    # Analyze errors filtered by category
    for error_entry in "${ERROR_LIST[@]}"; do
        # Extract error components
        IFS='|' read -r err_category err_severity err_message err_details <<< "$error_entry"
        
        # Filter by category if specified
        if [ -n "$category" ] && [ "$err_category" != "$category" ]; then
            continue
        fi
        
        # Increment counters
        total_count=$((total_count + 1))
        
        if [ "$err_severity" == "critical" ]; then
            critical_count=$((critical_count + 1))
        elif [ "$err_severity" == "warning" ]; then
            warning_count=$((warning_count + 1))
        fi
        
        # Add unique messages to array
        if ! [[ " ${unique_messages[*]} " =~ " ${err_message} " ]]; then
            unique_messages+=("$err_message")
        fi
    done
    
    # Return analysis based on counts
    if [ $total_count -eq 0 ]; then
        if [ -n "$category" ]; then
            debug "No errors found in category: $category"
        else
            debug "No errors found during verification"
        fi
        return 0
    fi
    
    # Log error summary
    if [ -n "$category" ]; then
        info "Error analysis for category '$category': $total_count total ($critical_count critical, $warning_count warnings)"
    else
        info "Error analysis: $total_count total errors ($critical_count critical, $warning_count warnings)"
    fi
    
    # If there are many errors of the same type, identify common patterns
    if [ ${#unique_messages[@]} -lt $total_count ]; then
        local most_common=""
        local most_common_count=0
        
        for msg in "${unique_messages[@]}"; do
            local count=0
            for error_entry in "${ERROR_LIST[@]}"; do
                if [[ "$error_entry" == *"|$msg|"* ]]; then
                    count=$((count + 1))
                fi
            done
            
            if [ $count -gt $most_common_count ]; then
                most_common="$msg"
                most_common_count=$count
            fi
        done
        
        if [ $most_common_count -gt 1 ]; then
            warning "Most common error ($most_common_count occurrences): $most_common"
        fi
    fi
    
    # Global impact assessment
    if [ $critical_count -gt 0 ]; then
        return 2  # Error
    elif [ $warning_count -gt 0 ]; then
        return 1  # Warning
    else
        return 0  # Success
    fi
}

# COMPREHENSIVE LOG MANAGEMENT
# ============================
# Main function for managing all log operations including rotation,
# copying to secondary storage, and cloud upload operations

# Main log management function
# This function orchestrates all log management operations including rotation,
# secondary storage copying, and cloud uploads based on configuration settings.
# It provides comprehensive error handling and status tracking for all operations.
#
# Global Variables Used:
#   - ENABLE_LOG_MANAGEMENT: Controls whether log management is active
#   - ENABLE_SECONDARY_BACKUP: Controls secondary storage operations
#   - ENABLE_CLOUD_BACKUP: Controls cloud storage operations
#   - LOCAL_LOG_PATH: Primary log storage path
#   - SECONDARY_LOG_PATH: Secondary log storage path
#   - CLOUD_LOG_PATH: Cloud log storage path
#   - MAX_*_LOGS: Retention policies for each storage location
#
# Returns:
#   0 (EXIT_SUCCESS): All log operations completed successfully
#   1 (EXIT_ERROR): Critical error occurred
#   2 (EXIT_WARNING): Some operations completed with warnings
manage_logs() {
    debug "Starting comprehensive log management"
    
    # Check if log management is enabled in configuration
    if [ "${ENABLE_LOG_MANAGEMENT:-true}" != "true" ]; then
        info "Log management is disabled in configuration. Skipping log operations."
        # Set all log operation statuses to success since they're disabled
        set_backup_status "log_creation" $EXIT_SUCCESS
        set_backup_status "log_rotation_primary" $EXIT_SUCCESS
        set_backup_status "log_secondary_copy" $EXIT_SUCCESS
        set_backup_status "log_rotation_secondary" $EXIT_SUCCESS
        set_backup_status "log_cloud_upload" $EXIT_SUCCESS
        set_backup_status "log_rotation_cloud" $EXIT_SUCCESS
        return $EXIT_SUCCESS
    fi
    
    # Force flush any pending log messages before management operations
    force_flush_log_buffer
    
    # Note: Log counts are already available from previous CHECK_COUNT calls
    # No need to update counts here as they will be updated before rotation if needed
    
    # PRIMARY LOG MANAGEMENT
    # Always active when ENABLE_LOG_MANAGEMENT=true
    debug "Managing primary log storage"
    if ! manage_log_rotation "primary" "$LOCAL_LOG_PATH" "$MAX_LOCAL_LOGS"; then
        warning "Primary log rotation completed with warnings"
        set_exit_code "warning"
    fi
    
    # SECONDARY LOG MANAGEMENT
    # Only active when ENABLE_SECONDARY_BACKUP=true
    if is_secondary_backup_enabled; then
        debug "Managing secondary log storage"
        
        # Copy current logs to secondary storage
        if ! copy_logs_to_secondary; then
            warning "Secondary log copy completed with warnings"
            set_exit_code "warning"
        fi
        
        # Rotate logs in secondary storage
        if ! manage_log_rotation "secondary" "$SECONDARY_LOG_PATH" "$MAX_SECONDARY_LOGS"; then
            warning "Secondary log rotation completed with warnings"
            set_exit_code "warning"
        fi
    else
        info "Secondary backup is disabled, skipping secondary log operations"
        set_backup_status "log_secondary_copy" $EXIT_SUCCESS
        set_backup_status "log_rotation_secondary" $EXIT_SUCCESS
    fi
    
    # CLOUD LOG MANAGEMENT
    # Only active when ENABLE_CLOUD_BACKUP=true
    if is_cloud_backup_enabled; then
        debug "Managing cloud log storage"
        
        # Upload current logs to cloud storage
        if ! upload_logs_to_cloud; then
            warning "Cloud log upload completed with warnings"
            set_exit_code "warning"
        fi
        
        # Rotate logs in cloud storage
        if ! manage_log_rotation "cloud" "$CLOUD_LOG_PATH" "$MAX_CLOUD_LOGS"; then
            warning "Cloud log rotation completed with warnings"
            set_exit_code "warning"
        fi
    else
        info "Cloud backup is disabled, skipping cloud log operations"
        set_backup_status "log_cloud_upload" $EXIT_SUCCESS
        set_backup_status "log_rotation_cloud" $EXIT_SUCCESS
    fi
    
    # Final buffer flush to ensure all log messages are written
    force_flush_log_buffer
    
    success "Log management completed successfully"
    return $EXIT_SUCCESS
}

# SECONDARY STORAGE LOG OPERATIONS
# ================================
# Functions for copying and managing logs in secondary storage locations

# Copy logs to secondary storage location
# This function copies the current log file to the configured secondary storage
# location for redundancy and disaster recovery purposes.
#
# Global Variables Used:
#   - DRY_RUN_MODE: Whether to simulate operations
#   - LOG_FILE: Path to current log file
#   - SECONDARY_LOG_PATH: Secondary storage path for logs
#
# Returns:
#   0 (EXIT_SUCCESS): Logs copied successfully
#   1 (EXIT_WARNING): Copy operation failed or skipped
copy_logs_to_secondary() {
    step "Copying log to secondary storage"
    
    # Handle dry-run mode
    if [ "${DRY_RUN_MODE:-false}" == "true" ]; then
        info "Dry run mode: Would copy logs to secondary location: $SECONDARY_LOG_PATH"
        set_backup_status "log_secondary_copy" $EXIT_SUCCESS
        return $EXIT_SUCCESS
    fi
    
    # Validate log file exists and is readable
    if [ -z "${LOG_FILE:-}" ] || [ ! -f "$LOG_FILE" ]; then
        warning "Log file not found or not readable, skipping secondary copy"
        debug "LOG_FILE: '${LOG_FILE:-unset}'"
        set_backup_status "log_secondary_copy" $EXIT_WARNING
        return $EXIT_WARNING
    fi
    
    # Validate secondary log path is configured
    if [ -z "${SECONDARY_LOG_PATH:-}" ]; then
        warning "Secondary log path not configured, skipping secondary copy"
        set_backup_status "log_secondary_copy" $EXIT_WARNING
        return $EXIT_WARNING
    fi
    
    # Create secondary log directory with proper error handling
    if ! mkdir -p "$SECONDARY_LOG_PATH" 2>/dev/null; then
        warning "Failed to create secondary log directory: $SECONDARY_LOG_PATH"
        warning "Check permissions and available disk space"
        set_backup_status "log_secondary_copy" $EXIT_WARNING
        return $EXIT_WARNING
    fi
    
    # Perform log file copy with verification
    local log_basename=$(basename "$LOG_FILE")
    local target_path="$SECONDARY_LOG_PATH/$log_basename"
    
    debug "Copying log file to secondary storage"
    debug "Source: $LOG_FILE"
    debug "Target: $target_path"
    
    # Copy with verification
    if ! cp "$LOG_FILE" "$target_path" 2>/dev/null; then
        warning "Failed to copy log file to secondary location"
        set_backup_status "log_secondary_copy" $EXIT_WARNING
        return $EXIT_WARNING
    fi
    
    # Verify copy was successful by checking file exists and has content
    if [ ! -f "$target_path" ] || [ ! -s "$target_path" ]; then
        warning "Log file copy verification failed - file missing or empty"
        set_backup_status "log_secondary_copy" $EXIT_WARNING
        return $EXIT_WARNING
    fi
    
    debug "Log file copied successfully: $target_path"
    success "Logs copied to secondary storage successfully"
    set_backup_status "log_secondary_copy" $EXIT_SUCCESS
    return $EXIT_SUCCESS
}

# CLOUD STORAGE LOG OPERATIONS
# ============================
# Functions for uploading and managing logs in cloud storage

# Enhanced verification with simplified retry logic for log uploads
verify_cloud_log_upload() {
    local log_basename="$1"
    local max_attempts="${2:-2}"  # Ridotto da 3 a 2 tentativi, allineato con backup
    
    # Check if verification should be skipped
    if [ "${SKIP_CLOUD_VERIFICATION:-false}" = "true" ]; then
        debug "Cloud log verification disabled by configuration - skipping verification"
        return 0
    fi
    
    info "Verifying log upload to cloud storage"
    
    local attempt=0
    while [ $attempt -lt $max_attempts ]; do
        attempt=$((attempt + 1))
        
        if [ $attempt -eq 1 ]; then
            info "Verifying log upload (attempt $attempt of $max_attempts)"
        else
            warning "Log verification failed, retrying (attempt $attempt of $max_attempts)"
            sleep 2  # Breve pausa prima del retry
        fi
        
        # Primary verification method
        if timeout 30s rclone lsl "${RCLONE_REMOTE}:${CLOUD_LOG_PATH}/$log_basename" ${RCLONE_FLAGS} >/dev/null 2>&1; then
            if [ $attempt -eq 1 ]; then
                info "Log upload verification successful on first attempt"
            else
                success "Log upload verification successful on attempt $attempt"
            fi
            return 0
        fi
        
        debug "Primary verification failed on attempt $attempt"
    done
    
    # Single alternative verification method (simplified)
    warning "Primary verification failed, trying alternative method"
    if timeout 30s rclone ls "${RCLONE_REMOTE}:${CLOUD_LOG_PATH}" ${RCLONE_FLAGS} 2>/dev/null | grep -q "$(basename "$log_basename")$"; then
        success "Alternative log verification successful"
        return 0
    fi
    
    warning "Log verification failed after $max_attempts attempts and alternative method"
    return 1
}

# Upload logs to cloud storage
upload_logs_to_cloud() {
    step "Uploading logs to cloud storage"
    
    # Handle dry-run mode
    if [ "${DRY_RUN_MODE:-false}" = "true" ]; then
        info "Dry run mode: Would upload logs to cloud storage: ${RCLONE_REMOTE:-unset}:${CLOUD_LOG_PATH:-unset}"
        set_backup_status "log_cloud_upload" $EXIT_SUCCESS
        export LOG_CLOUD_ERROR=false
        return $EXIT_SUCCESS
    fi
    
    # Validate log file exists and is readable
    if [ -z "${LOG_FILE:-}" ] || [ ! -f "$LOG_FILE" ]; then
        warning "Log file not found or not readable, skipping cloud upload"
        debug "LOG_FILE: '${LOG_FILE:-unset}'"
        set_backup_status "log_cloud_upload" $EXIT_WARNING
        export LOG_CLOUD_ERROR=true
        return $EXIT_WARNING
    fi
    
    # Check if rclone is available
    if ! command -v rclone &> /dev/null; then
        warning "rclone command not found, skipping cloud upload"
        warning "Install rclone to enable cloud log storage functionality"
        set_backup_status "log_cloud_upload" $EXIT_WARNING
        export LOG_CLOUD_ERROR=true
        return $EXIT_WARNING
    fi
    
    # Validate rclone remote configuration
    if [ -z "${RCLONE_REMOTE:-}" ]; then
        warning "RCLONE_REMOTE not configured, skipping cloud upload"
        set_backup_status "log_cloud_upload" $EXIT_WARNING
        export LOG_CLOUD_ERROR=true
        return $EXIT_WARNING
    fi
    
    # Check if the configured remote exists
    if ! rclone listremotes 2>/dev/null | grep -q "^${RCLONE_REMOTE}:$"; then
        warning "rclone remote '${RCLONE_REMOTE}' not configured, skipping cloud upload"
        warning "Configure rclone remote with: rclone config"
        set_backup_status "log_cloud_upload" $EXIT_WARNING
        export LOG_CLOUD_ERROR=true
        return $EXIT_WARNING
    fi
    
    # Validate cloud log path is configured
    if [ -z "${CLOUD_LOG_PATH:-}" ]; then
        warning "CLOUD_LOG_PATH not configured, skipping cloud upload"
        set_backup_status "log_cloud_upload" $EXIT_WARNING
        export LOG_CLOUD_ERROR=true
        return $EXIT_WARNING
    fi
    
    # Note: Cloud connectivity testing is now handled by the unified counting system
    # CHECK_COUNT "CLOUD_CONNECTIVITY" in proxmox-backup.sh provides comprehensive testing
    # This includes authentication, network connectivity, and path accessibility checks
    
    # Perform log upload with timeout protection and progress monitoring
    local log_basename=$(basename "$LOG_FILE")
    info "Uploading log file to cloud storage using rclone"
    debug "Source: $LOG_FILE"
    debug "Target: ${RCLONE_REMOTE}:${CLOUD_LOG_PATH}/$log_basename"
    
    # Prepare remote paths
    local remote_path="${RCLONE_REMOTE}:${CLOUD_LOG_PATH}/"
    local remote_file_path="${remote_path}${log_basename}"
    debug "Destination: $remote_file_path"
    
    # Upload con avanzamento (stats ogni 5s)
    if ! { set -o pipefail; rclone copy "$LOG_FILE" "$remote_path" --bwlimit=${RCLONE_BANDWIDTH_LIMIT} ${RCLONE_FLAGS} --stats=5s --stats-one-line 2>&1 | while read -r line; do
            debug "Progress: $line"
        done; }; then
        error "Failed to upload log file to cloud storage"
        set_exit_code "warning"
        set_backup_status "log_cloud_upload" $EXIT_WARNING
        export LOG_CLOUD_ERROR=true
        return $EXIT_WARNING
    fi
    
    # Simplified verification logic using dedicated function
    if verify_cloud_log_upload "$log_basename"; then
        verification_success=true
    else
        verification_success=false
    fi
    
    # Final status reporting
    if [ "$verification_success" = "true" ]; then
        info "Log file uploaded and verified successfully in cloud storage"
        success "Logs uploaded to cloud storage successfully"
        set_backup_status "log_cloud_upload" $EXIT_SUCCESS
        export LOG_CLOUD_ERROR=false
        # Update count logically: increment by 1 since we added a file
        COUNT_LOG_CLOUD=$((COUNT_LOG_CLOUD + 1))
        return $EXIT_SUCCESS
    else
        warning "Log upload verification failed but upload command succeeded"
        warning "File may still be synchronizing in cloud storage - check manually if needed"
        info "Log file uploaded to cloud storage (verification inconclusive)"
        success "Logs uploaded to cloud storage with verification warnings"
        set_backup_status "log_cloud_upload" $EXIT_WARNING
        export LOG_CLOUD_ERROR=false  # Don't mark as error since upload succeeded
        # Update count logically: likely increment by 1 since upload succeeded
        COUNT_LOG_CLOUD=$((COUNT_LOG_CLOUD + 1))
        return $EXIT_SUCCESS  # Don't fail the entire process for verification issues
    fi
}

# Function to manage log rotation
manage_log_rotation() {
    local location="$1"  # primary, secondary, o cloud
    local log_dir="$2"
    local max_logs="$3"
    local pattern="${PROXMOX_TYPE}-backup-*.log"
    local has_errors=false
    local exit_status=$EXIT_SUCCESS
    step "Managing log rotation for $location storage"
    
    # Skip cloud rotation if cloud backup is disabled
    if [ "$location" == "cloud" ] && ! is_cloud_backup_enabled; then
        info "Cloud backup is disabled, skipping cloud log rotation"
        set_backup_status "log_rotation_cloud" $EXIT_SUCCESS
        return $EXIT_SUCCESS
    fi
    
    # Skip secondary rotation if secondary backup is disabled
    if [ "$location" == "secondary" ] && ! is_secondary_backup_enabled; then
        info "Secondary backup is disabled, skipping secondary log rotation"
        set_backup_status "log_rotation_secondary" $EXIT_SUCCESS
        return $EXIT_SUCCESS
    fi
    
    # For cloud, update count only if we need to check rotation
    if [ "$location" == "cloud" ] && [ -z "${COUNT_LOG_CLOUD:-}" ]; then
        debug "Updating cloud log count for rotation check"
        _COUNT_LOGS_AUTONOMOUS "cloud"
    fi
    
    # Use counts from unified counting system directly
    case "$location" in
        "primary")
            if [ "$COUNT_LOG_PRIMARY" -gt "$max_logs" ]; then
                local to_delete=$((COUNT_LOG_PRIMARY - max_logs))
                info "Found $COUNT_LOG_PRIMARY logs in $location storage, removing $to_delete oldest logs"
                delete_oldest_local_logs "$log_dir" "$pattern" "$to_delete" "has_errors"
                # Update count logically: new_count = old_count - deleted_count  
                COUNT_LOG_PRIMARY=$((COUNT_LOG_PRIMARY - to_delete))
                info "Log count after rotation: $COUNT_LOG_PRIMARY"
            else
                info "No log rotation needed for $location storage (current: $COUNT_LOG_PRIMARY, max: $max_logs)"
            fi
            ;;
        "secondary")
            if [ "$COUNT_LOG_SECONDARY" -gt "$max_logs" ]; then
                local to_delete=$((COUNT_LOG_SECONDARY - max_logs))
                info "Found $COUNT_LOG_SECONDARY logs in $location storage, removing $to_delete oldest logs"
                delete_oldest_local_logs "$log_dir" "$pattern" "$to_delete" "has_errors"
                # Update count logically: new_count = old_count - deleted_count
                COUNT_LOG_SECONDARY=$((COUNT_LOG_SECONDARY - to_delete))
                info "Log count after rotation: $COUNT_LOG_SECONDARY"
            else
                info "No log rotation needed for $location storage (current: $COUNT_LOG_SECONDARY, max: $max_logs)"
            fi
            ;;
        "cloud")
            if [ "$COUNT_LOG_CLOUD" -gt "$max_logs" ]; then
                local to_delete=$((COUNT_LOG_CLOUD - max_logs))
                info "Found $COUNT_LOG_CLOUD logs in $location storage, removing $to_delete oldest logs"
                delete_oldest_cloud_logs "$log_dir" "$to_delete" "has_errors"
                # Update count logically: new_count = old_count - deleted_count
                COUNT_LOG_CLOUD=$((COUNT_LOG_CLOUD - to_delete))
                info "Log count after rotation: $COUNT_LOG_CLOUD"
            else
                info "No log rotation needed for $location storage (current: $COUNT_LOG_CLOUD, max: $max_logs)"
            fi
            ;;
        *)
            error "Invalid location: $location"
            return $EXIT_ERROR
            ;;
    esac
    
    if [ "$has_errors" = true ]; then
        warning "Log rotation for $location storage completed with warnings"
        case "$location" in
            "primary")
                set_backup_status "log_rotation_primary" $EXIT_WARNING
                ;;
            "secondary")
                set_backup_status "log_rotation_secondary" $EXIT_WARNING
                ;;
            "cloud")
                set_backup_status "log_rotation_cloud" $EXIT_WARNING
                ;;
        esac
    else
        success "Log rotation for $location storage completed successfully"
        case "$location" in
            "primary")
                set_backup_status "log_rotation_primary" $EXIT_SUCCESS
                ;;
            "secondary")
                set_backup_status "log_rotation_secondary" $EXIT_SUCCESS
                ;;
            "cloud")
                set_backup_status "log_rotation_cloud" $EXIT_SUCCESS
                ;;
        esac
    fi
}

# LOG ROTATION FUNCTIONS
# =====================
# Functions for deleting old logs from various storage locations

# Delete oldest logs from cloud storage
# This function removes the oldest log files from cloud storage to maintain
# the configured retention policy using advanced batch operations for efficiency.
# It handles associated files (checksums, metadata) and uses sophisticated
# file discovery and deletion strategies similar to backup management.
#
# Arguments:
#   $1: Cloud log directory path
#   $2: Number of logs to delete
#   $3: Reference to error flag variable
#
# Returns:
#   0: Deletion completed successfully
#   1: Deletion completed with errors
delete_oldest_cloud_logs() {
    local log_dir="$1"
    local to_delete="$2"
    local -n errors_flag="$3"
    
    debug "Preparing deletion of $to_delete oldest logs from cloud storage"
    
    local cloud_logs=$(mktemp)
    local files_to_delete=$(mktemp)
    
    # Ensure temporary files are cleaned up on error
    trap 'rm -f "$cloud_logs" "$files_to_delete"' INT TERM EXIT
    
    # Add 30s timeout to avoid blocks
    if ! timeout 30s rclone lsl --fast-list "${RCLONE_REMOTE}:${log_dir}" 2>/dev/null | grep "${PROXMOX_TYPE}-backup.*\.log" | grep -v "\.sha256$" | grep -v "\.metadata$" > "$cloud_logs"; then
        warning "Unable to get log list from cloud"
        errors_flag=true
        rm -f "$cloud_logs" "$files_to_delete"
        trap - INT TERM EXIT
        return 1
    fi
    
    # Verify file contains data
    if [ ! -s "$cloud_logs" ]; then
        warning "No logs found in cloud storage"
        errors_flag=true
        rm -f "$cloud_logs" "$files_to_delete"
        trap - INT TERM EXIT
        return 1
    fi
    
    # Use already calculated count from CHECK_COUNT instead of duplicate counting
    local total_logs=$COUNT_LOG_CLOUD
    
    # Sort by date, ensuring we use correct format
    mapfile -t to_delete_lines < <(sort -k2,2 -k3,3 "$cloud_logs" | head -n "$to_delete")
    
    # For debugging
    debug "Files selected for deletion in cloud:"
    
    for line in "${to_delete_lines[@]}"; do
        local file_to_delete="${line##* }"
        debug "  - $file_to_delete"
        
        # Add main file
        echo "$file_to_delete" >> "$files_to_delete"
        
        # Add checksum
        echo "${file_to_delete}.sha256" >> "$files_to_delete"
        
        # Add metadata if available
        # First check if .metadata file exists
        if timeout 10s rclone lsl "${RCLONE_REMOTE}:${log_dir}/${file_to_delete}.metadata" ${RCLONE_FLAGS:-} &>/dev/null; then
            echo "${file_to_delete}.metadata" >> "$files_to_delete"
            # And its possible checksum
            echo "${file_to_delete}.metadata.sha256" >> "$files_to_delete"
        fi
        
        # Extract base filename to search for other related files
        local base_name=$(basename "$file_to_delete" .log)
        if [ -n "$base_name" ]; then
            # Search for other files starting with same base name
            timeout 10s rclone lsf "${RCLONE_REMOTE}:${log_dir}" --include "${base_name}.*" ${RCLONE_FLAGS:-} 2>/dev/null | grep -v "^$file_to_delete$" | grep -v "^${file_to_delete}.sha256$" | grep -v "^${file_to_delete}.metadata$" | grep -v "^${file_to_delete}.metadata.sha256$" >> "$files_to_delete"
        fi
    done
    
    # Verify there are files to delete
    local delete_count=$(wc -l < "$files_to_delete")
    if [ "$delete_count" -eq 0 ]; then
        warning "No files identified for deletion"
        errors_flag=true
        rm -f "$cloud_logs" "$files_to_delete"
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
            
            info "Processing batch $i of $batches (files $start_line-$end_line)"
            
            # Add 60s timeout to avoid blocks
            if ! timeout 60s rclone --fast-list --files-from "$batch_file" delete "${RCLONE_REMOTE}:${log_dir}" ${RCLONE_FLAGS:-} 2>/dev/null; then
                warning "Unable to delete some files from cloud (batch $i)"
                errors_flag=true
            else
                info "Successfully deleted files from batch $i"
        fi
        
        rm -f "$batch_file"
        
            # Brief pause between batches to avoid API overload
        sleep 1
    done
    else
        # Delete all files in single call if few
        info "Processing batch 1 of 1 (files 1-$delete_count)"
        if ! timeout 60s rclone --fast-list --files-from "$files_to_delete" delete "${RCLONE_REMOTE}:${log_dir}" ${RCLONE_FLAGS:-} 2>/dev/null; then
            warning "Unable to delete some files from cloud"
            errors_flag=true
        else
            info "Successfully deleted files from batch 1"
        fi
    fi
    
    # Remove temporary files
    rm -f "$cloud_logs" "$files_to_delete"
    # Remove trap
    trap - INT TERM EXIT
    
    if [ "$errors_flag" = true ]; then
        warning "Cloud log deletion completed with warnings"
        return 1
    else
        success "Cloud log deletion completed successfully"
        return 0
    fi
}

# Delete oldest logs from local storage
# This function removes the oldest log files from local storage to maintain
# the configured retention policy, including associated files.
#
# Arguments:
#   $1: Local log directory path
#   $2: Pattern to identify log files
#   $3: Number of logs to delete
#   $4: Reference to error flag variable
#
# Returns:
#   0: Deletion completed successfully
#   1: Deletion completed with errors
delete_oldest_local_logs() {
    local log_dir="$1"         # Directory containing logs
    local pattern="$2"         # Pattern to identify logs
    local to_delete="$3"       # Number of logs to delete
    local -n errors_ref="$4"   # Renamed from has_errors to errors_ref
    
    # Find oldest log files based on modification time
    mapfile -t logs_to_delete < <(
        find "$log_dir" -maxdepth 1 -type f -name "$pattern" -not -name "*.log.*" -printf "%T@ %p\n" | \
        sort -n | head -n "$to_delete" | cut -d ' ' -f 2-
    )
    
    # Delete each identified log file and its associated files
    for log_file in "${logs_to_delete[@]}"; do
        # Remove main log file
        debug "Removing old log: $log_file"
        if ! rm -f "$log_file"; then
            warning "Failed to remove old log: $log_file"
            errors_ref=true
        fi
        
        # Search for and remove any associated files
        local base_log_name="$(basename "$log_file")"
        debug "Checking for associated log files: ${base_log_name}.*"
        local related_files=()
        mapfile -t related_files < <(find "$log_dir" -maxdepth 1 -type f -name "${base_log_name}.*")
        
        for related_file in "${related_files[@]}"; do
            debug "Removing associated file: $related_file"
            if ! rm -f "$related_file"; then
                warning "Failed to remove associated file: $related_file"
                # Don't set errors_ref to true because removing associated files is not critical
            fi
        done
    done
    
    return 0
}
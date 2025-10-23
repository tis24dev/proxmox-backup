#!/bin/bash
##
# Proxmox Backup System - Server ID Manager
# File: server-id-manager.sh
# Version: 0.2.1
# Last Modified: 2025-10-11
# Changes: Gestione ID server
##
# ==========================================
# SERVER ID MANAGER
# ==========================================
#
# Utility script to manage the Proxmox Backup System server ID
# 
# Features:
# - Show current server ID and related information
# - Validate server ID format and consistency
# - Reset/regenerate server ID when needed
# - Test server ID stability
#
# Usage:
#   ./server-id-manager.sh [OPTION]
#
# Options:
#   show      - Display current server ID and system information
#   validate  - Validate server ID format and consistency
#   reset     - Reset/regenerate server ID (WARNING: may require Telegram re-registration)
#   test      - Test server ID stability over multiple generations
#   help      - Show this help message
#
# Author: Proxmox Backup System
# Version: 0.2.1

# ==========================================

# Script version (autonomo)
SERVER_ID_MANAGER_VERSION="0.2.0"

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Mostra versione
echo "Server ID Manager Version: $SERVER_ID_MANAGER_VERSION"

# Source required modules
source "${SCRIPT_DIR}/../lib/log.sh"
source "${SCRIPT_DIR}/../lib/utils.sh"

# Load environment file
if [[ -f "${SCRIPT_DIR}/../env/backup.env" ]]; then
    source "${SCRIPT_DIR}/../env/backup.env"
fi

# Initialize logging
setup_logging() {
    # Set basic logging configuration
    DEBUG_LEVEL="${DEBUG_LEVEL:-basic}"
    CURRENT_LOG_LEVEL=3  # DEBUG level
    
    # Create log directory if needed
    LOCAL_LOG_PATH="${SCRIPT_DIR}/../log"
    mkdir -p "$LOCAL_LOG_PATH" 2>/dev/null || true
    
    # Set log file
    LOG_FILE="${LOCAL_LOG_PATH}/server-id-manager.log"
    
    # Initialize log file
    echo "$(date '+%Y-%m-%d %H:%M:%S') [INFO] Server ID Manager started" >> "$LOG_FILE"
}

# Show usage information
show_usage() {
    cat << EOF
Server ID Manager - Proxmox Backup System

USAGE:
    $0 [OPTION]

OPTIONS:
    show      Display current server ID and system information
    validate  Validate server ID format and consistency  
    reset     Reset/regenerate server ID (WARNING: may require Telegram re-registration)
    test      Test server ID stability over multiple generations
    help      Show this help message

EXAMPLES:
    $0 show      # Display current server ID
    $0 validate  # Check if server ID is valid
    $0 reset     # Generate new server ID
    $0 test      # Test ID stability

NOTES:
    - The server ID is used for Telegram bot registration in centralized mode
    - Resetting the server ID may require re-registering with the Telegram bot
    - The server ID is stored in: ${SCRIPT_DIR}/../config/server_id

EOF
}

# Main function
main() {
    local action="${1:-help}"
    
    # Initialize logging
    setup_logging
    
    case "$action" in
        "show")
            step "Displaying Server ID Information"
            show_server_info
            ;;
        "validate")
            step "Validating Server ID"
            if validate_server_id; then
                success "Server ID validation completed successfully"
                exit 0
            else
                error "Server ID validation failed"
                exit 1
            fi
            ;;
        "reset")
            step "Resetting Server ID"
            echo "WARNING: This will generate a new server ID!"
            echo "If you are using centralized Telegram configuration, you will need to re-register with the bot."
            echo ""
            read -p "Are you sure you want to continue? (y/N): " -n 1 -r
            echo ""
            
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                if reset_server_id; then
                    success "Server ID reset completed successfully"
                    echo ""
                    info "New server ID: $SERVER_ID"
                    echo ""
                    warning "If using centralized Telegram configuration:"
                    warning "1. Start the bot @ProxmoxAN_bot"
                    warning "2. Send your new server ID: $SERVER_ID"
                    exit 0
                else
                    error "Server ID reset failed"
                    exit 1
                fi
            else
                info "Server ID reset cancelled"
                exit 0
            fi
            ;;
        "test")
            step "Testing Server ID Stability"
            get_server_id
            info "Current server ID: $SERVER_ID"
            echo ""
            
            if test_server_id_stability 10; then
                success "Server ID stability test passed"
                exit 0
            else
                error "Server ID stability test failed"
                exit 1
            fi
            ;;
        "help"|"-h"|"--help")
            show_usage
            exit 0
            ;;
        *)
            error "Unknown option: $action"
            echo ""
            show_usage
            exit 1
            ;;
    esac
}

# Run main function
main "$@" 
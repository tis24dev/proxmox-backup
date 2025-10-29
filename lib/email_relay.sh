#!/bin/bash
##
# Proxmox Backup System - Email Relay Functions
# File: email_relay.sh (formerly email_ses.sh)
# Version: 0.6.0
# Last Modified: 2025-10-28
#
# This module provides cloud email relay delivery via Cloudflare Worker
# with HMAC signature authentication and automatic fallback to sendmail.
# Provider-agnostic implementation (currently using Brevo).
##

# ============================================================================
# CLOUDFLARE WORKER CONFIGURATION
# ============================================================================

# Cloudflare Worker URL for email relay delivery
readonly CLOUDFLARE_WORKER_URL="https://relay-tis24.weathered-hill-5216.workers.dev/send"

# Worker authentication token (hardcoded for out-of-the-box setup)
# Token is split to avoid trivial scraping from public repositories
TOKEN_PART_1="v1_public"
TOKEN_PART_2="20251024"
readonly CLOUDFLARE_WORKER_TOKEN="${TOKEN_PART_1}_${TOKEN_PART_2}"

# HMAC secret for payload signature (must match Worker configuration)
readonly HMAC_SECRET="4cc8946c15338082674d7213aee19069571e1afe60ad21b44be4d68260486fb2"

# Worker communication settings
readonly WORKER_TIMEOUT=30           # HTTP request timeout in seconds
readonly WORKER_MAX_RETRIES=2        # Maximum retry attempts
readonly WORKER_RETRY_DELAY=2        # Delay between retries in seconds

# ============================================================================
# HELPER FUNCTIONS
# ============================================================================

# Generate HMAC-SHA256 signature for Worker authentication
generate_hmac_signature() {
    local payload="$1"

    if [ -z "$payload" ]; then
        error "generate_hmac_signature: payload is empty"
        return 1
    fi

    # Compute HMAC-SHA256 using OpenSSL
    local signature
    signature=$(echo -n "$payload" | openssl dgst -sha256 -hmac "$HMAC_SECRET" 2>/dev/null | awk '{print $2}')

    if [ -z "$signature" ]; then
        error "Failed to generate HMAC signature"
        return 1
    fi

    echo "$signature"
    return 0
}

# Get primary network interface MAC address for rate limiting
get_primary_mac_address() {
    local mac=""

    # Method 1: Get MAC from default route interface
    local primary_iface=$(ip route show default 2>/dev/null | awk '/default/ {print $5}' | head -n1)

    if [ -n "$primary_iface" ]; then
        mac=$(ip link show "$primary_iface" 2>/dev/null | awk '/link\/ether/ {print $2}')
    fi

    # Method 2: Fallback to first non-loopback interface
    if [ -z "$mac" ]; then
        primary_iface=$(ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | grep -v '^lo$' | head -n1)
        if [ -n "$primary_iface" ]; then
            mac=$(ip link show "$primary_iface" 2>/dev/null | awk '/link\/ether/ {print $2}')
        fi
    fi

    # Return MAC or empty string
    echo "${mac}"
}

# Generate plain text version from HTML email
generate_plain_text_email() {
    local html_body="$1"

    # Build plain text version using already-computed variables
    local plain_text=""

    # Header
    plain_text+="$(echo "$subject" | sed 's/=?UTF-8?B?//g' | base64 -d 2>/dev/null || echo "$subject")\n"
    plain_text+="$(printf '=%.0s' {1..70})\n\n"

    # Backup status
    plain_text+="BACKUP STATUS\n"
    plain_text+="─────────────\n"
    plain_text+="Local Storage:     ${BACKUP_PRI_STATUS_STR} backups\n"
    plain_text+="Secondary Storage: ${BACKUP_SEC_STATUS_STR} backups\n"
    plain_text+="Cloud Storage:     ${BACKUP_CLO_STATUS_STR} backups\n\n"

    # Backup details
    plain_text+="BACKUP DETAILS\n"
    plain_text+="──────────────\n"
    plain_text+="File Name:       ${backup_file_name}\n"
    plain_text+="File Size:       ${backup_size}\n"
    plain_text+="Included Files:  ${FILES_INCLUDED:-0}\n"
    plain_text+="Missing Files:   ${FILE_MISSING:-0}\n"
    plain_text+="Duration:        ${BACKUP_DURATION_FORMATTED}\n"
    plain_text+="Compression:     ${COMPRESSION_TYPE} (level ${COMPRESSION_LEVEL})\n"
    plain_text+="Backup Mode:     ${COMPRESSION_MODE}\n"
    plain_text+="Server ID:       ${SERVER_ID:-N/A}\n\n"

    # Storage information
    plain_text+="STORAGE INFORMATION\n"
    plain_text+="───────────────────\n"
    if [ "$local_free" != "N/A" ]; then
        plain_text+="Local:     ${local_free} free (${local_percent} used)\n"
    fi
    if [ "$secondary_free" != "N/A" ]; then
        plain_text+="Secondary: ${secondary_free} free (${secondary_percent} used)\n"
    fi
    plain_text+="\n"

    # Error summary (if log file exists)
    if [ -f "$LOG_FILE" ]; then
        local error_count
        error_count=$(grep -c "\[ERROR\]" "$LOG_FILE" 2>/dev/null || echo "0")
        local warning_count
        warning_count=$(grep -c "\[WARNING\]" "$LOG_FILE" 2>/dev/null || echo "0")

        plain_text+="ERROR SUMMARY\n"
        plain_text+="─────────────\n"
        plain_text+="Errors:   ${error_count}\n"
        plain_text+="Warnings: ${warning_count}\n\n"
    fi

    # Footer
    plain_text+="$(printf '=%.0s' {1..70})\n"
    plain_text+="Generated by Proxmox Backup Script v${SCRIPT_VERSION}\n"
    plain_text+="${backup_date}\n"
    plain_text+="Log file: ${LOG_FILE}\n"

    echo -e "$plain_text"
    return 0
}

# Simple HTML-to-text fallback used when plain text rendering fails
strip_html_fallback() {
    local html="$1"
    if [ -z "$html" ]; then
        echo ""
        return 0
    fi

    printf '%s' "$html" | sed -e 's/<[^>]*>/ /g' -e 's/&nbsp;/ /g'
    return 0
}

# ============================================================================
# EMAIL DELIVERY FUNCTIONS
# ============================================================================

# Send email via cloud relay service (Cloudflare Worker)
# Uses HMAC signature for authentication
send_email_via_relay() {
    local recipient="$1"
    local email_subject="$2"
    local html_body="$3"
    local report_json="$4"

    debug "Attempting to send email via cloud relay service"

    # Validate Worker URL is configured
    if [ -z "${CLOUDFLARE_WORKER_URL:-}" ]; then
        error "CLOUDFLARE_WORKER_URL not configured in backup.env"
        EXIT_EMAIL_NOTIFICATION=$EXIT_ERROR
        return 1
    fi

    # Validate Worker URL format
    if ! echo "$CLOUDFLARE_WORKER_URL" | grep -qE '^https://'; then
        error "CLOUDFLARE_WORKER_URL must start with https://"
        EXIT_EMAIL_NOTIFICATION=$EXIT_ERROR
        return 1
    fi

    if [ -z "${report_json:-}" ]; then
        error "Structured report data missing; cannot send via Worker"
        EXIT_EMAIL_NOTIFICATION=$EXIT_ERROR
        return 1
    fi

    # Get server MAC address for rate limiting
    local server_mac
    server_mac=$(get_primary_mac_address)

    # If MAC not available, fallback to sendmail
    if [ -z "$server_mac" ]; then
        warning "Unable to detect MAC address, falling back to sendmail"
        debug "MAC address required for Worker rate limiting"
        EXIT_EMAIL_NOTIFICATION=$EXIT_ERROR
        return 1  # This will trigger fallback to sendmail
    fi

    debug "Server MAC address: ${server_mac}"

    # Embed MAC into report payload so the worker can include it in templates
    report_json=$(jq --arg mac "$server_mac" '.server_mac = $mac' <<<"$report_json")
    if [ $? -ne 0 ] || [ -z "$report_json" ]; then
        error "Failed to attach MAC address to report payload"
        EXIT_EMAIL_NOTIFICATION=$EXIT_ERROR
        return 1
    fi

    # Generate timestamp (Unix epoch)
    local timestamp
    timestamp=$(date +%s)

    # Build JSON payload with MAC address
    debug "Building JSON payload with MAC address"
    local json_payload
    json_payload=$(jq -n \
        --arg to "$recipient" \
        --arg subject "$email_subject" \
        --argjson report "$report_json" \
        --arg t "$timestamp" \
        --arg mac "$server_mac" \
        '{to: $to, subject: $subject, report: $report, t: ($t|tonumber), server_mac: $mac}')

    if [ $? -ne 0 ] || [ -z "$json_payload" ]; then
        error "Failed to build JSON payload"
        EXIT_EMAIL_NOTIFICATION=$EXIT_ERROR
        return 1
    fi

    # Generate HMAC signature
    debug "Generating HMAC signature for payload authentication"
    local signature
    signature=$(generate_hmac_signature "$json_payload")

    if [ $? -ne 0 ] || [ -z "$signature" ]; then
        error "Failed to generate HMAC signature"
        EXIT_EMAIL_NOTIFICATION=$EXIT_ERROR
        return 1
    fi

    debug "HMAC signature generated: ${signature:0:16}..."

    # Attempt to send with retry logic
    local attempt=0
    local max_attempts=$WORKER_MAX_RETRIES
    local success=false

    while [ $attempt -lt $max_attempts ] && [ "$success" = "false" ]; do
        attempt=$((attempt + 1))

        if [ $attempt -gt 1 ]; then
            info "Retry attempt $attempt/$max_attempts after ${WORKER_RETRY_DELAY}s delay"
            sleep $WORKER_RETRY_DELAY
        fi

        debug "Sending email via Worker (attempt $attempt/$max_attempts)"

        # Send request with curl
        local response
        response=$(curl -s -w "\n%{http_code}" \
            --max-time $WORKER_TIMEOUT \
            --connect-timeout 10 \
            -X POST \
            -H "Authorization: Bearer ${CLOUDFLARE_WORKER_TOKEN}" \
            -H "Content-Type: application/json" \
            -H "X-Signature: ${signature}" \
            -H "X-Script-Version: ${SCRIPT_VERSION}" \
            -H "X-Server-MAC: ${server_mac}" \
            -H "User-Agent: proxmox-backup-script/${SCRIPT_VERSION}" \
            -d "$json_payload" \
            "${CLOUDFLARE_WORKER_URL}" 2>&1)

        local curl_exit=$?
        local http_code
        http_code=$(echo "$response" | tail -n1)
        local body
        body=$(echo "$response" | sed '$d')

        debug "Curl exit code: $curl_exit"
        debug "HTTP Response Code: $http_code"
        debug "Response Body: ${body:0:200}..."

        # Handle curl errors
        if [ $curl_exit -ne 0 ]; then
            warning "Curl error (code $curl_exit) on attempt $attempt/$max_attempts"
            if [ $attempt -eq $max_attempts ]; then
                error "Unable to reach Worker after $max_attempts attempts"
                EXIT_EMAIL_NOTIFICATION=$EXIT_ERROR
                return 1
            fi
            continue
        fi

        # Handle HTTP response codes
        case "$http_code" in
            200)
                success "Email sent successfully via cloud relay"
                debug "Worker confirmed email delivery"
                success=true
                EXIT_EMAIL_NOTIFICATION=$EXIT_SUCCESS
                return 0
                ;;
            400)
                error "Bad request to Worker: $body"
                warning "This usually indicates invalid email format or missing required fields"
                EXIT_EMAIL_NOTIFICATION=$EXIT_ERROR
                return 1
                ;;
            401)
                error "Authentication failed: Invalid or missing token"
                warning "Response: $body"
                EXIT_EMAIL_NOTIFICATION=$EXIT_ERROR
                return 1
                ;;
            403)
                error "Forbidden: Email validation failed"
                warning "Possible causes: Invalid HMAC signature, subject format, or body content"
                warning "Response: $body"
                EXIT_EMAIL_NOTIFICATION=$EXIT_ERROR
                return 1
                ;;
            429)
                warning "Rate limit exceeded (attempt $attempt/$max_attempts)"
                if [ $attempt -eq $max_attempts ]; then
                    warning "Rate limit still active after $max_attempts attempts"
                    warning "Per-server limit: 3 emails/day for this MAC address"
                    warning "Global limits: 10/hour per-IP, 50/hour shared, 500/day shared"
                    warning "Contact support on GitHub for higher per-server limits"
                    EXIT_EMAIL_NOTIFICATION=$EXIT_ERROR
                    return 1
                fi
                sleep 5
                ;;
            500|502|503|504)
                warning "Server error from Worker (attempt $attempt/$max_attempts): $http_code"
                warning "Response: $body"
                if [ $attempt -eq $max_attempts ]; then
                    error "Worker server error persists after $max_attempts attempts"
                    EXIT_EMAIL_NOTIFICATION=$EXIT_ERROR
                    return 1
                fi
                ;;
            000)
                warning "Connection timeout or network error (attempt $attempt/$max_attempts)"
                if [ $attempt -eq $max_attempts ]; then
                    error "Unable to reach Worker after $max_attempts attempts"
                    EXIT_EMAIL_NOTIFICATION=$EXIT_ERROR
                    return 1
                fi
                ;;
            *)
                warning "Unexpected HTTP response code: $http_code (attempt $attempt/$max_attempts)"
                warning "Response: $body"
                if [ $attempt -eq $max_attempts ]; then
                    error "Unexpected error persists after $max_attempts attempts"
                    EXIT_EMAIL_NOTIFICATION=$EXIT_ERROR
                    return 1
                fi
                ;;
        esac
    done

    error "Failed to send email via cloud relay after $max_attempts attempts"
    EXIT_EMAIL_NOTIFICATION=$EXIT_ERROR
    return 1
}

# Send email via local sendmail (legacy method)
send_email_via_sendmail() {
    local recipient="$1"
    local encoded_subject="$2"
    local email_body="$3"

    debug "Attempting to send email via local sendmail"

    # Verify sendmail is available
    if ! command -v /usr/sbin/sendmail >/dev/null 2>&1; then
        error "sendmail command not found. Install sendmail or postfix"
        EXIT_EMAIL_NOTIFICATION=$EXIT_ERROR
        return 1
    fi

    # Prepare List-ID header
    local list_id_header
    if [ -n "${LIST_ID_HEADER:-}" ]; then
        list_id_header="$LIST_ID_HEADER"
    else
        list_id_header="<backup-reports.$(hostname -f 2>/dev/null || hostname)>"
    fi

    # Send email using sendmail
    info "Sending email to $recipient via sendmail"

    if echo -e "Subject: ${encoded_subject}\nTo: ${recipient}\nList-ID: ${list_id_header}\nAuto-Submitted: auto-generated\nX-Auto-Response-Suppress: All\nMIME-Version: 1.0\nContent-Type: text/html; charset=UTF-8\n\n$email_body" | /usr/sbin/sendmail -t "$recipient"; then
        success "Email notification sent successfully via sendmail to $recipient"
        EXIT_EMAIL_NOTIFICATION=$EXIT_SUCCESS
        return 0
    else
        warning "Unable to send email notification to $recipient (sendmail error)"
        debug "Checking mail configuration..."

        if [ ! -f "/etc/mail/sendmail.cf" ] && [ ! -f "/etc/postfix/main.cf" ]; then
            warning "Email configuration files not found. Mail server might not be configured"
        fi

        EXIT_EMAIL_NOTIFICATION=$EXIT_ERROR
        return 1
    fi
}


# ============================================================================
# BACKWARD COMPATIBILITY ALIASES
# ============================================================================

# Alias for legacy function name (backward compatibility)
# Old scripts may still call send_email_via_ses()
send_email_via_ses() {
    send_email_via_relay "$@"
}

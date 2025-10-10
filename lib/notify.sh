#!/bin/bash
# Proxmox backup notification system

# Central management of all notifications
send_notifications() {
    step "Sending completion notifications"
    
    local status message notification_sent=false force_notifications=false notification_method_enabled=false
    [ $EXIT_CODE -ne 0 ] && { force_notifications=true; info "Forcing notifications on error"; }
    case $EXIT_CODE in
        $EXIT_SUCCESS) status=success; message="Backup completed successfully.";;
        $EXIT_WARNING) status=warning; message="Backup completed with warnings.";;
        $EXIT_ERROR) status=failure; message="Backup failed.";;
        *) status=failure; message="Backup failed with code $EXIT_CODE.";;
    esac

    # Email notifications management
    if [ "${EMAIL_ENABLED:-false}" = "true" ]; then
        notification_method_enabled=true
        if $force_notifications || [ "${EMAIL_ENABLED:-false}" = "true" ]; then
            send_email_notification "$status" "$message" && notification_sent=true || warning "Email notify failed"
        fi
    else
        info "Email notifications are disabled, skipping email notification"
    fi

    # Update email emoji after completion of email process
    get_status_emoji "email" "email" > /dev/null  # Update EMOJI_EMAIL directly

    # Telegram notifications management with modification to respect disabling from setup_telegram_if_needed
    if [ "${TELEGRAM_ENABLED:-false}" = "true" ]; then
        notification_method_enabled=true
        # If Telegram is enabled, attempt to send notification
        if [ -n "${TELEGRAM_BOT_TOKEN:-}" ] && [ -n "${TELEGRAM_CHAT_ID:-}" ]; then
            send_telegram_notification "$status" "$message" && notification_sent=true || warning "Telegram notify failed"
        else
            warning "Telegram notify failed - missing token or chat_id"
        fi
    elif $force_notifications; then
        # If Telegram is disabled but force_notifications is true, log a special message
        info "Telegram notifications were disabled by centralized configuration, skipping"
    else
        # Telegram notifications normally disabled
        info "Telegram notifications are disabled, skipping"
    fi

    # Modify condition to show message only if at least one method was enabled but failed
    if $notification_method_enabled && ! $notification_sent && [ $EXIT_CODE -ne 0 ]; then
        warning "All notify methods failed."
        command -v wall &>/dev/null && echo "BACKUP ERROR: $message" | wall
        command -v logger &>/dev/null && logger -p crit -t "proxmox-backup" "Backup ERROR: $message"
    fi
    success "Notifications processed"
}

# Send a notification to Telegram
send_telegram_notification() {
    local status="$1"
    local message="$2"
    
    # Check if Telegram is enabled and properly configured
    if [ "${TELEGRAM_ENABLED:-false}" != "true" ]; then
        debug "Telegram notifications not enabled"
        return 1
    fi
    
    # Check if required Telegram configuration is present
    if [ -z "${TELEGRAM_BOT_TOKEN:-}" ] || [ -z "${TELEGRAM_CHAT_ID:-}" ]; then
        warning "Telegram notifications enabled but missing required configuration (BOT_TOKEN or CHAT_ID)"
        return 1
    fi
    
    # Validate Telegram configuration
    if ! echo "${TELEGRAM_BOT_TOKEN}" | grep -qE '^[0-9]+:[A-Za-z0-9_-]{35,}$'; then
        warning "Invalid Telegram bot token format"
        return 1
    fi
    
    if ! echo "${TELEGRAM_CHAT_ID}" | grep -qE '^-?[0-9]+$'; then
        warning "Invalid Telegram chat ID format"
        return 1
    fi
    
    step "Sending Telegram notification"
    
    # Emoji for overall backup status
    local status_emoji
    case "$status" in
        "success") status_emoji="✅" ;;
        "warning") status_emoji="⚠️" ;;
        *) status_emoji="❌" ;;
    esac
    
    # Building Telegram message using global variables
    build_telegram_message "$status_emoji"
    
    # Send the message 
    if curl -s "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
         -d "chat_id=${TELEGRAM_CHAT_ID}" \
         -d "text=${telegram_message}" > /dev/null; then
        success "Telegram notification sent successfully"
        return 0
    else
        warning "Failed to send Telegram notification"
        return 1
    fi
}

# Build Telegram message using global variables from collect_metrics
build_telegram_message() {
    local status_emoji="$1"
    
    # Use global variables calculated by collect_metrics
    # Available space using centralized functions
    local primario_space=$(df -h "$LOCAL_BACKUP_PATH" | tail -1 | awk '{print $4}')
    local secondario_space=""
    
    # Check both that directory exists and secondary backup is enabled
    if [ "${ENABLE_SECONDARY_BACKUP:-false}" = "true" ] && [ -d "$SECONDARY_BACKUP_PATH" ]; then
        secondario_space=$(df -h "$SECONDARY_BACKUP_PATH" | tail -1 | awk '{print $4}')
    fi
    
    # Padding for alignment
    local padding_primario="      "  
    local padding_secondario=" "     
    local padding_cloud="          "     
    
    telegram_message="${status_emoji} Backup PBS - ${HOSTNAME}

${EMOJI_PRI} Local${padding_primario}($BACKUP_PRI_STATUS_STR)
${EMOJI_SEC} Secondary${padding_secondario}($BACKUP_SEC_STATUS_STR)
${EMOJI_CLO} Cloud${padding_cloud}($BACKUP_CLO_STATUS_STR)
${EMOJI_EMAIL} Email

📁 Included files: ${FILES_INCLUDED:-0}
⚠️ Missing files: ${FILE_MISSING:-0}

💾 Available space:
🔹 Local: ${primario_space}"

    # Add secondary line only if it has a value
    if [ -n "$secondario_space" ]; then
        telegram_message+="
🔹 Secondary: ${secondario_space}"
    fi

    telegram_message+="

📅 Backup date: $(date '+%Y-%m-%d %H:%M')
⏱️ Duration: ${BACKUP_DURATION_FORMATTED}

🔢 Exit code: $EXIT_CODE"
}

# Send an email notification with complete details
send_email_notification() {
    local status="$1"
    local message="$2"
    
    if [ "$EMAIL_ENABLED" != "true" ]; then
        debug "Email notifications not configured, skipping"
        EXIT_EMAIL_NOTIFICATION=$EXIT_SUCCESS  # Not an error if disabled
        return 0
    fi
    
    step "Sending email notification"
    
    # Determine recipient address
    local recipient="$EMAIL_RECIPIENT"
    if [ -z "$recipient" ]; then
        # Try to get root email from Proxmox
        debug "EMAIL_RECIPIENT is empty, trying to get root email from Proxmox"
        
        if [ "$PROXMOX_TYPE" == "pve" ] && command -v pveum &> /dev/null; then
            recipient=$(pveum user list --output-format=json | jq -r '.[] | select(.userid=="root@pam") | .email' 2>/dev/null)
            if [ -n "$recipient" ]; then
                debug "Found root email from PVE: $recipient"
            fi
        elif [ "$PROXMOX_TYPE" == "pbs" ] && command -v proxmox-backup-manager &> /dev/null; then
            recipient=$(proxmox-backup-manager user list --output-format=json | jq -r '.[] | select(.userid=="root@pam") | .email' 2>/dev/null)
            if [ -n "$recipient" ]; then
                debug "Found root email from PBS: $recipient"
            fi
        fi
        
        # If still empty, use default value
        if [ -z "$recipient" ]; then
            warning "Unable to determine email recipient from Proxmox, using default value: root@localhost"
            recipient="root@localhost"
            EXIT_EMAIL_NOTIFICATION=$EXIT_WARNING  # Warning because using default value
        fi
    fi
    
    # Verify email address format
    if ! echo "$recipient" | grep -q -E '^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$'; then
        warning "Email address format appears invalid: $recipient"
        EXIT_EMAIL_NOTIFICATION=$EXIT_WARNING  # Warning for invalid email format
    fi
    
    # Prepare email data using global variables
    prepare_email_data "$status"
    
    # Create email content
    create_email_body "$status_color"

    # Function to encode email subject (as in working script)
    encode_subject() {
        local subject="$1"
        local encoded=$(printf '%s' "$subject" | base64 | tr -d '\n')
        echo "=?UTF-8?B?${encoded}?="
    }
    
    # Encode subject
    local encoded_subject=$(encode_subject "$subject")
    
    # Send email using sendmail with working script format
    if command -v /usr/sbin/sendmail >/dev/null 2>&1; then
        info "Send email to $recipient"
        if echo -e "Subject: ${encoded_subject}\nTo: ${recipient}\nMIME-Version: 1.0\nContent-Type: text/html; charset=UTF-8\n\n$email_body" | /usr/sbin/sendmail -t "$recipient"; then
            success "Email notification sent successfully to $recipient"
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
    else
        warning "sendmail command not found. Install sendmail or postfix"
        EXIT_EMAIL_NOTIFICATION=$EXIT_ERROR
        return 1
    fi
}

# Prepare data for email using global variables from collect_metrics
prepare_email_data() {
    local status="$1"
    
    # Ensure Server ID is available
    get_server_id
    
    # Emoji for subject based on overall status
    status_emoji=""
    if [ "$status" == "success" ]; then
        status_emoji="✅"
    elif [ "$status" == "failure" ]; then
        status_emoji="❌"
    elif [ "$status" == "warning" ]; then
        status_emoji="⚠️"
    fi
    
    # Format subject with emoji, date and time
    subject="${status_emoji} ${PROXMOX_TYPE^^} Backup on ${HOSTNAME} - $(date '+%Y-%m-%d %H:%M')"
    
    # Format HTML email body with status-dependent color
    status_color="blue"
    if [ "$status" == "success" ]; then
        status_color="#4CAF50"  # Green
    elif [ "$status" == "failure" ]; then
        status_color="#F44336"  # Red
    elif [ "$status" == "warning" ]; then
        status_color="#FF9800"  # Orange
    fi
    
    # Use global variables already calculated by collect_metrics
    backup_size="${BACKUP_SIZE_HUMAN:-N/A}"
    backup_date=$(date '+%Y-%m-%d %H:%M:%S')
    compression_ratio="${COMPRESSION_RATIO:-N/A}"
    backup_file_name="N/A"
    
    if [ -n "$BACKUP_FILE" ] && [ -f "$BACKUP_FILE" ]; then
        backup_file_name=$(basename "$BACKUP_FILE")
    fi
    
    # Get disk space information using global variables
    local_space="N/A"
    local_used="N/A"
    local_percent="N/A"
    local_free="N/A"
    
    if [ -d "$LOCAL_BACKUP_PATH" ]; then
        local df_output=$(df -h "$LOCAL_BACKUP_PATH" | tail -1)
        local_space=$(echo "$df_output" | awk '{print $2}')
        local_used=$(echo "$df_output" | awk '{print $3}')
        local_free=$(echo "$df_output" | awk '{print $4}')
        local_percent=$(echo "$df_output" | awk '{print $5}')
    fi
    
    secondary_space="N/A"
    secondary_used="N/A"
    secondary_percent="N/A"
    secondary_free="N/A"
    
    # Check both that directory exists and secondary backup is enabled
    if [ "${ENABLE_SECONDARY_BACKUP:-false}" = "true" ] && [ -d "$SECONDARY_BACKUP_PATH" ]; then
        local df_output=$(df -h "$SECONDARY_BACKUP_PATH" | tail -1)
        secondary_space=$(echo "$df_output" | awk '{print $2}')
        secondary_used=$(echo "$df_output" | awk '{print $3}')
        secondary_free=$(echo "$df_output" | awk '{print $4}')
        secondary_percent=$(echo "$df_output" | awk '{print $5}')
    fi
}

# Create email body
create_email_body() {
    local status_color="$1"
    
    # SIDEBAR COLOR LOGIC:
    # - Header (PBS BACKUP REPORT): reflects global script status (status_color)
    # - Backup Paths section: reflects backup path status
    # - Total Issues section: reflects presence of errors/warnings in logs
    
    # Determine sidebar color for backup paths section
    local backup_paths_color="#4CAF50"  # Green by default (all paths OK)
    
    # Check backup path status via emojis
    if [[ "$EMOJI_PRI" == "❌" ]] || [[ "$EMOJI_SEC" == "❌" ]] || [[ "$EMOJI_CLO" == "❌" ]]; then
        backup_paths_color="#F44336"  # Red if at least one in error
    elif [[ "$EMOJI_PRI" == "⚠️" ]] || [[ "$EMOJI_SEC" == "⚠️" ]] || [[ "$EMOJI_CLO" == "⚠️" ]]; then
        backup_paths_color="#FF9800"  # Orange if at least one in warning
    fi
    
    # Determine sidebar color for errors section
    local error_summary_color="#4CAF50"  # Green by default (no issues)
    if [ -f "$LOG_FILE" ]; then
        local error_count=$(grep -c "\[ERROR\]" "$LOG_FILE" 2>/dev/null)
        if [ $? -ne 0 ]; then
            error_count=0
        fi
        
        local warning_count=$(grep -c "\[WARNING\]" "$LOG_FILE" 2>/dev/null)
        if [ $? -ne 0 ]; then
            warning_count=0
        fi
        
        # Ensure values are numeric
        [[ "$error_count" =~ ^[0-9]+$ ]] || error_count=0
        [[ "$warning_count" =~ ^[0-9]+$ ]] || warning_count=0
        
        if [ "$error_count" -gt 0 ]; then
            error_summary_color="#F44336"  # Red if there are errors
        elif [ "$warning_count" -gt 0 ]; then
            error_summary_color="#FF9800"  # Orange if there are warnings
        fi
    fi
	
    # Create a clean and modern HTML email template
    email_body="<!DOCTYPE html>
<html>
<head>
    <meta charset=\"UTF-8\">
    <title>${PROXMOX_TYPE^^} Backup Report</title>
    <style>
        body { 
            font-family: 'Segoe UI', Arial, sans-serif; 
            margin: 0; 
            padding: 0; 
            color: #333; 
            background-color: #f5f5f5;
        }
        .container { 
            max-width: 800px; 
            margin: 0 auto; 
            background-color: #fff;
            border-radius: 8px;
            overflow: hidden;
            box-shadow: 0 2px 10px rgba(0,0,0,0.1);
        }
        .header { 
            background-color: $status_color; 
            color: white; 
            padding: 20px 30px; 
        }
        .header h1 {
            margin: 0;
            font-weight: 500;
            font-size: 24px;
        }
        .header p {
            margin: 10px 0 0 0;
            opacity: 0.9;
            font-size: 16px;
        }
        .content { 
            padding: 30px; 
        }
        .section { 
            margin-bottom: 30px; 
        }
        .section:last-child {
            margin-bottom: 0;
        }
        .section h2 { 
            font-size: 18px;
            font-weight: 500;
            margin-top: 0;
            margin-bottom: 15px; 
            padding-bottom: 10px; 
            border-bottom: 1px solid #eee; 
            color: #444;
        }
        .info-table { 
            width: 100%; 
            border-collapse: collapse; 
            margin-bottom: 10px;
        }
        .info-table td { 
            padding: 10px; 
            border-bottom: 1px solid #eee; 
            vertical-align: top;
        }
        .info-table tr:last-child td { 
            border-bottom: none; 
        }
        .info-table td:first-child { 
            font-weight: 500; 
            width: 35%; 
            color: #555;
        }
        .status-badge {
            display: inline-block;
            padding: 3px 8px;
            border-radius: 4px;
            font-size: 12px;
            font-weight: 500;
            text-transform: uppercase;
        }
        .status-success {
            background-color: #E8F5E9;
            color: #388E3C;
        }
        .status-warning {
            background-color: #FFF8E1;
            color: #FFA000;
        }
        .status-error {
            background-color: #FFEBEE;
            color: #D32F2F;
        }
        pre { 
            background: #f5f5f5; 
            padding: 15px; 
            border-radius: 6px; 
            overflow-x: auto;
            font-family: 'Consolas', 'Monaco', monospace;
            font-size: 13px;
            color: #333;
            white-space: pre-wrap;
        }
        .footer { 
            background-color: #f8f8f8; 
            padding: 15px 30px; 
            text-align: center; 
            font-size: 13px;
            color: #777;
            border-top: 1px solid #eee;
        }
        .backup-status {
            background-color: #f9f9f9; 
            border-radius: 8px; 
            padding: 20px; 
            margin-bottom: 30px;
            border-left: 4px solid ${backup_paths_color};
			box-shadow: 0 2px 5px rgba(0,0,0,0.05);
        }
        .backup-location {
            margin-bottom: 15px;
            padding-bottom: 15px;
            border-bottom: 1px solid #eee;
        }
        .backup-location:last-child {
            margin-bottom: 0;
            padding-bottom: 0;
            border-bottom: none;
        }
        .backup-location h3 {
            margin-top: 0;
            margin-bottom: 10px;
            font-size: 16px;
            font-weight: 500;
            color: #444;
        }
        .storage-info {
            display: flex;
            align-items: center;
            margin-top: 8px;
            font-size: 14px;
            color: #666;
        }
        .storage-info .space-bar {
            flex-grow: 1;
            height: 8px;
            margin: 0 10px;
            background-color: #eee;
            border-radius: 4px;
            overflow: hidden;
            position: relative;
        }
        .storage-info .space-used {
            position: absolute;
            height: 100%;
            background-color: #4CAF50;
            border-radius: 4px;
        }
        .storage-info .space-used.warning {
            background-color: #FF9800;
        }
        .storage-info .space-used.critical {
            background-color: #F44336;
        }
        .count-block {
            font-size: 16px; 
            font-weight: 500;
            margin-bottom: 5px;
        }
        .count-block .emoji {
            font-size: 18px;
            margin-right: 5px;
        }
    </style>
</head>
<body>
    <div class=\"container\">
        <div class=\"header\">
            <h1>${PROXMOX_TYPE^^} Backup Report - ${status^^}</h1>
            <p>${HOSTNAME} - ${backup_date}</p>
        </div>
        <div class=\"content\">
            <div class=\"backup-status\">
                <div class=\"backup-location\">
                    <h3>Local Storage</h3>
                    <div class=\"count-block\">
                        <span class=\"emoji\">${EMOJI_PRI}</span> ${BACKUP_PRI_STATUS_STR} backups
                    </div>"
    
    # Add space information for local storage
    if [ "$local_free" != "N/A" ]; then
        # Extract numeric percentage without % symbol
        local percent_num=${local_percent/\%/}
        local color_class="normal"
        
        if [ "$percent_num" -gt 85 ]; then
            color_class="critical"
        elif [ "$percent_num" -gt 70 ]; then
            color_class="warning"
        fi
        
        email_body+="
                    <div class=\"storage-info\">
                        <span>${local_used}</span>
                        <div class=\"space-bar\">
                            <div class=\"space-used ${color_class}\" style=\"width: ${local_percent};\"></div>
                        </div>
                        <span>${local_free} free (${local_percent} used)</span>
                    </div>"
    fi
    
    email_body+="
                </div>
                
                <div class=\"backup-location\">
                    <h3>Secondary Storage</h3>
                    <div class=\"count-block\">
                        <span class=\"emoji\">${EMOJI_SEC}</span> ${BACKUP_SEC_STATUS_STR} backups
                    </div>"
    
    # Add space information for secondary storage
    if [ "$secondary_free" != "N/A" ]; then
        # Extract numeric percentage without % symbol
        local percent_num=${secondary_percent/\%/}
        local color_class="normal"
        
        if [ "$percent_num" -gt 85 ]; then
            color_class="critical"
        elif [ "$percent_num" -gt 70 ]; then
            color_class="warning"
        fi
        
        email_body+="
                    <div class=\"storage-info\">
                        <span>${secondary_used}</span>
                        <div class=\"space-bar\">
                            <div class=\"space-used ${color_class}\" style=\"width: ${secondary_percent};\"></div>
                        </div>
                        <span>${secondary_free} free (${secondary_percent} used)</span>
                    </div>"
    fi
    
    email_body+="
                </div>
                
                <div class=\"backup-location\">
                    <h3>Cloud Storage</h3>
                    <div class=\"count-block\">
                        <span class=\"emoji\">${EMOJI_CLO}</span> ${BACKUP_CLO_STATUS_STR} backups
                    </div>
                </div>
            </div>
            
            <div class=\"section\">
                <h2>Backup Details</h2>
                <table class=\"info-table\">
                    <tr>
                        <td>Backup File</td>
                        <td>${backup_file_name}</td>
                    </tr>
                    <tr>
                        <td>File Size</td>
                        <td>${backup_size}</td>
                    </tr>
                    <tr>
                        <td>Included Files</td>
                        <td>${FILES_INCLUDED:-0}</td>
                    </tr>
                    <tr>
                        <td>Missing Files</td>
                        <td>${FILE_MISSING:-0}</td>
                    </tr>
                    <tr>
                        <td>Duration</td>
                        <td>${BACKUP_DURATION_FORMATTED}</td>
                    </tr>
                    <tr>
                        <td>Compression Ratio</td>
                        <td>${compression_ratio}</td>
                    </tr>
                    <tr>
                        <td>Compression Type</td>
                        <td>${COMPRESSION_TYPE} (level: ${COMPRESSION_LEVEL})</td>
                    </tr>
                    <tr>
                        <td>Backup Mode</td>
                        <td>${COMPRESSION_MODE}</td>
                    </tr>
                    <tr>
                        <td>Server ID</td>
                        <td>${SERVER_ID:-N/A}</td>
                    </tr>
                    <tr>
                        <td>Telegram Status</td>
                        <td>${TELEGRAM_SERVER_STATUS:-N/A}</td>
                    </tr>
                    <tr>
                        <td>Local Path</td>
                        <td>${LOCAL_BACKUP_PATH}</td>
                    </tr>"
    
    # Add secondary path if configured
    if [ "${ENABLE_SECONDARY_BACKUP:-false}" = "true" ] && [ -d "$SECONDARY_BACKUP_PATH" ]; then
        email_body+="
                    <tr>
                        <td>Secondary Path</td>
                        <td>${SECONDARY_BACKUP_PATH}</td>
                    </tr>"
    fi
    
    # Add cloud path if configured
    if command -v rclone &> /dev/null && [ -n "${RCLONE_REMOTE:-}" ] && rclone listremotes | grep -q "^${RCLONE_REMOTE}:"; then
        email_body+="
                    <tr>
                        <td>Cloud Storage</td>
                        <td>${RCLONE_REMOTE}:${CLOUD_BACKUP_PATH}</td>
                    </tr>"
    fi
    
    email_body+="
                </table>
            </div>"
    
    # Add error/warning summary
    add_error_summary_to_email "$error_summary_color"
    
    # Add system recommendations if needed
    add_system_recommendations_to_email
    
    # Add footer
    email_body+="
        </div>
        <div class=\"footer\">
            <p>This is an automated message from the Proxmox Backup Script.</p>
            <p>Generated on ${backup_date} by backup script v${SCRIPT_VERSION}</p>
        </div>
    </div>
</body>
</html>"
}

# Add error summary to email
add_error_summary_to_email() {
    local error_summary_color="$1"
    
    if [ -f "$LOG_FILE" ]; then
        # Count errors and warnings
        local error_count=$(grep -c "\[ERROR\]" "$LOG_FILE" 2>/dev/null)
        if [ $? -ne 0 ]; then
            error_count=0
        fi
        
        local warning_count=$(grep -c "\[WARNING\]" "$LOG_FILE" 2>/dev/null)
        if [ $? -ne 0 ]; then
            warning_count=0
        fi
        
        # Ensure values are numeric
        [[ "$error_count" =~ ^[0-9]+$ ]] || error_count=0
        [[ "$warning_count" =~ ^[0-9]+$ ]] || warning_count=0
        
        email_body+="
            <div class=\"section\">
                <h2>Error and Warning Summary</h2>"
        
        # Add summary box with counts and colored sidebar
        email_body+="
                <div style=\"padding:15px; background-color:#F5F5F5; border-radius:6px; margin-bottom:15px; border-left:4px solid ${error_summary_color};\">
                    <p style=\"margin:0;\"><strong>Total Issues:</strong> $((error_count + warning_count))</p>
                    <p style=\"margin:5px 0 0 0;\"><strong>Errors:</strong> $error_count</p>
                    <p style=\"margin:5px 0 0 0;\"><strong>Warnings:</strong> $warning_count</p>
                </div>"
        
        # If there are errors or warnings, list them by category
        if [ $((error_count + warning_count)) -gt 0 ]; then
            # Create table for error categories
            email_body+="
                <table class=\"info-table\">
                    <tr>
                        <th style=\"text-align:left; padding:10px; background-color:#f2f2f2;\">Problem</th>
                        <th style=\"text-align:left; padding:10px; background-color:#f2f2f2;\">Type</th>
                        <th style=\"text-align:left; padding:10px; background-color:#f2f2f2;\">Count</th>
                    </tr>"
            
            # Extract error categories and count them
            local categories=()
            local category_counts_error=()
            local category_counts_warning=()
            local category_examples_error=()
            local category_examples_warning=()
            
            # Search for patterns like [ERROR] Failed to create directory or [WARNING] Missing configuration
            # Extract these patterns to identify common categories
            
            # Process errors
            while read -r line; do
                # Extract category (first words after [ERROR])
                local category=$(echo "$line" | sed -n 's/.*\[ERROR\] \([^:]*\).*/\1/p')
                if [ -n "$category" ]; then
                    # Check if this category is already in our array
                    local found=0
                    for i in "${!categories[@]}"; do
                        if [ "${categories[$i]}" = "$category" ]; then
                            # Increment count
                            category_counts_error[$i]=$((category_counts_error[$i] + 1))
                            found=1
                            break
                        fi
                    done
                    
                    # If not found, add new category
                    if [ $found -eq 0 ]; then
                        categories+=("$category")
                        category_counts_error+=("1")
                        category_counts_warning+=("0")
                        # Extract example based on presence of colon
                        local example=""
                        if echo "$line" | grep -q "\[ERROR\] [^:]*:"; then
                            example=$(echo "$line" | sed 's/.*\[ERROR\] [^:]*: \(.*\)/\1/' | cut -c 1-50)
                        else
                            example=$(echo "$line" | sed 's/.*\[ERROR\] \(.*\)/\1/' | cut -c 1-50)
                        fi
                        category_examples_error+=("$example")
                        category_examples_warning+=("")
                    fi
                fi
            done < <(grep "\[ERROR\]" "$LOG_FILE")
            
            # Process warnings
            while read -r line; do
                # Extract category (first words after [WARNING])
                # Handle both cases with and without colon
                local category=""
                if echo "$line" | grep -q "\[WARNING\] [^:]*:"; then
                    # Case with colon
                    category=$(echo "$line" | sed -n 's/.*\[WARNING\] \([^:]*\):.*/\1/p')
                else
                    # Case without colon - take entire message
                    category=$(echo "$line" | sed -n 's/.*\[WARNING\] \(.*\)/\1/p')
                fi
                
                if [ -n "$category" ]; then
                    # Check if this category is already in our array
                    local found=0
                    for i in "${!categories[@]}"; do
                        if [ "${categories[$i]}" = "$category" ]; then
                            # Increment count
                            category_counts_warning[$i]=$((category_counts_warning[$i] + 1))
                            
                            # If this is the first warning in this category, save an example
                            if [ "${category_counts_warning[$i]}" -eq 1 ]; then
                                # Extract example based on presence of colon
                                local example=""
                                if echo "$line" | grep -q "\[WARNING\] [^:]*:"; then
                                    example=$(echo "$line" | sed 's/.*\[WARNING\] [^:]*: \(.*\)/\1/' | cut -c 1-50)
                                else
                                    example=$(echo "$line" | sed 's/.*\[WARNING\] \(.*\)/\1/' | cut -c 1-50)
                                fi
                                category_examples_warning[$i]="$example"
                            fi
                            
                            found=1
                            break
                        fi
                    done
                    
                    # If not found, add new category
                    if [ $found -eq 0 ]; then
                        categories+=("$category")
                        category_counts_error+=("0")
                        category_counts_warning+=("1")
                        category_examples_error+=("")
                        # Extract example based on presence of colon
                        local example=""
                        if echo "$line" | grep -q "\[WARNING\] [^:]*:"; then
                            example=$(echo "$line" | sed 's/.*\[WARNING\] [^:]*: \(.*\)/\1/' | cut -c 1-50)
                        else
                            example=$(echo "$line" | sed 's/.*\[WARNING\] \(.*\)/\1/' | cut -c 1-50)
                        fi
                        category_examples_warning+=("$example")
                    fi
                fi
            done < <(grep "\[WARNING\]" "$LOG_FILE")
            
            # If no categorized errors/warnings found, use simple counts
            if [ ${#categories[@]} -eq 0 ]; then
                # Add generic errors and warnings if present
                if [ $error_count -gt 0 ]; then
                    email_body+="
                    <tr>
                        <td>General errors</td>
                        <td><span style=\"color:#F44336;\">ERROR</span></td>
                        <td>$error_count</td>
                    </tr>"
                fi
                
                if [ $warning_count -gt 0 ]; then
                    email_body+="
                    <tr>
                        <td>General warnings</td>
                        <td><span style=\"color:#FF9800;\">WARNING</span></td>
                        <td>$warning_count</td>
                    </tr>"
                fi
            else
                # Add each category to table
                for i in "${!categories[@]}"; do
                    if [ "${category_counts_error[$i]}" -gt 0 ]; then
                        email_body+="
                        <tr>
                            <td>${categories[$i]}</td>
                            <td><span style=\"color:#F44336;\">ERROR</span></td>
                            <td>${category_counts_error[$i]}</td>
                        </tr>"
                    fi
                    
                    if [ "${category_counts_warning[$i]}" -gt 0 ]; then
                        email_body+="
                        <tr>
                            <td>${categories[$i]}</td>
                            <td><span style=\"color:#FF9800;\">WARNING</span></td>
                            <td>${category_counts_warning[$i]}</td>
                        </tr>"
                    fi
                done
            fi
            
            email_body+="
                </table>"
        else
            # No errors or warnings
            email_body+="
                <div style=\"padding:15px; background-color:#E8F5E9; border-radius:6px; border-left:4px solid #4CAF50;\">
                    <p style=\"margin:0;\">✅ <strong>No errors or warnings were found in the backup log.</strong></p>
                </div>"
        fi
        
        email_body+="
                <p style=\"font-size:13px; color:#666; margin-top:10px;\">Full log available at: ${LOG_FILE}</p>
            </div>"
    fi
}

# Add system recommendations to email
add_system_recommendations_to_email() {
    # Extract numeric values from percentages, handling "N/A" case
    local local_percent_num=""
    local secondary_percent_num=""
    
    if [ "$local_percent" != "N/A" ] && [[ "$local_percent" =~ ^[0-9]+%$ ]]; then
        local_percent_num="${local_percent/\%/}"
    fi
    
    if [ "$secondary_percent" != "N/A" ] && [[ "$secondary_percent" =~ ^[0-9]+%$ ]]; then
        secondary_percent_num="${secondary_percent/\%/}"
    fi
    
    # Check if at least one value exceeds 85%
    local show_recommendations=false
    if [ -n "$local_percent_num" ] && [ "$local_percent_num" -gt 85 ]; then
        show_recommendations=true
    fi
    if [ -n "$secondary_percent_num" ] && [ "$secondary_percent_num" -gt 85 ]; then
        show_recommendations=true
    fi
    
    if [ "$show_recommendations" = "true" ]; then
        email_body+="
            <div class=\"section\">
                <h2>System Recommendations</h2>
                <div style=\"padding:15px; background-color:#FFF3E0; border-radius:6px; border-left:4px solid #FF9800;\">"
        
        if [ -n "$local_percent_num" ] && [ "$local_percent_num" -gt 85 ]; then
            email_body+="
                    <p>⚠️ <strong>Local storage is nearly full (${local_percent})</strong> - Consider cleaning up older backups or adding more storage.</p>"
        fi
        
        if [ -n "$secondary_percent_num" ] && [ "$secondary_percent_num" -gt 85 ]; then
            email_body+="
                    <p>⚠️ <strong>Secondary storage is nearly full (${secondary_percent})</strong> - Consider cleaning up older backups or adding more storage.</p>"
        fi
        
        email_body+="
                </div>
            </div>"
    fi
}
			
			
			
			
			
			
			
			
			
			
			
			
			
			
			
			
			
			
			
			
			
			
			
			
			
			
			
			
			
			
			
			
			
			
			
			
#!/bin/bash
# Sistema di notifica per il backup Proxmox

# Gestione centrale di tutte le notifiche
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

    # Gestione email notifications
    if [ "${EMAIL_ENABLED:-false}" = "true" ]; then
        notification_method_enabled=true
        if $force_notifications || [ "${EMAIL_ENABLED:-false}" = "true" ]; then
            send_email_notification "$status" "$message" && notification_sent=true || warning "Email notify failed"
        fi
    else
        info "Email notifications are disabled, skipping email notification"
    fi

    # Aggiorna l'emoji email dopo il completamento del processo email
    get_status_emoji "email" "email" > /dev/null  # Aggiorna direttamente EMOJI_EMAIL

    # Gestione notifiche Telegram con modifica per rispettare la disabilitazione da setup_telegram_if_needed
    if [ "${TELEGRAM_ENABLED:-false}" = "true" ]; then
        notification_method_enabled=true
        # Se Telegram è abilitato, tenta di inviare la notifica
        if [ -n "${TELEGRAM_BOT_TOKEN:-}" ] && [ -n "${TELEGRAM_CHAT_ID:-}" ]; then
            send_telegram_notification "$status" "$message" && notification_sent=true || warning "Telegram notify failed"
        else
            warning "Telegram notify failed - missing token or chat_id"
        fi
    elif $force_notifications; then
        # Se Telegram è disabilitato ma force_notifications è true, log un messaggio speciale
        info "Telegram notifications were disabled by centralized configuration, skipping"
    else
        # Notifiche Telegram disabilitate normalmente
        info "Telegram notifications are disabled, skipping"
    fi

    # Modifica alla condizione per mostrare il messaggio solo se almeno un metodo era abilitato ma ha fallito
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
    
    # Emoji per lo stato di backup complessivo
    local status_emoji
    case "$status" in
        "success") status_emoji="✅" ;;
        "warning") status_emoji="⚠️" ;;
        *) status_emoji="❌" ;;
    esac
    
    # Costruzione del messaggio Telegram usando le variabili globali
    build_telegram_message "$status_emoji"
    
    # Invia il messaggio 
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
    
    # Usa le variabili globali calcolate da collect_metrics
    # Spazio disponibile usando le funzioni centralizzate
    local primario_space=$(df -h "$LOCAL_BACKUP_PATH" | tail -1 | awk '{print $4}')
    local secondario_space=""
    
    # Controlla sia che la directory esista sia che il backup secondario sia abilitato
    if [ "${ENABLE_SECONDARY_BACKUP:-false}" = "true" ] && [ -d "$SECONDARY_BACKUP_PATH" ]; then
        secondario_space=$(df -h "$SECONDARY_BACKUP_PATH" | tail -1 | awk '{print $4}')
    fi
    
    # Padding per allineamento
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

    # Aggiungi la riga del secondario solo se ha un valore
    if [ -n "$secondario_space" ]; then
        telegram_message+="
🔹 Secondary: ${secondario_space}"
    fi

    telegram_message+="

📅 Backup date: $(date '+%Y-%m-%d %H:%M')
⏱️ Duration: ${BACKUP_DURATION_FORMATTED}

🔢 Exit code: $EXIT_CODE"
}

# Invia una notifica email con dettagli completi
send_email_notification() {
    local status="$1"
    local message="$2"
    
    if [ "$EMAIL_ENABLED" != "true" ]; then
        debug "Notifiche email non configurate, salto"
        EXIT_EMAIL_NOTIFICATION=$EXIT_SUCCESS  # Non è un errore se è disabilitato
        return 0
    fi
    
    step "Invio notifica email"
    
    # Determina l'indirizzo del destinatario
    local recipient="$EMAIL_RECIPIENT"
    if [ -z "$recipient" ]; then
        # Prova a ottenere l'email di root da Proxmox
        debug "EMAIL_RECIPIENT è vuoto, provo a ottenere l'email di root da Proxmox"
        
        if [ "$PROXMOX_TYPE" == "pve" ] && command -v pveum &> /dev/null; then
            recipient=$(pveum user list --output-format=json | jq -r '.[] | select(.userid=="root@pam") | .email' 2>/dev/null)
            if [ -n "$recipient" ]; then
                debug "Trovata email di root da PVE: $recipient"
            fi
        elif [ "$PROXMOX_TYPE" == "pbs" ] && command -v proxmox-backup-manager &> /dev/null; then
            recipient=$(proxmox-backup-manager user list --output-format=json | jq -r '.[] | select(.userid=="root@pam") | .email' 2>/dev/null)
            if [ -n "$recipient" ]; then
                debug "Trovata email di root da PBS: $recipient"
            fi
        fi
        
        # Se ancora vuoto, usa un valore predefinito
        if [ -z "$recipient" ]; then
            warning "Impossibile determinare il destinatario email da Proxmox, uso il valore predefinito: root@localhost"
            recipient="root@localhost"
            EXIT_EMAIL_NOTIFICATION=$EXIT_WARNING  # Warning perché usiamo un valore predefinito
        fi
    fi
    
    # Verifica il formato dell'indirizzo email
    if ! echo "$recipient" | grep -q -E '^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$'; then
        warning "Il formato dell'indirizzo email sembra non valido: $recipient"
        EXIT_EMAIL_NOTIFICATION=$EXIT_WARNING  # Warning per formato email non valido
    fi
    
    # Prepara i dati per l'email usando le variabili globali
    prepare_email_data "$status"
    
    # Crea il contenuto dell'email
    create_email_body "$status_color"

    # Funzione per codificare l'oggetto email (come nello script funzionante)
    encode_subject() {
        local subject="$1"
        local encoded=$(printf '%s' "$subject" | base64 | tr -d '\n')
        echo "=?UTF-8?B?${encoded}?="
    }
    
    # Codifica l'oggetto
    local encoded_subject=$(encode_subject "$subject")
    
    # Invia l'email usando sendmail con il formato dello script funzionante
    if command -v /usr/sbin/sendmail >/dev/null 2>&1; then
        info "Invio email a $recipient"
        if echo -e "Subject: ${encoded_subject}\nTo: ${recipient}\nMIME-Version: 1.0\nContent-Type: text/html; charset=UTF-8\n\n$email_body" | /usr/sbin/sendmail -t "$recipient"; then
            success "Email di notifica inviata con successo a $recipient"
            EXIT_EMAIL_NOTIFICATION=$EXIT_SUCCESS
            return 0
        else
            warning "Impossibile inviare email di notifica a $recipient (errore sendmail)"
            debug "Controllo configurazione mail..."
            if [ ! -f "/etc/mail/sendmail.cf" ] && [ ! -f "/etc/postfix/main.cf" ]; then
                warning "File di configurazione email non trovati. Il server mail potrebbe non essere configurato"
            fi
            EXIT_EMAIL_NOTIFICATION=$EXIT_ERROR
            return 1
        fi
    else
        warning "Comando sendmail non trovato. Installa sendmail o postfix"
        EXIT_EMAIL_NOTIFICATION=$EXIT_ERROR
        return 1
    fi
}

# Prepare data for email using global variables from collect_metrics
prepare_email_data() {
    local status="$1"
    
    # Assicurati che il Server ID sia disponibile
    get_server_id
    
    # Emoji per l'oggetto basato sullo stato complessivo
    status_emoji=""
    if [ "$status" == "success" ]; then
        status_emoji="✅"
    elif [ "$status" == "failure" ]; then
        status_emoji="❌"
    elif [ "$status" == "warning" ]; then
        status_emoji="⚠️"
    fi
    
    # Formatta l'oggetto con emoji, data e ora
    subject="${status_emoji} ${PROXMOX_TYPE^^} Backup su ${HOSTNAME} - $(date '+%Y-%m-%d %H:%M')"
    
    # Formatta il corpo dell'email HTML con colore dipendente dallo stato
    status_color="blue"
    if [ "$status" == "success" ]; then
        status_color="#4CAF50"  # Verde
    elif [ "$status" == "failure" ]; then
        status_color="#F44336"  # Rosso
    elif [ "$status" == "warning" ]; then
        status_color="#FF9800"  # Arancione
    fi
    
    # Usa le variabili globali già calcolate da collect_metrics
    backup_size="${BACKUP_SIZE_HUMAN:-N/A}"
    backup_date=$(date '+%Y-%m-%d %H:%M:%S')
    compression_ratio="${COMPRESSION_RATIO:-N/A}"
    backup_file_name="N/A"
    
    if [ -n "$BACKUP_FILE" ] && [ -f "$BACKUP_FILE" ]; then
        backup_file_name=$(basename "$BACKUP_FILE")
    fi
    
    # Ottieni informazioni sullo spazio su disco usando le variabili globali
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
    
    # Controlla sia che la directory esista sia che il backup secondario sia abilitato
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
    
    # LOGICA COLORI BARRE LATERALI:
    # - Header (PBS BACKUP REPORT): riflette lo stato globale dello script (status_color)
    # - Sezione Backup Paths: riflette lo stato dei path di backup
    # - Sezione Total Issues: riflette la presenza di errori/warning nei log
    
    # Determina il colore della barra laterale per la sezione backup paths
    local backup_paths_color="#4CAF50"  # Verde di default (tutti i path OK)
    
    # Controlla lo stato dei path di backup tramite le emoji
    if [[ "$EMOJI_PRI" == "❌" ]] || [[ "$EMOJI_SEC" == "❌" ]] || [[ "$EMOJI_CLO" == "❌" ]]; then
        backup_paths_color="#F44336"  # Rosso se almeno uno in errore
    elif [[ "$EMOJI_PRI" == "⚠️" ]] || [[ "$EMOJI_SEC" == "⚠️" ]] || [[ "$EMOJI_CLO" == "⚠️" ]]; then
        backup_paths_color="#FF9800"  # Arancione se almeno uno in warning
    fi
    
    # Determina il colore della barra laterale per la sezione errori
    local error_summary_color="#4CAF50"  # Verde di default (nessun problema)
    if [ -f "$LOG_FILE" ]; then
        local error_count=$(grep -c "\[ERROR\]" "$LOG_FILE" 2>/dev/null || echo "0")
        local warning_count=$(grep -c "\[WARNING\]" "$LOG_FILE" 2>/dev/null || echo "0")
        
        # Assicurati che i valori siano numerici
        [[ "$error_count" =~ ^[0-9]+$ ]] || error_count=0
        [[ "$warning_count" =~ ^[0-9]+$ ]] || warning_count=0
        
        if [ "$error_count" -gt 0 ]; then
            error_summary_color="#F44336"  # Rosso se ci sono errori
        elif [ "$warning_count" -gt 0 ]; then
            error_summary_color="#FF9800"  # Arancione se ci sono warning
        fi
    fi
	
    # Crea un modello di email HTML pulito e moderno
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
    
    # Aggiungi informazioni di spazio per lo storage locale
    if [ "$local_free" != "N/A" ]; then
        # Estrai la percentuale numerica senza il simbolo %
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
    
    # Aggiungi informazioni di spazio per lo storage secondario
    if [ "$secondary_free" != "N/A" ]; then
        # Estrai la percentuale numerica senza il simbolo %
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
    
    # Aggiungi percorso secondario se configurato
    if [ "${ENABLE_SECONDARY_BACKUP:-false}" = "true" ] && [ -d "$SECONDARY_BACKUP_PATH" ]; then
        email_body+="
                    <tr>
                        <td>Secondary Path</td>
                        <td>${SECONDARY_BACKUP_PATH}</td>
                    </tr>"
    fi
    
    # Aggiungi percorso cloud se configurato
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
    
    # Aggiungi riepilogo errori/avvisi
    add_error_summary_to_email "$error_summary_color"
    
    # Aggiungi suggerimenti di sistema se necessario
    add_system_recommendations_to_email
    
    # Aggiungi footer
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
        # Conta errori e avvisi
        local error_count=$(grep -c "\[ERROR\]" "$LOG_FILE" 2>/dev/null || echo "0")
        local warning_count=$(grep -c "\[WARNING\]" "$LOG_FILE" 2>/dev/null || echo "0")
        
        # Assicurati che i valori siano numerici
        [[ "$error_count" =~ ^[0-9]+$ ]] || error_count=0
        [[ "$warning_count" =~ ^[0-9]+$ ]] || warning_count=0
        
        email_body+="
            <div class=\"section\">
                <h2>Error and Warning Summary</h2>"
        
        # Aggiungi box di riepilogo con conteggi e barra laterale colorata
        email_body+="
                <div style=\"padding:15px; background-color:#F5F5F5; border-radius:6px; margin-bottom:15px; border-left:4px solid ${error_summary_color};\">
                    <p style=\"margin:0;\"><strong>Total Issues:</strong> $((error_count + warning_count))</p>
                    <p style=\"margin:5px 0 0 0;\"><strong>Errors:</strong> $error_count</p>
                    <p style=\"margin:5px 0 0 0;\"><strong>Warnings:</strong> $warning_count</p>
                </div>"
        
        # Se ci sono errori o avvisi, elencali per categoria
        if [ $((error_count + warning_count)) -gt 0 ]; then
            # Crea una tabella per categorie di errori
            email_body+="
                <table class=\"info-table\">
                    <tr>
                        <th style=\"text-align:left; padding:10px; background-color:#f2f2f2;\">Problem</th>
                        <th style=\"text-align:left; padding:10px; background-color:#f2f2f2;\">Type</th>
                        <th style=\"text-align:left; padding:10px; background-color:#f2f2f2;\">Count</th>
                    </tr>"
            
            # Estrai categorie di errori e contale
            local categories=()
            local category_counts_error=()
            local category_counts_warning=()
            local category_examples_error=()
            local category_examples_warning=()
            
            # Cerca pattern come [ERROR] Failed to create directory o [WARNING] Missing configuration
            # Estrai questi pattern per identificare categorie comuni
            
            # Elabora errori
            while read -r line; do
                # Estrai la categoria (prime parole dopo [ERROR])
                local category=$(echo "$line" | sed -n 's/.*\[ERROR\] \([^:]*\).*/\1/p')
                if [ -n "$category" ]; then
                    # Verifica se questa categoria è già nel nostro array
                    local found=0
                    for i in "${!categories[@]}"; do
                        if [ "${categories[$i]}" = "$category" ]; then
                            # Incrementa il conteggio
                            category_counts_error[$i]=$((category_counts_error[$i] + 1))
                            found=1
                            break
                        fi
                    done
                    
                    # Se non trovata, aggiungi una nuova categoria
                    if [ $found -eq 0 ]; then
                        categories+=("$category")
                        category_counts_error+=("1")
                        category_counts_warning+=("0")
                        # Estrai l'esempio in base alla presenza dei due punti
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
            
            # Elabora avvisi
            while read -r line; do
			echo "DEBUG: Processando riga: $line" >> /tmp/debug_email.log
			echo "DEBUG: Categoria estratta: '$category'" >> /tmp/debug_email.log
                # Estrai la categoria (prime parole dopo [WARNING])
                # Gestisce sia il caso con i due punti che senza
                local category=""
                if echo "$line" | grep -q "\[WARNING\] [^:]*:"; then
                    # Caso con i due punti
                    category=$(echo "$line" | sed -n 's/.*\[WARNING\] \([^:]*\):.*/\1/p')
                else
                    # Caso senza i due punti - prendi tutto il messaggio
                    category=$(echo "$line" | sed -n 's/.*\[WARNING\] \(.*\)/\1/p')
                fi
                
                if [ -n "$category" ]; then
                    # Verifica se questa categoria è già nel nostro array
                    local found=0
                    for i in "${!categories[@]}"; do
                        if [ "${categories[$i]}" = "$category" ]; then
                            # Incrementa il conteggio
                            category_counts_warning[$i]=$((category_counts_warning[$i] + 1))
                            
                            # Se questo è il primo avviso in questa categoria, salva un esempio
                            if [ "${category_counts_warning[$i]}" -eq 1 ]; then
                                # Estrai l'esempio in base alla presenza dei due punti
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
                    
                    # Se non trovata, aggiungi una nuova categoria
                    if [ $found -eq 0 ]; then
                        categories+=("$category")
                        category_counts_error+=("0")
                        category_counts_warning+=("1")
                        category_examples_error+=("")
                        # Estrai l'esempio in base alla presenza dei due punti
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
            
            # Se non sono stati trovati errori/avvisi categorizzati, utilizza conteggi semplici
            if [ ${#categories[@]} -eq 0 ]; then
                # Aggiungi errori e avvisi generici se presenti
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
                # Aggiungi ogni categoria alla tabella
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
            # Nessun errore o avviso
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
    # Estrai valori numerici dalle percentuali, gestendo il caso "N/A"
    local local_percent_num=""
    local secondary_percent_num=""
    
    if [ "$local_percent" != "N/A" ] && [[ "$local_percent" =~ ^[0-9]+%$ ]]; then
        local_percent_num="${local_percent/\%/}"
    fi
    
    if [ "$secondary_percent" != "N/A" ] && [[ "$secondary_percent" =~ ^[0-9]+%$ ]]; then
        secondary_percent_num="${secondary_percent/\%/}"
    fi
    
    # Controlla se almeno uno dei valori supera 85%
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
			
			
			
			
			
			
			
			
			
			
			
			
			
			
			
			
			
			
			
			
			
			
			
			
			
			
			
			
			
			
			
			
			
			
			
			
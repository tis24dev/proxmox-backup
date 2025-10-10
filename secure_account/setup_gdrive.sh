#!/bin/bash
#
# Script di configurazione per Google Drive con rclone usando service account JSON
# Include assistenza per la creazione del file JSON
#
# Version: 0.2.1
#
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICE_ACCOUNT_FILE=""

# Funzione per creare il file JSON
create_json_file() {
    echo "=== CREAZIONE FILE JSON SERVICE ACCOUNT ==="
    echo "Inserisci i dati del service account (puoi ottenerli dalla Google Cloud Console):"
    echo ""
    
    read -p "Tipo di account [service_account]: " type
    type=${type:-service_account}
    
    read -p "Project ID: " project_id
    if [ -z "$project_id" ]; then
        echo "Project ID è obbligatorio"
        exit 1
    fi
    
    read -p "Private Key ID: " private_key_id
    if [ -z "$private_key_id" ]; then
        echo "Private Key ID è obbligatorio"
        exit 1
    fi
    
    echo "Private Key (incolla tutto il contenuto incluso -----BEGIN PRIVATE KEY----- e -----END PRIVATE KEY-----):"
    echo "Premi CTRL+D quando hai finito di incollare"
    private_key=$(cat)
    if [ -z "$private_key" ]; then
        echo "Private Key è obbligatorio"
        exit 1
    fi
    
    read -p "Client Email: " client_email
    if [ -z "$client_email" ]; then
        echo "Client Email è obbligatorio"
        exit 1
    fi
    
    read -p "Client ID: " client_id
    if [ -z "$client_id" ]; then
        echo "Client ID è obbligatorio"
        exit 1
    fi
    
    read -p "Auth URI [https://accounts.google.com/o/oauth2/auth]: " auth_uri
    auth_uri=${auth_uri:-https://accounts.google.com/o/oauth2/auth}
    
    read -p "Token URI [https://oauth2.googleapis.com/token]: " token_uri
    token_uri=${token_uri:-https://oauth2.googleapis.com/token}
    
    read -p "Auth Provider x509 Cert URL [https://www.googleapis.com/oauth2/v1/certs]: " auth_provider_x509_cert_url
    auth_provider_x509_cert_url=${auth_provider_x509_cert_url:-https://www.googleapis.com/oauth2/v1/certs}
    
    read -p "Client x509 Cert URL: " client_x509_cert_url
    if [ -z "$client_x509_cert_url" ]; then
        echo "Client x509 Cert URL è obbligatorio"
        exit 1
    fi
    
    read -p "Universe Domain [googleapis.com]: " universe_domain
    universe_domain=${universe_domain:-googleapis.com}
    
    # Nome del file JSON
    read -p "Nome del file JSON [service-account.json]: " json_filename
    json_filename=${json_filename:-service-account.json}
    
    SERVICE_ACCOUNT_FILE="$SCRIPT_DIR/$json_filename"
    
    # Crea il file JSON
    cat > "$SERVICE_ACCOUNT_FILE" << EOF
{
  "type": "$type",
  "project_id": "$project_id",
  "private_key_id": "$private_key_id",
  "private_key": "$private_key",
  "client_email": "$client_email",
  "client_id": "$client_id",
  "auth_uri": "$auth_uri",
  "token_uri": "$token_uri",
  "auth_provider_x509_cert_url": "$auth_provider_x509_cert_url",
  "client_x509_cert_url": "$client_x509_cert_url",
  "universe_domain": "$universe_domain"
}
EOF
    
    echo ""
    echo "File JSON creato: $SERVICE_ACCOUNT_FILE"
    echo ""
}

# Funzione per verificare se esiste già un file JSON
check_existing_json() {
    JSON_FILES=("$SCRIPT_DIR"/*.json)
    if [ ${#JSON_FILES[@]} -eq 1 ] && [ -f "${JSON_FILES[0]}" ]; then
        echo "Trovato file JSON esistente: ${JSON_FILES[0]}"
        read -p "Vuoi utilizzare questo file? (s/n) [s]: " use_existing
        use_existing=${use_existing:-s}
        
        if [[ "$use_existing" =~ ^[sS]$ ]]; then
            SERVICE_ACCOUNT_FILE="${JSON_FILES[0]}"
            return 0
        fi
    elif [ ${#JSON_FILES[@]} -gt 1 ]; then
        echo "Trovati più file JSON nella directory:"
        for i in "${!JSON_FILES[@]}"; do
            echo "$((i+1)). ${JSON_FILES[i]}"
        done
        
        read -p "Seleziona il numero del file da usare (0 per crearne uno nuovo): " selection
        
        if [ "$selection" -gt 0 ] && [ "$selection" -le "${#JSON_FILES[@]}" ]; then
            SERVICE_ACCOUNT_FILE="${JSON_FILES[$((selection-1))]}"
            return 0
        fi
    fi
    
    return 1
}

echo "=== CONFIGURAZIONE GOOGLE DRIVE CON RCLONE ==="
echo ""

# Verifica presenza di rclone
if ! command -v rclone &> /dev/null; then
    echo "rclone non è installato. Installalo con: apt-get install rclone"
    exit 1
fi

# Gestione del file JSON
if [ $# -eq 1 ]; then
    # File JSON specificato come parametro
    SERVICE_ACCOUNT_FILE="$1"
    if [ ! -f "$SERVICE_ACCOUNT_FILE" ]; then
        echo "File JSON non trovato: $SERVICE_ACCOUNT_FILE"
        exit 1
    fi
else
    # Chiedi se ha già il file JSON
    read -p "Hai già un file JSON del service account? (s/n): " has_json
    
    if [[ "$has_json" =~ ^[sS]$ ]]; then
        if ! check_existing_json; then
            read -p "Inserisci il percorso completo del file JSON: " json_path
            if [ ! -f "$json_path" ]; then
                echo "File non trovato: $json_path"
                exit 1
            fi
            SERVICE_ACCOUNT_FILE="$json_path"
        fi
    else
        create_json_file
    fi
fi

echo "Utilizzando file JSON: $SERVICE_ACCOUNT_FILE"

# Verifica che il file JSON sia valido
if ! python3 -m json.tool "$SERVICE_ACCOUNT_FILE" > /dev/null 2>&1; then
    if ! python -m json.tool "$SERVICE_ACCOUNT_FILE" > /dev/null 2>&1; then
        echo "Attenzione: Il file JSON potrebbe non essere valido"
        read -p "Vuoi continuare comunque? (s/n): " continue_anyway
        if [[ ! "$continue_anyway" =~ ^[sS]$ ]]; then
            exit 1
        fi
    fi
fi

# Imposta permessi 400 e proprietario root al file JSON
if [ "$(stat -c "%a" "$SERVICE_ACCOUNT_FILE")" != "400" ]; then
    chmod 400 "$SERVICE_ACCOUNT_FILE"
    echo "Impostati permessi 400 sul file JSON"
fi

if [ "$(stat -c "%U" "$SERVICE_ACCOUNT_FILE")" != "root" ]; then
    chown root:root "$SERVICE_ACCOUNT_FILE"
    echo "Impostato proprietario root sul file JSON"
fi

RCLONE_CONF="$HOME/.config/rclone/rclone.conf"
mkdir -p "$(dirname "$RCLONE_CONF")"

# Rimuove eventuale configurazione gdrive esistente
if grep -q "^\[gdrive\]" "$RCLONE_CONF" 2>/dev/null; then
    echo "Rimossa configurazione gdrive esistente"
    sed -i '/^\[gdrive\]/,/^$/d' "$RCLONE_CONF"
fi

# Richiedi il root_folder_id
echo ""
echo "=== CONFIGURAZIONE CARTELLA GOOGLE DRIVE ==="
echo "Per ottenere l'ID della cartella:"
echo "1. Vai su https://drive.google.com"
echo "2. Naviga nella cartella che vuoi usare come root"
echo "3. Copia l'ID dall'URL: https://drive.google.com/drive/folders/ID_CARTELLA"
echo ""
read -p "Inserisci l'ID della cartella di Google Drive (root_folder_id): " ROOT_FOLDER_ID

if [ -z "$ROOT_FOLDER_ID" ]; then
    echo "root_folder_id è obbligatorio"
    exit 1
fi

# Crea il nuovo blocco di configurazione
cat >> "$RCLONE_CONF" << EOF

[gdrive]
# access with a service account JSON credentials
type = drive
service_account_file = $SERVICE_ACCOUNT_FILE
scope = drive.file
root_folder_id = $ROOT_FOLDER_ID
acknowledge_abuse = true
# personalizza le seguenti opzioni se necessario:
# chunk_size = 64M
# upload_cutoff = 64M
# use_trash = false
EOF

chmod 400 "$RCLONE_CONF"

echo ""
echo "=== CONFIGURAZIONE COMPLETATA ==="
echo "- File JSON: $SERVICE_ACCOUNT_FILE"
echo "- Configurazione rclone: $RCLONE_CONF"
echo "- Root folder ID: $ROOT_FOLDER_ID"
echo ""
echo "IMPORTANTE: Assicurati di condividere la cartella Google Drive con:"
echo "$(grep '"client_email"' "$SERVICE_ACCOUNT_FILE" | cut -d'"' -f4)"
echo ""
echo "Test della configurazione con: rclone lsd gdrive:"
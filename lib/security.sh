#!/bin/bash
# Funzioni di sicurezza base per il backup

# Cache per command -v per evitare chiamate ridondanti
declare -A COMMAND_CACHE

# Funzione per verificare se un comando esiste (con cache)
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

# Funzione per invalidare la cache dei comandi
clear_command_cache() {
    local cmd="$1"
    if [[ -n "$cmd" ]]; then
        # Cancella un comando specifico
        unset COMMAND_CACHE["$cmd"]
        debug "Cleared cache for command: $cmd"
    else
        # Cancella tutta la cache
        COMMAND_CACHE=()
        debug "Cleared entire command cache"
    fi
}

# Funzione per forzare un refresh della cache di un comando
refresh_command_cache() {
    local cmd="$1"
    clear_command_cache "$cmd"
    command_exists "$cmd"  # Questo ricostruirà la cache
}

# Funzione per rilevare il package manager disponibile
detect_package_manager() {
    if command_exists "apt-get"; then
        echo "apt-get"
    elif command_exists "dnf"; then
        echo "dnf"
    elif command_exists "yum"; then
        echo "yum"
    else
        echo ""
    fi
}

# Funzione per installare pacchetti usando il package manager rilevato
install_packages() {
    local packages=("$@")
    local pkg_manager
    
    pkg_manager=$(detect_package_manager)
    if [[ -z "$pkg_manager" ]]; then
        error "Unable to detect package manager. Please install missing packages manually."
        return $EXIT_ERROR
    fi
    
    debug "Using $pkg_manager package manager"
    
    case "$pkg_manager" in
        "apt-get")
            info "Updating package list..."
            if apt-get update 2>&1 | while IFS= read -r line; do info "APT: $line"; done; then
                info "Installing packages: ${packages[*]}"
                if apt-get install -y "${packages[@]}" 2>&1 | while IFS= read -r line; do info "APT: $line"; done; then
                    return $EXIT_SUCCESS
                else
                    return $EXIT_ERROR
                fi
            else
                return $EXIT_ERROR
            fi
            ;;
        "dnf")
            info "Installing packages with dnf: ${packages[*]}"
            if dnf install -y "${packages[@]}" 2>&1 | while IFS= read -r line; do info "DNF: $line"; done; then
                return $EXIT_SUCCESS
            else
                return $EXIT_ERROR
            fi
            ;;
        "yum")
            info "Installing packages with yum: ${packages[*]}"
            if yum install -y "${packages[@]}" 2>&1 | while IFS= read -r line; do info "YUM: $line"; done; then
                return $EXIT_SUCCESS
            else
                return $EXIT_ERROR
            fi
            ;;
    esac
    
    return $EXIT_SUCCESS
}

# Verifica la sicurezza dello script
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

    # Decide se eseguire controllo completo o solo script check
    debug "Running security check (FULL_SECURITY_CHECK=${FULL_SECURITY_CHECK:-false})"
    local check_result=0
    if [[ "${FULL_SECURITY_CHECK:-false}" == "true" ]]; then
        bash "$security_script" || check_result=$?
    else
        bash "$security_script" --script-check || check_result=$?
    fi

    # Handle security check result
    case $check_result in
        0)
            debug "Security check passed successfully"
            success "Script security verification completed successfully"
            ;;
        1)
            warning "Security check completed with warnings"
            if [[ "${ABORT_ON_SECURITY_ISSUES:-false}" == "true" ]]; then
                error "Aborting due to security issues (ABORT_ON_SECURITY_ISSUES=true)"
                return $EXIT_ERROR
            else
                warning "Continuazione nonostante warning di sicurezza (ABORT_ON_SECURITY_ISSUES=false)"
                set_exit_code "warning"
            fi
            ;;
        2)
            error "Security check failed"
            if [[ "${ABORT_ON_SECURITY_ISSUES:-false}" == "true" ]]; then
                error "Aborting due to security issues (ABORT_ON_SECURITY_ISSUES=true)"
                return $EXIT_ERROR
            else
                warning "Continuazione nonostante errori di sicurezza (ABORT_ON_SECURITY_ISSUES=false)"
                set_exit_code "warning"
            fi
            ;;
    esac

    return $security_status
}

# Controllo delle dipendenze del sistema
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
    
    # Check required packages
    local missing_packages=()
    local pkg
    for pkg in ${REQUIRED_PACKAGES:-}; do
        if ! command_exists "$pkg"; then
            missing_packages+=("$pkg")
            warning "Required package not found: $pkg"
        else
            debug "Found required package: $pkg"
        fi
    done
    
    # Handle missing packages
    if [[ ${#missing_packages[@]} -gt 0 ]]; then
        warning "Missing required packages: ${missing_packages[*]}"
        
        if [[ "${AUTO_INSTALL_DEPENDENCIES:-false}" == "true" ]]; then
            install_missing_packages "${missing_packages[@]}"
        else
            error "Missing required packages and AUTO_INSTALL_DEPENDENCIES is disabled"
            set_exit_code "error"
            return $EXIT_ERROR
        fi
    fi
    
    # Verifica degli strumenti di compressione
    if ! check_compression_tools; then
        error "Compression tools check failed"
        set_exit_code "error"
        return $EXIT_ERROR
    fi
    
    success "All dependencies are satisfied"
}

# Installazione pacchetti mancanti
install_missing_packages() {
    local packages=("$@")
    
    if [[ ${#packages[@]} -eq 0 ]]; then
        debug "No packages to install"
        return $EXIT_SUCCESS
    fi
    
    info "Attempting to install missing required packages: ${packages[*]}"
    
    # Usa la funzione unificata per installare i pacchetti
    if ! install_packages "${packages[@]}"; then
        error "Failed to install required packages"
        set_exit_code "error"
        return $EXIT_ERROR
    fi
    
    # Clear command cache for installed packages to ensure fresh verification
    info "Clearing command cache for installed packages..."
    for pkg in "${packages[@]}"; do
        clear_command_cache "$pkg"
    done
    
    # Also clear bash's command hash to ensure fresh PATH lookup
    hash -r 2>/dev/null || true
    
    # Verify installation
    local failed_installs=()
    local pkg
    for pkg in "${packages[@]}"; do
        if ! command_exists "$pkg"; then
            failed_installs+=("$pkg")
            error "Failed to install required package: $pkg"
        else
            info "Successfully installed package: $pkg"
        fi
    done
    
    if [[ ${#failed_installs[@]} -gt 0 ]]; then
        error "Failed to install some required packages: ${failed_installs[*]}"
        set_exit_code "error"
        return $EXIT_ERROR
    fi
}

# Version comparison function migliorata
check_version() {
    local version="$1"
    local required_version="$2"
    
    # Validazione input
    if [[ -z "$version" || -z "$required_version" ]]; then
        debug "Invalid version parameters: version='$version', required='$required_version'"
        return 1
    fi
    
    # Normalizza le versioni rimuovendo caratteri non numerici eccetto punti
    version=$(echo "$version" | sed 's/[^0-9.]//g')
    required_version=$(echo "$required_version" | sed 's/[^0-9.]//g')
    
    # Usa sort -V per comparazione semantica delle versioni
    if [[ "$version" == "$required_version" ]]; then
        return 0
    fi
    
    # Controlla se la versione corrente è maggiore o uguale a quella richiesta
    local older_version
    older_version=$(printf '%s\n%s\n' "$version" "$required_version" | sort -V | head -n1)
    
    if [[ "$older_version" == "$required_version" ]]; then
        return 0  # version >= required_version
    else
        return 1  # version < required_version
    fi
}

# Compression tools checking - CORRETTA per evitare ricorsione infinita
check_compression_tools() {
    local tools_missing=false
    local required_tools=()  # Array invece di stringa
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

    # Gestione strumenti mancanti - RIMOSSA la ricorsione infinita
    if [[ "$tools_missing" == "true" ]]; then
        if [[ "${AUTO_INSTALL_DEPENDENCIES:-false}" == "true" ]]; then
            info "Installing missing compression tools: ${required_tools[*]}"
            if ! install_packages "${required_tools[@]}"; then
                error "Install failed: ${required_tools[*]}"
                return $EXIT_ERROR
            fi
            
            # Clear command cache for installed tools to ensure fresh verification
            info "Clearing command cache for installed compression tools..."
            for tool in "${required_tools[@]}"; do
                clear_command_cache "$tool"
            done
            
            # Also clear bash's command hash to ensure fresh PATH lookup
            hash -r 2>/dev/null || true
            
            # Verifica che l'installazione sia andata a buon fine
            local tool
            for tool in "${required_tools[@]}"; do
                if ! command_exists "$tool"; then
                    error "Failed to install compression tool: $tool"
                    return $EXIT_ERROR
                fi
            done
        else
            error "Missing compression tools: ${required_tools[*]}"
            return $EXIT_ERROR
        fi
    fi

    return $EXIT_SUCCESS
}
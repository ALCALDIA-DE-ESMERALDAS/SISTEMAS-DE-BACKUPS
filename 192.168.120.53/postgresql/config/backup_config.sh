#!/bin/bash
# ===============================================
# CONFIGURACIÓN COMPARTIDA PARA SISTEMA DE BACKUP
# ===============================================

# Definir LOG_DIR primero
LOG_DIR="/home/sis_backups_auto/postgresql/config/logs"

# Función de logging compartida
log() {
    local level="${1:-INFO}"
    local message="$2"
    local script_name="${3:-$(basename "$0")}"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local log_file="${LOG_DIR}/backup_$(date +"%Y%m").log"
    
    # Crear directorio de logs si no existe
    mkdir -p "$LOG_DIR"
    
    echo "[$timestamp] [$level] [$script_name] $message" | tee -a "$log_file"
    
    # Log adicional para errores críticos
    if [[ "$level" == "ERROR" || "$level" == "CRITICAL" ]]; then
        echo "[$timestamp] [$level] [$script_name] $message" >> "${LOG_DIR}/error_$(date +"%Y%m").log"
    fi
}

# Agrega al inicio del script, después del shebang
CONFIG_FILE="${CONFIG_FILE:-/home/sis_backups_auto/postgresql/config/.env}"

# Cargar configuración desde .env si existe
if [[ -f "$CONFIG_FILE" ]]; then
    log "INFO" "Cargando configuración desde: $CONFIG_FILE" "CONFIG"
    # Usar source para cargar las variables
    set -a  # Automáticamente exporta todas las variables
    source "$CONFIG_FILE"
    set +a
else
    log "WARNING" "Archivo .env no encontrado: $CONFIG_FILE, usando valores por defecto" "CONFIG"
fi

# Códigos de error específicos
readonly ERROR_PREREQ=1
readonly ERROR_CONNECTION=2
readonly ERROR_BACKUP=3
readonly ERROR_TRANSFER=4
readonly ERROR_CLEANUP=5
readonly ERROR_CONFIG=6
readonly ERROR_ALREADY_RUNNING=7


# Función para validar configuración
validate_config() {
    local errors=()
    
    # Verificar variables críticas
    [[ -z "$PG_USER" ]] && errors+=("PG_USER no definido")
    [[ -z "$DATABASE_NAME" ]] && errors+=("DATABASE_NAME no definido")
    [[ -z "$BACKUP_DIR" ]] && errors+=("BACKUP_DIR no definido")
    [[ -z "$RSYNC_HOST" ]] && errors+=("RSYNC_HOST no definido")
    
    # Verificar archivos críticos
    [[ ! -f "$RSYNC_PASSFILE" ]] && errors+=("Archivo de contraseña rsync no existe: $RSYNC_PASSFILE")
    
    # Verificar directorios
    [[ ! -d "$BACKUP_DIR" ]] && mkdir -p "$BACKUP_DIR" 2>/dev/null || errors+=("No se puede crear BACKUP_DIR: $BACKUP_DIR")
    [[ ! -d "$LOG_DIR" ]] && mkdir -p "$LOG_DIR" 2>/dev/null || errors+=("No se puede crear LOG_DIR: $LOG_DIR")
    
    # Verificar permisos
    [[ ! -w "$BACKUP_DIR" ]] && errors+=("Sin permisos de escritura en BACKUP_DIR: $BACKUP_DIR")
    [[ ! -r "$RSYNC_PASSFILE" ]] && errors+=("Sin permisos de lectura en RSYNC_PASSFILE: $RSYNC_PASSFILE")
    
    if [[ ${#errors[@]} -gt 0 ]]; then
        log "ERROR" "Errores de configuración:" "CONFIG"
        for error in "${errors[@]}"; do
            log "ERROR" "  - $error" "CONFIG"
        done
        return $ERROR_CONFIG
    fi
    
    log "INFO" "Configuración validada correctamente" "CONFIG"
    return 0
}

# Función para guardar información del último backup
save_backup_info() {
    local backup_file="$1"
    local backup_size="$2"
    local backup_duration="$3"
    
    cat > "$LAST_BACKUP_FILE" << EOF
LAST_BACKUP_FILE="$backup_file"
LAST_BACKUP_DATE="$(date '+%Y-%m-%d %H:%M:%S')"
LAST_BACKUP_SIZE="$backup_size"
LAST_BACKUP_DURATION="$backup_duration"
LAST_BACKUP_STATUS="CREATED"
EOF
    
    log "INFO" "Información de backup guardada en $LAST_BACKUP_FILE" "CONFIG"
}

# Función para cargar información del último backup
load_backup_info() {
    if [[ -f "$LAST_BACKUP_FILE" ]]; then
        source "$LAST_BACKUP_FILE"
        log "INFO" "Información de backup cargada: $LAST_BACKUP_FILE" "CONFIG"
        return 0
    else
        log "ERROR" "No se encontró información del último backup" "CONFIG"
        return 1
    fi
}

# Función para actualizar estado del backup
update_backup_status() {
    local new_status="$1"
    
    if [[ -f "$LAST_BACKUP_FILE" ]]; then
        sed -i "s/LAST_BACKUP_STATUS=.*/LAST_BACKUP_STATUS=\"$new_status\"/" "$LAST_BACKUP_FILE"
        log "INFO" "Estado actualizado a: $new_status" "CONFIG"
    fi
}

# Función para verificar si otro proceso está ejecutándose
check_process_lock() {
    local lock_file="$1"
    local process_name="$2"
    
    if [[ -f "$lock_file" ]]; then
        local old_pid=$(cat "$lock_file")
        if kill -0 "$old_pid" 2>/dev/null; then
            log "ERROR" "$process_name ya se está ejecutando (PID: $old_pid)" "LOCK"
            return $ERROR_ALREADY_RUNNING
        else
            log "INFO" "Archivo PID obsoleto encontrado, eliminando..." "LOCK"
            rm -f "$lock_file"
        fi
    fi
    
    echo $$ > "$lock_file"
    log "INFO" "$process_name iniciado (PID: $$)" "LOCK"
    return 0
}

# Función para limpiar archivo PID
cleanup_lock() {
    local lock_file="$1"
    rm -f "$lock_file"
}

# Función de limpieza en caso de error
cleanup_on_error() {
    log "INFO" "Ejecutando limpieza de emergencia..." "CLEANUP"
    
    # Limpiar variables de entorno sensibles
    unset PGPASSWORD 2>/dev/null || true
    
    # Limpiar archivos temporales
    rm -f /tmp/postgres_backup_* 2>/dev/null || true
    
    log "INFO" "Limpieza completada" "CLEANUP"
}

# Trap global para todos los scripts
setup_global_trap() {
    trap 'cleanup_on_error; log "ERROR" "Script interrumpido inesperadamente" "$(basename "$0")"; exit 1' ERR INT TERM
}

# Verificar herramientas necesarias
check_required_tools() {
    local missing_tools=()
    local required_tools=("$@")
    
    for tool in "${required_tools[@]}"; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            missing_tools+=("$tool")
        fi
    done
    
    if [[ ${#missing_tools[@]} -gt 0 ]]; then
        log "ERROR" "Herramientas faltantes: ${missing_tools[*]}" "PREREQ"
        return $ERROR_PREREQ
    fi
    
    return 0
}
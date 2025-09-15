#!/bin/bash
set -euo pipefail

# ===============================================
# SCRIPT DE BACKUP POSTGRESQL CON RSYNC
# Versión optimizada con manejo de errores mejorado
# ===============================================

# Configuración
LOG_DIR="/var/log/postgres_backups"
LOG_FILE="${LOG_DIR}/backup_$(date +"%Y%m").log"
PG_USER="postgres"
PG_PASS="postgres"
PG_HOST="127.0.0.1"
PG_PORT="5432"
DATABASE_NAME="sigcal"

# Configuración de backup
BACKUP_DIR="/backups/postgres"
DATE=$(date +"%Y%m%d-%H%M%S")
FILENAME="sigcal_backup_${DATE}.sql.gz"
FULLPATH="${BACKUP_DIR}/${FILENAME}"

# Configuración RSYNC
RSYNC_HOST="159.223.186.132"
RSYNC_USER="usuario"
RSYNC_MODULE="backup_192.168.120.52"
RSYNC_PORT="9000"
RSYNC_PASSFILE="/home/sis_backups_auto/password"

# Configuración de retención
RETENTION_DAYS=3
MAX_LOG_SIZE=10485760  # 10MB en bytes

# Códigos de error específicos
readonly ERROR_PREREQ=1
readonly ERROR_CONNECTION=2
readonly ERROR_BACKUP=3
readonly ERROR_TRANSFER=4
readonly ERROR_CLEANUP=5

# ===============================================
# FUNCIONES DE UTILIDAD
# ===============================================

# Función de logging mejorada con niveles
log() {
    local level="${1:-INFO}"
    local message="$2"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    echo "[$timestamp] [$level] $message" | tee -a "$LOG_FILE"
    
    # Log adicional para errores críticos
    if [[ "$level" == "ERROR" || "$level" == "CRITICAL" ]]; then
        echo "[$timestamp] [$level] $message" >> "${LOG_DIR}/error_$(date +"%Y%m").log"
    fi
}

# Función para enviar notificaciones (opcional)
send_notification() {
    local subject="$1"
    local message="$2"
    
    # Ejemplo usando curl para webhook (personalizar según necesidades)
    # curl -X POST "https://your-webhook-url.com" \
    #   -H "Content-Type: application/json" \
    #   -d "{\"subject\":\"$subject\",\"message\":\"$message\"}"
    
    log "NOTIFICATION" "$subject: $message"
}

# Función para limpieza en caso de error
cleanup_on_error() {
    log "INFO" "Ejecutando limpieza de emergencia..."
    
    # Limpiar archivo de backup parcial si existe
    if [[ -f "$FULLPATH" ]]; then
        local filesize=$(stat -c%s "$FULLPATH" 2>/dev/null || echo "0")
        if [[ $filesize -lt 1000 ]]; then  # Archivo muy pequeño, probablemente corrupto
            rm -f "$FULLPATH"
            log "INFO" "Archivo de backup corrupto eliminado"
        fi
    fi
    
    # Limpiar variables de entorno sensibles
    unset PGPASSWORD 2>/dev/null || true
}

# Trap para manejar errores y señales4
trap 'cleanup_on_error; log "ERROR" "Script interrumpido inesperadamente"; exit 1' ERR INT TERM

# ===============================================
# VALIDACIONES PREVIAS
# ===============================================

validate_prerequisites() {
    log "INFO" "Validando prerrequisitos..."
    
    local missing_tools=()
    
    # Verificar herramientas necesarias
    for tool in pg_dump psql rsync gzip find nc; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            missing_tools+=("$tool")
        fi
    done
    
    if [[ ${#missing_tools[@]} -gt 0 ]]; then
        log "ERROR" "Herramientas faltantes: ${missing_tools[*]}"
        return $ERROR_PREREQ
    fi
    
    # Crear directorios necesarios
    mkdir -p "$BACKUP_DIR" "$LOG_DIR"
    
    # Verificar permisos de escritura
    if [[ ! -w "$BACKUP_DIR" ]]; then
        log "ERROR" "No hay permisos de escritura en $BACKUP_DIR"
        return $ERROR_PREREQ
    fi
    
    # Verificar archivo de contraseña para rsync
    if [[ ! -r "$RSYNC_PASSFILE" ]]; then
        log "ERROR" "Archivo de contraseña rsync no accesible: $RSYNC_PASSFILE"
        return $ERROR_PREREQ
    fi
    
    # Verificar espacio en disco
    local available_space=$(df "$BACKUP_DIR" | awk 'NR==2 {print $4}')
    local required_space=1048576  # 1GB en KB
    
    if [[ $available_space -lt $required_space ]]; then
        log "ERROR" "Espacio insuficiente. Disponible: ${available_space}KB, Requerido: ${required_space}KB"
        return $ERROR_PREREQ
    fi
    
    log "INFO" "Prerrequisitos validados correctamente"
    return 0
}

# Función para verificar conectividad
test_connections() {
    log "INFO" "Verificando conectividad..."
    
    # Verificar conexión a PostgreSQL
    export PGPASSWORD="$PG_PASS"
    
    if ! timeout 10 psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$DATABASE_NAME" -c "SELECT version();" >/dev/null 2>&1; then
        log "ERROR" "No se puede conectar a PostgreSQL"
        log "ERROR" "Host: $PG_HOST, Puerto: $PG_PORT, Usuario: $PG_USER, Base: $DATABASE_NAME"
        
        # Intentar diagnóstico más detallado
        if ! nc -z -w 5 "$PG_HOST" "$PG_PORT" 2>/dev/null; then
            log "ERROR" "Puerto PostgreSQL ($PG_PORT) no responde en $PG_HOST"
        fi
        
        return $ERROR_CONNECTION
    fi
    
    # Verificar conexión a servidor rsync
    if ! timeout 10 nc -z -w 5 "$RSYNC_HOST" "$RSYNC_PORT" 2>/dev/null; then
        log "ERROR" "No se puede conectar al servidor rsync"
        log "ERROR" "Host: $RSYNC_HOST, Puerto: $RSYNC_PORT"
        return $ERROR_CONNECTION
    fi
    
    log "INFO" "Conectividad verificada correctamente"
    return 0
}

# ===============================================
# FUNCIÓN PRINCIPAL DE BACKUP
# ===============================================

perform_backup() {
    log "INFO" "Iniciando backup de PostgreSQL - Base de datos: $DATABASE_NAME"
    
    # Crear archivo temporal para capturar salida de pg_dump
    local pg_dump_log=$(mktemp)
    local start_time=$(date +%s)
    
    # Configurar variable de entorno para la contraseña
    export PGPASSWORD="$PG_PASS"
    
    # Ejecutar pg_dump con opciones optimizadas
    if pg_dump -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" \
        -d "$DATABASE_NAME" \
        --format=plain \
        --no-owner \
        --no-acl \
        --verbose \
        --compress=0 2>"$pg_dump_log" | gzip -9 > "$FULLPATH"; then
        
        local end_time=$(date +%s)
        local duration=$((end_time - start_time))
        local file_size=$(du -h "$FULLPATH" | cut -f1)
        
        log "INFO" "Backup completado exitosamente"
        log "INFO" "Archivo: $FULLPATH"
        log "INFO" "Tamaño: $file_size"
        log "INFO" "Duración: ${duration}s"
        
        # Verificar integridad básica del backup
        if ! gzip -t "$FULLPATH" 2>/dev/null; then
            log "ERROR" "El archivo de backup está corrupto (fallo en verificación gzip)"
            rm -f "$FULLPATH"
            return $ERROR_BACKUP
        fi
        
    else
        log "ERROR" "Falló la generación del backup de PostgreSQL"
        log "ERROR" "Salida de pg_dump:"
        while IFS= read -r line; do
            log "ERROR" "PG_DUMP: $line"
        done < "$pg_dump_log"
        
        rm -f "$pg_dump_log" "$FULLPATH"
        return $ERROR_BACKUP
    fi
    
    rm -f "$pg_dump_log"
    unset PGPASSWORD
    
    # Verificación final del archivo
    if [[ ! -s "$FULLPATH" ]]; then
        log "ERROR" "El archivo de backup está vacío"
        return $ERROR_BACKUP
    fi
    
    return 0
}

# ===============================================
# FUNCIÓN DE TRANSFERENCIA
# ===============================================

transfer_backup() {
    log "INFO" "Iniciando transferencia vía rsync..."
    
    local rsync_log=$(mktemp)
    local rsync_error=$(mktemp)
    local start_time=$(date +%s)
    
    # Ejecutar rsync con opciones optimizadas
    if rsync -avz \
        --progress \
        --partial \
        --partial-dir=/tmp/rsync-partial \
        --stats \
        --timeout=600 \
        --compress-level=0 \
        --checksum \
        "$FULLPATH" \
        "${RSYNC_USER}@${RSYNC_HOST}::${RSYNC_MODULE}" \
        --password-file="$RSYNC_PASSFILE" \
        --port="$RSYNC_PORT" >"$rsync_log" 2>"$rsync_error"; then
        
        local end_time=$(date +%s)
        local duration=$((end_time - start_time))
        
        log "INFO" "Backup transferido exitosamente"
        log "INFO" "Destino: ${RSYNC_MODULE}"
        log "INFO" "Duración transferencia: ${duration}s"
        
        # Log estadísticas detalladas
        if grep -q "Total transferred file size" "$rsync_log"; then
            grep "Total transferred file size\|Total bytes sent\|Total bytes received" "$rsync_log" | while read -r line; do
                log "INFO" "RSYNC_STATS: $line"
            done
        fi
        
    else
        local rsync_exit_code=$?
        log "ERROR" "Falló la transferencia rsync (código: $rsync_exit_code)"
        
        # Log salida detallada del error
        log "ERROR" "Salida de rsync:"
        while IFS= read -r line; do
            [[ -n "$line" ]] && log "ERROR" "RSYNC_OUT: $line"
        done < "$rsync_log"
        
        log "ERROR" "Errores de rsync:"
        while IFS= read -r line; do
            [[ -n "$line" ]] && log "ERROR" "RSYNC_ERR: $line"
        done < "$rsync_error"
        
        # Intentar diagnóstico adicional
        if [[ $rsync_exit_code -eq 12 ]]; then
            log "ERROR" "Error de protocolo rsync - verificar configuración del servidor"
        elif [[ $rsync_exit_code -eq 23 ]]; then
            log "ERROR" "Algunos archivos no pudieron ser transferidos"
        fi
        
        rm -f "$rsync_log" "$rsync_error"
        return $ERROR_TRANSFER
    fi
    
    rm -f "$rsync_log" "$rsync_error"
    return 0
}

# ===============================================
# FUNCIÓN DE LIMPIEZA
# ===============================================

cleanup_old_backups() {
    log "INFO" "Ejecutando limpieza de backups antiguos..."
    
    # Listar archivos que serán eliminados
    local files_to_delete=$(find "$BACKUP_DIR" -name "sigcal_backup_*.sql.gz" -mtime +$RETENTION_DAYS -type f)
    
    if [[ -n "$files_to_delete" ]]; then
        log "INFO" "Archivos a eliminar (más de $RETENTION_DAYS días):"
        echo "$files_to_delete" | while read -r file; do
            if [[ -f "$file" ]]; then
                local file_age=$(find "$file" -mtime +$RETENTION_DAYS -printf "%TY-%Tm-%Td %TH:%TM")
                local file_size=$(du -h "$file" | cut -f1)
                log "INFO" "  - $(basename "$file") ($file_size, $file_age)"
            fi
        done
        
        # Eliminar archivos antiguos
        find "$BACKUP_DIR" -name "sigcal_backup_*.sql.gz" -mtime +$RETENTION_DAYS -type f -delete
        log "INFO" "Limpieza completada"
    else
        log "INFO" "No hay archivos antiguos para eliminar"
    fi
    
    # Rotar logs si son muy grandes
    if [[ -f "$LOG_FILE" ]] && [[ $(stat -c%s "$LOG_FILE") -gt $MAX_LOG_SIZE ]]; then
        mv "$LOG_FILE" "${LOG_FILE}.old"
        log "INFO" "Log rotado por tamaño"
    fi
}

# ===============================================
# FUNCIÓN PRINCIPAL
# ===============================================

main() {
    local script_start=$(date +%s)
    log "INFO" "=== INICIANDO PROCESO DE BACKUP ==="
    log "INFO" "Script: $(realpath "$0")"
    log "INFO" "PID: $$"
    log "INFO" "Usuario: $(whoami)"
    log "INFO" "Hostname: $(hostname)"
    
    # Ejecutar validaciones y operaciones
    validate_prerequisites || exit $?
    test_connections || exit $?
    perform_backup || exit $?
    transfer_backup || exit $?
    cleanup_old_backups
    
    local script_end=$(date +%s)
    local total_duration=$((script_end - script_start))
    
    log "INFO" "=== PROCESO COMPLETADO EXITOSAMENTE ==="
    log "INFO" "Duración total: ${total_duration}s"
    log "INFO" "Archivo final: $FULLPATH"
    
    # Enviar notificación de éxito (opcional)
    send_notification "Backup Exitoso" "Backup de $DATABASE_NAME completado en ${total_duration}s"
    
    return 0
}

# ===============================================
# EJECUCIÓN
# ===============================================

# Verificar que el script no se esté ejecutando ya
PIDFILE="/var/run/postgres_backup.pid"
if [[ -f "$PIDFILE" ]]; then
    OLD_PID=$(cat "$PIDFILE")
    if kill -0 "$OLD_PID" 2>/dev/null; then
        log "ERROR" "El script ya se está ejecutando (PID: $OLD_PID)"
        exit 1
    else
        rm -f "$PIDFILE"
    fi
fi

# Crear archivo PID
echo $$ > "$PIDFILE"
trap 'rm -f "$PIDFILE"' EXIT

# Ejecutar función principal
main "$@"
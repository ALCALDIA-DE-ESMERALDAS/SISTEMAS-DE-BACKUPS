#!/bin/bash
set -euo pipefail

# ===============================================
# SCRIPT DE TRANSFERENCIA DE BACKUPS
# Solo se encarga de transferir archivos de backup existentes
# ===============================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
echo $SCRIPT_DIR
source "$SCRIPT_DIR/config/backup_config.sh"

# Configurar trap y validaciones
setup_global_trap
validate_config || exit $?

# Verificar que no se esté ejecutando otro proceso de transferencia
check_process_lock "$PIDFILE_TRANSFER" "Proceso de transferencia de backup" || exit $?
trap "cleanup_lock '$PIDFILE_TRANSFER'" EXIT

# Verificar herramientas necesarias
check_required_tools rsync nc bc || exit $?

# Variables para el archivo a transferir
TRANSFER_FILE=""

# ===============================================
# FUNCIONES ESPECÍFICAS
# ===============================================

# Mostrar ayuda
show_help() {
    cat << EOF
Uso: $0 [OPCIONES] [ARCHIVO]

Transfiere archivos de backup via rsync al servidor remoto.

OPCIONES:
  -h, --help        Mostrar esta ayuda
  -i, --info        Mostrar información del sistema
  -l, --last        Transferir el último backup creado
  -a, --all         Transferir todos los backups pendientes
  -f, --file ARCHIVO Transferir archivo específico

EJEMPLOS:
  $0 --last                           # Transferir último backup
  $0 --file /path/to/backup.sql.gz    # Transferir archivo específico
  $0 --all                           # Transferir todos los pendientes

EOF
}

# Verificar conectividad al servidor rsync
test_rsync_connection() {
    log "INFO" "Verificando conectividad al servidor rsync..." "backup_transfer"
    
    if ! timeout 10 nc -z -w 5 "$RSYNC_HOST" "$RSYNC_PORT" 2>/dev/null; then
        log "ERROR" "No se puede conectar al servidor rsync" "backup_transfer"
        log "ERROR" "Host: $RSYNC_HOST, Puerto: $RSYNC_PORT" "backup_transfer"
        return $ERROR_CONNECTION
    fi
    
    log "INFO" "Conectividad al servidor rsync verificada" "backup_transfer"
    return 0
}

# Función para monitorear progreso de rsync en tiempo real
monitor_rsync_progress() {
    local rsync_log="$1"
    local file_size_bytes="$2"
    local monitor_interval=15  # segundos
    
    log "INFO" "Iniciando monitoreo de progreso (cada ${monitor_interval}s)" "backup_transfer"
    
    local last_progress=""
    local consecutive_same_progress=0
    
    while [[ -f "$rsync_log" ]] && kill -0 $! 2>/dev/null; do
        sleep $monitor_interval
        
        if [[ -f "$rsync_log" ]]; then
            # Buscar línea de progreso más reciente
            local progress_line=$(tail -50 "$rsync_log" | grep -E "[0-9]{1,3}%" | tail -1)
            
            if [[ -n "$progress_line" ]]; then
                # Extraer porcentaje
                local percentage=$(echo "$progress_line" | grep -o '[0-9]\{1,3\}%' | head -1)
                
                # Detectar si el progreso se ha detenido
                if [[ "$progress_line" == "$last_progress" ]]; then
                    consecutive_same_progress=$((consecutive_same_progress + 1))
                    if [[ $consecutive_same_progress -ge 4 ]]; then  # 1 minuto sin cambios
                        log "WARN" "Progreso detenido detectado: $progress_line" "backup_transfer"
                    fi
                else
                    consecutive_same_progress=0
                    last_progress="$progress_line"
                fi
                
                log "INFO" "PROGRESO: $progress_line" "backup_transfer"
                
                # Extraer velocidad si está disponible
                local speed_line=$(echo "$progress_line" | grep -o '[0-9.]\+[kKmMgG][Bb]/s')
                if [[ -n "$speed_line" ]]; then
                    log "INFO" "VELOCIDAD: $speed_line" "backup_transfer"
                fi
            fi
            
            # Buscar información adicional de rsync
            local bytes_line=$(tail -20 "$rsync_log" | grep -E "bytes/sec|MB/s|KB/s" | tail -1)
            if [[ -n "$bytes_line" && "$bytes_line" != "$progress_line" ]]; then
                log "INFO" "ESTADISTICAS: $bytes_line" "backup_transfer"
            fi
        fi
    done
    
    log "INFO" "Monitoreo de progreso finalizado" "backup_transfer"
}

# Función principal de transferencia
transfer_file() {
    local file_to_transfer="$1"
    
    log "INFO" "Iniciando transferencia de archivo: $(basename "$file_to_transfer")" "backup_transfer"
    
    # Validar que el archivo existe y no está vacío
    if [[ ! -f "$file_to_transfer" ]]; then
        log "ERROR" "El archivo no existe: $file_to_transfer" "backup_transfer"
        return $ERROR_BACKUP
    fi
    
    if [[ ! -s "$file_to_transfer" ]]; then
        log "ERROR" "El archivo está vacío: $file_to_transfer" "backup_transfer"
        return $ERROR_BACKUP
    fi
    
    local file_size=$(du -h "$file_to_transfer" | cut -f1)
    local file_size_bytes=$(stat -c%s "$file_to_transfer")
    local start_time=$(date +%s)
    
    log "INFO" "Archivo: $file_to_transfer" "backup_transfer"
    log "INFO" "Tamaño: $file_size ($file_size_bytes bytes)" "backup_transfer"
    log "INFO" "Destino: ${RSYNC_HOST}::${RSYNC_MODULE}" "backup_transfer"
    
    # Calcular timeout apropiado basado en el tamaño del archivo
    local timeout_seconds=$((file_size_bytes / 1048576 * 30))  # 30 segundos por MB
    timeout_seconds=$((timeout_seconds < 1800 ? 1800 : timeout_seconds))      # Mínimo 30 min
    timeout_seconds=$((timeout_seconds > 14400 ? 14400 : timeout_seconds))    # Máximo 4 horas
    
    log "INFO" "Timeout configurado: $((timeout_seconds/60)) minutos" "backup_transfer"
    
    # Crear archivos temporales para logs
    local rsync_log=$(mktemp)
    local rsync_pid_file=$(mktemp)
    
    # Ejecutar rsync en background con opciones optimizadas
    {
        rsync -avz \
            --progress \
            --partial \
            --partial-dir=/tmp/rsync-partial \
            --stats \
            --timeout="$timeout_seconds" \
            --compress-level=1 \
            --no-whole-file \
            --inplace \
            --human-readable \
            "$file_to_transfer" \
            "${RSYNC_USER}@${RSYNC_HOST}::${RSYNC_MODULE}" \
            --password-file="$RSYNC_PASSFILE" \
            --port="$RSYNC_PORT" 2>&1
        echo $? > "$rsync_pid_file"
    } > "$rsync_log" &
    
    local rsync_pid=$!
    echo $rsync_pid > /var/run/rsync_transfer.pid
    
    # Iniciar monitoreo en background
    monitor_rsync_progress "$rsync_log" "$file_size_bytes" &
    local monitor_pid=$!
    
    log "INFO" "Proceso rsync iniciado (PID: $rsync_pid)" "backup_transfer"
    log "INFO" "Monitor de progreso iniciado (PID: $monitor_pid)" "backup_transfer"
    
    # Esperar a que termine rsync
    wait $rsync_pid
    local rsync_exit_code=$(cat "$rsync_pid_file" 2>/dev/null || echo "1")
    
    # Detener monitor
    kill $monitor_pid 2>/dev/null || true
    wait $monitor_pid 2>/dev/null || true
    
    # Limpiar archivos PID
    rm -f /var/run/rsync_transfer.pid "$rsync_pid_file"
    
    if [[ $rsync_exit_code -eq 0 ]]; then
        local end_time=$(date +%s)
        local duration=$((end_time - start_time))
        
        # Calcular velocidad promedio
        local speed_mbps="N/A"
        if command -v bc >/dev/null 2>&1 && [[ $duration -gt 0 ]]; then
            speed_mbps=$(echo "scale=2; $file_size_bytes / 1048576 / $duration" | bc -l)
        fi
        
        log "INFO" "Transferencia completada exitosamente" "backup_transfer"
        log "INFO" "Duración: ${duration}s ($(($duration/60))m $(($duration%60))s)" "backup_transfer"
        log "INFO" "Velocidad promedio: ${speed_mbps} MB/s" "backup_transfer"
        
        # Mostrar estadísticas finales de rsync
        log "INFO" "Estadísticas finales:" "backup_transfer"
        if grep -q "Total transferred file size" "$rsync_log"; then
            grep -E "Total transferred file size|Total bytes|speedup is" "$rsync_log" | while read -r line; do
                log "INFO" "  $line" "backup_transfer"
            done
        fi
        
        # Actualizar estado si es el último backup
        if [[ -f "$LAST_BACKUP_FILE" ]]; then
            source "$LAST_BACKUP_FILE" 2>/dev/null || true
            if [[ "${LAST_BACKUP_FILE:-}" == "$file_to_transfer" ]]; then
                update_backup_status "TRANSFERRED"
                log "INFO" "Estado actualizado a TRANSFERRED" "backup_transfer"
            fi
        fi
        
        log "INFO" "Archivo transferido exitosamente: $(basename "$file_to_transfer")" "backup_transfer"
        
    else
        log "ERROR" "Falló la transferencia (código: $rsync_exit_code)" "backup_transfer"
        
        # Diagnóstico específico por código de error
        case $rsync_exit_code in
            1)   log "ERROR" "Error de sintaxis o uso" "backup_transfer" ;;
            2)   log "ERROR" "Error de protocolo" "backup_transfer" ;;
            3)   log "ERROR" "Error en selección de archivos" "backup_transfer" ;;
            4)   log "ERROR" "Acción no soportada" "backup_transfer" ;;
            5)   log "ERROR" "Error iniciando protocolo cliente-servidor" "backup_transfer" ;;
            6)   log "ERROR" "Daemon no disponible" "backup_transfer" ;;
            10)  log "ERROR" "Error de I/O en socket" "backup_transfer" ;;
            11)  log "ERROR" "Error de I/O en archivo" "backup_transfer" ;;
            12)  log "ERROR" "Error en protocolo de datos" "backup_transfer" ;;
            20)  log "ERROR" "Transferencia interrumpida por señal" "backup_transfer" ;;
            23)  log "ERROR" "Transferencia parcial - algunos archivos no se transfirieron" "backup_transfer" ;;
            30)  log "ERROR" "Timeout en I/O de datos" "backup_transfer" ;;
            35)  log "ERROR" "Timeout esperando datos" "backup_transfer" ;;
            *)   log "ERROR" "Código de error desconocido: $rsync_exit_code" "backup_transfer" ;;
        esac
        
        # Mostrar últimas líneas del log para diagnóstico
        log "ERROR" "Últimas líneas del log de rsync:" "backup_transfer"
        tail -20 "$rsync_log" | while IFS= read -r line; do
            [[ -n "$line" ]] && log "ERROR" "  $line" "backup_transfer"
        done
        
        # Verificar si hay archivos parciales
        if [[ -d "/tmp/rsync-partial" ]]; then
            local partial_files=$(find /tmp/rsync-partial -name "*.sql.gz" -type f 2>/dev/null | head -3)
            if [[ -n "$partial_files" ]]; then
                log "INFO" "Archivos parciales encontrados:" "backup_transfer"
                echo "$partial_files" | while read -r pfile; do
                    local psize=$(du -h "$pfile" 2>/dev/null | cut -f1 || echo "?")
                    log "INFO" "  $(basename "$pfile") - $psize" "backup_transfer"
                done
            fi
        fi
        
        rm -f "$rsync_log"
        return $ERROR_TRANSFER
    fi
    
    rm -f "$rsync_log"
    return 0
}

# Transferir el último backup creado
transfer_last_backup() {
    log "INFO" "Buscando último backup para transferir..." "backup_transfer"
    
    if load_backup_info; then
        if [[ -n "${LAST_BACKUP_FILE:-}" && -f "${LAST_BACKUP_FILE:-}" ]]; then
            local current_status="${LAST_BACKUP_STATUS:-UNKNOWN}"
            log "INFO" "Último backup: $(basename "$LAST_BACKUP_FILE")" "backup_transfer"
            log "INFO" "Estado actual: $current_status" "backup_transfer"
            
            if [[ "$current_status" == "TRANSFERRED" ]]; then
                log "WARN" "El último backup ya fue transferido" "backup_transfer"
                return 0
            fi
            
            transfer_file "$LAST_BACKUP_FILE"
            return $?
        else
            log "ERROR" "El archivo del último backup no existe: ${LAST_BACKUP_FILE:-}" "backup_transfer"
            return $ERROR_BACKUP
        fi
    else
        log "ERROR" "No se encontró información del último backup" "backup_transfer"
        return $ERROR_BACKUP
    fi
}

# Transferir todos los backups pendientes
transfer_all_pending() {
    log "INFO" "Buscando todos los backups pendientes de transferencia..." "backup_transfer"
    
    local backup_files=$(find "$BACKUP_DIR" -name "sigcal_backup_*.sql.gz" -type f -mtime -$RETENTION_DAYS | sort)
    
    if [[ -z "$backup_files" ]]; then
        log "INFO" "No se encontraron archivos de backup pendientes" "backup_transfer"
        return 0
    fi
    
    local total_files=$(echo "$backup_files" | wc -l)
    local current_file=0
    local failed_transfers=0
    
    log "INFO" "Se encontraron $total_files archivos de backup" "backup_transfer"
    
    echo "$backup_files" | while read -r backup_file; do
        current_file=$((current_file + 1))
        log "INFO" "Transfiriendo archivo $current_file de $total_files: $(basename "$backup_file")" "backup_transfer"
        
        if ! transfer_file "$backup_file"; then
            failed_transfers=$((failed_transfers + 1))
            log "ERROR" "Falló la transferencia de: $(basename "$backup_file")" "backup_transfer"
        fi
    done
    
    if [[ $failed_transfers -gt 0 ]]; then
        log "ERROR" "Fallaron $failed_transfers transferencias de $total_files archivos" "backup_transfer"
        return $ERROR_TRANSFER
    else
        log "INFO" "Todos los archivos ($total_files) fueron transferidos exitosamente" "backup_transfer"
        return 0
    fi
}

# ===============================================
# FUNCIÓN PRINCIPAL
# ===============================================

main() {
    local script_start=$(date +%s)
    
    log "INFO" "=== INICIANDO PROCESO DE TRANSFERENCIA ===" "backup_transfer"
    log "INFO" "Script: $(realpath "$0")" "backup_transfer"
    log "INFO" "PID: $$" "backup_transfer"
    log "INFO" "Usuario: $(whoami)" "backup_transfer"
    log "INFO" "Servidor destino: ${RSYNC_HOST}:${RSYNC_PORT}" "backup_transfer"
    
    # Verificar conectividad
    test_rsync_connection || exit $?
    
    # Procesar según los parámetros
    if [[ -n "$TRANSFER_FILE" ]]; then
        transfer_file "$TRANSFER_FILE" || exit $?
    else
        log "ERROR" "No se especificó qué transferir. Use --help para ver opciones." "backup_transfer"
        exit 1
    fi
    
    local script_end=$(date +%s)
    local total_duration=$((script_end - script_start))
    
    log "INFO" "=== TRANSFERENCIA COMPLETADA ===" "backup_transfer"
    log "INFO" "Duración total: ${total_duration}s ($(($total_duration/60))m $(($total_duration%60))s)" "backup_transfer"
    
    return 0
}

# ===============================================
# PROCESAMIENTO DE ARGUMENTOS
# ===============================================

while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            show_help
            exit 0
            ;;
        -i|--info)
            echo "Sistema de transferencia de backups"
            echo "Servidor: $RSYNC_HOST:$RSYNC_PORT"
            echo "Módulo: $RSYNC_MODULE"
            echo "Directorio local: $BACKUP_DIR"
            exit 0
            ;;
        -l|--last)
            TRANSFER_FILE="LAST"
            shift
            ;;
        -a|--all)
            TRANSFER_FILE="ALL"
            shift
            ;;
        -f|--file)
            if [[ $# -lt 2 ]]; then
                log "ERROR" "Opción --file requiere un archivo" "backup_transfer"
                exit 1
            fi
            TRANSFER_FILE="$2"
            shift 2
            ;;
        *)
            # Asumir que es un archivo si no tiene guiones
            if [[ ! "$1" =~ ^- ]]; then
                TRANSFER_FILE="$1"
                shift
            else
                log "ERROR" "Opción desconocida: $1" "backup_transfer"
                show_help
                exit 1
            fi
            ;;
    esac
done

# Ejecutar según el tipo de transferencia especificado
case "${TRANSFER_FILE:-}" in
    "LAST")
        transfer_last_backup || exit $?
        ;;
    "ALL")
        transfer_all_pending || exit $?
        ;;
    "")
        log "ERROR" "Debe especificar qué transferir (--last, --all, o --file)" "backup_transfer"
        show_help
        exit 1
        ;;
    *)
        main "$@"
        ;;
esac
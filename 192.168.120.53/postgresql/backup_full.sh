#!/bin/bash
set -euo pipefail

# ===============================================
# SCRIPT PRINCIPAL DE BACKUP POSTGRESQL
# Coordina la creación y transferencia de backups
# ===============================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config/backup_config.sh"

# Configurar trap y validaciones
setup_global_trap
validate_config || exit $?

# ===============================================
# FUNCIONES
# ===============================================

show_help() {
    cat << EOF
Uso: $0 [OPCIONES]

Ejecuta backup completo de PostgreSQL con transferencia.

OPCIONES:
  -h, --help           Mostrar esta ayuda
  -i, --info           Mostrar información del sistema
  -c, --create-only    Solo crear backup, no transferir
  -t, --transfer-only  Solo transferir último backup existente
  -f, --force         Forzar ejecución aunque otro proceso esté corriendo
  --dry-run           Simular ejecución sin hacer cambios reales

EJEMPLOS:
  $0                   # Backup completo (crear + transferir)
  $0 --create-only     # Solo crear backup
  $0 --transfer-only   # Solo transferir último backup

ARCHIVOS:
  Configuración: $SCRIPT_DIR/config/backup_config.sh
  Logs: $LOG_DIR/
  Backups: $BACKUP_DIR/

EOF
}

show_status() {
    echo "=== ESTADO DEL SISTEMA DE BACKUP ==="
    echo "Fecha/Hora: $(date)"
    echo "Usuario: $(whoami)"
    echo "Hostname: $(hostname)"
    echo ""
    
    echo "CONFIGURACIÓN:"
    echo "  Base de datos: $DATABASE_NAME"
    echo "  Directorio backup: $BACKUP_DIR"
    echo "  Servidor rsync: $RSYNC_HOST:$RSYNC_PORT"
    echo "  Retención: $RETENTION_DAYS días"
    echo ""
    
    echo "PROCESOS ACTIVOS:"
    local create_running=""
    local transfer_running=""
    
    if [[ -f "$PIDFILE_CREATE" ]] && kill -0 $(cat "$PIDFILE_CREATE" 2>/dev/null) 2>/dev/null; then
        create_running="SÍ (PID: $(cat "$PIDFILE_CREATE"))"
    else
        create_running="NO"
    fi
    
    if [[ -f "$PIDFILE_TRANSFER" ]] && kill -0 $(cat "$PIDFILE_TRANSFER" 2>/dev/null) 2>/dev/null; then
        transfer_running="SÍ (PID: $(cat "$PIDFILE_TRANSFER"))"
    else
        transfer_running="NO"
    fi
    
    echo "  Creación de backup: $create_running"
    echo "  Transferencia: $transfer_running"
    echo ""
    
    echo "ÚLTIMO BACKUP:"
    if [[ -f "$LAST_BACKUP_FILE" ]]; then
        source "$LAST_BACKUP_FILE"
        echo "  Archivo: $(basename "${LAST_BACKUP_FILE:-N/A}")"
        echo "  Fecha: ${LAST_BACKUP_DATE:-N/A}"
        echo "  Tamaño: ${LAST_BACKUP_SIZE:-N/A}"
        echo "  Duración: ${LAST_BACKUP_DURATION:-N/A}s"
        echo "  Estado: ${LAST_BACKUP_STATUS:-UNKNOWN}"
    else
        echo "  No hay información disponible"
    fi
    echo ""
    
    echo "BACKUPS RECIENTES:"
    if [[ -d "$BACKUP_DIR" ]]; then
        find "$BACKUP_DIR" -name "sigcal_backup_*.sql.gz" -type f -mtime -7 -exec ls -lh {} \; | head -5 | while read -r line; do
            echo "  $line"
        done
    fi
    echo ""
    
    echo "ESPACIO EN DISCO:"
    df -h "$BACKUP_DIR" | tail -1 | awk '{print "  Disponible: " $4 " (" $5 " usado)"}'
}

run_dry_run() {
    echo "=== SIMULACIÓN DE BACKUP (DRY RUN) ==="
    echo "Fecha: $(date)"
    echo ""
    
    echo "1. VALIDACIONES:"
    echo "   ✓ Verificar herramientas necesarias"
    echo "   ✓ Verificar espacio en disco"
    echo "   ✓ Verificar conectividad PostgreSQL"
    echo "   ✓ Verificar conectividad servidor rsync"
    echo ""
    
    echo "2. CREACIÓN DE BACKUP:"
    local filename="sigcal_backup_$(date +"%Y%m%d-%H%M%S").sql.gz"
    echo "   → Archivo: $BACKUP_DIR/$filename"
    echo "   → Comando: pg_dump [...] | gzip -9"
    echo "   → Estimado: ~15-20 minutos para base grande"
    echo ""
    
    echo "3. TRANSFERENCIA:"
    echo "   → Destino: $RSYNC_HOST::$RSYNC_MODULE"
    echo "   → Comando: rsync -avz --progress [...]"
    echo "   → Estimado: Depende del tamaño y conexión"
    echo ""
    
    echo "4. LIMPIEZA:"
    echo "   → Eliminar backups > $RETENTION_DAYS días"
    echo "   → Rotar logs si son muy grandes"
    echo ""
    
    echo "NOTA: Esta fue una simulación. Use sin --dry-run para ejecutar."
}

# ===============================================
# FUNCIÓN PRINCIPAL
# ===============================================

main() {
    local script_start=$(date +%s)
    local create_only=false
    local transfer_only=false
    local force_run=false
    local dry_run=false
    
    # Procesar argumentos
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                show_help
                exit 0
                ;;
            -i|--info)
                show_status
                exit 0
                ;;
            -c|--create-only)
                create_only=true
                shift
                ;;
            -t|--transfer-only)
                transfer_only=true
                shift
                ;;
            -f|--force)
                force_run=true
                shift
                ;;
            --dry-run)
                dry_run=true
                shift
                ;;
            *)
                log "ERROR" "Opción desconocida: $1" "backup_full"
                show_help
                exit 1
                ;;
        esac
    done
    
    # Ejecutar dry run si se solicitó
    if [[ "$dry_run" = true ]]; then
        run_dry_run
        exit 0
    fi
    
    log "INFO" "=== INICIANDO BACKUP COMPLETO ===" "backup_full"
    log "INFO" "Script: $(realpath "$0")" "backup_full"
    log "INFO" "PID: $$" "backup_full"
    log "INFO" "Modo: $(if [[ "$create_only" = true ]]; then echo "Solo creación"; elif [[ "$transfer_only" = true ]]; then echo "Solo transferencia"; else echo "Completo"; fi)" "backup_full"
    
    # Verificar si otros procesos están corriendo (a menos que se fuerce)
    if [[ "$force_run" != true ]]; then
        local running_processes=()
        
        if [[ -f "$PIDFILE_CREATE" ]] && kill -0 $(cat "$PIDFILE_CREATE" 2>/dev/null) 2>/dev/null; then
            running_processes+=("creación de backup (PID: $(cat "$PIDFILE_CREATE"))")
        fi
        
        if [[ -f "$PIDFILE_TRANSFER" ]] && kill -0 $(cat "$PIDFILE_TRANSFER" 2>/dev/null) 2>/dev/null; then
            running_processes+=("transferencia (PID: $(cat "$PIDFILE_TRANSFER"))")
        fi
        
        if [[ ${#running_processes[@]} -gt 0 ]]; then
            log "ERROR" "Ya hay procesos de backup ejecutándose:" "backup_full"
            for proc in "${running_processes[@]}"; do
                log "ERROR" "  - $proc" "backup_full"
            done
            log "ERROR" "Use --force para ejecutar de todos modos o --info para ver estado" "backup_full"
            exit $ERROR_ALREADY_RUNNING
        fi
    fi
    
    # Ejecutar según el modo seleccionado
    if [[ "$transfer_only" = true ]]; then
        log "INFO" "Ejecutando solo transferencia..." "backup_full"
        if ! "$SCRIPT_DIR/backup_transfer.sh" --last; then
            log "ERROR" "Falló la transferencia" "backup_full"
            exit $ERROR_TRANSFER
        fi
        
    elif [[ "$create_only" = true ]]; then
        log "INFO" "Ejecutando solo creación de backup..." "backup_full"
        if ! "$SCRIPT_DIR/backup_create.sh"; then
            log "ERROR" "Falló la creación del backup" "backup_full"
            exit $ERROR_BACKUP
        fi
        
    else
        # Backup completo: crear + transferir
        log "INFO" "Ejecutando backup completo (crear + transferir)..." "backup_full"
        
        # Paso 1: Crear backup
        log "INFO" "FASE 1: Creando backup..." "backup_full"
        if ! "$SCRIPT_DIR/backup_create.sh"; then
            log "ERROR" "Falló la creación del backup" "backup_full"
            exit $ERROR_BACKUP
        fi
        
        log "INFO" "FASE 1 COMPLETADA: Backup creado exitosamente" "backup_full"
        
        # Espera breve para que se escriba la información del backup
        sleep 2
        
        # Paso 2: Transferir backup
        log "INFO" "FASE 2: Transfiriendo backup..." "backup_full"
        if ! "$SCRIPT_DIR/backup_transfer.sh" --last; then
            log "ERROR" "Falló la transferencia del backup" "backup_full"
            log "WARN" "El backup fue creado pero no transferido" "backup_full"
            log "INFO" "Puede ejecutar: ./backup_transfer.sh --last para reintentarlo" "backup_full"
            exit $ERROR_TRANSFER
        fi
        
        log "INFO" "FASE 2 COMPLETADA: Backup transferido exitosamente" "backup_full"
    fi
    
    local script_end=$(date +%s)
    local total_duration=$((script_end - script_start))
    
    log "INFO" "=== PROCESO COMPLETADO EXITOSAMENTE ===" "backup_full"
    log "INFO" "Duración total: ${total_duration}s ($(($total_duration/60))m $(($total_duration%60))s)" "backup_full"
    
    # Mostrar resumen final
    if [[ "$create_only" != true && "$transfer_only" != true ]]; then
        if [[ -f "$LAST_BACKUP_FILE" ]]; then
            source "$LAST_BACKUP_FILE"
            log "INFO" "RESUMEN:" "backup_full"
            log "INFO" "  Archivo: $(basename "${LAST_BACKUP_FILE:-}")" "backup_full"
            log "INFO" "  Tamaño: ${LAST_BACKUP_SIZE:-}" "backup_full"
            log "INFO" "  Estado: ${LAST_BACKUP_STATUS:-}" "backup_full"
        fi
    fi
    
    return 0
}

# Ejecutar función principal
main "$@"
#!/bin/bash
set -euo pipefail

# ===============================================
# SCRIPT DE CREACIÓN DE BACKUP POSTGRESQL
# Solo se encarga de crear el backup, no de transferirlo
# ===============================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config/backup_config.sh"

# Configurar trap y validaciones
setup_global_trap
validate_config || exit $?

# Verificar que no se esté ejecutando otro proceso de backup
check_process_lock "$PIDFILE_CREATE" "Proceso de creación de backup" || exit $?
trap "cleanup_lock '$PIDFILE_CREATE'" EXIT

# Verificar herramientas necesarias
check_required_tools pg_dump psql gzip || exit $?

# Variables específicas para este script
DATE=$(date +"%Y%m%d-%H%M%S")
FILENAME="sigcal_backup_${DATE}.sql.gz"
FULLPATH="${BACKUP_DIR}/${FILENAME}"

# ===============================================
# FUNCIONES ESPECÍFICAS
# ===============================================

# Verificar conexión a PostgreSQL
test_postgresql_connection() {
    log "INFO" "Verificando conectividad a PostgreSQL..." "backup_create"
    
    export PGPASSWORD="$PG_PASS"
    
    if ! timeout 10 psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$DATABASE_NAME" -c "SELECT version();" >/dev/null 2>&1; then
        log "ERROR" "No se puede conectar a PostgreSQL" "backup_create"
        log "ERROR" "Host: $PG_HOST, Puerto: $PG_PORT, Usuario: $PG_USER, Base: $DATABASE_NAME" "backup_create"
        
        # Intentar diagnóstico más detallado
        if ! nc -z -w 5 "$PG_HOST" "$PG_PORT" 2>/dev/null; then
            log "ERROR" "Puerto PostgreSQL ($PG_PORT) no responde en $PG_HOST" "backup_create"
        fi
        
        unset PGPASSWORD
        return $ERROR_CONNECTION
    fi
    
    unset PGPASSWORD
    log "INFO" "Conectividad verificada correctamente" "backup_create"
    return 0
}

# Verificar espacio disponible
check_disk_space() {
    log "INFO" "Verificando espacio en disco..." "backup_create"
    
    local available_space=$(df "$BACKUP_DIR" | awk 'NR==2 {print $4}')
    
    if [[ $available_space -lt $MIN_DISK_SPACE ]]; then
        log "ERROR" "Espacio insuficiente en $BACKUP_DIR" "backup_create"
        log "ERROR" "Disponible: ${available_space}KB, Requerido: ${MIN_DISK_SPACE}KB" "backup_create"
        return $ERROR_PREREQ
    fi
    
    log "INFO" "Espacio disponible: $(($available_space/1024/1024))GB" "backup_create"
    return 0
}

# Obtener información de la base de datos antes del backup
get_database_info() {
    log "INFO" "Obteniendo información de la base de datos..." "backup_create"
    
    export PGPASSWORD="$PG_PASS"
    
    # Tamaño de la base de datos
    local db_size=$(psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$DATABASE_NAME" \
        -t -c "SELECT pg_size_pretty(pg_database_size('$DATABASE_NAME'));" 2>/dev/null | xargs)
    
    # Número de tablas
    local table_count=$(psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$DATABASE_NAME" \
        -t -c "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = 'public';" 2>/dev/null | xargs)
    
    # Versión de PostgreSQL
    local pg_version=$(psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$DATABASE_NAME" \
        -t -c "SELECT version();" 2>/dev/null | head -1)
    
    unset PGPASSWORD
    
    log "INFO" "Tamaño de la base de datos: $db_size" "backup_create"
    log "INFO" "Número de tablas: $table_count" "backup_create"
    log "INFO" "Versión PostgreSQL: $pg_version" "backup_create"
}

# Crear backup de PostgreSQL
create_backup() {
    log "INFO" "Iniciando creación de backup de PostgreSQL - Base de datos: $DATABASE_NAME" "backup_create"
    
    # Crear archivo temporal para capturar salida de pg_dump
    local pg_dump_log=$(mktemp)
    local start_time=$(date +%s)
    
    # Configurar variable de entorno para la contraseña
    export PGPASSWORD="$PG_PASS"
    
    log "INFO" "Archivo de backup: $FULLPATH" "backup_create"
    log "INFO" "Proceso iniciado a las $(date)" "backup_create"
    
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
        local file_size_bytes=$(stat -c%s "$FULLPATH")
        
        log "INFO" "Backup completado exitosamente" "backup_create"
        log "INFO" "Archivo: $FULLPATH" "backup_create"
        log "INFO" "Tamaño: $file_size ($file_size_bytes bytes)" "backup_create"
        log "INFO" "Duración: ${duration}s ($(($duration/60)) min $(($duration%60)) seg)" "backup_create"
        
        # Verificar integridad básica del backup
        if ! gzip -t "$FULLPATH" 2>/dev/null; then
            log "ERROR" "El archivo de backup está corrupto (fallo en verificación gzip)" "backup_create"
            rm -f "$FULLPATH"
            return $ERROR_BACKUP
        fi
        
        # Verificación adicional del contenido
        local lines_count=$(gzip -dc "$FULLPATH" | wc -l)
        log "INFO" "Líneas en el backup: $lines_count" "backup_create"
        
        if [[ $lines_count -lt 10 ]]; then
            log "ERROR" "El backup parece estar vacío o corrupto (muy pocas líneas)" "backup_create"
            return $ERROR_BACKUP
        fi
        
        # Guardar información del backup para usar en transferencia
        save_backup_info "$FULLPATH" "$file_size" "$duration"
        
    else
        local pg_dump_exit_code=$?
        log "ERROR" "Falló la generación del backup de PostgreSQL (código: $pg_dump_exit_code)" "backup_create"
        
        # Log salida detallada del error
        log "ERROR" "Salida de pg_dump:" "backup_create"
        while IFS= read -r line; do
            [[ -n "$line" ]] && log "ERROR" "PG_DUMP: $line" "backup_create"
        done < "$pg_dump_log"
        
        rm -f "$pg_dump_log" "$FULLPATH"
        return $ERROR_BACKUP
    fi
    
    rm -f "$pg_dump_log"
    unset PGPASSWORD
    
    # Verificación final del archivo
    if [[ ! -s "$FULLPATH" ]]; then
        log "ERROR" "El archivo de backup está vacío" "backup_create"
        return $ERROR_BACKUP
    fi
    
    return 0
}

# Limpiar backups antiguos
cleanup_old_backups() {
    log "INFO" "Ejecutando limpieza de backups antiguos..." "backup_create"
    
    # Listar archivos que serán eliminados
    local files_to_delete=$(find "$BACKUP_DIR" -name "sigcal_backup_*.sql.gz" -mtime +$RETENTION_DAYS -type f)
    
    if [[ -n "$files_to_delete" ]]; then
        log "INFO" "Archivos a eliminar (más de $RETENTION_DAYS días):" "backup_create"
        echo "$files_to_delete" | while read -r file; do
            if [[ -f "$file" ]]; then
                local file_age=$(stat -c %y "$file" | cut -d' ' -f1)
                local file_size=$(du -h "$file" | cut -f1)
                log "INFO" "  - $(basename "$file") ($file_size, $file_age)" "backup_create"
            fi
        done
        
        # Eliminar archivos antiguos
        find "$BACKUP_DIR" -name "sigcal_backup_*.sql.gz" -mtime +$RETENTION_DAYS -type f -delete
        log "INFO" "Limpieza completada" "backup_create"
    else
        log "INFO" "No hay archivos antiguos para eliminar" "backup_create"
    fi
    
    # Mostrar archivos actuales
    log "INFO" "Archivos de backup actuales:" "backup_create"
    find "$BACKUP_DIR" -name "sigcal_backup_*.sql.gz" -type f -exec ls -lh {} \; | while read -r line; do
        log "INFO" "  $line" "backup_create"
    done
}

# ===============================================
# FUNCIÓN PRINCIPAL
# ===============================================

main() {
    local script_start=$(date +%s)
    
    log "INFO" "=== INICIANDO PROCESO DE CREACIÓN DE BACKUP ===" "backup_create"
    log "INFO" "Script: $(realpath "$0")" "backup_create"
    log "INFO" "PID: $$" "backup_create"
    log "INFO" "Usuario: $(whoami)" "backup_create"
    log "INFO" "Hostname: $(hostname)" "backup_create"
    log "INFO" "Archivo objetivo: $FILENAME" "backup_create"
    
    # Ejecutar validaciones y operaciones
    check_disk_space || exit $?
    test_postgresql_connection || exit $?
    get_database_info
    create_backup || exit $?
    cleanup_old_backups
    
    local script_end=$(date +%s)
    local total_duration=$((script_end - script_start))
    
    log "INFO" "=== CREACIÓN DE BACKUP COMPLETADA EXITOSAMENTE ===" "backup_create"
    log "INFO" "Duración total: ${total_duration}s ($(($total_duration/60)) min $(($total_duration%60)) seg)" "backup_create"
    log "INFO" "Archivo creado: $FULLPATH" "backup_create"
    log "INFO" "Siguiente paso: Ejecutar backup_transfer.sh para enviar el archivo" "backup_create"
    
    return 0
}

# ===============================================
# EJECUCIÓN
# ===============================================

# Verificar parámetros de línea de comandos
case "${1:-}" in
    --help|-h)
        echo "Uso: $0 [--help]"
        echo ""
        echo "Este script crea un backup de PostgreSQL sin transferirlo."
        echo "Después de la ejecución exitosa, usar backup_transfer.sh para enviarlo."
        echo ""
        echo "Configuración en: config/backup_config.sh"
        echo "Logs en: $LOG_DIR"
        exit 0
        ;;
    --info|-i)
        echo "Información del sistema de backup:"
        echo "Base de datos: $DATABASE_NAME"
        echo "Directorio de backup: $BACKUP_DIR"
        echo "Retención: $RETENTION_DAYS días"
        echo "Servidor rsync: $RSYNC_HOST:$RSYNC_PORT"
        exit 0
        ;;
esac

# Ejecutar función principal
main "$@"
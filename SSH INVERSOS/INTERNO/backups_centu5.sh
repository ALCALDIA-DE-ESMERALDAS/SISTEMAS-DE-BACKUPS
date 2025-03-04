#!/bin/bash
###########################################################
## Script para realizar backup de Oracle ##
## FXGS                                                 ##
###########################################################

# Cargar configuración
CONFIG_FILE="/home/sis_backups_auto/config.sh"
if [ ! -f "$CONFIG_FILE" ]; then
    echo "Error: Archivo de configuración no encontrado en $CONFIG_FILE"
    echo "Advertencia: Archivo de configuración no encontrado, usando valores por defecto."
    # Variables de entorno Oracle
    ORACLE_SID="bdesme"
    ORACLE_HOME="/u01/app/oracle/product/10.2.0/db_1"

    # Configuración de backup
    BACKUP_DIR="/backups/oracle/freenas"   # Directorio local para backups
    ORACLE_USER="sisesmer"             # Usuario de Oracle
    ORACLE_PASSWORD="294A315LS1S"         # Contraseña de Oracle
    REQUIRED_SPACE=10                  # Espacio mínimo requerido en GB
    BACKUP_RETENTION_DAYS=7            # Días a mantener los backups

    # Configuración de logs
    LOG_DIR="${BACKUP_DIR}"            # Directorio para logs
    DATE_FORMAT="%Y%m%d-%H%M%S"        # Formato de fecha para archivos
fi
echo "Config file: $CONFIG_FILE"
source "$CONFIG_FILE"
echo "Congiugration variables:"
echo "ORACLE_SID: $ORACLE_SID"
echo "ORACLE_HOME: $ORACLE_HOME"
echo "BACKUP_DIR: $BACKUP_DIR"
echo "ORACLE_USER: $ORACLE_USER"
echo "ORACLE_PASSWORD: $ORACLE_PASSWORD"
echo "REQUIRED_SPACE: $REQUIRED_SPACE"
echo "BACKUP_RETENTION_DAYS: $BACKUP_RETENTION_DAYS"
echo "LOG_DIR: $LOG_DIR"
echo "DATE_FORMAT: $DATE_FORMAT"

# Variables de entorno
export ORACLE_SID
export ORACLE_HOME
export PATH=$PATH:$ORACLE_HOME/bin

# Variables dinámicas
DATE=$(date +"$DATE_FORMAT")
BACKUP_NAME="${1:-exp${ORACLE_USER}_${DATE}}"  # Usar argumento o nombre por defecto
BACKUP_FILE="${BACKUP_NAME}.gz"
LOG_FILE="${LOG_DIR}/backup_${DATE}.log"

# Crear carpetas necesarias
mkdir -p "${BACKUP_DIR}"
touch "${LOG_FILE}"

# Función de log
log() {
    echo "$(date +'%Y-%m-%d %H:%M:%S') - $1" | tee -a "${LOG_FILE}"
}

# Verificar dependencias
check_dependencies() {
    log "Verificando dependencias..."
    local DEPS=("exp" "gzip" "scp" "ssh" "rsync")

    for cmd in "${DEPS[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then
            log "Error: $cmd no está instalado."
            case $cmd in
                exp) 
                    log "Instalar manualmente el cliente de Oracle."
                    exit 1
                    ;;
                gzip) 
                    sudo apt-get update && sudo apt-get install -y gzip || sudo yum install -y gzip
                    ;;
                scp|ssh) 
                    sudo apt-get update && sudo apt-get install -y openssh-client || sudo yum install -y openssh-clients
                    ;;
            esac
        fi
    done
    log "Todas las dependencias están presentes."
}

# Función para verificar espacio disponible en el servidor local
check_local_space() {
    log "Verificando espacio disponible en el servidor local..."
    local available_space=$(df -P "${BACKUP_DIR}" | tail -1 | awk '{print $4}')
    local available_gb=$((available_space / 1024 / 1024))
    
    log "Espacio disponible: ${available_gb} GB"
    if (( available_gb < REQUIRED_SPACE )); then
        log "Error: Espacio insuficiente. Se requieren ${REQUIRED_SPACE} GB."
        exit 1
    fi
}

# Función para verificar si ya existe un backup válido del día actual
check_today_backup() {
    # En RHEL 5.3 el comando date tiene algunas limitaciones
    local today=$(date +"%Y%m%d")
    log "Verificando si existe un backup válido para el día $today..."
    
    # find en RHEL 5.3 puede no soportar -print -quit, usamos head
    local today_backup=$(find "${BACKUP_DIR}" -type f -name "*${today}*.gz" | head -1)
    
    if [ -n "$today_backup" ]; then
        # Verificar que el backup encontrado es válido
        if gzip -t "$today_backup" 2>/dev/null; then
            local backup_size=$(du -h "$today_backup" | cut -f1)
            log "Se encontró un backup válido del día actual: $today_backup"
            log "Tamaño del backup: $backup_size"
            return 0
        else
            log "Se encontró un backup del día actual pero está corrupto: $today_backup"
            log "Se procederá a generar un nuevo backup"
            rm -f "$today_backup"
            return 1
        fi
    fi
    
    log "No se encontró ningún backup del día actual"
    return 1
}

# Función para generar el backup de Oracle
generate_backup() {
    local start_time=$(date +%s)
    log "Iniciando generación del backup para Oracle y compresión directa... ${BACKUP_NAME}"

    exp "${ORACLE_USER}/${ORACLE_PASSWORD}" file="/dev/stdout" grants=n full=y | gzip -8 > "${BACKUP_DIR}/${BACKUP_NAME}.gz"

    if [ $? -ne 0 ]; then
        log "Error: Falló la generación o compresión del backup."
        exit 1
    fi

    if [ ! -s "${BACKUP_DIR}/${BACKUP_NAME}.gz" ]; then
        log "Error: El archivo de backup está vacío o no se generó correctamente."
        exit 1
    fi

    local end_time=$(date +%s)
    local elapsed_time=$((end_time - start_time))
    # Tamaño del archivo
    local backup_size=$(du -h "${BACKUP_DIR}/${BACKUP_NAME}.gz" | cut -f1)

    log "Backup completado: ${BACKUP_FILE}"
    log "Tamaño: ${backup_size}"
    log "Tiempo: $((elapsed/60)) minutos y $((elapsed%60)) segundos"
}

# Función para verificar si el nuevo backup se generó correctamente
verify_new_backup() {
    local backup_path="${BACKUP_DIR}/${BACKUP_FILE}"
    
    if [ ! -f "$backup_path" ]; then
        log "Error: No se encuentra el nuevo backup en: $backup_path"
        return 1
    fi
    
    if [ ! -s "$backup_path" ]; then
        log "Error: El nuevo backup está vacío"
        return 1
    fi
    
    # Verificar que el archivo se puede leer
    if ! gzip -t "$backup_path" 2>/dev/null; then
        log "Error: El archivo de backup está corrupto o no es un archivo gzip válido"
        return 1
    fi
    
    log "Verificación del nuevo backup exitosa"
    return 0
}

# Función para limpiar todos los backups excepto el nuevo
clean_backups() {
    local new_backup="${BACKUP_DIR}/${BACKUP_FILE}"
    
    # Primero verificar que el nuevo backup existe y es válido
    if ! verify_new_backup; then
        log "No se realizará la limpieza porque el nuevo backup no es válido"
        return 1
    fi
    
    log "Limpiando backups antiguos..."
    
    # En RHEL 5.3 necesitamos manejar los espacios en nombres de archivo de manera más cuidadosa
    find "${BACKUP_DIR}" -type f -name "*.gz" | while read -r backup; do
        if [ "$(readlink -f "$backup")" != "$(readlink -f "$new_backup")" ]; then
            log "Eliminando backup: $backup"
            rm -f "$backup"
        fi
    done
    
    log "Limpieza completada. Se mantiene solo el backup actual"
    return 0
}

# Función para enviar el backup por rsync
send_backup_rsync() {
    log "Iniciando transferencia del backup por rsync..."
    local backup_path="${BACKUP_DIR}/${BACKUP_FILE}"

    # Verificar que el archivo existe
    if [ ! -f "$backup_path" ]; then
        log "Error: No se encuentra el archivo de backup: $backup_path"
        return 1
    fi

    # Configuración de rsync
    local RSYNC_HOST="159.223.186.132"
    local RSYNC_USER="usuario"
    local RSYNC_MODULE="backup"
    local RSYNC_PASSWORD_FILE="/home/sis_backups_auto/password"
    local RSYNC_PORT="9000"

    # Verificar archivo de contraseña
    if [ ! -f "$RSYNC_PASSWORD_FILE" ]; then
        log "Error: No se encuentra el archivo de contraseña para rsync"
        return 1
    fi

    # Verificar permisos del archivo de contraseña
    local password_file_permissions
    password_file_permissions=$(stat -c %a "$RSYNC_PASSWORD_FILE")
    if [ "$password_file_permissions" != "600" ]; then
        log "Corrigiendo permisos del archivo de contraseña a 600..."
        chmod 600 "$RSYNC_PASSWORD_FILE"
        if [ $? -ne 0 ]; then
            log "Error al intentar cambiar los permisos del archivo de contraseña"
            return 1
        fi
    fi

    # Construir el comando rsync (sin mostrar la contraseña)
    local RSYNC_CMD="rsync -avz --progress --stats --partial --partial-dir=/tmp/rsync-partial '${backup_path}' '${RSYNC_USER}@${RSYNC_HOST}::${RSYNC_MODULE}' --password-file='${RSYNC_PASSWORD_FILE}' --port='${RSYNC_PORT}'"
    
    # Loggear el comando (útil para debug)
    log "Comando a ejecutar: $RSYNC_CMD"
    
    # Crear un archivo temporal para capturar la salida de rsync
    local RSYNC_LOG_TMP=$(mktemp)
    
    # Ejecutar rsync y capturar tanto stdout como stderr
    rsync -avz --progress --stats \
        --partial \
        --partial-dir=/tmp/rsync-partial \
        "$backup_path" \
        "${RSYNC_USER}@${RSYNC_HOST}::${RSYNC_MODULE}" \
        --password-file="$RSYNC_PASSWORD_FILE" \
        --port="$RSYNC_PORT" \
        2>&1 | tee "$RSYNC_LOG_TMP"
    
    # Capturar el código de salida de rsync
    local RSYNC_EXIT_CODE=${PIPESTATUS[0]}
    
    # Registrar los detalles importantes del log de rsync
    log "=== Detalles de la transferencia rsync ==="
    log "Bytes transferidos: $(grep "bytes transferred" "$RSYNC_LOG_TMP" | tail -n 1)"
    log "Velocidad de transferencia: $(grep "bytes/sec" "$RSYNC_LOG_TMP" | tail -n 1)"
    
    # Si hay error, mostrar el comando de nuevo para fácil copia/pega
    if [ $RSYNC_EXIT_CODE -ne 0 ]; then
        log "ERROR: La transferencia falló con código $RSYNC_EXIT_CODE"
        log "Para reintentar manualmente, puedes usar el siguiente comando:"
        log "----------------------------------------------------------------"
        log "$RSYNC_CMD"
        log "----------------------------------------------------------------"
        # También mostrar las últimas líneas del log que podrían contener el error
        log "Últimas líneas del log de error:"
        tail -n 5 "$RSYNC_LOG_TMP" | while IFS= read -r line; do
            log "$line"
        done
    else
        log "Transferencia completada exitosamente"
    fi
    
    # Limpiar el archivo temporal
    rm -f "$RSYNC_LOG_TMP"

    return $RSYNC_EXIT_CODE
}

# Ejecución principal
main() {
    local start_time=$(date +%s)
    log "=== Iniciando proceso de backup ==="

     # Verificar si ya existe un backup válido del día
    if check_today_backup; then
        log "Ya existe un backup válido del día actual. No es necesario generar uno nuevo."
        exit 0
    fi    

    check_dependencies
    check_local_space
    generate_backup

    # Solo limpiar si el nuevo backup se generó correctamente
    if ! clean_backups; then
        log "ADVERTENCIA: No se eliminaron los backups anteriores debido a errores en el nuevo backup"
        exit 1
    fi

    # Añadir el envío por rsync
    log "=== Iniciando envío del backup ==="
    send_backup_rsync
    if [ $? -ne 0 ]; then
        log "Error: Falló el envío del backup"
        exit 1
    fi
    
    local end_time=$(date +%s)
    local total_time=$((end_time - start_time))
    log "=== Proceso completado: $((total_time/60)) minutos y $((total_time%60)) segundos ==="
}

# Ejecutar script
main
exit 0

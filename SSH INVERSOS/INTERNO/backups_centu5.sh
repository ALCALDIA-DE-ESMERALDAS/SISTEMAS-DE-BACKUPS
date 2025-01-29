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
    BACKUP_DIR="/backups/oracle/temp"   # Directorio local para backups
    ORACLE_USER="sisesmer"             # Usuario de Oracle
    ORACLE_PASSWORD="sisesmer"         # Contraseña de Oracle
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

# Limpieza de backups antiguos (opcional)
clean_old_backups() {
    log "Iniciando limpieza de backups antiguos..."

    # Buscar archivos .gz en el directorio de backups y ordenarlos por fecha de modificación (más antiguos primero)
    local files_to_delete=$(find "${BACKUP_DIR}" -type f -name "*.gz" -printf "%T@ %p\n" | sort -n | head -n -1 | cut -d' ' -f2-)

    # Verificar si hay archivos adicionales para eliminar
    if [ -n "$files_to_delete" ]; then
        log "Archivos que serán eliminados:"
        echo "$files_to_delete" | while read -r file; do
            log "Eliminando: $file"
            rm -f "$file"
        done
        log "Limpieza completada: solo se conservan los 2 backups más recientes."
    else
        log "No hay backups adicionales para eliminar. Todo está en orden."
    fi
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

    log "Iniciando transferencia del archivo: $backup_path"

    # Ejecutar rsync
    rsync -avz --progress --stats \
        --partial \
        --partial-dir=/tmp/rsync-partial \
        "$backup_path" \
        "${RSYNC_USER}@${RSYNC_HOST}::${RSYNC_MODULE}" \
        --password-file="$RSYNC_PASSWORD_FILE" \
        --port="$RSYNC_PORT"

    # Verificar el resultado de rsync
    if [ $? -eq 0 ]; then
        log "Transferencia completada exitosamente"
        return 0
    else
        log "Error en la transferencia del backup"
        return 1
    fi
}


# Ejecución principal
main() {
    local start_time=$(date +%s)
    log "=== Iniciando proceso de backup ==="
    
    check_dependencies
    clean_old_backups
    check_local_space
    generate_backup

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

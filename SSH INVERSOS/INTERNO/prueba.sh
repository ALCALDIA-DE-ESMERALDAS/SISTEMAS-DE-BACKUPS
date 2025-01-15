#!/bin/bash
###########################################################
## Script para realizar backup de Oracle ##
## FXGS                                                 ##
###########################################################

# Cargar configuración
CONFIG_FILE="config.sh"
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

# Ejecución principal
main() {
    local start_time=$(date +%s)
    log "=== Iniciando proceso de backup ==="
        
    local end_time=$(date +%s)
    local total_time=$((end_time - start_time))
    log "=== Proceso completado: $((total_time/60)) minutos y $((total_time%60)) segundos ==="
}

# Ejecutar script
main
exit 0

#!/bin/bash
###########################################################
## Script para realizar transferencia de backup de Oracle ##
## FXGS                                                 ##
###########################################################

# Ruta del directorio donde se encuentra el script
SCRIPT_DIR=$(dirname "$(realpath "$0")")

# Variables del backup
BACKUP_DIR="/backups/oracle/temp"               # Directorio local para backups
LOCAL_USER="root"                               # Usuario local
LOCAL_PASSWORD="admin.prueba/2015*"                  # Contraseña local
LOCAL_HOST="192.168.120.13"                          # IP del servidor local
SH_DIR="/home/sis_backups_auto/backups_centu5.sh"                                       # Directorio de scripts


REMOTE_USER="root"                               # Usuario remoto
REMOTE_PASSWORD="alcaldiA2025P"                  # Contraseña para ssh
REMOTE_HOST="159.223.186.132"                    # IP del servidor remoto
REMOTE_PATH="/var/backups/back_cabildo"          # Ruta remota
TIMEOUT="-1"                                     # Tiempo de espera para el comando SCP

DATE=$(date +'%Y%m%d-%H%M%S')                     # Fecha actual para nombres únicos
BACKUP_NAME="expsisesmer_${DATE}.dmp"            # Nombre del archivo de backup
BACKUP_FILE="${BACKUP_NAME}.gz"                  # Nombre del archivo comprimido
LOG_FILE="${BACKUP_DIR}/backup_${DATE}.log"      # Archivo de log

# Crear carpetas necesarias
mkdir -p "${BACKUP_DIR}"
touch "${LOG_FILE}"

# Función para registrar mensajes en el log
log() {
    local message="$1"
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $message" | tee -a "${LOG_FILE}"
}

# Verificar dependencias
check_dependencies() {
    log "Verificando dependencias..."
    
    # Lista de dependencias requeridas
    DEPS=(
        "scp:openssh-client"
        "sshpass:sshpass"
        "expect:expect"
        "msmtp:msmtp"
        "msmtp-mta:msmtp-mta"
        "awk:gawk"
        "df:coreutils"
        "spawn:spawn"
    )

    # Detectar el sistema operativo
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
    else
        OS=$(uname -s)
    fi

    # Instalar dependencias según el SO
    for dep in "${DEPS[@]}"; do
        CMD="${dep%%:*}"
        PKG="${dep##*:}"
        
        if ! command -v "$CMD" &>/dev/null; then
            log "Falta $CMD. Instalando $PKG..."
            case $OS in
                "ubuntu"|"debian")
                    sudo apt-get update && sudo apt-get install -y "$PKG"
                    ;;
                "centos"|"rhel"|"fedora")
                    sudo yum install -y "$PKG"
                    ;;
                *)
                    log "Sistema operativo no soportado: $OS"
                    exit 1
                    ;;
            esac
        fi
    done
    
    log "Todas las dependencias están instaladas."
}

# Función para generar el backup de Oracle
generate_backup() {
    log "Iniciando el proceso de backup en el servidor local... ${BACKUP_NAME}"
    
    # Construir el comando completo
    
    local comando="sshpass -p \"${LOCAL_PASSWORD}\" ssh -o KexAlgorithms=+diffie-hellman-group1-sha1 -o HostKeyAlgorithms=+ssh-rsa -p 2222 root@localhost \"bash ${SH_DIR} ${BACKUP_NAME}\""
   
    log "Ejecutando: ${comando}"
    eval sshpass -p \"${LOCAL_PASSWORD}\" ssh -o KexAlgorithms=+diffie-hellman-group1-sha1 -o HostKeyAlgorithms=+ssh-rsa -p 2222 root@localhost \"bash ${SH_DIR} ${BACKUP_NAME}\"
    
    if [ $? -ne 0 ]; then
        log "Error: Falló la ejecución del script de backup en el servidor local."
        exit 1
    fi
    log "Backup generado correctamente en el servidor local."
}


# Función para descargar el backup desde el servidor CentOS 5
download_backup_centos5() {
    log "Iniciando descarga del backup desde el servidor CentOS 5..."

    # Verificar si el script transfer_interno.sh existe y tiene permisos de ejecución
    if [[ -x "${SCRIPT_DIR}/transfer_interno.sh" ]]; then
        "${SCRIPT_DIR}/transfer_interno.sh" "${BACKUP_FILE}"
    else
        log "Error: ${SCRIPT_DIR}/transfer_interno.sh no encontrado o no tiene permisos de ejecución."
        exit 1
    fi
}

# Ejecución del script
log "***** Proceso de Backup Iniciado *****"
start_time=$(date +%s)
log "Hora de inicio del proceso de backup: ${start_time}"
check_dependencies
generate_backup
download_backup_centos5
end_time=$(date +%s)
elapsed_time=$((end_time - start_time))
minutes=$((elapsed_time / 60))
seconds=$((elapsed_time % 60))
log "Tiempo total de ejecución del script: ${minutes} minutos y ${seconds} segundos"
log "***** Proceso de Backup Finalizado Exitosamente *****"

# Llamar al script de envío de correo y pasar los tiempos de ejecución
# Enviar correo con los tiempos de ejecución
log "Enviando correo..."
if [[ -x "${SCRIPT_DIR}/send_email.sh" ]]; then
    "${SCRIPT_DIR}/send_email.sh" "${LOCAL_HOST}" "${start_time}" "${minutes}" "${seconds}" "${LOG_FILE}"
else
    log "Error: ${SCRIPT_DIR}/send_email.sh no encontrado o no tiene permisos de ejecución."
    exit 1
fi

exit 0

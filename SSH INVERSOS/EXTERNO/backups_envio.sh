#!/bin/bash
###########################################################
## Script para realizar transferencia de backup de Oracle ##
## FXGS                                                 ##
###########################################################

set -euo pipefail  # Enable strict error handling

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
mkdir -p "${BACKUP_DIR}" || {
    echo "Error: No se pudo crear el directorio ${BACKUP_DIR}"
    exit 1
}

# Función para registrar mensajes en el log
log() {
    local message="$1"
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $message" | tee -a "${LOG_FILE}"
}

# Verificar dependencias
check_dependencies() {
    log "Verificando dependencias..."
    
    # Lista de dependencias requeridas
    declare -A DEPS=(
        ["scp"]="openssh-client"
        ["sshpass"]="sshpass"
        ["expect"]="expect"
        ["msmtp"]="msmtp"
        ["df"]="coreutils"
    )

    # Detectar el sistema operativo
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
    else
        OS=$(uname -s)
    fi

    # Instalar dependencias faltantes
    for cmd in "${!DEPS[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then
            pkg="${DEPS[$cmd]}"
            log "Falta $cmd. Instalando $pkg..."
            case $OS in
                "ubuntu"|"debian")
                    sudo apt-get update && sudo apt-get install -y "$pkg" || {
                        log "Error: No se pudo instalar $pkg"
                        exit 1
                    }
                    ;;
                "centos"|"rhel"|"fedora")
                    sudo yum install -y "$pkg" || {
                        log "Error: No se pudo instalar $pkg"
                        exit 1
                    }
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
    log "Iniciando el proceso de backup en el servidor local... Archivo: ${BACKUP_NAME}"
    
    # Construir el comando completo
    
    local comando="sshpass -p \"${LOCAL_PASSWORD}\" ssh -o KexAlgorithms=+diffie-hellman-group1-sha1 -o HostKeyAlgorithms=+ssh-rsa -p 2222 root@localhost \"bash ${SH_DIR} ${BACKUP_NAME}\""
   
    #log "Ejecutando: ${comando}"
    eval sshpass -p \"${LOCAL_PASSWORD}\" ssh -o KexAlgorithms=+diffie-hellman-group1-sha1 -o HostKeyAlgorithms=+ssh-rsa -p 2222 root@localhost \"bash ${SH_DIR} ${BACKUP_NAME}\"
    
    if [ $? -ne 0 ]; then
        log "Error: Falló la ejecución del script de backup en el servidor local."
        return 1
    fi

    log "Backup generado correctamente en el servidor local."
    return 0
}


# Función para descargar el backup desde el servidor CentOS 5
download_backup_centos5() {
    log "Iniciando descarga del backup desde el servidor CentOS 5..."

    if [[ ! -x "${SCRIPT_DIR}/transfer_interno.sh" ]]; then
        log "Error: ${SCRIPT_DIR}/transfer_interno.sh no encontrado o no tiene permisos de ejecución."
        return 1
    fi

    if ! "${SCRIPT_DIR}/transfer_interno.sh" "${BACKUP_FILE}"; then
        log "Error: Falló la transferencia del backup."
        return 1
    fi

    log "Backup descargado exitosamente."
    return 0
}

# Función para enviar correo
send_email_notification() {
    local start_time=$1
    local minutes=$2
    local seconds=$3
    
    if [[ ! -x "${SCRIPT_DIR}/send_email.sh" ]]; then
        log "Error: ${SCRIPT_DIR}/send_email.sh no encontrado o no tiene permisos de ejecución."
        return 1
    fi

    if ! "${SCRIPT_DIR}/send_email.sh" \
        "${LOCAL_HOST}" \
        "${start_time}" \
        "${minutes}" \
        "${seconds}" \
        "${LOG_FILE}"; then
        
        log "Error: Falló el envío del correo de notificación."
        return 1
    fi

    log "Correo de notificación enviado exitosamente."
    return 0
}

# Ejecución del script
main(){
    local start_time end_time elapsed_time minutes seconds
    
    log "***** Proceso de Backup Iniciado *****"
    start_time=$(date +%s)

    # Verificar espacio en disco antes de comenzar
    local available_space=$(df -P "${BACKUP_DIR}" | awk 'NR==2 {print $4}')
    local min_required_space=$((10 * 1024 * 1024))  # 10GB en KB

  if [[ ${available_space} -lt ${min_required_space} ]]; then
        log "Error: Espacio insuficiente en disco. Se requieren al menos 5GB."
        backup_status=1
    else
        # Ejecutar las funciones principales con manejo de errores
        if ! check_dependencies; then
            log "Error en la verificación de dependencias"
            backup_status=1
        elif ! generate_backup; then
            log "Error en la generación del backup"
            backup_status=1
        elif ! download_backup_centos5; then
            log "Error en la descarga del backup"
            backup_status=1
        fi
    fi
    
    # Calcular tiempo de ejecución
    end_time=$(date +%s)
    elapsed_time=$((end_time - start_time))
    minutes=$((elapsed_time / 60))
    seconds=$((elapsed_time % 60))
    
    if [ $backup_status -eq 0 ]; then
        log "***** Proceso de Backup Finalizado Exitosamente *****"
    else
        log "***** Proceso de Backup Finalizado con Errores *****"
    fi
    
    log "Tiempo total de ejecución: ${minutes} minutos y ${seconds} segundos"

    # Enviar notificación por correo siempre, independientemente del resultado
    if ! send_email_notification "${start_time}" "${minutes}" "${seconds}"; then
        log "Error al enviar la notificación por correo"
        backup_status=1
    fi

    exit $backup_status
}

# Ejecutar el script principal con trap para limpieza
trap 'log "Script interrumpido"; exit 1' INT TERM
main "$@"
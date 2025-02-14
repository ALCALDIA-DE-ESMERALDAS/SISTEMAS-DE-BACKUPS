#!/bin/bash

# Parámetros
MACHINE_NAME=$1
DATE=$2
STATUS=$3
MAIN_SPACE_AVAILABLE=$4
MAIN_SPACE_TOTAL=$5
BACKUP_SPACE_AVAILABLE=$6
BACKUP_SPACE_TOTAL=$7
MOVED_FILES=$8
TEMPLATE_PATH="/home/sis_backups_auto/move_template.html"
ERROR_LOG="/home/sis_backups_auto/error_log.txt"

# Verificar argumentos
if [ -z "$MOVED_FILES" ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Error: Faltan argumentos requeridos" >> "$ERROR_LOG"
    exit 1
fi

# Configuración correo
RECIPIENT="saamare99@gmail.com, aplicaciones@esmeraldas.gob.ec"
SUBJECT="Movimiento de Backups Antiguos"
SENDER="tecnologias.informacion@esmeraldas.gob.ec"

# Convertir timestamp a formato legible
FORMATTED_DATE=$(date -d "@$DATE" "+%d-%m-%Y %H:%M:%S")

# Verificar template
if [ ! -f "$TEMPLATE_PATH" ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Error: Template no encontrado en $TEMPLATE_PATH" >> "$ERROR_LOG"
    exit 1
fi

# Escapar contenido para sed
MOVED_FILES_ESCAPED=$(echo "$MOVED_FILES" | sed ':a;N;$!ba;s/\n/\\n/g' | sed 's/[&/\]/\\&/g')

# Leer y reemplazar variables en template
EMAIL_CONTENT=$(cat "$TEMPLATE_PATH" | sed \
    -e "s|{{MACHINE_NAME}}|${MACHINE_NAME}|g" \
    -e "s|{{DATE}}|${FORMATTED_DATE}|g" \
    -e "s|{{STATUS}}|${STATUS}|g" \
    -e "s|{{MAIN_SPACE_AVAILABLE}}|${MAIN_SPACE_AVAILABLE}|g" \
    -e "s|{{MAIN_SPACE_TOTAL}}|${MAIN_SPACE_TOTAL}|g" \
    -e "s|{{BACKUP_SPACE_AVAILABLE}}|${BACKUP_SPACE_AVAILABLE}|g" \
    -e "s|{{BACKUP_SPACE_TOTAL}}|${BACKUP_SPACE_TOTAL}|g" \
    -e "s|{{MOVED_FILES}}|${MOVED_FILES_ESCAPED}|g")

# Configurar msmtp
cat > ~/.msmtprc <<EOL
defaults
auth on
tls on
tls_trust_file /etc/ssl/certs/ca-certificates.crt
logfile ~/.msmtp.log

account default
host mail.esmeraldas.gob.ec
port 465
from tecnologias.informacion@esmeraldas.gob.ec
user tecnologias.informacion@esmeraldas.gob.ec
password "tecnologias.informacion/8956*"
tls_starttls off
EOL

chmod 600 ~/.msmtprc

# Enviar correo
echo -e "Subject: $SUBJECT\nContent-Type: text/html\n\n$EMAIL_CONTENT" | msmtp -t "$RECIPIENT" 2>> "$ERROR_LOG"

if [ $? -ne 0 ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Error: Fallo al enviar correo a $RECIPIENT" >> "$ERROR_LOG"
    exit 1
fi

exit 0
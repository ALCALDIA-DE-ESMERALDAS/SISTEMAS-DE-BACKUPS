#!/bin/bash

# Parámetros
MACHINE_NAME=$1
DATE=$2
MINUTES=$3
SECONDS=$4
LOG_FILE=$5
TEMPLATE_PATH="/home/sis_backups_auto/template.html"
ERROR_LOG="/home/sis_backups_auto/error_log.txt"

# Verificar argumentos
if [ -z "$LOG_FILE" ] || [ ! -f "$LOG_FILE" ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Error: Archivo de log no encontrado" >> "$ERROR_LOG"
    exit 1
fi

# Configuración correo
RECIPIENT="saamare99@gmail.com"
SUBJECT="Resultado del Backup de Oracle"
SENDER="tecnologias.informacion@esmeraldas.gob.ec"

# Determinar estado
if grep -qi "error\|failed\|failure" "$LOG_FILE"; then
    STATUS="❌ Con Errores"
else
    STATUS="✅ Exitoso"
fi

# Escapar contenido del log para sed
LOG_CONTENT=$(cat "$LOG_FILE" | sed ':a;N;$!ba;s/\n/\\n/g' | sed 's/[&/\]/\\&/g')
# Convertir timestamp a formato legible
FORMATTED_DATE=$(date -d "@$DATE" "+%d-%m-%Y %H:%M:%S")

# Leer y reemplazar variables en template
if [ ! -f "$TEMPLATE_PATH" ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Error: Template no encontrado en $TEMPLATE_PATH" >> "$ERROR_LOG"
    exit 1
fi

# Leer y reemplazar variables en template
EMAIL_CONTENT=$(cat "$TEMPLATE_PATH" | sed \
    -e "s|{{MACHINE_NAME}}|${MACHINE_NAME}|g" \
    -e "s|{{DATE}}|${FORMATTED_DATE}|g" \
    -e "s|{{MINUTES}}|${MINUTES}|g" \
    -e "s|{{SECONDS}}|${SECONDS}|g" \
    -e "s|{{STATUS}}|${STATUS}|g" \
    -e "s|{{LOG_CONTENT}}|${LOG_CONTENT}|g")

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

# Enviar correo
echo -e "Subject: $SUBJECT\nContent-Type: text/html\n\n$EMAIL_CONTENT" | msmtp -t "$RECIPIENT" 2>> "$ERROR_LOG"

if [ $? -ne 0 ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Error: Fallo al enviar correo a $RECIPIENT" >> "$ERROR_LOG"
    exit 1
fi

exit 0
#!/bin/bash
set -euo pipefail

# Configuración
LOG_DIR="/var/log/mysql_backups"
LOG_FILE="${LOG_DIR}/backup_$(date +"%Y%m").log"
MYSQL_USER="repositorio"
MYSQL_PASS="Teclado2025/*"
MYSQL_HOST="127.0.0.1"
MYSQL_PORT="3306"

# Configuración de backup
BACKUP_DIR="/backups/mysql"
DATE=$(date +"%Y%m%d-%H%M%S")
FILENAME="mysql_backup_${DATE}.sql.gz"
FULLPATH="${BACKUP_DIR}/${FILENAME}"

# Configuración RSYNC (usando backup_192.168.120.53 como solicitaste)
RSYNC_HOST="159.223.186.132"
RSYNC_USER="usuario"
RSYNC_MODULE="backup_192.168.120.53"  # Cambiado a backup_192.168.120.53
RSYNC_PORT="9000"
RSYNC_PASSFILE="/home/sis_backups_auto/password"

# Función de logging
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# Crear directorios si no existen
mkdir -p "$BACKUP_DIR" "$LOG_DIR"

log "Iniciando backup de MySQL..."

# Backup de las bases de datos
if mysqldump -h "$MYSQL_HOST" -P "$MYSQL_PORT" -u "$MYSQL_USER" -p"$MYSQL_PASS" \
  --databases sigdar sigdar2 \
  --single-transaction \
  --routines \
  --triggers \
  --events \
  | gzip > "$FULLPATH"; then
    
    log "Backup generado exitosamente: $FULLPATH"
    log "Tamaño del backup: $(du -h "$FULLPATH" | cut -f1)"
else
    log "ERROR: Falló la generación del backup de MySQL"
    exit 1
fi

# Verificar que el archivo de backup existe y no está vacío
if [[ ! -s "$FULLPATH" ]]; then
    log "ERROR: El archivo de backup está vacío o no existe"
    exit 1
fi

log "Iniciando transferencia vía rsync..."

# Transferencia con rsync
if rsync -avz --progress \
  --partial \
  --partial-dir=/tmp/rsync-partial \
  --stats \
  --timeout=300 \
  "$FULLPATH" \
  "${RSYNC_USER}@${RSYNC_HOST}::${RSYNC_MODULE}" \
  --password-file="$RSYNC_PASSFILE" \
  --port="$RSYNC_PORT" 2>> "$LOG_FILE"; then
    
    log "Backup transferido exitosamente a ${RSYNC_MODULE}"
else
    log "ERROR: Falló la transferencia rsync"
    exit 1
fi

# Limpieza de backups locales (mantener últimos 3 días)
find "$BACKUP_DIR" -name "mysql_backup_*.sql.gz" -mtime +3 -delete
log "Limpieza de backups locales completada (manteniendo últimos 3 días)"

log "Proceso de backup completado exitosamente"
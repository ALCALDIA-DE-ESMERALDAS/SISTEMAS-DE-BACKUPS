#!/bin/bash
set -euo pipefail

# Configuración
LOG_DIR="/var/log/postgres_backups"
LOG_FILE="${LOG_DIR}/backup_$(date +"%Y%m").log"
PG_USER="postgres"
PG_PASS="postgres"  # Credenciales por defecto como mencionaste
PG_HOST="127.0.0.1"
PG_PORT="5432"      # Puerto por defecto de PostgreSQL

# Configuración de backup
BACKUP_DIR="/backups/postgres"
DATE=$(date +"%Y%m%d-%H%M%S")
FILENAME="sigcal_backup_${DATE}.sql.gz"
FULLPATH="${BACKUP_DIR}/${FILENAME}"

# Configuración RSYNC
RSYNC_HOST="159.223.186.132"
RSYNC_USER="usuario"
RSYNC_MODULE="backup_192.168.120.53"
RSYNC_PORT="9000"
RSYNC_PASSFILE="/home/sis_backups_auto/password"

# Función de logging
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# Crear directorios si no existen
mkdir -p "$BACKUP_DIR" "$LOG_DIR"

log "Iniciando backup de PostgreSQL - Base de datos sigcal..."

# Configurar variable de entorno para la contraseña
export PGPASSWORD="$PG_PASS"

# Backup de la base de datos sigcal
if pg_dump -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" \
  -d sigcal \
  --format=plain \
  --no-owner \
  --no-acl \
  | gzip > "$FULLPATH"; then
    
    log "Backup generado exitosamente: $FULLPATH"
    log "Tamaño del backup: $(du -h "$FULLPATH" | cut -f1)"
else
    log "ERROR: Falló la generación del backup de PostgreSQL"
    exit 1
fi

# Limpiar la variable de entorno
unset PGPASSWORD

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
find "$BACKUP_DIR" -name "sigcal_backup_*.sql.gz" -mtime +3 -delete
log "Limpieza de backups locales completada (manteniendo últimos 3 días)"

log "Proceso de backup completado exitosamente"
# config.sh - Archivo de configuración
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
#!/usr/bin/expect -f

# Argumentos pasados al script
set BACKUP_FILE [lindex $argv 0]
set BACKUP_DIR "/backups/oracle/temp"          
set LOCAL_PASSWORD "admin.prueba/2015*"       
set timeout -1                                 
set LOCAL_PATH "/var/backups/back_cabildo"

# Configuración de logs
set LOG_DIR "./log/envio"      

# Verificar que el archivo de backup está definido
if {![info exists BACKUP_FILE] || $BACKUP_FILE == ""} {
    puts "Error: No se especificó un archivo de backup."
    exit 1
}

# Archivo de log sin la extensión .gz
set LOG_FILE "${LOG_DIR}/${BACKUP_FILE}.log"

# Crear estructura de directorios para logs
if {![file exists $LOG_DIR]} {
    if [catch {file mkdir $LOG_DIR} error] {
        puts "Error creando directorio de logs: $error"
        exit 1
    }
}

# Función de log
proc log {message} {
    set timestamp [exec date +%Y-%m-%d\ %H:%M:%S]
    set log_message "$timestamp - $message"
    
    # Mostrar en consola
    puts $log_message
    
    # Guardar en archivo de log
    if [catch {
        set fd [open $::LOG_FILE "a"]
        puts $fd $log_message
        close $fd
    } error] {
        puts "Error escribiendo en archivo de log: $error"
    }
}

# Iniciar el log con información de la ejecución
log "=== Iniciando nueva transferencia ==="
log "Archivo a transferir: $BACKUP_FILE"
log "Ruta origen: $BACKUP_DIR"
log "Ruta destino: $LOCAL_PATH"

# Verificar existencia del archivo remoto
log "Verificando existencia del archivo en el servidor remoto... ${BACKUP_DIR}/${BACKUP_FILE}"    
spawn ssh -p 2222 -oHostKeyAlgorithms=+ssh-rsa -oKexAlgorithms=+diffie-hellman-group14-sha1 root@localhost "test -f ${BACKUP_DIR}/${BACKUP_FILE} && echo 'EXISTS' || echo 'NOT_EXISTS'"

expect {
    "assword:" {
        send "$LOCAL_PASSWORD\r"
        exp_continue
    }
    "EXISTS" {
        log "Archivo encontrado en el servidor remoto."
    }
    "NOT_EXISTS" {
        log "Error: El archivo ${BACKUP_DIR}/${BACKUP_FILE} no existe en el servidor remoto."
        exit 1
    }
    timeout {
        log "Error: Tiempo de espera excedido al verificar el archivo."
        exit 1
    }
}

# Descargar el backup desde el servidor CentOS 5 con reintentos
log "Iniciando descarga del backup desde el servidor CentOS 5...${BACKUP_DIR}/${BACKUP_FILE} -> ${LOCAL_PATH}"

set MAX_RETRIES 5
set retry 0

# Descargar el archivo con reintentos
while {$retry < $MAX_RETRIES} {
    log "Intento [expr $retry + 1] de $MAX_RETRIES..."
    set comando "rsync -avz --progress -e 'ssh -p 2222 -oHostKeyAlgorithms=+ssh-rsa -oKexAlgorithms=+diffie-hellman-group14-sha1' root@localhost:${BACKUP_DIR}/${BACKUP_FILE} $LOCAL_PATH"
    log "Comando: ${comando}"

    # Ejecutar el comando de transferencia
    spawn bash -c $comando
   
    expect {
        "assword:" {
            send "$LOCAL_PASSWORD\r"
            exp_continue
        }
        timeout {
            log "Advertencia: Tiempo de espera excedido. Reintentando..."
            incr retry
            continue
        }
        eof {
            log "Transferencia completada con éxito."
            break
        }
    }
}

if {$retry == $MAX_RETRIES} {
    log "Error: La transferencia falló después de $MAX_RETRIES intentos."
    exit 1
}

log "Backup descargado correctamente desde el servidor CentOS 5."
exit 0

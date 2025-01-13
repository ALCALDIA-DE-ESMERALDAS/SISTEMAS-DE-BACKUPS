#!/usr/bin/expect -f

# Argumentos pasados al script
set BACKUP_FILE [lindex $argv 0]
set BACKUP_DIR "/backups/oracle/temp"          
set LOCAL_PASSWORD "admin.prueba/2015*"       
set timeout -1                                
set LOCAL_PATH "/var/backups/back_cabildo"          

# Verificar que el archivo de backup está definido
if {![info exists BACKUP_FILE] || $BACKUP_FILE == ""} {
    puts "Error: No se especificó un archivo de backup."
    exit 1
}

# Registrar mensajes (función de log)
proc log {message} {
    puts "[exec date +%Y-%m-%d\ %H:%M:%S] - $message"
}

# Descargar el backup desde el servidor CentOS 5 con reintentos
log "Iniciando descarga del backup desde el servidor CentOS 5..."

# Construir la ruta completa del archivo remoto
set REMOTE_FILE "${BACKUP_DIR}/${BACKUP_FILE}"

# Verificar la existencia del archivo remoto
log "Verificando existencia del archivo en el servidor remoto... ${REMOTE_FILE}"    
spawn ssh -p 2222 -oHostKeyAlgorithms=+ssh-rsa -oKexAlgorithms=+diffie-hellman-group14-sha1 root@localhost "test -f ${REMOTE_FILE} && echo 'EXISTS' || echo 'NOT_EXISTS'"

expect {
    "assword:" {
        send "$LOCAL_PASSWORD\r"
        exp_continue
    }
    "EXISTS" {
        log "Archivo encontrado en el servidor remoto."
    }
    "NOT_EXISTS" {
        log "Error: El archivo ${REMOTE_FILE} no existe en el servidor remoto."
        exit 1
    }
    timeout {
        log "Error: Tiempo de espera excedido al verificar el archivo."
        exit 1
    }
}

# Descargar el backup desde el servidor CentOS 5 con reintentos
log "Iniciando descarga del backup desde el servidor CentOS 5...${REMOTE_FILE} -> ${LOCAL_PATH}"

set MAX_RETRIES 5
set retry 0

# Descargar el archivo con reintentos
while {$retry < $MAX_RETRIES} {
    log "Intento [expr $retry + 1] de $MAX_RETRIES..."
    # Construir el comando completo de rsync
    set comando "rsync -avz --progress -e 'ssh -p 2222 -oHostKeyAlgorithms=+ssh-rsa -oKexAlgorithms=+diffie-hellman-group14-sha1' root@localhost:$REMOTE_FILE $LOCAL_PATH"
    log "Comando: ${comando}"

    # Ejecutar el comando PARA TRANSFERENCIA DE ARCHIVOS PESADOS
    spawn bash -c "rsync -avz --progress -e 'ssh -p 2222 -oHostKeyAlgorithms=+ssh-rsa -oKexAlgorithms=+diffie-hellman-group14-sha1' root@localhost:$REMOTE_FILE $LOCAL_PATH 2>&1"
   
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

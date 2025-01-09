#!/usr/bin/expect -f

# Configuración de logging
log_file -a "/var/log/ssh_tunnels.log"
set timestamp [exec date "+%Y-%m-%d %H:%M:%S"]

# Configuración general
set timeout 60
set user_remote "root"
set host_remote "159.223.186.132"
set port_remote "22"
set password "alcaldiA2025P"
set MAX_RETRIES 5

# Configuración de hosts locales
set Hostname {192.168.120.13}
set users {root}
set password_users {admin.prueba/2015*}
set remote_port {2222}

# Función de logging
proc log_message {level message} {
    set timestamp [exec date "+%Y-%m-%d %H:%M:%S"]
    puts "$timestamp \[$level\] $message"
    exec logger -t "ssh_tunnel" "$level: $message"
}

# Verificar si un puerto está en uso
proc is_port_in_use {host port} {
    log_message "INFO" "Verificando puerto $port en $host"
    if {[catch {exec nc -z -w3 $host $port} result]} {
        return 1
    }
    return 0
}

# Verificar si el túnel está activo
proc is_tunnel_active {host port} {
    log_message "INFO" "Verificando túnel en $host:$port"
    if {[catch {exec nc -z -w5 $host $port} result]} {
        log_message "WARNING" "Error verificando túnel en $host:$port"
        return 0
    }
    return 1
}

# Validar configuración
proc validate_config {host user password port} {
    log_message "INFO" "Validando configuración... host=$host, user=$user, port=$port"
    if {$host == "" || $user == "" || $password == "" || $port == ""} {
        log_message "ERROR" "Configuración incompleta: host=$host, user=$user, port=$port"
        return 0
    }
    return 1
}

# Conectar al servidor externo
proc connect_to_remote {user_remote host_remote port_remote password} {
    log_message "INFO" "Conectando a $host_remote..."
    spawn ssh -oHostKeyAlgorithms=+ssh-rsa -oKexAlgorithms=+diffie-hellman-group14-sha1 $user_remote@$host_remote

    expect {
        "assword:" {
            send "$password\r"
            expect {
                "$ " {
                    return 1
                }
                timeout {
                    log_message "ERROR" "Tiempo de espera excedido al conectar al servidor externo"
                    return 0
                }
            }
        }
        timeout {
            log_message "ERROR" "Tiempo de espera excedido esperando prompt de contraseña"
            return 0
        }
    }
}

# Establecer túnel SSH
proc establish_tunnel {local_host local_user local_password local_port user_remote host_remote port_remote password max_retries} {
    set retry 0
    while {$retry < $max_retries} {
        log_message "INFO" "Intentando conectar a $local_host con usuario $local_user (Intento [expr {$retry + 1}] de $max_retries)..."

        # Conectar a la máquina local usando sshpass
        spawn sshpass -p "$local_password" ssh -oHostKeyAlgorithms=+ssh-rsa -oKexAlgorithms=+diffie-hellman-group14-sha1 $local_user@$local_host
        
        expect eof {
            # Verificar si el túnel está activo con ps aux
            set tunnel_active [exec ps aux | grep "ssh -N -f -R $local_port:localhost:$port_remote" | grep -v grep]
            if {[string length $tunnel_active] > 0} {
                log_message "INFO" "Túnel creado con éxito desde $local_host."
                return 1
            } else {
                log_message "ERROR" "El túnel no pudo establecerse. Reintentando..."
                incr retry
            }
        }

        # Enviar el comando para establecer el túnel SSH inverso
        send "ssh -N -f -R $local_port:localhost:$port_remote $user_remote@$host_remote\r"
        expect {
            "assword:" {
                send "$password\r"
                expect {
                    timeout {
                        log_message "WARNING" "Timeout esperando confirmación del túnel. Reintentando..."
                        incr retry
                    }                    
                    -re ".*Permission denied.*" {
                        log_message "ERROR" "Permiso denegado al intentar establecer el túnel."
                        return 0
                    }
                }
            }
            timeout {
                log_message "WARNING" "Timeout esperando credenciales de $local_user. Reintentando..."
                incr retry
            }
            eof {
                log_message "ERROR" "Sesión cerrada inesperadamente durante la conexión inicial."
                incr retry
            }
        }
    }
    log_message "ERROR" "No se pudo establecer el túnel desde $local_host después de $max_retries intentos."
    return 0
}


# Iterar sobre la lista de hosts locales
for {set i 0} {$i < [llength $Hostname]} {incr i} {
    set LOCAL_HOST [lindex $Hostname $i]
    set LOCAL_USER [lindex $users $i]
    set LOCAL_PASSWORD [lindex $password_users $i]
    set LOCAL_PORT [lindex $remote_port $i]
    
    # Validar configuración
    if {![validate_config $LOCAL_HOST $LOCAL_USER $LOCAL_PASSWORD $LOCAL_PORT]} {
        continue
    }
    
    # Comprobar si el túnel está activo
    if {[is_tunnel_active $host_remote $LOCAL_PORT]} {
        log_message "INFO" "Túnel ya activo desde $LOCAL_HOST. No se requiere reinicio."
        #continue
    }
    
    # Verificación de puerto
    if {[is_port_in_use $LOCAL_HOST $LOCAL_PORT]} {
        log_message "ERROR" "Puerto $LOCAL_PORT en uso o inaccesible en $LOCAL_HOST"
        #continue
    }
    
    # Intentos de conexión
    if {![establish_tunnel $LOCAL_HOST $LOCAL_USER $LOCAL_PASSWORD $LOCAL_PORT $user_remote $host_remote $port_remote $password $MAX_RETRIES]} {
        continue
    }
}
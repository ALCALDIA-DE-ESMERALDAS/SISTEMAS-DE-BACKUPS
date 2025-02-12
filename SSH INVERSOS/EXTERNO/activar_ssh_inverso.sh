#!/usr/bin/expect -f

# Configuración de logs
log_file -a "/home/sis_backups_auto/log/ssh_inverso/ssh_tunnel.log"
puts "[exec date] Iniciando script principal SSH"

set timeout -1

# Arrays de configuración
set hostnames {192.168.120.15 192.168.120.13}
set users {root root}
set passwords {Teclado2025/* admin.prueba/2015*}
set remote_ports {2223 2222}

# Ruta del script secundario
set tunnel_script "/home/backups_auto/MONITOREO_SSH_INVERSE/ssh_tunnels.exp"

# Conexión SSH inicial
spawn sshpass -p "des-2024*" ssh -p 2221 desarrollo@localhost
expect {
    "$ " { puts "[exec date] Conexión inicial exitosa" }
    timeout { puts "[exec date] Error: Timeout en conexión inicial"; exit 1 }
    "Permission denied" { puts "[exec date] Error: Autenticación fallida"; exit 1 }
}

# Iterar sobre las máquinas virtuales
for {set i 0} {$i < [llength $hostnames]} {incr i} {
    set hostname [lindex $hostnames $i]
    set user [lindex $users $i]
    set password [lindex $passwords $i]
    set remote_port [lindex $remote_ports $i]
    
    puts "[exec date] Ejecutando script para $hostname"
    send "$tunnel_script \"$hostname\" \"$user\" \"$password\" \"$remote_port\"\r"
    expect "$ "
}

puts "[exec date] Script principal completado"
exit
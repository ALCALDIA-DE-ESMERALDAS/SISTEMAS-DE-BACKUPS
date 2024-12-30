#!/bin/bash

# Script de verificación de dependencias para SSH Tunnel
DEPS=(
   "expect"
   "sshpass" 
   "netcat"
   "openssh-client"
   "logger"
)

check_dependency() {
   if ! command -v $1 &> /dev/null; then
       echo "ERROR: $1 no está instalado"
       echo "Instalando $1..."
       if ! apt-get install -y $1; then
           echo "ERROR: Falló la instalación de $1"
           exit 1
       fi
   fi
}

# Verificar si es root
if [ "$EUID" -ne 0 ]; then 
   echo "Este script debe ejecutarse como root"
   exit 1
fi

# Modo de solo verificación
if [[ $1 == "--check-only" ]]; then
    for dep in "${DEPS[@]}"; do
        if ! command -v $dep &> /dev/null; then
            echo "ERROR: $dep no está instalado"
        else
            echo "$dep está instalado"
        fi
    done
    exit 0
fi

# Verificar y actualizar repositorios
apt-get update

# Verificar cada dependencia
for dep in "${DEPS[@]}"; do
   check_dependency $dep
done

# Verificar permisos del archivo de log
touch /var/log/ssh_tunnels.log
chmod 640 /var/log/ssh_tunnels.log

# Verificar configuración SSH
if ! grep -q "^GatewayPorts yes" /etc/ssh/sshd_config; then
   echo "GatewayPorts yes" >> /etc/ssh/sshd_config
   systemctl restart sshd
fi

echo "Verificación completada. Sistema listo para SSH Tunneling."

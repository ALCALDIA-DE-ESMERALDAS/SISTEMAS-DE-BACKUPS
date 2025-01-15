# SSH Tunnel Configuration Guide

## ¿Qué es SSH?

SSH (Secure Shell) es un protocolo de red que permite el acceso remoto seguro entre dos sistemas. Proporciona:

- Comunicación cifrada entre cliente y servidor
- Autenticación fuerte de usuarios
- Integridad de datos durante la transmisión
- Reenvío de puertos para servicios adicionales

## ¿Qué es SSH Inverso?

SSH inverso permite establecer una conexión desde un servidor interno hacia uno externo, creando un túnel a través del cual el servidor externo puede acceder al interno. Casos de uso:

- Acceso remoto a dispositivos detrás de firewalls
- Soporte técnico a sistemas en redes privadas
- Mantenimiento de servidores sin IP pública
- Bypass de restricciones de red cuando el acceso directo no es posible

## Servidor Local

### Establecer SSH Inverso

```bash
ssh -R 2222:192.168.***.13:22 root@159.***.186.***
```

### Gestión de Sesiones Screen

- Listar sesiones:
  ```bash
  screen -ls
  ```
- Recuperar sesión:
  ```bash
  screen -r ssh_tunnel
  ```
- Iniciar nueva sesión:
  ```bash
  screen -S ssh_tunnel
  ```
- Túnel inverso a externo:
  ```bash
  ssh -N -R 2222:localhost:22 root@159.***.186.***
  ```
- Ejecutar en segundo plano: `Ctrl+A, D`

## Servidor Externo

### Conexión a Interno (Equipos Antiguos)

```bash
ssh -o KexAlgorithms=+diffie-hellman-group1-sha1 -o HostKeyAlgorithms=+ssh-rsa -p 2222 root@localhost
```

## Estructura del Comando SSH Inverso

```bash
ssh -R <puerto_remoto>:localhost:<puerto_local> usuario@<servidor_remoto> -p <puerto_remoto_servidor_remoto>
```

### Componentes:

- `-R`: Indica túnel SSH inverso
- `<puerto_remoto>`: Puerto de redirección en servidor remoto
- `localhost`: Especifica redirección a máquina local
- `<puerto_local>`: Puerto local para redirección desde servidor remoto
- `usuario@<servidor_remoto>`: Credenciales y dirección del servidor
- `-p <puerto_remoto_servidor_remoto>`: Puerto de conexión en servidor remoto (opcional si es 22)

## Edición de Crontab para la ejecución del script de backup diariamente

```bash
sudo crontab -e

0 20 * * * /home/sis_backups_auto/backups_envio.sh >> /home/sis_backups_auto/backups_envio.log 2>&1
```

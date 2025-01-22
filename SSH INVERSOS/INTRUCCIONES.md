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


root@ubuntu-apps-desarrollo:/tmp# sudo nano /etc/systemd/system/reverse-ssh.service
root@ubuntu-apps-desarrollo:/tmp# sudo systemctl daemon-reload
root@ubuntu-apps-desarrollo:/tmp# sudo systemctl enable reverse-ssh.service
root@ubuntu-apps-desarrollo:/tmp# sudo systemctl status reverse-ssh.service
● reverse-ssh.service - Reverse SSH Tunnel
     Loaded: loaded (/etc/systemd/system/reverse-ssh.service; enabled; vendor preset: enabled)
     Active: activating (auto-restart) since Wed 2025-01-22 11:09:55 -05; 32s ago
   Main PID: 329503 (code=exited, status=0/SUCCESS)
        CPU: 54ms
root@ubuntu-apps-desarrollo:/tmp# ps aux | grep "ssh"
root      101943  0.0  0.1  15432  9200 ?        Ss    2024   0:00 sshd: /usr/sbin/sshd -D [listener] 0 of 10-100 startups
root      324707  0.0  0.1  17184 11144 ?        Ss   08:15   0:00 sshd: desarrollo [priv]
desarro+  324815  0.0  0.1  17316  8324 ?        S    08:15   0:00 sshd: desarrollo@pts/0
root      326217  0.0  0.1  17180 11192 ?        Ss   08:50   0:00 sshd: desarrollo [priv]
desarro+  326275  0.0  0.1  17312  8264 ?        S    08:50   0:00 sshd: desarrollo@pts/2
root      328580  0.0  0.1  17184 10880 ?        Ss   10:39   0:00 sshd: desarrollo [priv]
desarro+  328638  0.0  0.1  17316  8080 ?        S    10:39   0:00 sshd: desarrollo@notty
desarro+  328639  0.0  0.0   7916  5372 ?        Ss   10:39   0:00 /usr/lib/openssh/sftp-server
root      330348  0.0  0.0   6612  2332 pts/1    S+   11:10   0:00 grep --color=auto ssh
root@ubuntu-apps-desarrollo:/tmp# sudo systemctl restart reverse-ssh.service
root@ubuntu-apps-desarrollo:/tmp# sudo systemctl status reverse-ssh.service
● reverse-ssh.service - Reverse SSH Tunnel
     Loaded: loaded (/etc/systemd/system/reverse-ssh.service; enabled; vendor preset: enabled)
     Active: active (running) since Wed 2025-01-22 11:10:47 -05; 7s ago
   Main PID: 330355 (ssh)
      Tasks: 1 (limit: 6972)
     Memory: 1.7M
        CPU: 63ms
     CGroup: /system.slice/reverse-ssh.service
             └─330355 /usr/bin/ssh -vvv -N -R 2221:localhost:22 -E /tmp/sshinverse.log root@159.223.186.132

ene 22 11:10:47 ubuntu-apps-desarrollo systemd[1]: Started Reverse SSH Tunnel.
root@ubuntu-apps-desarrollo:/tmp# ps aux | grep "ssh"
root      101943  0.0  0.1  15432  9200 ?        Ss    2024   0:00 sshd: /usr/sbin/sshd -D [listener] 0 of 10-100 startups
root      324707  0.0  0.1  17184 11144 ?        Ss   08:15   0:00 sshd: desarrollo [priv]
desarro+  324815  0.0  0.1  17316  8324 ?        S    08:15   0:00 sshd: desarrollo@pts/0
root      326217  0.0  0.1  17180 11192 ?        Ss   08:50   0:00 sshd: desarrollo [priv]
desarro+  326275  0.0  0.1  17312  8264 ?        S    08:50   0:00 sshd: desarrollo@pts/2
root      328580  0.0  0.1  17184 10880 ?        Ss   10:39   0:00 sshd: desarrollo [priv]
desarro+  328638  0.0  0.1  17316  8080 ?        S    10:39   0:00 sshd: desarrollo@notty
desarro+  328639  0.0  0.0   7916  5372 ?        Ss   10:39   0:00 /usr/lib/openssh/sftp-server
root      330355  0.3  0.1  14320  8604 ?        Ss   11:10   0:00 /usr/bin/ssh -vvv -N -R 2221:localhost:22 -E /tmp/sshinverse.log root@159.223.186.132
root      330362  0.0  0.0   6612  2304 pts/1    S+   11:11   0:00 grep --color=auto ssh
root@ubuntu-apps-desarrollo:/tmp#

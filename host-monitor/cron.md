# Instalación del monitor del host (H1 UFW + R4 SSH)

El monitor corre en el **host** (no en un contenedor) porque vigila el
firewall y el SSH de la máquina.

## 1. Configurar

```bash
cd host-monitor
cp monitor_host.env.example monitor_host.env
chmod 600 monitor_host.env
# Edite WEBHOOK_TOKEN = MONITOR_WEBHOOK_TOKEN del .env principal
chmod +x monitor_host.sh
```

## 2. Permitir leer el estado de UFW sin contraseña

`monitor_host.sh` usa `sudo ufw status`. Para que el cron no pida contraseña:

```bash
echo "$USER ALL=(root) NOPASSWD: /usr/sbin/ufw status verbose" | \
  sudo tee /etc/sudoers.d/monitor-ufw
sudo chmod 440 /etc/sudoers.d/monitor-ufw
```

## 3. Programar cada minuto

```bash
crontab -e
```

Agregar (ajuste la ruta absoluta):

```cron
* * * * * /ruta/al/proyecto/host-monitor/monitor_host.sh >> /ruta/al/proyecto/host-monitor/estado/monitor.log 2>&1
```

## 4. Primer arranque

La primera corrida solo toma la "foto" de UFW; a partir de la segunda
detecta cambios. Para la demostración, el webhook debe estar activo en N8N
(flujo `02_alertas_host.json`) y el túnel/puerto accesible.

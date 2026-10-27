#!/usr/bin/env bash
# =====================================================================
#  A1 — Fuerza bruta SSH  ->  alerta R4
#  Genera 20 intentos de login SSH fallidos contra el propio host.
#  El monitor del host (host-monitor/monitor_host.sh) los cuenta y
#  envía R4 al webhook de N8N.
# =====================================================================
set -euo pipefail
OBJETIVO="${1:-127.0.0.1}"
INTENTOS="${2:-20}"

echo "== A1: $INTENTOS intentos SSH fallidos contra $OBJETIVO =="
if ! command -v ssh >/dev/null 2>&1; then
  echo "ssh no está instalado. En su lugar, se simulan fallos en el log de auth."
  for i in $(seq "$INTENTOS"); do
    logger -p auth.warning -t sshd "Failed password for invalid user atacante$i from 203.0.113.7 port 50$i ssh2" || true
  done
else
  for i in $(seq "$INTENTOS"); do
    # Usuario inexistente + BatchMode para que falle de inmediato sin pedir clave.
    ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=3 \
        "usuario_falso_$i@$OBJETIVO" exit 2>/dev/null || true
    printf '.'
  done
  echo
fi

echo
echo "Hecho. Ahora:"
echo "  1. Espera a la próxima corrida de host-monitor/monitor_host.sh (cada minuto)."
echo "  2. Debe llegar a Telegram la alerta R4 (fuerza bruta SSH)."
echo "  3. Respuesta esperada: bloquear la IP en UFW/fail2ban y revisar SSH."
echo
echo "Para forzar la detección ahora mismo desde el host:"
echo "  ./host-monitor/monitor_host.sh"

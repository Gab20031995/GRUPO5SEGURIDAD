#!/usr/bin/env bash
# =====================================================================
#  A3 — Apertura del puerto 5432 en el firewall  ->  alerta H1
#  Simula que alguien expone PostgreSQL al exterior con UFW.
# =====================================================================
set -euo pipefail
cd "$(dirname "$0")/.."

echo "== A3: abrir el puerto 5432 en UFW =="
if command -v ufw >/dev/null 2>&1; then
  echo "   Ejecutando: sudo ufw allow 5432/tcp"
  sudo ufw allow 5432/tcp || true
  echo
  echo "Hecho. host-monitor/monitor_host.sh detectará el cambio de reglas (H1)."
  echo "Para forzar la detección ahora:  ./host-monitor/monitor_host.sh"
  echo
  echo "RESPUESTA / reversión (hazlo tras capturar la alerta):"
  echo "   sudo ufw delete allow 5432/tcp"
else
  echo "UFW no está instalado en este host."
  echo "Para la demo puedes instalarlo (sudo apt install ufw) o documentar"
  echo "la alerta H1 con el escenario del monitor del host."
fi

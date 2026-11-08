#!/usr/bin/env bash
# =====================================================================
#  monitor_host.sh — Vigila eventos que NO viven dentro de PostgreSQL:
#    H1  Cambios en el firewall UFW (regla nueva, eliminada o UFW apagado)
#    R4  Fuerza bruta SSH (fallos de autenticación en el host)
#  Cada hallazgo se envía al webhook del flujo 02 de N8N, que deduplica
#  y reenvía a Telegram.
#
#  Se ejecuta por cron en el HOST (no en un contenedor), cada minuto.
#  Ver host-monitor/cron.md para la instalación.
#
#  Variables (en host-monitor/monitor_host.env):
#    WEBHOOK_URL    https://localhost:8443/webhook/alertas-host
#    WEBHOOK_TOKEN  = MONITOR_WEBHOOK_TOKEN del .env
#    R4_UMBRAL      fallos SSH en 10 min para alertar (def. 5)
# =====================================================================
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
ESTADO="$DIR/estado"
mkdir -p "$ESTADO"
# shellcheck source=/dev/null
[[ -f "$DIR/monitor_host.env" ]] && source "$DIR/monitor_host.env"

WEBHOOK_URL="${WEBHOOK_URL:-https://localhost:8443/webhook/alertas-host}"
WEBHOOK_TOKEN="${WEBHOOK_TOKEN:-cambiar_token_webhook}"
R4_UMBRAL="${R4_UMBRAL:-5}"

enviar() {  # enviar <codigo> <severidad> <titulo> <detalle> <clave>
  local payload
  payload=$(CODIGO="$1" SEV="$2" TIT="$3" DET="$4" CLV="$5" python3 -c '
import json, os
print(json.dumps({
  "codigo":   os.environ["CODIGO"],
  "severidad":os.environ["SEV"],
  "titulo":   os.environ["TIT"],
  "detalle":  os.environ["DET"],
  "clave":    os.environ["CLV"],
}))')
  curl -sS -k -m 10 -X POST "$WEBHOOK_URL" \
       -H "Content-Type: application/json" \
       -H "X-Webhook-Token: $WEBHOOK_TOKEN" \
       -d "$payload" >/dev/null \
    && echo "[$(date '+%F %T')] enviado $1" \
    || echo "[$(date '+%F %T')] ERROR enviando $1" >&2
}

# ---------- H1: estado del firewall UFW ----------
if command -v ufw >/dev/null 2>&1; then
  ACTUAL="$(sudo ufw status verbose 2>/dev/null || echo 'ufw inaccesible')"
  HASH_NUEVO="$(printf '%s' "$ACTUAL" | md5sum | cut -d' ' -f1)"
  PREV="$ESTADO/ufw.hash"
  PREV_TXT="$ESTADO/ufw.txt"
  if [[ -f "$PREV" ]]; then
    if [[ "$(cat "$PREV")" != "$HASH_NUEVO" ]]; then
      DIFF="$(diff <(cat "$PREV_TXT" 2>/dev/null) <(printf '%s' "$ACTUAL") | grep -E '^[<>]' | head -20 || true)"
      APAGADO=""; printf '%s' "$ACTUAL" | grep -qi 'Status: inactive' && APAGADO=" ¡UFW DESACTIVADO!"
      enviar "H1" "CRÍTICA" "Cambio en el firewall UFW" \
             "Se modificó la configuración de UFW.${APAGADO} Cambios:
${DIFF}
Acción: revisar si fue autorizado; restaurar reglas y reactivar UFW si procede." \
             "H1:${HASH_NUEVO}"
    fi
  fi
  printf '%s' "$HASH_NUEVO" > "$PREV"
  printf '%s' "$ACTUAL" > "$PREV_TXT"
fi

# ---------- R4: fuerza bruta SSH ----------
# Cuenta fallos de SSH de los últimos 10 min en el journal (o en auth.log).
VENTANA="10 minutes ago"
if command -v journalctl >/dev/null 2>&1; then
  LOG="$(journalctl -u ssh -u sshd --since "$VENTANA" --no-pager 2>/dev/null || true)"
else
  LOG="$(grep -a "sshd" /var/log/auth.log 2>/dev/null | tail -500 || true)"
fi
FALLOS="$(printf '%s\n' "$LOG" | grep -ciE 'Failed password|Invalid user|authentication failure' || true)"
if [[ "${FALLOS:-0}" -gt "$R4_UMBRAL" ]]; then
  IPS="$(printf '%s\n' "$LOG" | grep -oE 'from ([0-9]{1,3}\.){3}[0-9]{1,3}' | awk '{print $2}' | sort | uniq -c | sort -rn | head -5 | tr '\n' ' ')"
  # Clave por franja de 10 min: no repite cada minuto el mismo incidente
  SLOT="$(( $(date +%s) / 600 ))"
  enviar "R4" "CRÍTICA" "Fuerza bruta SSH en el host" \
         "Fallos de autenticación SSH en los últimos 10 min: ${FALLOS} (umbral: ${R4_UMBRAL}).
Top IPs (conteo IP): ${IPS:-n/d}
Acción: bloquear las IP en UFW/fail2ban y verificar que SSH use solo llaves." \
         "R4:ssh:${SLOT}"
fi

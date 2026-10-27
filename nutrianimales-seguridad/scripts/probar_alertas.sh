#!/usr/bin/env bash
# =====================================================================
#  probar_alertas.sh — Evalúa las 16 alertas de BD de una sola pasada
#  (lo mismo que hace el flujo 01 de N8N cada minuto) y muestra cuáles
#  están activas en este momento. Útil para la demo y para capturas.
# =====================================================================
set -euo pipefail
cd "$(dirname "$0")/.."
Q(){ docker compose exec -T postgres psql -U postgres -d nutrianimales_db "$@"; }

echo "===== Estado de las alertas de base de datos ====="
for c in R1 R2 R3 R4 R5 H2 H3 H4 H5 D1 D2 D3 D4 D5 D6 D7; do
  N=$(Q -At -c "SELECT count(*) FROM monitor.ejecutar_chequeo('$c');")
  if [[ "$N" -gt 0 ]]; then printf '  [DISPARA]  %s  (%s)\n' "$c" "$N"
  else                      printf '  .          %s\n' "$c"; fi
done
echo
echo "Nota: H1 y la parte SSH de R4 provienen del host (host-monitor/monitor_host.sh)."
echo
echo "Últimas 10 alertas registradas:"
Q -c "SELECT tipo, severidad, alerta, to_char(fecha AT TIME ZONE 'America/Costa_Rica','YYYY-MM-DD HH24:MI:SS') AS fecha FROM alertas_auditoria ORDER BY fecha DESC LIMIT 10;"

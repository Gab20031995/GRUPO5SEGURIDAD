#!/usr/bin/env bash
# Utilidades comunes para los scripts de ataque.
set -euo pipefail
cd "$(dirname "$0")/.."

PSQL_POSTGRES() { docker compose exec -T -u postgres postgres psql -U postgres -d nutrianimales_db "$@"; }
VER_ALERTA() {  # VER_ALERTA <codigo> [segundos_max]
  # NO llama a monitor.ejecutar_chequeo(): eso registraría la alerta y la
  # deduplicación impediría que N8N la enviara a Telegram. En su lugar espera
  # a que el flujo 01 de N8N (cada minuto) la detecte, registre y envíe.
  local cod="$1" max="${2:-120}" t=0 inicio
  inicio=$(PSQL_POSTGRES -At -c "SELECT now();")
  echo "  -> Esperando a que N8N detecte $cod y la envíe a Telegram (máx. ${max}s)..."
  while (( t < max )); do
    if PSQL_POSTGRES -At -c "SELECT 1 FROM alertas_auditoria WHERE tipo='$cod' AND fecha >= '$inicio' LIMIT 1;" | grep -q 1; then
      echo "     ✔ Detectada a los ~${t}s. Mensaje registrado (revisa Telegram):"
      PSQL_POSTGRES -At -c "SELECT severidad || ' | ' || alerta || ' / ' || replace(mensaje, E'\n', ' / ') FROM alertas_auditoria WHERE tipo='$cod' AND fecha >= '$inicio' ORDER BY fecha DESC LIMIT 1;" \
        | sed 's/^/     /'
      return 0
    fi
    sleep 5; t=$((t + 5))
  done
  echo "     ✘ No se registró $cod en ${max}s. Puede estar deduplicada (misma alerta en los"
  echo "       últimos 60 min) o el flujo 01 no está activo. Ver: ./scripts/probar_alertas.sh"
  return 0
}
ULTIMA_ALERTA() {  # ULTIMA_ALERTA <codigo>
  PSQL_POSTGRES -c "SELECT tipo, severidad, fecha FROM alertas_auditoria WHERE tipo='$1' ORDER BY fecha DESC LIMIT 1;"
}
pausa() { echo; read -rp "   [Enter para continuar]" _ || true; echo; }

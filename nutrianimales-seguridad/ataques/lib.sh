#!/usr/bin/env bash
# Utilidades comunes para los scripts de ataque.
set -euo pipefail
cd "$(dirname "$0")/.."

PSQL_POSTGRES() { docker compose exec -T postgres psql -U postgres -d nutrianimales_db "$@"; }
VER_ALERTA() {  # VER_ALERTA <codigo>
  echo "  -> Evaluando alerta $1 (lo mismo que hace N8N cada minuto):"
  PSQL_POSTGRES -At -c "SELECT severidad || ' | ' || replace(texto, E'\n', ' / ') FROM monitor.ejecutar_chequeo('$1');" \
    | sed 's/^/     /' || true
}
ULTIMA_ALERTA() {  # ULTIMA_ALERTA <codigo>
  PSQL_POSTGRES -c "SELECT tipo, severidad, fecha FROM alertas_auditoria WHERE tipo='$1' ORDER BY fecha DESC LIMIT 1;"
}
pausa() { echo; read -rp "   [Enter para continuar]" _ || true; echo; }

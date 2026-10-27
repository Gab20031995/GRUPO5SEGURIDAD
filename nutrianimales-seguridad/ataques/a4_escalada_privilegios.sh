#!/usr/bin/env bash
# =====================================================================
#  A4 — Escalada de privilegios: GRANT a agente_ia  ->  alerta H3
#  Simula que un atacante con acceso administrativo le da permisos de
#  escritura al usuario de solo lectura del bot.
# =====================================================================
set -euo pipefail
cd "$(dirname "$0")/.."
source ataques/lib.sh

echo "== A4: GRANT INSERT ON ALL TABLES IN SCHEMA public TO agente_ia =="
echo "   (agente_ia debería ser SOLO lectura; esto es la escalada)"
PSQL_POSTGRES -c "GRANT INSERT ON ALL TABLES IN SCHEMA public TO agente_ia;"
echo

VER_ALERTA H3
echo
echo "RESPUESTA / reversión (tras capturar la alerta en Telegram):"
echo "   docker compose exec postgres psql -U postgres -d nutrianimales_db \\"
echo "     -c \"REVOKE INSERT ON ALL TABLES IN SCHEMA public FROM agente_ia;\""
read -rp "   ¿Revertir ahora? [s/N] " r || true
if [[ "${r:-}" =~ ^[sS]$ ]]; then
  PSQL_POSTGRES -c "REVOKE INSERT ON ALL TABLES IN SCHEMA public FROM agente_ia;"
  echo "   Revertido. Nueva evaluación de H3 (debe salir vacío):"
  VER_ALERTA H3
fi

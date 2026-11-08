#!/usr/bin/env bash
# =====================================================================
#  A5 — Exfiltración masiva de datos  ->  alerta D7
#  Conecta como agente_ia y hace un SELECT masivo de la tabla clientes
#  (> 1 000 filas). pg_stat_statements lo registra y D7 lo detecta.
# =====================================================================
set -euo pipefail
cd "$(dirname "$0")/.."
source ataques/lib.sh

echo "== A5: SELECT * FROM clientes como agente_ia (exfiltración) =="
docker compose exec -T postgres bash -lc '
  PGPASSWORD="$AGENTE_IA_PASSWORD" psql -U agente_ia -d nutrianimales_db \
    -c "SELECT * FROM clientes;" > /dev/null && echo "   SELECT ejecutado ($(PGPASSWORD=$AGENTE_IA_PASSWORD psql -U agente_ia -d nutrianimales_db -At -c "SELECT count(*) FROM clientes") filas leídas)"'
echo

VER_ALERTA D7
echo
echo "RESPUESTA esperada: verificar si es legítimo. Si no lo es, bloquear al"
echo "usuario y rotar su contraseña:"
echo "   docker compose exec postgres psql -U postgres -d nutrianimales_db \\"
echo "     -c \"ALTER ROLE agente_ia NOLOGIN;\"   # y luego ALTER ROLE ... PASSWORD 'nueva'"

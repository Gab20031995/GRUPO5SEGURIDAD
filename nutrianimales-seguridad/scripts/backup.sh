#!/usr/bin/env bash
# =====================================================================
#  backup.sh — Respaldo lógico de la BD. Registra el resultado en la
#  tabla backups para que la alerta D3 (backup obsoleto) quede satisfecha.
#  Programar por cron cada 24 h (ver más abajo).
# =====================================================================
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p backups
STAMP="$(date +%Y%m%d_%H%M%S)"
ARCHIVO="backups/nutrianimales_${STAMP}.dump"

if docker compose exec -T postgres pg_dump -U postgres -Fc nutrianimales_db > "$ARCHIVO" 2>backups/last_error.log; then
  TAM=$(stat -c%s "$ARCHIVO" 2>/dev/null || echo 0)
  docker compose exec -T postgres psql -U postgres -d nutrianimales_db \
    -c "INSERT INTO backups(estado, ruta, tamano_bytes) VALUES ('exitoso', '$ARCHIVO', $TAM);" >/dev/null
  echo "[OK] Backup creado: $ARCHIVO ($TAM bytes)"
  # Retención: conservar los últimos 14
  ls -1t backups/nutrianimales_*.dump | tail -n +15 | xargs -r rm -f
else
  docker compose exec -T postgres psql -U postgres -d nutrianimales_db \
    -c "INSERT INTO backups(estado, ruta) VALUES ('fallido', '$ARCHIVO');" >/dev/null || true
  echo "[ERROR] Falló el backup. Ver backups/last_error.log" >&2
  exit 1
fi

# Programar cada día a la 1:30 am:
#   30 1 * * * /ruta/al/proyecto/scripts/backup.sh >> /ruta/al/proyecto/backups/backup.log 2>&1

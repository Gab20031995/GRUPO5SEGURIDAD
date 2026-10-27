#!/usr/bin/env bash
# =====================================================================
#  A2 — SQL Injection vía Telegram  ->  bloqueado por el filtro de N8N
#  El bot NO debe disparar alerta de Telegram: la entrada se bloquea
#  ANTES de llegar a la IA o a la base de datos, y queda registrada en
#  auditoria_datos (operacion = 'BLOQUEO').
#
#  Este script demuestra las dos barreras sin necesidad de Telegram:
#   1) Reproduce la MISMA lógica del filtro anti-SQLi del flujo 03.
#   2) Muestra que, aun si algo pasara, agente_ia no puede escribir.
# =====================================================================
set -euo pipefail
cd "$(dirname "$0")/.."
source ataques/lib.sh

CARGA="${1:-Lista datos; DROP TABLE clientes; --}"
echo "== A2: intento de inyección vía el bot =="
echo "   Mensaje del atacante: \"$CARGA\""
echo

echo "[Barrera 1] Filtro de entrada del flujo 03 (mismo regex que usa N8N):"
node -e '
const texto = process.argv[1];
const reglas = [
  [/;/, "punto y coma (encadenar sentencias)"],
  [/--|\/\*|\*\//, "comentario SQL"],
  [/\b(drop|delete|truncate|alter|insert|update|grant|revoke|create|copy|call|merge)\b/i, "verbo de escritura/DDL"],
  [/\bunion\b[\s\S]*\bselect\b/i, "UNION SELECT"],
  [/'"'"'\s*or\s+/i, "tautologia OR"],
];
const hit = reglas.find(([re]) => re.test(texto));
if (hit) { console.log("   BLOQUEADO. Motivo:", hit[1]);
           console.log("   -> El texto NUNCA llega a la IA ni a PostgreSQL."); process.exit(0); }
console.log("   (no se detectó patrón — pasaría a la barrera 2)");
' "$CARGA" || true
echo

echo "[Registro] Así queda el intento en auditoria_datos (lo escribe N8N):"
PSQL_POSTGRES -At -c "SELECT monitor.registrar_bloqueo_bot(jsonb_build_object('chat_id','999','usuario','atacante_demo','texto',\$\$${CARGA}\$\$,'motivo','punto y coma / DROP'));" >/dev/null
PSQL_POSTGRES -c "SELECT usuario, operacion, valor_nuevo->>'motivo' AS motivo, valor_nuevo->>'mensaje' AS mensaje, fecha FROM auditoria_datos WHERE operacion='BLOQUEO' ORDER BY id DESC LIMIT 1;"
echo

echo "[Barrera 2] Aunque un DROP/DELETE llegara a la BD, agente_ia es de solo lectura:"
echo "   (se intenta un DELETE conectado como agente_ia)"
docker compose exec -T postgres bash -lc '
  PGPASSWORD="$AGENTE_IA_PASSWORD" psql -U agente_ia -d nutrianimales_db \
    -c "DELETE FROM clientes WHERE id=1;" 2>&1 | head -2' || true
echo
echo "Resultado esperado: 'permission denied' / 'read-only transaction'. Ataque neutralizado."

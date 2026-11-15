#!/usr/bin/env bash
# =====================================================================
#  demo_alertas.sh — Dispara alertas de base de datos de forma controlada,
#  espera a que N8N las detecte y las envíe a Telegram, y REVIERTE cada
#  cambio. Deja el registro en evidencias/<fecha>/alertas.log.
#
#  Uso:
#    ./scripts/demo_alertas.sh            # todas, en orden
#    ./scripts/demo_alertas.sh R2 D4      # solo las indicadas
#  Códigos: R1 R2 R3 R4 R5H5 H2H4 H3 D1 D2 D4 D5 D6 D7
#
#  Requisitos: sistema levantado y flujo 01 de N8N activo.
#  No usa monitor.ejecutar_chequeo(): deja que N8N detecte y envíe.
# =====================================================================
set -uo pipefail
cd "$(dirname "$0")/.."

FECHA=$(date +%Y%m%d)
EVID="evidencias/$FECHA"; mkdir -p "$EVID"
LOG="$EVID/alertas.log"
exec > >(tee -a "$LOG") 2>&1

PG()  { docker compose exec -T -u postgres postgres psql -U postgres -d nutrianimales_db -v ON_ERROR_STOP=1 "$@"; }
PGq() { PG -At -q "$@"; }
COMO() {  # COMO <usuario> <variable_password> <sql>   (conexión TCP+SSL dentro de la red Docker)
  docker compose exec -T postgres bash -c \
    "PGPASSWORD=\"\$$2\" psql 'host=172.28.0.10 sslmode=require dbname=nutrianimales_db user=$1' -At -q -c \"$3\""
}
titulo() { echo; echo "=================================================================="; echo " $*"; echo " $(date '+%F %T')"; echo "=================================================================="; }
cmd()    { echo "  \$ $*"; }

ESPERAR() {  # ESPERAR <codigo> <desde_timestamp> [max_seg]
  local cod="$1" desde="$2" max="${3:-150}" t=0
  echo "  … esperando a que N8N detecte $cod y la envíe a Telegram (máx. ${max}s)"
  while (( t < max )); do
    if [[ -n "$(PGq -c "SELECT 1 FROM alertas_auditoria WHERE tipo='$cod' AND fecha >= '$desde' LIMIT 1;")" ]]; then
      echo "  ✔ $cod registrada y enviada (~${t}s):"
      PGq -c "SELECT '    ' || to_char(fecha,'HH24:MI:SS') || ' | ' || severidad || ' | ' || alerta || E'\n' ||
                     regexp_replace(mensaje, '^', '      ', 'gn')
              FROM alertas_auditoria WHERE tipo='$cod' AND fecha >= '$desde' ORDER BY fecha DESC LIMIT 1;"
      RESULTADOS+=("$cod OK")
      return 0
    fi
    sleep 5; t=$((t + 5))
  done
  echo "  ✘ $cod NO se registró en ${max}s"
  RESULTADOS+=("$cod FALLÓ")
}
AHORA() { PGq -c "SELECT now();"; }

# ---------------------------------------------------------------------
demo_R1() {
  titulo "R1 — Consulta lenta (> 1 s)"
  local t0; t0=$(AHORA)
  cmd "SELECT pg_sleep(1.3)"
  PGq -c "SELECT pg_sleep(1.3) AS demo_r1_$(date +%s);" >/dev/null
  ESPERAR R1 "$t0"
}

demo_R2() {
  titulo "R2 — Saturación de conexiones (> 10)"
  local t0; t0=$(AHORA)
  cmd "12 conexiones simultáneas con pg_sleep(90)"
  for _ in $(seq 12); do PGq -c "SELECT pg_sleep(90);" >/dev/null 2>&1 & done
  ESPERAR R2 "$t0"
  echo "  ↺ Revertir: cerrar las conexiones de prueba"
  PGq -c "SELECT count(pg_terminate_backend(pid)) FROM pg_stat_activity WHERE query LIKE 'SELECT pg_sleep(90)%' AND pid <> pg_backend_pid();" >/dev/null
  wait 2>/dev/null
}

demo_R3() {
  titulo "R3 — Conexión en horario no laboral"
  local t0 hora; t0=$(AHORA); hora=$(TZ=America/Costa_Rica date +%-H)
  cmd "UPDATE monitor.config SET valor='$hora' WHERE clave='horario_fin'   (simula que ya terminó la jornada)"
  PGq -c "UPDATE monitor.config SET valor='$hora' WHERE clave='horario_fin';"
  cmd "conexión de ti_db fuera de horario (pg_sleep 90)"
  COMO ti_db TI_DB_PASSWORD "SELECT pg_sleep(90);" >/dev/null 2>&1 &
  ESPERAR R3 "$t0"
  echo "  ↺ Revertir: horario_fin = 23 y cerrar la sesión"
  PGq -c "UPDATE monitor.config SET valor='23' WHERE clave='horario_fin';"
  PGq -c "SELECT count(pg_terminate_backend(pid)) FROM pg_stat_activity WHERE usename='ti_db';" >/dev/null
  wait 2>/dev/null
}

demo_R4() {
  titulo "R4 — Autenticación fallida en PostgreSQL (> 5 en 10 min)"
  local t0; t0=$(AHORA)
  cmd "8 intentos de login de agente_ia con contraseña incorrecta"
  for _ in $(seq 8); do
    docker compose exec -T postgres bash -c \
      "PGPASSWORD=incorrecta psql 'host=172.28.0.10 sslmode=require dbname=nutrianimales_db user=agente_ia' -c 'select 1'" >/dev/null 2>&1
  done
  ESPERAR R4 "$t0"
}

demo_R5H5() {
  titulo "R5 + H5 — Cambio de configuración y degradación a MD5"
  local t0; t0=$(AHORA)
  cmd "ALTER SYSTEM SET password_encryption = 'md5'"
  PGq -c "ALTER SYSTEM SET password_encryption = 'md5';"
  ESPERAR R5 "$t0"
  ESPERAR H5 "$t0"
  echo "  ↺ Revertir: ALTER SYSTEM RESET password_encryption; SELECT pg_reload_conf();"
  PGq -c "ALTER SYSTEM RESET password_encryption;"; PGq -c "SELECT pg_reload_conf();" >/dev/null
}

demo_H2H4() {
  titulo "H2 + H4 — Se abre pg_hba.conf y entra una conexión desde otra red"
  local t0 ip_pg; t0=$(AHORA)
  cp postgres/conf/pg_hba.conf "$EVID/pg_hba.conf.original"
  cmd "echo 'hostssl nutrianimales_db all 172.29.0.0/16 scram-sha-256' >> postgres/conf/pg_hba.conf"
  # Debe ir ANTES de las líneas 'reject': se inserta sobre la primera de ellas
  sed -i '0,/^host[[:space:]]\+all[[:space:]]\+all[[:space:]]\+0\.0\.0\.0\/0[[:space:]]\+reject/s//hostssl   nutrianimales_db  all       172.29.0.0\/16    scram-sha-256   # ATAQUE DEMO H2\/H4\n&/' postgres/conf/pg_hba.conf
  PGq -c "SELECT pg_reload_conf();" >/dev/null
  ESPERAR H2 "$t0"
  cmd "docker network connect nutrianimales-edge nutri_postgres   (Postgres queda alcanzable desde otra red)"
  docker network connect nutrianimales-edge nutri_postgres
  ip_pg=$(docker inspect nutri_postgres --format '{{(index .NetworkSettings.Networks "nutrianimales-edge").IPAddress}}')
  cmd "conexión de ti_db desde un contenedor en 172.29.0.0/16 -> $ip_pg"
  docker run --rm -d --name nutri_intruso --network nutrianimales-edge \
    -e PGPASSWORD="$(grep ^TI_DB_PASSWORD .env | cut -d= -f2)" --entrypoint psql \
    nutrianimales/postgres:16-hardened \
    "host=$ip_pg sslmode=require dbname=nutrianimales_db user=ti_db" -c "SELECT pg_sleep(100);" >/dev/null
  ESPERAR H4 "$t0"
  echo "  ↺ Revertir: cortar la sesión, quitar la red y restaurar pg_hba.conf"
  docker rm -f nutri_intruso >/dev/null 2>&1
  docker network disconnect nutrianimales-edge nutri_postgres
  cp "$EVID/pg_hba.conf.original" postgres/conf/pg_hba.conf
  PGq -c "SELECT pg_reload_conf();" >/dev/null
  PGq -c "SELECT count(pg_terminate_backend(pid)) FROM pg_stat_activity WHERE client_addr << '172.29.0.0/16';" >/dev/null
}

demo_H3() {
  titulo "H3 — Escalada de privilegios: GRANT a agente_ia (ataque A4)"
  local t0; t0=$(AHORA)
  cmd "GRANT INSERT ON ALL TABLES IN SCHEMA public TO agente_ia"
  PGq -c "GRANT INSERT ON ALL TABLES IN SCHEMA public TO agente_ia;"
  ESPERAR H3 "$t0"
  echo "  ↺ Respuesta: REVOKE INSERT ON ALL TABLES IN SCHEMA public FROM agente_ia"
  PGq -c "REVOKE INSERT ON ALL TABLES IN SCHEMA public FROM agente_ia;"
}

demo_D1() {
  titulo "D1 — DELETE masivo sin WHERE (> 100 filas)"
  local t0; t0=$(AHORA)
  PGq -c "DROP TABLE IF EXISTS prueba_d1; CREATE TABLE prueba_d1 AS SELECT g AS id FROM generate_series(1,150) g;"
  cmd "DELETE FROM prueba_d1   (150 filas, sin WHERE)"
  PGq -c "DELETE FROM prueba_d1;"
  ESPERAR D1 "$t0"
  PGq -c "DROP TABLE prueba_d1;"
}

demo_D6() {
  titulo "D6 — UPDATE masivo sin WHERE (> 50 filas)"
  local t0; t0=$(AHORA)
  PGq -c "DROP TABLE IF EXISTS prueba_d6; CREATE TABLE prueba_d6 AS SELECT g AS id, 100 AS precio FROM generate_series(1,80) g;"
  cmd "UPDATE prueba_d6 SET precio = 0   (80 filas, sin WHERE)"
  PGq -c "UPDATE prueba_d6 SET precio = 0;"
  ESPERAR D6 "$t0"
  PGq -c "DROP TABLE prueba_d6;"
}

demo_D2() {
  titulo "D2 — Crecimiento anormal de tabla (> 20 %)"
  local t0; t0=$(AHORA)
  echo "  (ventana de comparación reducida de 30 a 2 min para la demo)"
  PGq -c "UPDATE monitor.config SET valor='2' WHERE clave='d2_ventana_min';"
  PGq -c "DROP TABLE IF EXISTS prueba_d2; CREATE TABLE prueba_d2 AS SELECT g AS id FROM generate_series(1,100) g; ANALYZE prueba_d2;"
  echo "  … 100 filas iniciales; esperando 3 min para que N8N tome la foto de referencia"
  sleep 180
  cmd "INSERT INTO prueba_d2 SELECT generate_series(101,160)   (+60 %)"
  PGq -c "INSERT INTO prueba_d2 SELECT generate_series(101,160); ANALYZE prueba_d2;"
  ESPERAR D2 "$t0"
  echo "  ↺ Revertir: ventana = 30 min y borrar la tabla de prueba"
  PGq -c "UPDATE monitor.config SET valor='30' WHERE clave='d2_ventana_min';"
  PGq -c "DROP TABLE prueba_d2;"
}

demo_D4() {
  titulo "D4 — Duplicados en tablas críticas (> 5)"
  local t0; t0=$(AHORA)
  cmd "INSERT 7 clientes con el mismo correo"
  PGq -c "INSERT INTO clientes(nombre,tipo,correo,segmento)
          SELECT 'Cliente duplicado demo','persona','duplicado.demo@nutrianimales.com','mixto' FROM generate_series(1,7);"
  ESPERAR D4 "$t0"
  echo "  ↺ Respuesta: depurar duplicados (queda registrado en auditoria_datos)"
  PGq -c "DELETE FROM clientes WHERE correo='duplicado.demo@nutrianimales.com';"
}

demo_D5() {
  titulo "D5 — Transacción bloqueada (> 30 s)"
  local t0; t0=$(AHORA)
  PGq -c "DROP TABLE IF EXISTS prueba_d5; CREATE TABLE prueba_d5 (id int PRIMARY KEY, v int); INSERT INTO prueba_d5 VALUES (1,0);"
  cmd "Sesión A: BEGIN; UPDATE prueba_d5 ... ; pg_sleep(80)  |  Sesión B: UPDATE la misma fila (queda esperando)"
  PGq -c "BEGIN; UPDATE prueba_d5 SET v=1 WHERE id=1; SELECT pg_sleep(80); COMMIT;" >/dev/null 2>&1 &
  sleep 2
  PGq -c "UPDATE prueba_d5 SET v=2 WHERE id=1;" >/dev/null 2>&1 &
  ESPERAR D5 "$t0"
  echo "  ↺ Respuesta: terminar la sesión bloqueadora"
  PGq -c "SELECT count(pg_terminate_backend(pid)) FROM pg_stat_activity WHERE query LIKE 'BEGIN; UPDATE prueba_d5%';" >/dev/null
  wait 2>/dev/null
  PGq -c "DROP TABLE prueba_d5;"
}

demo_D7() {
  titulo "D7 — Exfiltración: SELECT masivo de agente_ia (ataque A5)"
  local t0; t0=$(AHORA)
  cmd "agente_ia: SELECT * FROM clientes"
  echo "  filas leídas: $(COMO agente_ia AGENTE_IA_PASSWORD "SELECT * FROM clientes;" | wc -l)"
  ESPERAR D7 "$t0"
}

# ---------------------------------------------------------------------
RESULTADOS=()
TODAS=(R1 R2 R3 R4 R5H5 H2H4 H3 D1 D6 D4 D5 D7 D2)
LISTA=("${@:-${TODAS[@]}}")

titulo "Demo de alertas — NutriAnimales S.A."
echo "  Alertas a probar: ${LISTA[*]}"
echo "  Evidencia: $LOG"
for c in "${LISTA[@]}"; do
  if declare -f "demo_$c" >/dev/null; then "demo_$c"; else echo "Código desconocido: $c"; fi
done

echo "  ↺ Limpieza final: reiniciar pg_stat_statements (evita re-alertas cada hora)"
PGq -c "SELECT pg_stat_statements_reset();" >/dev/null

titulo "RESUMEN"
printf '  %s\n' "${RESULTADOS[@]}"

#!/usr/bin/env bash
# =====================================================================
#  evidencias.sh — Ejecuta las verificaciones de hardening, RBAC,
#  auditoría y gestión de secretos, y guarda la salida de cada una en
#  evidencias/<fecha>/ para el informe (sección 10 y checklist 13).
#  Solo lectura, salvo la demo del trigger (3.4), que hace un UPDATE
#  y lo revierte.
# =====================================================================
set -uo pipefail
cd "$(dirname "$0")/.."
EVID="evidencias/$(date +%Y%m%d)"; mkdir -p "$EVID"
OUT="$EVID/hardening_rbac_auditoria.log"
exec > >(tee "$OUT") 2>&1

PG()   { docker compose exec -T -u postgres postgres psql -U postgres -d nutrianimales_db "$@"; }
COMO() {  # COMO <usuario> <VAR_PASSWORD> <sql>
  docker compose exec -T postgres bash -c \
    "PGPASSWORD=\"\$$2\" psql 'host=172.28.0.10 sslmode=require dbname=nutrianimales_db user=$1' -c \"$3\"" 2>&1
}
sec() { echo; echo "------------------------------------------------------------------"; echo "## $*"; echo "------------------------------------------------------------------"; }
cmd() { echo "\$ $*"; }

echo "Evidencias NutriAnimales S.A. — $(date '+%F %T')"

# ============================ HARDENING ============================
sec "Hardening #1 — Contenedores sin root"
for s in n8n pgadmin postgres nginx; do
  printf '%-9s usuario: %s\n' "$s" "$(docker compose exec -T "$s" sh -c 'id -un 2>/dev/null || id -u')"
done
echo "(postgres arranca como root solo para el entrypoint y luego baja al usuario 'postgres':)"
docker compose exec -T postgres ps -o user=,comm= -p 1

sec "Hardening #2 — Secretos en .env con permisos 600 y fuera de git"
cmd "ls -l .env"; ls -l .env | awk '{print $1, $NF}'
cmd "grep -n '^\.env' .gitignore"; grep -n '^\.env' .gitignore
cmd "git ls-files | grep -E '(^|/)\.env$' (debe estar vacío)"; git ls-files | grep -E '(^|/)\.env$' || echo "(vacío: .env no está versionado)"

sec "Hardening #3 — Red Docker aislada"
cmd "docker network inspect nutrianimales-net"
docker network inspect nutrianimales-net --format 'Nombre: {{.Name}}  Internal: {{.Internal}}  Subred: {{range .IPAM.Config}}{{.Subnet}}{{end}}'
docker network inspect nutrianimales-net --format '{{range .Containers}}  {{.Name}} {{.IPv4Address}}{{"\n"}}{{end}}'

sec "Hardening #4 — PostgreSQL sin puerto expuesto"
cmd "docker compose ps"; docker compose ps --format 'table {{.Service}}\t{{.Status}}\t{{.Ports}}'

sec "Hardening #5 y #6 — scram-sha-256 y SSL en PostgreSQL"
PG -c "SHOW password_encryption;" -c "SHOW ssl;" -c "SHOW ssl_min_protocol_version;"
PG -c "SELECT usename, ssl, version, cipher FROM pg_stat_ssl JOIN pg_stat_activity USING (pid) WHERE usename IS NOT NULL LIMIT 5;"
PG -c "SELECT type, database, user_name, address, auth_method FROM pg_hba_file_rules;"

sec "Hardening #7 — agente_ia solo lectura"
cmd "INSERT como agente_ia"
COMO agente_ia AGENTE_IA_PASSWORD "INSERT INTO gastos(categoria,descripcion,monto,fecha,aprobado_por) VALUES (1,2,3,now(),4);"
PG -c "SELECT rolname, rolconfig FROM pg_roles WHERE rolname='agente_ia';"
PG -c "SELECT privilege_type, count(*) AS tablas FROM information_schema.role_table_grants WHERE grantee='agente_ia' GROUP BY 1;"

sec "Hardening #8 y #9 — Headers de seguridad y certificado de Nginx"
cmd "curl -kI https://localhost:8443/"; curl -skI https://localhost:8443/ | grep -iE '^(HTTP|strict-transport|x-frame|x-content|content-security|referrer|permissions|server)'
cmd "curl -I http://localhost:8080/  (redirige a HTTPS)"; curl -sI http://localhost:8080/ | grep -iE '^(HTTP|location)'
cmd "openssl x509 -in nginx/certs/nginx.crt -noout -subject -dates"
openssl x509 -in nginx/certs/nginx.crt -noout -subject -issuer -dates 2>/dev/null || echo "(certificado no encontrado)"

sec "Hardening #10 — Volúmenes con permisos restringidos"
cmd "ls -ld data/* backups"; ls -ld data/* backups | awk '{print $1, $3, $NF}'

sec "Hardening #11 — Logs de auditoría de PostgreSQL"
PG -c "SELECT name, setting FROM pg_settings WHERE name IN ('logging_collector','log_statement','log_min_duration_statement','log_connections','log_disconnections','log_lock_waits') ORDER BY name;"

sec "Hardening #12 — Tabla pg_settings_baseline"
PG -c "SELECT * FROM pg_settings_baseline ORDER BY categoria, name;"
PG -c "SELECT archivo, hash_esperado FROM monitor.hash_archivos;"

# ============================== RBAC ===============================
sec "RBAC 2.2 — Los 3 roles y sus usuarios"
PG -c "SELECT r.rolname AS rol, string_agg(u.rolname, ', ') AS usuarios
       FROM pg_roles r LEFT JOIN pg_auth_members m ON m.roleid=r.oid LEFT JOIN pg_roles u ON u.oid=m.member
       WHERE r.rolname LIKE 'rol\_%' GROUP BY 1 ORDER BY 1;"

sec "RBAC 2.3 — El gerente NO ve tablas base ni auditoría"
cmd "gerente_db: SELECT * FROM auditoria_datos"; COMO gerente_db GERENTE_DB_PASSWORD "SELECT * FROM auditoria_datos LIMIT 1;"
cmd "gerente_db: SELECT * FROM clientes";        COMO gerente_db GERENTE_DB_PASSWORD "SELECT * FROM clientes LIMIT 1;"
cmd "gerente_db: SELECT de una vista de reportes"
COMO gerente_db GERENTE_DB_PASSWORD "SELECT table_name FROM information_schema.views WHERE table_schema='reportes';"

sec "RBAC — El auditor NO ve datos del negocio, sí la auditoría"
cmd "auditor_db: SELECT * FROM ventas";                COMO auditor_db AUDITOR_DB_PASSWORD "SELECT * FROM ventas LIMIT 1;"
cmd "auditor_db: SELECT count(*) FROM auditoria_datos"; COMO auditor_db AUDITOR_DB_PASSWORD "SELECT count(*) FROM auditoria_datos;"

sec "RBAC — TI no puede modificar datos del negocio"
cmd "ti_db: UPDATE clientes ..."; COMO ti_db TI_DB_PASSWORD "UPDATE clientes SET segmento=segmento WHERE id=1;"

# ========================== AUDITORÍA ==============================
sec "Auditoría 3.1 — Estructura de auditoria_datos"
PG -c "\d auditoria_datos"

sec "Auditoría 3.2 y 3.3 — Función y triggers"
PG -c "SELECT proname FROM pg_proc WHERE proname LIKE 'fn_auditoria%';"
PG -c "SELECT trigger_name, event_object_table AS tabla, string_agg(event_manipulation, ', ') AS eventos
       FROM information_schema.triggers WHERE trigger_name LIKE 'trg_auditoria%' GROUP BY 1,2 ORDER BY 2;"

sec "Auditoría 3.4 — Demostración: UPDATE queda registrado con valor antes/después"
ANT=$(PG -At -c "SELECT estado FROM ventas WHERE id=1;")
cmd "UPDATE ventas SET estado='anulada' WHERE id=1;"
PG -c "UPDATE ventas SET estado='anulada' WHERE id=1;"
PG -c "SELECT id, usuario, operacion, fecha, valor_antes->>'estado' AS antes, valor_nuevo->>'estado' AS despues
       FROM auditoria_datos WHERE tabla='ventas' ORDER BY id DESC LIMIT 1;"
cmd "Revertir: UPDATE ventas SET estado='$ANT' WHERE id=1;"
PG -c "UPDATE ventas SET estado='$ANT' WHERE id=1;"

sec "Auditoría — auditoria_datos es de solo-agregar (ni el superusuario la borra)"
cmd "DELETE FROM auditoria_datos WHERE id = 1;"; PG -c "DELETE FROM auditoria_datos WHERE id = 1;" 2>&1

sec "Historial de alertas (alertas_auditoria) — últimas 25"
PG -c "SELECT tipo, severidad, alerta, to_char(fecha,'YYYY-MM-DD HH24:MI:SS') AS fecha FROM alertas_auditoria ORDER BY fecha DESC LIMIT 25;"

# ========================== SECRETOS ===============================
sec "Secretos 6.2 / 6.3 — .env y .gitignore"
cat .gitignore

echo; echo "Evidencia guardada en: $OUT"

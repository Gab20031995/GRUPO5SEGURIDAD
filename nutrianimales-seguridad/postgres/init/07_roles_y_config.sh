#!/usr/bin/env bash
# =====================================================================
#  07_roles_y_config.sh — RBAC (sección 7) + usuarios de aplicación
#  Las contraseñas vienen del .env (no quedan escritas en el SQL),
#  a diferencia del ejemplo del enunciado.
# =====================================================================
set -euo pipefail

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname nutrianimales_db \
  -v agente_pw="$AGENTE_IA_PASSWORD" \
  -v monitor_pw="$MONITOR_PASSWORD" \
  -v gerente_pw="$GERENTE_DB_PASSWORD" \
  -v ti_pw="$TI_DB_PASSWORD" \
  -v auditor_pw="$AUDITOR_DB_PASSWORD" \
  -v chat_id="${TELEGRAM_CHAT_ID:-0}" <<'EOSQL'

-- ---------------------------------------------------------------
-- 1. Tres roles de negocio (NOLOGIN) — sección 7.1
-- ---------------------------------------------------------------
CREATE ROLE rol_gerente NOLOGIN;
CREATE ROLE rol_ti      NOLOGIN;
CREATE ROLE rol_auditor NOLOGIN;

-- Gerente: SOLO vistas de reportes. Sin tablas base ni auditoría.
GRANT CONNECT ON DATABASE nutrianimales_db TO rol_gerente;
GRANT USAGE  ON SCHEMA public, reportes TO rol_gerente;   -- USAGE no da acceso a tablas
GRANT SELECT ON ALL TABLES IN SCHEMA reportes TO rol_gerente;

-- Administrador TI: lectura de todo + INSERT en backups y alertas_auditoria
GRANT CONNECT ON DATABASE nutrianimales_db TO rol_ti;
GRANT USAGE  ON SCHEMA public, reportes TO rol_ti;
GRANT SELECT ON ALL TABLES IN SCHEMA public   TO rol_ti;
GRANT SELECT ON ALL TABLES IN SCHEMA reportes TO rol_ti;
GRANT INSERT ON backups, alertas_auditoria TO rol_ti;
GRANT USAGE  ON SEQUENCE backups_id_seq, alertas_auditoria_id_seq TO rol_ti;

-- Auditor: SOLO tablas de monitoreo + estadísticas del servidor
GRANT CONNECT ON DATABASE nutrianimales_db TO rol_auditor;
GRANT USAGE  ON SCHEMA public TO rol_auditor;
GRANT SELECT ON auditoria_datos, backups, alertas_auditoria TO rol_auditor;
GRANT pg_read_all_stats TO rol_auditor;   -- pg_stat_statements y pg_stat_activity completos

-- Usuarios con login asignados a cada rol
CREATE ROLE gerente_db LOGIN PASSWORD :'gerente_pw' IN ROLE rol_gerente;
CREATE ROLE ti_db      LOGIN PASSWORD :'ti_pw'      IN ROLE rol_ti;
CREATE ROLE auditor_db LOGIN PASSWORD :'auditor_pw' IN ROLE rol_auditor;

-- ---------------------------------------------------------------
-- 2. agente_ia — usuario del bot (SOLO LECTURA, hardening #7)
-- ---------------------------------------------------------------
CREATE ROLE agente_ia LOGIN PASSWORD :'agente_pw' CONNECTION LIMIT 5;
GRANT CONNECT ON DATABASE nutrianimales_db TO agente_ia;
GRANT USAGE  ON SCHEMA public, reportes TO agente_ia;
GRANT SELECT ON plantas, productos, materias_primas, lotes_produccion,
                ventas, clientes, control_calidad, gastos TO agente_ia;
GRANT SELECT ON ALL TABLES IN SCHEMA reportes TO agente_ia;
ALTER ROLE agente_ia SET default_transaction_read_only = on;
ALTER ROLE agente_ia SET statement_timeout = '5s';

-- ---------------------------------------------------------------
-- 3. monitor_n8n — usado por los flujos de alertas.
--    Solo puede EJECUTAR las funciones de la API de monitoreo.
-- ---------------------------------------------------------------
CREATE ROLE monitor_n8n LOGIN PASSWORD :'monitor_pw' CONNECTION LIMIT 10;
GRANT CONNECT ON DATABASE nutrianimales_db TO monitor_n8n;
GRANT USAGE ON SCHEMA monitor TO monitor_n8n;
GRANT EXECUTE ON FUNCTION monitor.ejecutar_chequeo(text),
                          monitor.registrar_alerta_externa(jsonb),
                          monitor.rol_usuario_bot(bigint),
                          monitor.registrar_bloqueo_bot(jsonb)
      TO monitor_n8n;
ALTER ROLE monitor_n8n SET statement_timeout = '20s';

-- ---------------------------------------------------------------
-- 4. Configuración: chat de Telegram para las alertas
-- ---------------------------------------------------------------
UPDATE monitor.config SET valor = :'chat_id' WHERE clave = 'telegram_chat_alertas';

-- Verificación
SELECT rolname, rolcanlogin FROM pg_roles
WHERE rolname IN ('rol_gerente','rol_ti','rol_auditor','gerente_db','ti_db','auditor_db','agente_ia','monitor_n8n')
ORDER BY 1;
EOSQL

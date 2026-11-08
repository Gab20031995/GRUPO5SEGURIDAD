-- =====================================================================
--  05_monitor.sql — Motor de detección de las 17 alertas (sección 4 y 5)
--
--  Diseño (mínimo privilegio):
--   * Cada alerta es una función monitor.chk_xx() que devuelve "hallazgos".
--   * N8N se conecta como monitor_n8n, que SOLO puede ejecutar
--     monitor.ejecutar_chequeo('R1'..'D7'). No lee tablas directamente.
--   * ejecutar_chequeo es SECURITY DEFINER: corre con los permisos del dueño
--     (postgres) para leer pg_stat_statements, pg_authid, pg_hba_file_rules,
--     logs, etc. y deduplica: la misma alerta no se repite en 60 min.
--   * Cada alerta enviada queda guardada en alertas_auditoria.
--
--  Alertas que se originan FUERA de PostgreSQL (llegan por webhook a N8N
--  y se registran con monitor.registrar_alerta_externa):
--   * H1 (UFW) y R4-SSH (fuerza bruta SSH) -> host-monitor/monitor_host.sh
-- =====================================================================
\connect nutrianimales_db

CREATE SCHEMA monitor;
REVOKE ALL ON SCHEMA monitor FROM PUBLIC;

-- ---------- Configuración ----------
CREATE TABLE monitor.config (
  clave  TEXT PRIMARY KEY,
  valor  TEXT NOT NULL,
  nota   TEXT
);
INSERT INTO monitor.config (clave, valor, nota) VALUES
 ('telegram_chat_alertas', '0',              'Lo completa 07_roles_y_config.sh con TELEGRAM_CHAT_ID'),
 ('red_docker',            '172.28.0.0/16',  'H4: red permitida'),
 ('horario_inicio',        '6',              'R3: hora de inicio laboral (0-23)'),
 ('horario_fin',           '23',             'R3: hora de fin laboral (0-23). Para la demo poner la hora actual'),
 ('r1_umbral_ms',          '1000',           'R1'),
 ('r2_umbral_conexiones',  '10',             'R2'),
 ('r4_umbral_fallos',      '5',              'R4 en ventana de 10 min'),
 ('d1_umbral_filas',       '100',            'D1'),
 ('d2_ventana_min',        '30',             'D2: ventana de comparación (para demo usar 2)'),
 ('d2_umbral_pct',         '20',             'D2'),
 ('d3_umbral_horas',       '24',             'D3'),
 ('d4_umbral_duplicados',  '5',              'D4'),
 ('d5_umbral_seg',         '30',             'D5'),
 ('d6_umbral_filas',       '50',             'D6'),
 ('d7_umbral_filas',       '1000',           'D7'),
 ('d7_tablas_sensibles',   'clientes,ventas','D7: tablas separadas por coma'),
 ('dedup_minutos',         '60',             'No repetir la misma alerta durante N minutos'),
 ('ultimo_deadlocks',      '-1',             'D5: contador interno');

CREATE OR REPLACE FUNCTION monitor.cfg(p_clave TEXT) RETURNS TEXT
LANGUAGE sql STABLE AS $$ SELECT valor FROM monitor.config WHERE clave = p_clave $$;

-- ---------- Hashes de archivos de configuración (H2) ----------
CREATE TABLE monitor.hash_archivos (
  archivo        TEXT PRIMARY KEY,
  hash_esperado  TEXT NOT NULL,
  actualizado    TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ---------- Fotos de tamaño de tablas (D2) ----------
CREATE TABLE monitor.snapshot_tablas (
  fecha  TIMESTAMPTZ NOT NULL DEFAULT now(),
  tabla  TEXT NOT NULL,
  filas  BIGINT NOT NULL
);
CREATE INDEX ON monitor.snapshot_tablas (tabla, fecha DESC);

-- ---------- Usuarios autorizados del bot de Telegram (RBAC) ----------
CREATE TABLE monitor.usuarios_bot (
  chat_id  BIGINT PRIMARY KEY,
  nombre   TEXT NOT NULL,
  rol      TEXT NOT NULL CHECK (rol IN ('gerente','ti','auditor')),
  activo   BOOLEAN NOT NULL DEFAULT true
);

-- ---------- Tipo común de hallazgo ----------
CREATE TYPE monitor.hallazgo AS (
  codigo     TEXT,   -- R1..D7
  severidad  TEXT,   -- ADVERTENCIA | CRÍTICA
  clave      TEXT,   -- llave de deduplicación
  titulo     TEXT,
  detalle    TEXT
);

-- Base de datos actual (para filtrar pg_stat_statements)
CREATE OR REPLACE FUNCTION monitor.db_oid() RETURNS OID
LANGUAGE sql STABLE AS $$ SELECT oid FROM pg_database WHERE datname = current_database() $$;

-- Consultas que NO deben contarse (las del propio monitoreo)
CREATE OR REPLACE FUNCTION monitor.es_consulta_interna(q TEXT) RETURNS BOOLEAN
LANGUAGE sql IMMUTABLE AS $$
  SELECT q ~* '(pg_stat_statements|monitor\.|pg_stat_activity|pg_catalog\.|information_schema)'
$$;

-- =====================================================================
--  RENDIMIENTO
-- =====================================================================

-- R1 — Consulta lenta (> 1 s)
CREATE OR REPLACE FUNCTION monitor.chk_r1() RETURNS SETOF monitor.hallazgo
LANGUAGE sql AS $$
  SELECT 'R1', 'ADVERTENCIA',
         'R1:' || s.queryid,
         'Consulta lenta — supera ' || monitor.cfg('r1_umbral_ms') || ' ms',
         format(E'Usuario: %s\nTiempo máximo: %s ms (umbral: %s ms)\nTiempo medio: %s ms\nEjecuciones: %s\nQuery: %s',
                r.rolname, round(s.max_exec_time::numeric, 1), monitor.cfg('r1_umbral_ms'),
                round(s.mean_exec_time::numeric, 1), s.calls, left(s.query, 300))
  FROM public.pg_stat_statements s
  JOIN pg_roles r ON r.oid = s.userid
  WHERE s.dbid = monitor.db_oid()
    AND s.max_exec_time > monitor.cfg('r1_umbral_ms')::numeric
    AND NOT monitor.es_consulta_interna(s.query)
  ORDER BY s.max_exec_time DESC
  LIMIT 5
$$;

-- R2 — Saturación de conexiones (> 10)
CREATE OR REPLACE FUNCTION monitor.chk_r2() RETURNS SETOF monitor.hallazgo
LANGUAGE sql AS $$
  WITH c AS (
    SELECT coalesce(usename::text, '?') AS u, count(*) AS n
    FROM pg_stat_activity WHERE backend_type = 'client backend'
    GROUP BY 1
  ), t AS (
    SELECT sum(n) AS total, string_agg(u || '=' || n, ', ' ORDER BY n DESC) AS det FROM c
  )
  SELECT 'R2', 'ADVERTENCIA', 'R2', 'Saturación de conexiones activas',
         format(E'Conexiones de clientes: %s (umbral: %s)\nPor usuario: %s',
                total, monitor.cfg('r2_umbral_conexiones'), det)
  FROM t WHERE total > monitor.cfg('r2_umbral_conexiones')::int
$$;

-- R3 — Conexión en horario no laboral (23:00–06:00 por defecto)
CREATE OR REPLACE FUNCTION monitor.chk_r3() RETURNS SETOF monitor.hallazgo
LANGUAGE sql AS $$
  -- Una alerta por usuario + IP (no una por conexión)
  SELECT 'R3', 'CRÍTICA',
         'R3:' || a.usename || ':' || coalesce(host(a.client_addr), 'local'),
         'Conexión en horario no laboral',
         format(E'Usuario: %s\nIP: %s\nConexiones: %s\nAplicación: %s\nPrimera conexión: %s\nHorario laboral: %s:00 a %s:00\nAcción: confirmar con el responsable; si no es legítima, pg_terminate_backend y bloquear el usuario.',
                a.usename, coalesce(host(a.client_addr), 'socket local'), count(*),
                string_agg(DISTINCT nullif(a.application_name, ''), ', '),
                to_char(min(a.backend_start) AT TIME ZONE 'America/Costa_Rica', 'YYYY-MM-DD HH24:MI:SS'),
                monitor.cfg('horario_inicio'), monitor.cfg('horario_fin'))
  FROM pg_stat_activity a
  WHERE a.backend_type = 'client backend'
    AND a.usename IS DISTINCT FROM 'monitor_n8n'
    AND a.pid <> pg_backend_pid()
    AND ( extract(hour FROM a.backend_start AT TIME ZONE 'America/Costa_Rica') <  monitor.cfg('horario_inicio')::int
       OR extract(hour FROM a.backend_start AT TIME ZONE 'America/Costa_Rica') >= monitor.cfg('horario_fin')::int )
  GROUP BY a.usename, a.client_addr
$$;

-- R4 — Intentos de autenticación fallidos en PostgreSQL (> 5 en 10 min)
--      Lee el log del servidor (logging_collector=on). La parte SSH llega por webhook.
CREATE OR REPLACE FUNCTION monitor.chk_r4() RETURNS SETOF monitor.hallazgo
LANGUAGE plpgsql AS $$
DECLARE
  v_file TEXT; v_txt TEXT; v_n INT; v_usuarios TEXT; v_ips TEXT; h monitor.hallazgo;
BEGIN
  SELECT name INTO v_file FROM pg_ls_logdir()
   WHERE name LIKE '%.log' ORDER BY modification DESC LIMIT 1;
  IF v_file IS NULL THEN RETURN; END IF;

  v_txt := pg_read_file(current_setting('log_directory') || '/' || v_file);

  SELECT count(*),
         string_agg(DISTINCT substring(l FROM 'user "([^"]+)"'), ', '),
         string_agg(DISTINCT split_part(substring(l FROM '@\S* (\S+) FATAL'), '(', 1), ', ')
    INTO v_n, v_usuarios, v_ips
  FROM regexp_split_to_table(v_txt, E'\n') AS l
  WHERE l ~ 'FATAL:\s+(password authentication failed|no pg_hba.conf entry)'
    AND substring(l FROM '^(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d)')::timestamp
        > (now() AT TIME ZONE 'America/Costa_Rica') - interval '10 minutes';

  IF v_n > monitor.cfg('r4_umbral_fallos')::int THEN
    h := ROW('R4', 'CRÍTICA', 'R4:pg',
             'Intentos de autenticación fallidos en PostgreSQL',
             format(E'Fallos en los últimos 10 min: %s (umbral: %s)\nUsuarios intentados: %s\nOrigen: %s\nAcción: revisar origen; bloquear IP o rotar credenciales.',
                    v_n, monitor.cfg('r4_umbral_fallos'), coalesce(v_usuarios, '-'), coalesce(v_ips, '-')));
    RETURN NEXT h;
  END IF;
END;
$$;

-- R5 — Cambio en parámetros de PostgreSQL (vs baseline) o ALTER SYSTEM pendiente
CREATE OR REPLACE FUNCTION monitor.chk_r5() RETURNS SETOF monitor.hallazgo
LANGUAGE sql AS $$
  WITH dif AS (
    SELECT b.name, b.valor_esperado AS esperado, s.setting AS actual, 'en uso' AS origen
    FROM public.pg_settings_baseline b JOIN pg_settings s USING (name)
    WHERE b.categoria = 'general' AND s.setting IS DISTINCT FROM b.valor_esperado
    UNION ALL
    SELECT f.name, coalesce(b.valor_esperado, '(sin baseline)'), f.setting, 'ALTER SYSTEM'
    FROM pg_file_settings f LEFT JOIN public.pg_settings_baseline b USING (name)
    WHERE f.sourcefile LIKE '%postgresql.auto.conf'
    UNION ALL
    SELECT name, '-', setting, 'pendiente de reinicio' FROM pg_settings WHERE pending_restart
  )
  SELECT 'R5', 'CRÍTICA',
         'R5:' || md5(string_agg(name || '=' || actual || '/' || origen, ',' ORDER BY name)),
         'Cambio en parámetros de postgresql.conf',
         E'Parámetros fuera de la línea base:\n' ||
         string_agg(format('• %s: esperado=%s, actual=%s [%s]', name, esperado, actual, origen), E'\n' ORDER BY name) ||
         E'\nAcción: confirmar si el cambio fue autorizado; si no, ALTER SYSTEM RESET y pg_reload_conf().'
  FROM dif
  HAVING count(*) > 0
$$;

-- =====================================================================
--  HARDENING
-- =====================================================================

-- H1 — UFW: se detecta en el host (monitor_host.sh) y llega por webhook.
CREATE OR REPLACE FUNCTION monitor.chk_h1() RETURNS SETOF monitor.hallazgo
LANGUAGE sql AS $$ SELECT NULL::text, NULL, NULL, NULL, NULL WHERE false $$;

-- H2 — pg_hba.conf o postgresql.conf modificados (hash MD5)
CREATE OR REPLACE FUNCTION monitor.chk_h2() RETURNS SETOF monitor.hallazgo
LANGUAGE sql AS $$
  SELECT 'H2', 'CRÍTICA',
         'H2:' || x.archivo || ':' || x.actual,
         'Archivo de configuración modificado',
         format(E'Archivo: %s\nHash esperado: %s\nHash actual:   %s\nAcción: revisar el cambio. Si fue autorizado: SELECT monitor.aceptar_hash(''%s'');',
                x.archivo, x.hash_esperado, x.actual, x.archivo)
  FROM (SELECT a.archivo, a.hash_esperado, md5(pg_read_file(a.archivo)) AS actual
        FROM monitor.hash_archivos a) x
  WHERE x.actual <> x.hash_esperado
$$;

-- H3 — Privilegios de agente_ia fuera de su línea base (solo SELECT)
CREATE OR REPLACE FUNCTION monitor.chk_h3() RETURNS SETOF monitor.hallazgo
LANGUAGE sql AS $$
  WITH p AS (
    SELECT format('%s en %s tabla(s) (ej.: %s)', privilege_type, count(*),
                  array_to_string((array_agg(table_schema || '.' || table_name ORDER BY table_name))[1:3], ', ')) AS d
    FROM information_schema.role_table_grants
    WHERE grantee = 'agente_ia' AND privilege_type <> 'SELECT'
    GROUP BY privilege_type
    UNION ALL
    SELECT 'Miembro del rol ' || r.rolname
    FROM pg_auth_members m
    JOIN pg_roles r ON r.oid = m.roleid
    JOIN pg_roles u ON u.oid = m.member
    WHERE u.rolname = 'agente_ia'
    UNION ALL
    SELECT 'Atributo peligroso: ' || concat_ws(', ',
             CASE WHEN rolsuper      THEN 'SUPERUSER'  END,
             CASE WHEN rolcreaterole THEN 'CREATEROLE' END,
             CASE WHEN rolcreatedb   THEN 'CREATEDB'   END,
             CASE WHEN rolbypassrls  THEN 'BYPASSRLS'  END)
    FROM pg_roles
    WHERE rolname = 'agente_ia' AND (rolsuper OR rolcreaterole OR rolcreatedb OR rolbypassrls)
    UNION ALL
    SELECT 'CREATE en el esquema ' || n.nspname
    FROM pg_namespace n
    WHERE n.nspname IN ('public', 'reportes') AND has_schema_privilege('agente_ia', n.oid, 'CREATE')
  )
  SELECT 'H3', 'CRÍTICA',
         'H3:' || md5(string_agg(d, '|' ORDER BY d)),
         'GRANT de permisos a usuario agente_ia',
         E'Privilegios fuera de la línea base (agente_ia debe ser solo lectura):\n' ||
         string_agg('• ' || d, E'\n' ORDER BY d) ||
         E'\nAcción: REVOKE inmediato y revisar el log DDL (log_statement=ddl) para ver quién hizo el GRANT.'
  FROM p
  HAVING count(*) > 0
$$;

-- H4 — Conexión desde IP fuera de la red Docker
CREATE OR REPLACE FUNCTION monitor.chk_h4() RETURNS SETOF monitor.hallazgo
LANGUAGE sql AS $$
  SELECT 'H4', 'CRÍTICA',
         'H4:' || a.pid || ':' || host(a.client_addr),
         'Conexión desde IP fuera de la red Docker',
         format(E'IP origen: %s (red permitida: %s)\nUsuario: %s\nBase: %s\nAplicación: %s\nConectado: %s\nAcción: terminar la sesión con SELECT pg_terminate_backend(%s); y revisar pg_hba.conf.',
                host(a.client_addr), monitor.cfg('red_docker'), a.usename, a.datname,
                nullif(a.application_name, ''),
                to_char(a.backend_start AT TIME ZONE 'America/Costa_Rica', 'YYYY-MM-DD HH24:MI:SS'), a.pid)
  FROM pg_stat_activity a
  WHERE a.client_addr IS NOT NULL
    AND NOT (a.client_addr << monitor.cfg('red_docker')::inet)
    AND NOT (a.client_addr << '127.0.0.0/8'::inet)
    AND a.client_addr <> '::1'::inet
$$;

-- H5 — SSL desactivado o autenticación degradada a MD5/trust
CREATE OR REPLACE FUNCTION monitor.chk_h5() RETURNS SETOF monitor.hallazgo
LANGUAGE sql AS $$
  WITH d AS (
    SELECT format('%s: esperado=%s, actual=%s', b.name, b.valor_esperado, s.setting) AS det
    FROM public.pg_settings_baseline b JOIN pg_settings s USING (name)
    WHERE b.categoria = 'seguridad' AND s.setting IS DISTINCT FROM b.valor_esperado
    UNION ALL
    SELECT format('%s (pendiente, vía ALTER SYSTEM): %s', f.name, f.setting)
    FROM pg_file_settings f JOIN public.pg_settings_baseline b USING (name)
    WHERE b.categoria = 'seguridad' AND f.sourcefile LIKE '%postgresql.auto.conf'
      AND f.setting IS DISTINCT FROM b.valor_esperado
    UNION ALL
    SELECT format('pg_hba.conf línea %s: método %s para %s', line_number, auth_method,
                  coalesce(address, type))
    FROM pg_hba_file_rules
    WHERE auth_method IN ('md5', 'trust', 'password')
    UNION ALL
    SELECT format('Usuario %s guarda contraseña MD5 (no SCRAM)', rolname)
    FROM pg_authid WHERE rolpassword LIKE 'md5%'
  )
  SELECT 'H5', 'CRÍTICA',
         'H5:' || md5(string_agg(det, '|' ORDER BY det)),
         'SSL desactivado o autenticación degradada',
         E'Diferencias contra pg_settings_baseline:\n' || string_agg('• ' || det, E'\n' ORDER BY det) ||
         E'\nAcción: restaurar ssl=on / scram-sha-256 y recargar configuración.'
  FROM d
  HAVING count(*) > 0
$$;

-- =====================================================================
--  DATOS
-- =====================================================================

-- D1 — DELETE masivo sin WHERE (> 100 filas)
CREATE OR REPLACE FUNCTION monitor.chk_d1() RETURNS SETOF monitor.hallazgo
LANGUAGE sql AS $$
  SELECT 'D1', 'CRÍTICA',
         'D1:' || s.queryid || ':' || s.calls,
         'DELETE masivo sin WHERE en tabla crítica',
         format(E'Tabla: %s\nFilas eliminadas: %s (umbral: %s)\nEjecuciones: %s\nUsuario: %s\nQuery: %s\nAcción: recuperar con valor_antes de auditoria_datos (operacion = ''DELETE'').',
                coalesce(substring(s.query FROM '(?i)delete\s+from\s+(?:only\s+)?([a-z0-9_."]+)'), '?'),
                s.rows, monitor.cfg('d1_umbral_filas'), s.calls, r.rolname, left(s.query, 300))
  FROM public.pg_stat_statements s
  JOIN pg_roles r ON r.oid = s.userid
  WHERE s.dbid = monitor.db_oid()
    AND s.query ~* '^\s*delete\s'
    AND s.query !~* '\mwhere\M'
    AND s.rows > monitor.cfg('d1_umbral_filas')::bigint
    AND NOT monitor.es_consulta_interna(s.query)
$$;

-- D2 — Crecimiento anormal de tabla (> 20 % en 30 min)
CREATE OR REPLACE FUNCTION monitor.chk_d2() RETURNS SETOF monitor.hallazgo
LANGUAGE plpgsql AS $$
DECLARE
  r RECORD; h monitor.hallazgo;
  v_min INT := monitor.cfg('d2_ventana_min')::int;
  v_pct NUMERIC := monitor.cfg('d2_umbral_pct')::numeric;
BEGIN
  -- Foto actual
  INSERT INTO monitor.snapshot_tablas (tabla, filas)
  SELECT relname, n_live_tup FROM pg_stat_user_tables WHERE schemaname = 'public';
  DELETE FROM monitor.snapshot_tablas WHERE fecha < now() - make_interval(mins => v_min * 4);

  FOR r IN
    SELECT s.relname, s.n_live_tup AS actual, o.filas AS antes, o.fecha
    FROM pg_stat_user_tables s
    JOIN LATERAL (
      SELECT t.filas, t.fecha FROM monitor.snapshot_tablas t
      WHERE t.tabla = s.relname AND t.fecha <= now() - make_interval(mins => v_min)
      ORDER BY t.fecha DESC LIMIT 1
    ) o ON true
    WHERE s.schemaname = 'public'
      AND s.relname NOT IN ('auditoria_datos', 'alertas_auditoria')
      AND o.filas >= 50
      AND s.n_live_tup > o.filas * (1 + v_pct / 100)
  LOOP
    h := ROW('D2', 'ADVERTENCIA', 'D2:' || r.relname,
             'Crecimiento anormal de tabla',
             format(E'Tabla: %s\nFilas hace %s min: %s\nFilas ahora: %s\nCrecimiento: %s %% (umbral: %s %%)\nAcción: revisar inserciones recientes en auditoria_datos.',
                    r.relname, v_min, r.antes, r.actual,
                    round((r.actual - r.antes) * 100.0 / r.antes, 1), v_pct));
    RETURN NEXT h;
  END LOOP;
END;
$$;

-- D3 — Backup obsoleto (> 24 h sin respaldo exitoso)
CREATE OR REPLACE FUNCTION monitor.chk_d3() RETURNS SETOF monitor.hallazgo
LANGUAGE sql AS $$
  SELECT 'D3', 'ADVERTENCIA', 'D3',
         'Backup obsoleto — sin respaldo reciente',
         format(E'Último backup exitoso: %s\nAntigüedad: %s (umbral: %s h)\nAcción: ejecutar scripts/backup.sh',
                coalesce(to_char(max(fecha) AT TIME ZONE 'America/Costa_Rica', 'YYYY-MM-DD HH24:MI'), 'nunca'),
                coalesce(date_trunc('minute', now() - max(fecha))::text, '-'),
                monitor.cfg('d3_umbral_horas'))
  FROM public.backups
  WHERE estado = 'exitoso'
  HAVING max(fecha) IS NULL
      OR max(fecha) < now() - make_interval(hours => monitor.cfg('d3_umbral_horas')::int)
$$;

-- D4 — Duplicados en tablas críticas (> 5 registros sobrantes)
CREATE OR REPLACE FUNCTION monitor.chk_d4() RETURNS SETOF monitor.hallazgo
LANGUAGE sql AS $$
  WITH dup AS (
    SELECT 'clientes (correo)' AS tabla, count(*) - 1 AS extra
    FROM public.clientes GROUP BY lower(correo) HAVING count(*) > 1
    UNION ALL
    SELECT 'ventas (cliente, producto, fecha, cantidad)', count(*) - 1
    FROM public.ventas GROUP BY cliente_id, producto_id, fecha, cantidad HAVING count(*) > 1
    UNION ALL
    SELECT 'productos (nombre, tipo)', count(*) - 1
    FROM public.productos GROUP BY lower(nombre), tipo HAVING count(*) > 1
  ), res AS (
    SELECT tabla, sum(extra) AS extra FROM dup GROUP BY tabla
  )
  SELECT 'D4', 'ADVERTENCIA', 'D4:' || sum(extra),
         'Duplicados en tablas críticas',
         format(E'Registros duplicados: %s (umbral: %s)\n%s\nAcción: depurar con SELECT ... GROUP BY ... HAVING COUNT(*) > 1.',
                sum(extra), monitor.cfg('d4_umbral_duplicados'),
                string_agg('• ' || tabla || ': ' || extra, E'\n'))
  FROM res
  HAVING coalesce(sum(extra), 0) > monitor.cfg('d4_umbral_duplicados')::int
$$;

-- D5 — Transacción bloqueada (> 30 s) o deadlock nuevo
CREATE OR REPLACE FUNCTION monitor.chk_d5() RETURNS SETOF monitor.hallazgo
LANGUAGE plpgsql AS $$
DECLARE
  r RECORD; h monitor.hallazgo; v_dl BIGINT; v_prev BIGINT;
BEGIN
  FOR r IN
    SELECT a.pid, a.usename, a.query_start, now() - a.query_start AS espera,
           pg_blocking_pids(a.pid) AS bloqueadores, left(a.query, 200) AS q
    FROM pg_stat_activity a
    WHERE a.wait_event_type = 'Lock'
      AND now() - a.query_start > make_interval(secs => monitor.cfg('d5_umbral_seg')::int)
  LOOP
    h := ROW('D5', 'ADVERTENCIA',
             'D5:' || r.pid || ':' || extract(epoch FROM r.query_start)::bigint,
             'Transacción bloqueada',
             format(E'PID bloqueado: %s (usuario %s)\nEsperando: %s (umbral: %s s)\nBloqueado por PID: %s\nQuery: %s\nAcción: revisar el PID bloqueador; si procede, SELECT pg_terminate_backend(pid);',
                    r.pid, r.usename, date_trunc('second', r.espera), monitor.cfg('d5_umbral_seg'),
                    array_to_string(r.bloqueadores, ', '), r.q));
    RETURN NEXT h;
  END LOOP;

  SELECT deadlocks INTO v_dl FROM pg_stat_database WHERE datname = current_database();
  v_prev := monitor.cfg('ultimo_deadlocks')::bigint;
  IF v_prev >= 0 AND v_dl > v_prev THEN
    h := ROW('D5', 'ADVERTENCIA', 'D5:deadlock:' || v_dl, 'Deadlock detectado',
             format(E'Deadlocks nuevos: %s (total acumulado: %s)\nAcción: revisar el log de PostgreSQL (log_lock_waits=on).',
                    v_dl - v_prev, v_dl));
    RETURN NEXT h;
  END IF;
  UPDATE monitor.config SET valor = v_dl::text WHERE clave = 'ultimo_deadlocks';
END;
$$;

-- D6 — UPDATE masivo sin WHERE (> 50 filas) — modificación silenciosa
CREATE OR REPLACE FUNCTION monitor.chk_d6() RETURNS SETOF monitor.hallazgo
LANGUAGE sql AS $$
  SELECT 'D6', 'CRÍTICA',
         'D6:' || s.queryid || ':' || s.calls,
         'UPDATE masivo sin WHERE detectado',
         format(E'Tabla: %s\nFilas modificadas: %s (umbral: %s)\nEjecuciones: %s\nUsuario: %s\nQuery: %s\nAcción: verificar intención. Consultar auditoria_datos para ver valor_antes y revertir.',
                coalesce(substring(s.query FROM '(?i)update\s+(?:only\s+)?([a-z0-9_."]+)'), '?'),
                s.rows, monitor.cfg('d6_umbral_filas'), s.calls, r.rolname, left(s.query, 300))
  FROM public.pg_stat_statements s
  JOIN pg_roles r ON r.oid = s.userid
  WHERE s.dbid = monitor.db_oid()
    AND s.query ~* '^\s*update\s'
    AND s.query !~* '\mwhere\M'
    AND s.rows > monitor.cfg('d6_umbral_filas')::bigint
    AND NOT monitor.es_consulta_interna(s.query)
$$;

-- D7 — Exfiltración: SELECT masivo en tabla sensible (> 1 000 filas por ejecución)
--      Corrige el error de precedencia del enunciado (OR sin paréntesis).
CREATE OR REPLACE FUNCTION monitor.chk_d7() RETURNS SETOF monitor.hallazgo
LANGUAGE sql AS $$
  SELECT 'D7', 'CRÍTICA',
         'D7:' || s.queryid || ':' || s.calls,
         'Posible exfiltración de datos detectada',
         format(E'Tabla: %s\nFilas retornadas por ejecución: %s (umbral: %s)\nEjecuciones: %s\nUsuario: %s\nQuery: %s\nAcción: verificar si es consulta legítima. Revisar logs de acceso de N8N; si no lo es, bloquear al usuario (ALTER ROLE ... NOLOGIN) y rotar su contraseña.',
                coalesce(substring(s.query FROM '(?i)from\s+(?:public\.)?([a-z0-9_]+)'), '?'),
                round(s.rows::numeric / greatest(s.calls, 1)), monitor.cfg('d7_umbral_filas'),
                s.calls, r.rolname, left(s.query, 300))
  FROM public.pg_stat_statements s
  JOIN pg_roles r ON r.oid = s.userid
  WHERE s.dbid = monitor.db_oid()
    AND s.query ~* '^\s*select'
    AND s.query ~* ('\mfrom\s+(public\.)?(' || replace(monitor.cfg('d7_tablas_sensibles'), ',', '|') || ')\M')
    AND s.rows::numeric / greatest(s.calls, 1) > monitor.cfg('d7_umbral_filas')::numeric
    AND NOT monitor.es_consulta_interna(s.query)
$$;

-- =====================================================================
--  EMISIÓN, DEDUPLICACIÓN Y API PARA N8N
-- =====================================================================

-- Formatea un hallazgo, lo guarda en alertas_auditoria y lo devuelve
-- solo si no se envió la misma clave en los últimos N minutos.
CREATE OR REPLACE FUNCTION monitor.emitir(h monitor.hallazgo)
RETURNS TABLE (codigo TEXT, severidad TEXT, chat_id TEXT, texto TEXT)
LANGUAGE plpgsql AS $$
#variable_conflict use_column
BEGIN
  IF h.codigo IS NULL THEN RETURN; END IF;
  IF EXISTS (SELECT 1 FROM public.alertas_auditoria a
             WHERE a.clave = h.clave
               AND a.fecha > now() - make_interval(mins => monitor.cfg('dedup_minutos')::int)) THEN
    RETURN;
  END IF;

  INSERT INTO public.alertas_auditoria (tipo, alerta, mensaje, severidad, clave)
  VALUES (h.codigo, left(h.titulo, 150), h.detalle, h.severidad, left(h.clave, 200));

  codigo    := h.codigo;
  severidad := h.severidad;
  chat_id   := monitor.cfg('telegram_chat_alertas');
  texto     := format(E'%s - NutriAnimales S.A. | Lead University BCD 9220\nAlerta %s: %s\nFecha: %s\n%s\nSeveridad: %s',
                      CASE WHEN h.severidad = 'CRÍTICA' THEN '🚨 ALERTA CRÍTICA' ELSE '⚠️ ADVERTENCIA' END,
                      h.codigo, h.titulo,
                      to_char(now() AT TIME ZONE 'America/Costa_Rica', 'YYYY-MM-DD HH24:MI:SS'),
                      h.detalle, h.severidad);
  RETURN NEXT;
END;
$$;

-- Punto de entrada para N8N: un nodo por alerta llama a esta función.
CREATE OR REPLACE FUNCTION monitor.ejecutar_chequeo(p_codigo TEXT)
RETURNS TABLE (codigo TEXT, severidad TEXT, chat_id TEXT, texto TEXT)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = monitor, public, pg_catalog
AS $$
DECLARE h monitor.hallazgo;
BEGIN
  IF p_codigo IS NULL OR p_codigo !~ '^(R[1-5]|H[1-5]|D[1-7])$' THEN
    RAISE EXCEPTION 'Código de alerta inválido: %', p_codigo;
  END IF;
  FOR h IN EXECUTE format('SELECT * FROM monitor.%I()', 'chk_' || lower(p_codigo)) LOOP
    RETURN QUERY SELECT * FROM monitor.emitir(h);
  END LOOP;
END;
$$;

-- Alertas que vienen del host (H1 UFW, R4 SSH) vía webhook de N8N.
CREATE OR REPLACE FUNCTION monitor.registrar_alerta_externa(p JSONB)
RETURNS TABLE (codigo TEXT, severidad TEXT, chat_id TEXT, texto TEXT)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = monitor, public, pg_catalog
AS $$
DECLARE h monitor.hallazgo;
BEGIN
  IF coalesce(p->>'codigo', '') !~ '^(H1|R4)$' THEN
    RAISE EXCEPTION 'Alerta externa no permitida: %', p->>'codigo';
  END IF;
  h := ROW(p->>'codigo',
           CASE WHEN p->>'severidad' = 'ADVERTENCIA' THEN 'ADVERTENCIA' ELSE 'CRÍTICA' END,
           left(coalesce(p->>'clave', p->>'codigo'), 150),
           left(coalesce(p->>'titulo', 'Alerta del host'), 150),
           left(coalesce(p->>'detalle', ''), 3000));
  RETURN QUERY SELECT * FROM monitor.emitir(h);
END;
$$;

-- Bot de Telegram: rol del usuario (NULL si no está autorizado)
CREATE OR REPLACE FUNCTION monitor.rol_usuario_bot(p_chat_id BIGINT)
RETURNS TEXT
LANGUAGE sql STABLE
SECURITY DEFINER
SET search_path = monitor, pg_catalog
AS $$ SELECT rol FROM monitor.usuarios_bot WHERE chat_id = p_chat_id AND activo $$;

-- Bot de Telegram: registra intentos bloqueados (A2 — SQL Injection)
CREATE OR REPLACE FUNCTION monitor.registrar_bloqueo_bot(p JSONB)
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = monitor, public, pg_catalog
AS $$
DECLARE v_id INTEGER;
BEGIN
  INSERT INTO public.auditoria_datos (tabla, operacion, usuario, fila_id, valor_antes, valor_nuevo)
  VALUES ('telegram_bot', 'BLOQUEO',
          'telegram:' || coalesce(p->>'usuario', '?') || ' (' || coalesce(p->>'chat_id', '?') || ')',
          NULL,
          NULL,
          jsonb_build_object('mensaje', left(p->>'texto', 500),
                             'motivo',  p->>'motivo',
                             'origen',  'filtro anti-SQLi de N8N'))
  RETURNING id INTO v_id;
  RETURN v_id;
END;
$$;

-- Administración (solo superusuario): aceptar un cambio legítimo de archivo
CREATE OR REPLACE FUNCTION monitor.aceptar_hash(p_archivo TEXT)
RETURNS TEXT LANGUAGE sql AS $$
  UPDATE monitor.hash_archivos
     SET hash_esperado = md5(pg_read_file(p_archivo)), actualizado = now()
   WHERE archivo = p_archivo
  RETURNING hash_esperado
$$;

-- Nadie más que el dueño ejecuta las funciones internas
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA monitor FROM PUBLIC;

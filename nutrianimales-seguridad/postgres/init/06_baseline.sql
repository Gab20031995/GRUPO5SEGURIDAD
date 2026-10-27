-- =====================================================================
--  06_baseline.sql — Línea base de configuración (hardening #12)
--  Los valores se escriben explícitamente (no se copian de pg_settings)
--  porque durante la inicialización el servidor temporal corre con
--  listen_addresses='' y daría una línea base incorrecta.
-- =====================================================================
\connect nutrianimales_db

INSERT INTO pg_settings_baseline (name, valor_esperado, categoria, descripcion) VALUES
 -- Seguridad (alerta H5)
 ('ssl',                        'on',                  'seguridad', 'TLS obligatorio'),
 ('password_encryption',        'scram-sha-256',       'seguridad', 'Nunca md5'),
 ('ssl_min_protocol_version',   'TLSv1.2',             'seguridad', 'Sin TLS 1.0/1.1'),
 ('log_connections',            'on',                  'seguridad', 'Trazabilidad de accesos'),
 ('log_disconnections',         'on',                  'seguridad', 'Trazabilidad de accesos'),
 ('log_statement',              'ddl',                 'seguridad', 'Registrar GRANT/ALTER/DROP'),
 ('logging_collector',          'on',                  'seguridad', 'Necesario para R4'),
 ('hba_file',                   '/etc/postgresql/pg_hba.conf', 'seguridad', 'pg_hba endurecido'),
 -- Generales (alerta R5)
 ('listen_addresses',           '*',                   'general', 'Solo dentro de la red Docker'),
 ('port',                       '5432',                'general', NULL),
 ('max_connections',            '50',                  'general', NULL),
 ('shared_preload_libraries',   'pg_stat_statements',  'general', 'Requerido por R1/D1/D6/D7'),
 ('log_min_duration_statement', '1000',                'general', 'Hardening #11'),
 ('TimeZone',                   'America/Costa_Rica',  'general', 'Requerido por R3'),
 ('log_lock_waits',             'on',                  'general', 'Requerido por D5'),
 ('deadlock_timeout',           '1000',                'general', NULL);

-- Hashes MD5 de los archivos de configuración (alerta H2)
INSERT INTO monitor.hash_archivos (archivo, hash_esperado)
SELECT f, md5(pg_read_file(f))
FROM unnest(ARRAY['/etc/postgresql/postgresql.conf', '/etc/postgresql/pg_hba.conf']) AS f;

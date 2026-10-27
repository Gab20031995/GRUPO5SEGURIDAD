-- =====================================================================
--  01_schema.sql — Modelo de datos de NutriAnimales S.A. (sección 11)
-- =====================================================================
\connect nutrianimales_db

CREATE EXTENSION IF NOT EXISTS pg_stat_statements;

-- PostgreSQL 15+ ya no da CREATE en public a todos; lo reforzamos.
REVOKE ALL ON SCHEMA public FROM PUBLIC;
REVOKE CONNECT, TEMPORARY ON DATABASE nutrianimales_db FROM PUBLIC;

CREATE TABLE plantas (
  id                    SERIAL PRIMARY KEY,
  nombre                VARCHAR(100) NOT NULL,
  ubicacion             VARCHAR(150) NOT NULL,
  capacidad_produccion  NUMERIC(12,2) NOT NULL,        -- toneladas/mes
  estado                VARCHAR(20) NOT NULL DEFAULT 'activa'
                        CHECK (estado IN ('activa','mantenimiento','inactiva'))
);

CREATE TABLE productos (
  id               SERIAL PRIMARY KEY,
  codigo           VARCHAR(20) NOT NULL UNIQUE,
  nombre           VARCHAR(120) NOT NULL,
  tipo             VARCHAR(20) NOT NULL CHECK (tipo IN ('aves','cerdos','ganado','peces')),
  precio_unitario  NUMERIC(12,2) NOT NULL CHECK (precio_unitario > 0),  -- colones por saco 46 kg
  activo           BOOLEAN NOT NULL DEFAULT true
);

CREATE TABLE materias_primas (
  id            SERIAL PRIMARY KEY,
  nombre        VARCHAR(120) NOT NULL,
  categoria     VARCHAR(50)  NOT NULL,
  stock_actual  NUMERIC(12,2) NOT NULL,              -- kg
  stock_minimo  NUMERIC(12,2) NOT NULL,
  proveedor     VARCHAR(120) NOT NULL
);

CREATE TABLE lotes_produccion (
  id                  SERIAL PRIMARY KEY,
  codigo              VARCHAR(30) NOT NULL UNIQUE,
  planta_id           INTEGER NOT NULL REFERENCES plantas(id),
  producto_id         INTEGER NOT NULL REFERENCES productos(id),
  cantidad_producida  NUMERIC(12,2) NOT NULL,        -- sacos
  fecha_inicio        TIMESTAMP NOT NULL,
  estado              VARCHAR(20) NOT NULL
                      CHECK (estado IN ('planificado','en_proceso','completado','cancelado'))
);

CREATE TABLE clientes (
  id        SERIAL PRIMARY KEY,
  nombre    VARCHAR(150) NOT NULL,
  tipo      VARCHAR(20) NOT NULL CHECK (tipo IN ('distribuidor','empresa','persona')),
  correo    VARCHAR(150) NOT NULL,
  segmento  VARCHAR(30) NOT NULL
);

CREATE TABLE ventas (
  id           SERIAL PRIMARY KEY,
  cliente_id   INTEGER NOT NULL REFERENCES clientes(id),
  producto_id  INTEGER NOT NULL REFERENCES productos(id),
  cantidad     INTEGER NOT NULL CHECK (cantidad > 0),
  precio_total NUMERIC(14,2) NOT NULL,
  fecha        TIMESTAMP NOT NULL,
  estado       VARCHAR(20) NOT NULL CHECK (estado IN ('pendiente','despachada','pagada','anulada'))
);

CREATE TABLE control_calidad (
  id              SERIAL PRIMARY KEY,
  lote_id         INTEGER NOT NULL REFERENCES lotes_produccion(id),
  parametro       VARCHAR(50) NOT NULL,
  valor_obtenido  NUMERIC(8,2) NOT NULL,
  valor_esperado  NUMERIC(8,2) NOT NULL,
  aprobado        BOOLEAN NOT NULL
);

CREATE TABLE gastos (
  id            SERIAL PRIMARY KEY,
  categoria     VARCHAR(50) NOT NULL,
  descripcion   VARCHAR(200) NOT NULL,
  monto         NUMERIC(14,2) NOT NULL,
  fecha         DATE NOT NULL,
  aprobado_por  VARCHAR(100) NOT NULL
);

-- ---------- Tablas de seguridad / monitoreo ----------
CREATE TABLE backups (
  id      SERIAL PRIMARY KEY,
  fecha   TIMESTAMPTZ NOT NULL DEFAULT now(),
  estado  VARCHAR(20) NOT NULL CHECK (estado IN ('exitoso','fallido')),
  ruta    VARCHAR(255) NOT NULL,
  tamano_bytes BIGINT
);

CREATE TABLE alertas_auditoria (
  id         SERIAL PRIMARY KEY,
  tipo       VARCHAR(5)   NOT NULL,          -- R1..R5, H1..H5, D1..D7
  alerta     VARCHAR(150) NOT NULL,
  mensaje    TEXT         NOT NULL,
  fecha      TIMESTAMPTZ  NOT NULL DEFAULT now(),
  severidad  VARCHAR(15)  NOT NULL CHECK (severidad IN ('ADVERTENCIA','CRÍTICA')),
  clave      VARCHAR(200) NOT NULL           -- evita alertas repetidas (deduplicación)
);
CREATE INDEX idx_alertas_clave_fecha ON alertas_auditoria (clave, fecha DESC);

CREATE TABLE pg_settings_baseline (
  name            TEXT PRIMARY KEY,
  valor_esperado  TEXT NOT NULL,
  categoria       TEXT NOT NULL CHECK (categoria IN ('seguridad','general')),
  descripcion     TEXT
);

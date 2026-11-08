-- =====================================================================
--  03_auditoria.sql — Triggers de auditoría (sección 6)
--  Mejoras sobre la versión del enunciado:
--   * SECURITY DEFINER: la auditoría se escribe aunque el usuario que modifica
--     no tenga permiso sobre auditoria_datos.
--   * Se registra session_user (el usuario REAL que se conectó). Dentro de una
--     función SECURITY DEFINER current_user sería el dueño (postgres).
--   * auditoria_datos es de solo-agregar: UPDATE/DELETE sobre ella se bloquean.
--   * TRUNCATE también queda registrado (los triggers por fila no lo ven).
-- =====================================================================
\connect nutrianimales_db

CREATE TABLE auditoria_datos (
  id          SERIAL PRIMARY KEY,
  tabla       VARCHAR(100) NOT NULL,
  operacion   VARCHAR(10)  NOT NULL,   -- INSERT, UPDATE, DELETE, TRUNCATE, BLOQUEO
  usuario     VARCHAR(100) DEFAULT session_user,
  fecha       TIMESTAMP    DEFAULT NOW(),
  ip_cliente  INET         DEFAULT inet_client_addr(),
  fila_id     INTEGER,
  valor_antes JSONB,
  valor_nuevo JSONB
);

CREATE INDEX idx_audit_tabla   ON auditoria_datos(tabla);
CREATE INDEX idx_audit_usuario ON auditoria_datos(usuario);
CREATE INDEX idx_audit_fecha   ON auditoria_datos(fecha);

-- ---------- Función genérica (UPDATE / DELETE / INSERT) ----------
CREATE OR REPLACE FUNCTION fn_auditoria()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    INSERT INTO auditoria_datos (tabla, operacion, usuario, fila_id, valor_antes, valor_nuevo)
    VALUES (TG_TABLE_NAME, 'DELETE', session_user, OLD.id, to_jsonb(OLD), NULL);
    RETURN OLD;
  ELSIF TG_OP = 'UPDATE' THEN
    INSERT INTO auditoria_datos (tabla, operacion, usuario, fila_id, valor_antes, valor_nuevo)
    VALUES (TG_TABLE_NAME, 'UPDATE', session_user, NEW.id, to_jsonb(OLD), to_jsonb(NEW));
    RETURN NEW;
  ELSIF TG_OP = 'INSERT' THEN
    INSERT INTO auditoria_datos (tabla, operacion, usuario, fila_id, valor_antes, valor_nuevo)
    VALUES (TG_TABLE_NAME, 'INSERT', session_user, NEW.id, NULL, to_jsonb(NEW));
    RETURN NEW;
  END IF;
  RETURN NULL;
END;
$$;

-- ---------- TRUNCATE (nivel sentencia) ----------
CREATE OR REPLACE FUNCTION fn_auditoria_truncate()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
BEGIN
  INSERT INTO auditoria_datos (tabla, operacion, usuario, fila_id, valor_antes, valor_nuevo)
  VALUES (TG_TABLE_NAME, 'TRUNCATE', session_user, NULL, NULL, NULL);
  RETURN NULL;
END;
$$;

-- ---------- auditoria_datos es inmutable ----------
CREATE OR REPLACE FUNCTION fn_auditoria_inmutable()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  RAISE EXCEPTION 'auditoria_datos es de solo-agregar: % no permitido (usuario %)', TG_OP, session_user
    USING ERRCODE = 'insufficient_privilege';
END;
$$;

CREATE TRIGGER trg_auditoria_inmutable
  BEFORE UPDATE OR DELETE ON auditoria_datos
  FOR EACH ROW EXECUTE FUNCTION fn_auditoria_inmutable();
CREATE TRIGGER trg_auditoria_inmutable_trunc
  BEFORE TRUNCATE ON auditoria_datos
  FOR EACH STATEMENT EXECUTE FUNCTION fn_auditoria_inmutable();

-- ---------- Activar triggers en las 4 tablas críticas ----------
CREATE TRIGGER trg_auditoria_lotes
  AFTER INSERT OR UPDATE OR DELETE ON lotes_produccion
  FOR EACH ROW EXECUTE FUNCTION fn_auditoria();

CREATE TRIGGER trg_auditoria_ventas
  AFTER INSERT OR UPDATE OR DELETE ON ventas
  FOR EACH ROW EXECUTE FUNCTION fn_auditoria();

CREATE TRIGGER trg_auditoria_clientes
  AFTER INSERT OR UPDATE OR DELETE ON clientes
  FOR EACH ROW EXECUTE FUNCTION fn_auditoria();

CREATE TRIGGER trg_auditoria_formulas
  AFTER INSERT OR UPDATE OR DELETE ON productos
  FOR EACH ROW EXECUTE FUNCTION fn_auditoria();

-- TRUNCATE en las mismas 4 tablas
CREATE TRIGGER trg_auditoria_lotes_trunc    AFTER TRUNCATE ON lotes_produccion FOR EACH STATEMENT EXECUTE FUNCTION fn_auditoria_truncate();
CREATE TRIGGER trg_auditoria_ventas_trunc   AFTER TRUNCATE ON ventas           FOR EACH STATEMENT EXECUTE FUNCTION fn_auditoria_truncate();
CREATE TRIGGER trg_auditoria_clientes_trunc AFTER TRUNCATE ON clientes         FOR EACH STATEMENT EXECUTE FUNCTION fn_auditoria_truncate();
CREATE TRIGGER trg_auditoria_formulas_trunc AFTER TRUNCATE ON productos        FOR EACH STATEMENT EXECUTE FUNCTION fn_auditoria_truncate();

REVOKE ALL ON FUNCTION fn_auditoria(), fn_auditoria_truncate() FROM PUBLIC;

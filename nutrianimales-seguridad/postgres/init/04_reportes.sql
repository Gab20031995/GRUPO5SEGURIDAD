-- =====================================================================
--  04_reportes.sql — Vistas de reportes para la gerencia y el bot
--  rol_gerente SOLO ve estas vistas (sección 7.1), nunca tablas base
--  ni auditoría. Las vistas no exponen correos de clientes.
-- =====================================================================
\connect nutrianimales_db

CREATE SCHEMA reportes;

CREATE VIEW reportes.v_ventas_mensuales AS
SELECT date_trunc('month', v.fecha)::date AS mes,
       p.tipo                              AS linea,
       count(*)                            AS num_ventas,
       sum(v.cantidad)                     AS sacos,
       round(sum(v.precio_total), 2)       AS monto_total
FROM ventas v JOIN productos p ON p.id = v.producto_id
WHERE v.estado <> 'anulada'
GROUP BY 1, 2;

CREATE VIEW reportes.v_top_clientes AS
SELECT c.id AS cliente_id, c.nombre, c.tipo, c.segmento,
       count(v.id) AS num_compras,
       round(sum(v.precio_total), 2) AS monto_total
FROM clientes c JOIN ventas v ON v.cliente_id = c.id
WHERE v.estado <> 'anulada'
GROUP BY c.id, c.nombre, c.tipo, c.segmento;

CREATE VIEW reportes.v_produccion_por_planta AS
SELECT pl.nombre AS planta, date_trunc('month', l.fecha_inicio)::date AS mes,
       l.estado, count(*) AS lotes, round(sum(l.cantidad_producida), 2) AS sacos
FROM lotes_produccion l JOIN plantas pl ON pl.id = l.planta_id
GROUP BY 1, 2, 3;

CREATE VIEW reportes.v_inventario_critico AS
SELECT nombre, categoria, stock_actual, stock_minimo, proveedor,
       stock_actual < stock_minimo AS bajo_minimo
FROM materias_primas;

CREATE VIEW reportes.v_calidad_por_lote AS
SELECT l.codigo AS lote, pr.nombre AS producto, q.parametro,
       q.valor_obtenido, q.valor_esperado, q.aprobado
FROM control_calidad q
JOIN lotes_produccion l ON l.id = q.lote_id
JOIN productos pr ON pr.id = l.producto_id;

CREATE VIEW reportes.v_gastos_mensuales AS
SELECT date_trunc('month', fecha)::date AS mes, categoria,
       round(sum(monto), 2) AS monto_total, count(*) AS registros
FROM gastos GROUP BY 1, 2;

-- =====================================================================
--  02_seed.sql — Datos sintéticos (por encima de los mínimos de la sección 11)
--  Se carga ANTES de activar los triggers para no llenar auditoria_datos.
--  clientes = 2 000 y ventas = 5 000 para que el escenario D7/A5 supere 1 000 filas.
-- =====================================================================
\connect nutrianimales_db
SELECT setseed(0.2026);

INSERT INTO plantas (nombre, ubicacion, capacidad_produccion, estado) VALUES
 ('Planta Cartago',  'Cartago, Zona Industrial de Guadalupe', 4200, 'activa'),
 ('Planta Alajuela', 'Alajuela, El Coyol',                    5600, 'activa'),
 ('Planta Heredia',  'Heredia, Barreal',                      3100, 'mantenimiento');

-- 60 productos
INSERT INTO productos (codigo, nombre, tipo, precio_unitario, activo)
SELECT 'NA-' || lpad(g::text, 4, '0'),
       (ARRAY['Iniciador','Crecimiento','Engorde','Finalizador','Reproductoras','Premium'])[1 + (g % 6)]
         || ' ' || initcap(t.tipo) || ' ' || g,
       t.tipo,
       round((9000 + random() * 16000)::numeric, 2),
       random() > 0.08
FROM generate_series(1, 60) g
CROSS JOIN LATERAL (SELECT (ARRAY['aves','cerdos','ganado','peces'])[1 + (g % 4)] AS tipo) t;

-- 120 materias primas
INSERT INTO materias_primas (nombre, categoria, stock_actual, stock_minimo, proveedor)
SELECT (ARRAY['Maíz amarillo','Harina de soya','Sorgo','Melaza','Harina de pescado','Carbonato de calcio',
              'Fosfato dicálcico','Sal mineral','Premezcla vitamínica','Aceite de palma','Salvado de trigo','DDGS'])[1 + (g % 12)]
         || ' lote ' || g,
       (ARRAY['granos','proteínas','energéticos','minerales','aditivos'])[1 + (g % 5)],
       round((random() * 90000)::numeric, 2),
       round((5000 + random() * 15000)::numeric, 2),
       (ARRAY['Granos del Pacífico','Importadora Central','Agroinsumos CR','Molinos del Valle','NutriTrade Ltda'])[1 + (g % 5)]
FROM generate_series(1, 120) g;

-- 600 lotes
INSERT INTO lotes_produccion (codigo, planta_id, producto_id, cantidad_producida, fecha_inicio, estado)
SELECT 'L-2026-' || lpad(g::text, 5, '0'),
       1 + (g % 3),
       1 + floor(random() * 60)::int,
       round((200 + random() * 1800)::numeric, 2),
       timestamp '2026-01-05 06:00' + (g * interval '11 hours'),
       (ARRAY['completado','completado','completado','en_proceso','planificado','cancelado'])[1 + floor(random() * 6)::int]
FROM generate_series(1, 600) g;

-- 2 000 clientes
INSERT INTO clientes (nombre, tipo, correo, segmento)
SELECT CASE WHEN t.tipo = 'persona'
            THEN (ARRAY['Ana','Luis','María','Carlos','Sofía','Jorge','Valeria','Andrés'])[1 + (g % 8)] || ' '
              || (ARRAY['Mora','Rojas','Jiménez','Vargas','Solís','Araya','Castro','Quesada'])[1 + ((g / 8) % 8)]
            ELSE (ARRAY['Agropecuaria','Distribuidora','Granja','Hacienda','Acuícola','Porcina'])[1 + (g % 6)]
              || ' ' || (ARRAY['El Roble','San José','La Esperanza','Los Ángeles','Santa Rosa','El Valle'])[1 + ((g / 6) % 6)]
              || ' #' || g
       END,
       t.tipo,
       'cliente' || g || '@correo.cr',
       (ARRAY['avícola','porcino','bovino','acuícola','mixto'])[1 + (g % 5)]
FROM generate_series(1, 2000) g
CROSS JOIN LATERAL (SELECT (ARRAY['distribuidor','empresa','persona','empresa'])[1 + (g % 4)] AS tipo) t;

-- 5 000 ventas
INSERT INTO ventas (cliente_id, producto_id, cantidad, precio_total, fecha, estado)
SELECT c, p, q, round(q * (SELECT precio_unitario FROM productos WHERE id = p), 2),
       timestamp '2026-01-02 07:00' + (g * interval '71 minutes') + (random() * interval '50 minutes'),
       (ARRAY['pagada','pagada','despachada','pendiente','anulada'])[1 + floor(random() * 5)::int]
FROM (SELECT g,
             1 + floor(random() * 2000)::int AS c,
             1 + floor(random() * 60)::int   AS p,
             1 + floor(random() * 120)::int  AS q
      FROM generate_series(1, 5000) g) s;

-- 360 controles de calidad
INSERT INTO control_calidad (lote_id, parametro, valor_obtenido, valor_esperado, aprobado)
SELECT l, par, obt, esp, abs(obt - esp) <= esp * 0.05
FROM (SELECT 1 + floor(random() * 600)::int AS l,
             x.par, x.esp,
             round((x.esp * (0.92 + random() * 0.14))::numeric, 2) AS obt
      FROM generate_series(1, 360) g
      CROSS JOIN LATERAL (SELECT (ARRAY['proteína %','humedad %','grasa %','fibra %','cenizas %'])[1 + (g % 5)] AS par,
                                 (ARRAY[18.0, 12.0, 4.5, 6.0, 7.0])[1 + (g % 5)]::numeric AS esp) x) s;

-- 240 gastos
INSERT INTO gastos (categoria, descripcion, monto, fecha, aprobado_por)
SELECT (ARRAY['energía','mantenimiento','transporte','planilla','insumos','tecnología'])[1 + (g % 6)],
       'Gasto operativo ' || g,
       round((50000 + random() * 4500000)::numeric, 2),
       date '2026-01-01' + (g % 290),
       (ARRAY['Gerencia General','Gerencia Financiera','Jefatura de Planta','Gerencia TI'])[1 + (g % 4)]
FROM generate_series(1, 240) g;

ANALYZE;

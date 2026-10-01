-- =====================================================================
-- tp_desnormalizacion_top_categorias.sql
-- TPI Base de Datos - Food Store
-- TP Unidad 4 - Parte 2: desnormalizacion controlada
--                        "Top 5 de categorias por monto vendido en el dia"
--
-- Requiere: schema.sql, objects.sql, restricciones_negocio.sql, indices.sql y
-- data.sql (Semana 5, con su volumen) ya ejecutados sobre una COPIA de trabajo.
-- Protocolo de la catedra: copia + BEGIN/ROLLBACK para pruebas + pg_dump previo
-- (este script contiene DDL).
--
-- Patron elegido: TABLA RESUMEN (agregado precalculado) mantenida por
-- DISPARADORES, en lugar de vista materializada. Motivos (detalle en el informe):
--   * el reporte es "en tiempo real" y se consulta muchas veces por minuto: una
--     vista materializada devuelve datos viejos hasta el proximo REFRESH, y
--     REFRESH recalcula TODO el historial aunque solo cambie el dia de hoy;
--   * la tabla resumen se actualiza en la misma transaccion que la venta, con
--     un costo proporcional a las filas modificadas;
--   * es reversible sin perdida: es redundancia pura, la fuente de verdad sigue
--     intacta y la tabla se reconstruye con una sola consulta.
--
-- Adaptacion de nombres: la consigna escribe c.nombre, dp.subtotal, ped.fecha;
-- el esquema real usa nombre_categoria, subtotal_detallepedido, fecha_pedido.
-- =====================================================================


-- ---------------------------------------------------------------------
-- 0. VOLUMEN (OPCIONAL, solo en la copia de trabajo, ~20 s)
--    La consigna pide una instancia "razonablemente poblada". Con los ~5.000
--    pedidos de la Semana 5 repartidos en 2 anios, "hoy" tiene muy pocas filas.
--    Se agregan 150.000 pedidos de los ultimos 60 dias (~2.500 por dia) con 2
--    detalles cada uno, y un 2 % de pedidos dados de baja (soft delete) para
--    que la auditoria final no sea trivial.
-- ---------------------------------------------------------------------
BEGIN;

WITH nuevos AS (
    INSERT INTO pedido (fecha_pedido, estado_pedido, forma_pago, usuario_id, eliminado)
    SELECT (CURRENT_DATE - (g % 60))::DATE,
           (ARRAY['PENDIENTE','CONFIRMADO','TERMINADO','CANCELADO'])[1 + (g % 4)]::estado_pedido,
           (ARRAY['TARJETA','TRANSFERENCIA','EFECTIVO'])[1 + (g % 3)]::forma_pago,
           2 + (g % 3),                         -- usuarios vigentes 2, 3 y 4
           FALSE
    FROM   generate_series(1, 150000) AS g
    RETURNING id_pedido
)
INSERT INTO detalle_pedido (cantidad_detallepedido, precio_unitario,
                            subtotal_detallepedido, pedido_id, producto_id)
SELECT 1 + (n.id_pedido % 4), pr.precio_producto,
       (1 + (n.id_pedido % 4)) * pr.precio_producto, n.id_pedido, pr.id_producto
FROM   nuevos n
JOIN   producto pr ON pr.id_producto = (n.id_pedido % 13) + 1          -- productos 1..13
UNION ALL
SELECT 1 + ((n.id_pedido + 3) % 4), pr.precio_producto,
       (1 + ((n.id_pedido + 3) % 4)) * pr.precio_producto, n.id_pedido, pr.id_producto
FROM   nuevos n
JOIN   producto pr ON pr.id_producto = ((n.id_pedido + 5) % 13) + 1;   -- siempre distinto al anterior

-- Baja logica de ~2 % de los pedidos recientes (detalle primero, pedido despues).
UPDATE detalle_pedido SET eliminado = TRUE
WHERE  pedido_id IN (SELECT id_pedido FROM pedido
                     WHERE  fecha_pedido >= CURRENT_DATE - 59 AND id_pedido % 50 = 0);
UPDATE pedido SET eliminado = TRUE
WHERE  fecha_pedido >= CURRENT_DATE - 59 AND id_pedido % 50 = 0;

COMMIT;

VACUUM (ANALYZE) pedido;
VACUUM (ANALYZE) detalle_pedido;

-- Verificacion de volumen (informar en el informe).
SELECT (SELECT COUNT(*) FROM pedido         WHERE eliminado = FALSE) AS pedidos_vigentes,
       (SELECT COUNT(*) FROM detalle_pedido WHERE eliminado = FALSE) AS detalles_vigentes,
       (SELECT COUNT(*) FROM pedido
        WHERE  eliminado = FALSE AND fecha_pedido = CURRENT_DATE)    AS pedidos_de_hoy;


-- ---------------------------------------------------------------------
-- 1. APARTADO (a): CONSULTA ORIGINAL - EXPLAIN ANALYZE ("ANTES")
-- ---------------------------------------------------------------------
EXPLAIN (ANALYZE, BUFFERS)
SELECT c.nombre_categoria          AS categoria,
       SUM(dp.subtotal_detallepedido) AS total_vendido
FROM   detalle_pedido dp
JOIN   producto  pr  ON pr.id_producto  = dp.producto_id
JOIN   categoria c   ON c.id_categoria  = pr.categoria_id
JOIN   pedido    ped ON ped.id_pedido   = dp.pedido_id
WHERE  ped.fecha_pedido = CURRENT_DATE
  AND  dp.eliminado  = FALSE
  AND  ped.eliminado = FALSE
GROUP  BY c.nombre_categoria
ORDER  BY total_vendido DESC
LIMIT  5;
-- Nodo dominante a reportar: Parallel Seq Scan sobre detalle_pedido (lee las
-- ~310.000 filas para quedarse con ~5.000 del dia) mas el Parallel Seq Scan sobre
-- pedido; el costo crece linealmente con el historial, no con las ventas de hoy.


-- ---------------------------------------------------------------------
-- 2. APARTADO (c): ESTRUCTURA DESNORMALIZADA + SINCRONIZACION
-- ---------------------------------------------------------------------
BEGIN;

-- Congela escrituras mientras se crea y se puebla, para que no se cuele ninguna
-- venta entre la carga inicial y la activacion de los disparadores.
LOCK TABLE detalle_pedido, pedido, producto IN SHARE ROW EXCLUSIVE MODE;

-- 2.1 Estructura: un total por (dia, categoria).
-- Sin CHECK (total >= 0) a proposito: los disparadores aplican deltas con
-- INSERT ... ON CONFLICT, y PostgreSQL valida los CHECK sobre la fila PROPUESTA
-- (un delta negativo la rechazaria aunque la fila existente quedara en positivo).
-- La integridad se vigila con la auditoria de la seccion 5.
CREATE TABLE resumen_ventas_categoria_dia (
    fecha         DATE          NOT NULL,
    categoria_id  BIGINT        NOT NULL REFERENCES categoria(id_categoria),
    total_vendido NUMERIC(14,2) NOT NULL DEFAULT 0,
    updated_at    TIMESTAMPTZ   NOT NULL DEFAULT now(),
    PRIMARY KEY (fecha, categoria_id)       -- soporta WHERE fecha = ...
);

-- 2.2 Carga inicial desde la fuente de verdad (misma semantica que la consulta
--     original: detalle vigente dentro de pedido vigente).
INSERT INTO resumen_ventas_categoria_dia (fecha, categoria_id, total_vendido)
SELECT ped.fecha_pedido, pr.categoria_id, SUM(dp.subtotal_detallepedido)
FROM   detalle_pedido dp
JOIN   pedido   ped ON ped.id_pedido  = dp.pedido_id AND ped.eliminado = FALSE
JOIN   producto pr  ON pr.id_producto = dp.producto_id
WHERE  dp.eliminado = FALSE
GROUP  BY ped.fecha_pedido, pr.categoria_id;

-- 2.3 Disparador sobre INSERT en detalle_pedido (statement-level + tabla de
--     transicion, igual estilo que trg_total_ins). Suma los subtotales nuevos.
--     Corre despues de trg_subtotal (BEFORE ROW), asi que ve el subtotal final.
CREATE OR REPLACE FUNCTION fn_resumen_detalle_ins()
RETURNS TRIGGER AS $$
BEGIN
    INSERT INTO resumen_ventas_categoria_dia AS r (fecha, categoria_id, total_vendido)
    SELECT ped.fecha_pedido, pr.categoria_id, SUM(n.subtotal_detallepedido)
    FROM   nuevos n
    JOIN   pedido   ped ON ped.id_pedido  = n.pedido_id AND ped.eliminado = FALSE
    JOIN   producto pr  ON pr.id_producto = n.producto_id
    WHERE  n.eliminado = FALSE
    GROUP  BY ped.fecha_pedido, pr.categoria_id
    ORDER  BY ped.fecha_pedido, pr.categoria_id          -- orden estable: evita deadlocks
    ON CONFLICT (fecha, categoria_id)
    DO UPDATE SET total_vendido = r.total_vendido + EXCLUDED.total_vendido,
                  updated_at    = now();
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_resumen_detalle_ins
AFTER INSERT ON detalle_pedido
REFERENCING NEW TABLE AS nuevos
FOR EACH STATEMENT EXECUTE FUNCTION fn_resumen_detalle_ins();

-- 2.4 Disparador sobre UPDATE en detalle_pedido: cambio de cantidad/precio,
--     baja logica del detalle, o cambio de pedido/producto. El delta es
--     (aporte nuevo) - (aporte viejo); un aporte solo existe si el detalle y su
--     pedido estan vigentes.
CREATE OR REPLACE FUNCTION fn_resumen_detalle_upd()
RETURNS TRIGGER AS $$
BEGIN
    INSERT INTO resumen_ventas_categoria_dia AS r (fecha, categoria_id, total_vendido)
    SELECT d.fecha, d.categoria_id, SUM(d.delta)
    FROM (
        SELECT ped.fecha_pedido AS fecha, pr.categoria_id,
               -v.subtotal_detallepedido AS delta
        FROM   viejos v
        JOIN   pedido   ped ON ped.id_pedido  = v.pedido_id AND ped.eliminado = FALSE
        JOIN   producto pr  ON pr.id_producto = v.producto_id
        WHERE  v.eliminado = FALSE
        UNION ALL
        SELECT ped.fecha_pedido, pr.categoria_id,
               n.subtotal_detallepedido
        FROM   nuevos n
        JOIN   pedido   ped ON ped.id_pedido  = n.pedido_id AND ped.eliminado = FALSE
        JOIN   producto pr  ON pr.id_producto = n.producto_id
        WHERE  n.eliminado = FALSE
    ) d
    GROUP  BY d.fecha, d.categoria_id
    HAVING SUM(d.delta) <> 0
    ORDER  BY d.fecha, d.categoria_id
    ON CONFLICT (fecha, categoria_id)
    DO UPDATE SET total_vendido = r.total_vendido + EXCLUDED.total_vendido,
                  updated_at    = now();
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_resumen_detalle_upd
AFTER UPDATE ON detalle_pedido
REFERENCING OLD TABLE AS viejos NEW TABLE AS nuevos
FOR EACH STATEMENT EXECUTE FUNCTION fn_resumen_detalle_upd();

-- 2.5 Disparador sobre pedido: baja logica del pedido o cambio de fecha. Mueve
--     (o quita) el aporte de todos sus detalles vigentes. Es por fila porque
--     estos cambios son raros y una tabla de transicion no admite lista de
--     columnas; el WHEN evita que se dispare con el UPDATE de total_pedido que
--     hace trg_total_*.
CREATE OR REPLACE FUNCTION fn_resumen_pedido_upd()
RETURNS TRIGGER AS $$
BEGIN
    INSERT INTO resumen_ventas_categoria_dia AS r (fecha, categoria_id, total_vendido)
    SELECT d.fecha, d.categoria_id, SUM(d.delta)
    FROM (
        SELECT OLD.fecha_pedido AS fecha, pr.categoria_id,
               -dp.subtotal_detallepedido AS delta
        FROM   detalle_pedido dp
        JOIN   producto pr ON pr.id_producto = dp.producto_id
        WHERE  dp.pedido_id = OLD.id_pedido AND dp.eliminado = FALSE
          AND  OLD.eliminado = FALSE
        UNION ALL
        SELECT NEW.fecha_pedido, pr.categoria_id,
               dp.subtotal_detallepedido
        FROM   detalle_pedido dp
        JOIN   producto pr ON pr.id_producto = dp.producto_id
        WHERE  dp.pedido_id = NEW.id_pedido AND dp.eliminado = FALSE
          AND  NEW.eliminado = FALSE
    ) d
    GROUP  BY d.fecha, d.categoria_id
    HAVING SUM(d.delta) <> 0
    ORDER  BY d.fecha, d.categoria_id
    ON CONFLICT (fecha, categoria_id)
    DO UPDATE SET total_vendido = r.total_vendido + EXCLUDED.total_vendido,
                  updated_at    = now();
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_resumen_pedido_upd
AFTER UPDATE OF fecha_pedido, eliminado ON pedido
FOR EACH ROW
WHEN (OLD.fecha_pedido IS DISTINCT FROM NEW.fecha_pedido
   OR OLD.eliminado    IS DISTINCT FROM NEW.eliminado)
EXECUTE FUNCTION fn_resumen_pedido_upd();

-- 2.6 Disparador sobre producto: si un producto cambia de categoria, su
--     historial se reasigna (la consulta original agrupa por la categoria
--     ACTUAL del producto, asi que la fuente de verdad se comporta asi).
CREATE OR REPLACE FUNCTION fn_resumen_producto_categoria()
RETURNS TRIGGER AS $$
BEGIN
    INSERT INTO resumen_ventas_categoria_dia AS r (fecha, categoria_id, total_vendido)
    SELECT d.fecha, d.categoria_id, SUM(d.delta)
    FROM (
        SELECT ped.fecha_pedido AS fecha, OLD.categoria_id AS categoria_id,
               -dp.subtotal_detallepedido AS delta
        FROM   detalle_pedido dp
        JOIN   pedido ped ON ped.id_pedido = dp.pedido_id AND ped.eliminado = FALSE
        WHERE  dp.producto_id = NEW.id_producto AND dp.eliminado = FALSE
        UNION ALL
        SELECT ped.fecha_pedido, NEW.categoria_id,
               dp.subtotal_detallepedido
        FROM   detalle_pedido dp
        JOIN   pedido ped ON ped.id_pedido = dp.pedido_id AND ped.eliminado = FALSE
        WHERE  dp.producto_id = NEW.id_producto AND dp.eliminado = FALSE
    ) d
    GROUP  BY d.fecha, d.categoria_id
    HAVING SUM(d.delta) <> 0
    ORDER  BY d.fecha, d.categoria_id
    ON CONFLICT (fecha, categoria_id)
    DO UPDATE SET total_vendido = r.total_vendido + EXCLUDED.total_vendido,
                  updated_at    = now();
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_resumen_producto_categoria
AFTER UPDATE OF categoria_id ON producto
FOR EACH ROW
WHEN (OLD.categoria_id IS DISTINCT FROM NEW.categoria_id)
EXECUTE FUNCTION fn_resumen_producto_categoria();

-- LIMITACION CONOCIDA (probada): si el detalle y su pedido se dan de baja en UNA
-- MISMA sentencia (por ejemplo, un WITH ... UPDATE detalle ... UPDATE pedido), los
-- disparadores ven el pedido ya eliminado y nadie descuenta el aporte. El flujo del
-- proyecto (HU-PED-04: dos UPDATE en una transaccion) esta cubierto; para cualquier
-- otro camino esta la auditoria de la seccion 5.
--
-- Nota: no hace falta un trigger de DELETE. fn_soft_delete (BEFORE DELETE)
-- convierte todo DELETE en UPDATE eliminado = TRUE y cancela el borrado fisico,
-- de modo que las bajas ya pasan por los disparadores de UPDATE.
-- TRUNCATE no esta cubierto: sobre estas tablas no debe usarse.

ANALYZE resumen_ventas_categoria_dia;

COMMIT;


-- ---------------------------------------------------------------------
-- 3. APARTADO (d): MISMO REPORTE LEYENDO LA ESTRUCTURA DESNORMALIZADA
-- ---------------------------------------------------------------------
EXPLAIN (ANALYZE, BUFFERS)
SELECT c.nombre_categoria AS categoria,
       r.total_vendido
FROM   resumen_ventas_categoria_dia r
JOIN   categoria c ON c.id_categoria = r.categoria_id
WHERE  r.fecha = CURRENT_DATE
ORDER  BY r.total_vendido DESC
LIMIT  5;

-- Equivalencia de resultados (EXCEPT en ambos sentidos): debe dar 0 y 0.
SELECT 'original EXCEPT resumen' AS prueba, COUNT(*) AS filas
FROM (
    SELECT c.nombre_categoria AS categoria, SUM(dp.subtotal_detallepedido) AS total_vendido
    FROM   detalle_pedido dp
    JOIN   producto  pr  ON pr.id_producto = dp.producto_id
    JOIN   categoria c   ON c.id_categoria = pr.categoria_id
    JOIN   pedido    ped ON ped.id_pedido  = dp.pedido_id
    WHERE  ped.fecha_pedido = CURRENT_DATE AND dp.eliminado = FALSE AND ped.eliminado = FALSE
    GROUP  BY c.nombre_categoria
    EXCEPT
    SELECT c.nombre_categoria, r.total_vendido
    FROM   resumen_ventas_categoria_dia r
    JOIN   categoria c ON c.id_categoria = r.categoria_id
    WHERE  r.fecha = CURRENT_DATE AND r.total_vendido > 0
) t
UNION ALL
SELECT 'resumen EXCEPT original', COUNT(*)
FROM (
    SELECT c.nombre_categoria, r.total_vendido
    FROM   resumen_ventas_categoria_dia r
    JOIN   categoria c ON c.id_categoria = r.categoria_id
    WHERE  r.fecha = CURRENT_DATE AND r.total_vendido > 0
    EXCEPT
    SELECT c.nombre_categoria, SUM(dp.subtotal_detallepedido)
    FROM   detalle_pedido dp
    JOIN   producto  pr  ON pr.id_producto = dp.producto_id
    JOIN   categoria c   ON c.id_categoria = pr.categoria_id
    JOIN   pedido    ped ON ped.id_pedido  = dp.pedido_id
    WHERE  ped.fecha_pedido = CURRENT_DATE AND dp.eliminado = FALSE AND ped.eliminado = FALSE
    GROUP  BY c.nombre_categoria
) t;


-- ---------------------------------------------------------------------
-- 4. CONTRASTE HONESTO (opcional): "y si solo agrego un indice?"
--    Un indice sobre pedido(fecha_pedido) mejora el "antes", pero la consulta
--    sigue obligada a leer y sumar todos los detalles del dia (miles de filas);
--    el resumen lee a lo sumo una fila por categoria. Se prueba y se descarta
--    dentro de una transaccion con ROLLBACK.
-- ---------------------------------------------------------------------
BEGIN;
    CREATE INDEX idx_tmp_pedido_fecha ON pedido (fecha_pedido) WHERE eliminado = FALSE;
    ANALYZE pedido;
    EXPLAIN (ANALYZE, BUFFERS)
    SELECT c.nombre_categoria AS categoria, SUM(dp.subtotal_detallepedido) AS total_vendido
    FROM   detalle_pedido dp
    JOIN   producto  pr  ON pr.id_producto = dp.producto_id
    JOIN   categoria c   ON c.id_categoria = pr.categoria_id
    JOIN   pedido    ped ON ped.id_pedido  = dp.pedido_id
    WHERE  ped.fecha_pedido = CURRENT_DATE AND dp.eliminado = FALSE AND ped.eliminado = FALSE
    GROUP  BY c.nombre_categoria
    ORDER  BY total_vendido DESC
    LIMIT  5;
ROLLBACK;


-- ---------------------------------------------------------------------
-- 5. APARTADO (e): AUDITORIA DE SINCRONIZACION
--    Recalcula la verdad desde la fuente y la compara con el resumen. Cualquier
--    fila devuelta es una desincronizacion. Se deja como vista para poder
--    ejecutarla cuando se quiera (por ejemplo, en un job nocturno).
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW v_auditoria_resumen_ventas AS
WITH fuente AS (
    SELECT ped.fecha_pedido AS fecha,
           pr.categoria_id,
           SUM(dp.subtotal_detallepedido) AS total_fuente
    FROM   detalle_pedido dp
    JOIN   pedido   ped ON ped.id_pedido  = dp.pedido_id AND ped.eliminado = FALSE
    JOIN   producto pr  ON pr.id_producto = dp.producto_id
    WHERE  dp.eliminado = FALSE
    GROUP  BY ped.fecha_pedido, pr.categoria_id
)
SELECT COALESCE(f.fecha, r.fecha)               AS fecha,
       COALESCE(f.categoria_id, r.categoria_id) AS categoria_id,
       f.total_fuente,
       r.total_vendido                          AS total_resumen
FROM   fuente f
FULL   OUTER JOIN resumen_ventas_categoria_dia r
       ON  r.fecha = f.fecha AND r.categoria_id = f.categoria_id
WHERE  COALESCE(f.total_fuente, 0) IS DISTINCT FROM COALESCE(r.total_vendido, 0);

-- Ejecucion sobre la base ya migrada. RESULTADO ESPERADO: 0 filas.
SELECT * FROM v_auditoria_resumen_ventas;


-- ---------------------------------------------------------------------
-- 6. PRUEBAS DE SINCRONIZACION (cada una aislada con ROLLBACK)
--    Despues de cada operacion la auditoria debe dar 0 desincronizaciones.
-- ---------------------------------------------------------------------

-- Referencia: total de hoy en el resumen antes de las pruebas.
SELECT 'baseline (sin cambios)' AS prueba, COUNT(*) AS desincronizaciones,
       (SELECT SUM(total_vendido) FROM resumen_ventas_categoria_dia WHERE fecha = CURRENT_DATE) AS total_resumen_hoy
FROM   v_auditoria_resumen_ventas;

-- T1: alta de pedido por el procedimiento transaccional del proyecto.
BEGIN;
    CALL sp_crear_pedido(2, 'EFECTIVO',
         '[{"producto_id":1,"cantidad":2},{"producto_id":9,"cantidad":3}]'::jsonb);
    SELECT 'T1 sp_crear_pedido' AS prueba, COUNT(*) AS desincronizaciones,
           (SELECT SUM(total_vendido) FROM resumen_ventas_categoria_dia WHERE fecha = CURRENT_DATE) AS total_resumen_hoy
    FROM   v_auditoria_resumen_ventas;
ROLLBACK;

-- T2: cambio de cantidad en un detalle de hoy (trg_subtotal recalcula el subtotal).
BEGIN;
    UPDATE detalle_pedido
    SET    cantidad_detallepedido = cantidad_detallepedido + 5
    WHERE  id_detallepedido = (SELECT dp.id_detallepedido
                               FROM   detalle_pedido dp
                               JOIN   pedido p ON p.id_pedido = dp.pedido_id
                               WHERE  p.fecha_pedido = CURRENT_DATE
                                 AND  dp.eliminado = FALSE AND p.eliminado = FALSE
                               ORDER  BY dp.id_detallepedido LIMIT 1);
    SELECT 'T2 update cantidad' AS prueba, COUNT(*) AS desincronizaciones,
           (SELECT SUM(total_vendido) FROM resumen_ventas_categoria_dia WHERE fecha = CURRENT_DATE) AS total_resumen_hoy
    FROM   v_auditoria_resumen_ventas;
ROLLBACK;

-- T3: baja logica de un detalle (via DELETE, que fn_soft_delete convierte en UPDATE).
--     El motor informa DELETE 0 porque el borrado fisico se cancela; el efecto
--     real es el UPDATE eliminado = TRUE, visible en la baja de total_resumen_hoy.
BEGIN;
    DELETE FROM detalle_pedido
    WHERE  id_detallepedido = (SELECT dp.id_detallepedido
                               FROM   detalle_pedido dp
                               JOIN   pedido p ON p.id_pedido = dp.pedido_id
                               WHERE  p.fecha_pedido = CURRENT_DATE
                                 AND  dp.eliminado = FALSE AND p.eliminado = FALSE
                               ORDER  BY dp.id_detallepedido LIMIT 1);
    SELECT 'T3 baja de detalle' AS prueba, COUNT(*) AS desincronizaciones,
           (SELECT SUM(total_vendido) FROM resumen_ventas_categoria_dia WHERE fecha = CURRENT_DATE) AS total_resumen_hoy
    FROM   v_auditoria_resumen_ventas;
ROLLBACK;

-- T4: baja logica de un pedido completo, en el orden del proyecto
--     (detalles primero, pedido despues, en sentencias separadas).
BEGIN;
    UPDATE detalle_pedido SET eliminado = TRUE
    WHERE  pedido_id = (SELECT id_pedido FROM pedido
                        WHERE fecha_pedido = CURRENT_DATE AND eliminado = FALSE
                        ORDER BY id_pedido LIMIT 1);
    UPDATE pedido SET eliminado = TRUE
    WHERE  id_pedido = (SELECT id_pedido FROM pedido
                        WHERE fecha_pedido = CURRENT_DATE AND eliminado = FALSE
                        ORDER BY id_pedido LIMIT 1);
    SELECT 'T4 baja de pedido' AS prueba, COUNT(*) AS desincronizaciones,
           (SELECT SUM(total_vendido) FROM resumen_ventas_categoria_dia WHERE fecha = CURRENT_DATE) AS total_resumen_hoy
    FROM   v_auditoria_resumen_ventas;
ROLLBACK;

-- T5: baja del pedido SIN dar de baja antes sus detalles (orden inverso).
BEGIN;
    UPDATE pedido SET eliminado = TRUE
    WHERE  id_pedido = (SELECT id_pedido FROM pedido
                        WHERE fecha_pedido = CURRENT_DATE AND eliminado = FALSE
                        ORDER BY id_pedido LIMIT 1);
    SELECT 'T5 baja de pedido solo' AS prueba, COUNT(*) AS desincronizaciones,
           (SELECT SUM(total_vendido) FROM resumen_ventas_categoria_dia WHERE fecha = CURRENT_DATE) AS total_resumen_hoy
    FROM   v_auditoria_resumen_ventas;
ROLLBACK;

-- T6: un pedido de hoy se reasigna a ayer (cambio de fecha_pedido).
BEGIN;
    UPDATE pedido SET fecha_pedido = CURRENT_DATE - 1
    WHERE  id_pedido = (SELECT id_pedido FROM pedido
                        WHERE fecha_pedido = CURRENT_DATE AND eliminado = FALSE
                        ORDER BY id_pedido LIMIT 1);
    SELECT 'T6 cambio de fecha' AS prueba, COUNT(*) AS desincronizaciones,
           (SELECT SUM(total_vendido) FROM resumen_ventas_categoria_dia WHERE fecha = CURRENT_DATE) AS total_resumen_hoy
    FROM   v_auditoria_resumen_ventas;
ROLLBACK;

-- T7: un producto cambia de categoria (se reasigna todo su historial).
BEGIN;
    SELECT 'T7 antes' AS momento, categoria_id, SUM(total_vendido) AS total_historico
    FROM   resumen_ventas_categoria_dia WHERE categoria_id IN (1, 2) GROUP BY categoria_id ORDER BY categoria_id;
    UPDATE producto SET categoria_id = 2 WHERE id_producto = 1;
    SELECT 'T7 despues' AS momento, categoria_id, SUM(total_vendido) AS total_historico
    FROM   resumen_ventas_categoria_dia WHERE categoria_id IN (1, 2) GROUP BY categoria_id ORDER BY categoria_id;
    SELECT 'T7 producto cambia de categoria' AS prueba, COUNT(*) AS desincronizaciones,
           (SELECT SUM(total_vendido) FROM resumen_ventas_categoria_dia WHERE fecha = CURRENT_DATE) AS total_resumen_hoy
    FROM   v_auditoria_resumen_ventas;
ROLLBACK;

-- T8: alta masiva (INSERT ... SELECT de muchas filas en una sola sentencia).
BEGIN;
    INSERT INTO pedido (fecha_pedido, forma_pago, usuario_id)
    SELECT CURRENT_DATE, 'TARJETA', 3 FROM generate_series(1, 1000);
    INSERT INTO detalle_pedido (cantidad_detallepedido, pedido_id, producto_id)
    SELECT 2, p.id_pedido, 4
    FROM   pedido p
    WHERE  p.created_at = now();          -- now() es fijo dentro de la transaccion
    SELECT 'T8 alta masiva' AS prueba, COUNT(*) AS desincronizaciones,
           (SELECT SUM(total_vendido) FROM resumen_ventas_categoria_dia WHERE fecha = CURRENT_DATE) AS total_resumen_hoy
    FROM   v_auditoria_resumen_ventas;
ROLLBACK;

-- T9 (prueba NEGATIVA): se corrompe el resumen a mano y la auditoria debe
--     detectarlo. Esperado: 1 desincronizacion, con ambos totales distintos.
BEGIN;
    UPDATE resumen_ventas_categoria_dia
    SET    total_vendido = total_vendido + 100
    WHERE  (fecha, categoria_id) = (SELECT fecha, categoria_id
                                    FROM   resumen_ventas_categoria_dia
                                    WHERE  fecha = CURRENT_DATE LIMIT 1);
    SELECT * FROM v_auditoria_resumen_ventas;
ROLLBACK;

-- Auditoria final sobre la base migrada. RESULTADO ESPERADO: 0 filas.
SELECT * FROM v_auditoria_resumen_ventas;


-- ---------------------------------------------------------------------
-- 7. REVERSIBILIDAD (no ejecutar salvo que se quiera volver atras)
--    La estructura es redundancia pura: quitarla no pierde informacion.
-- ---------------------------------------------------------------------
-- DROP VIEW    v_auditoria_resumen_ventas;
-- DROP TRIGGER trg_resumen_detalle_ins      ON detalle_pedido;
-- DROP TRIGGER trg_resumen_detalle_upd      ON detalle_pedido;
-- DROP TRIGGER trg_resumen_pedido_upd       ON pedido;
-- DROP TRIGGER trg_resumen_producto_categoria ON producto;
-- DROP FUNCTION fn_resumen_detalle_ins(), fn_resumen_detalle_upd(),
--               fn_resumen_pedido_upd(), fn_resumen_producto_categoria();
-- DROP TABLE   resumen_ventas_categoria_dia;

-- =====================================================================
-- tp_fnbc_control_lote.sql
-- TPI Base de Datos - Food Store
-- TP Unidad 4 - Parte 1: Forma Normal de Boyce-Codd (FNBC)
--                        sobre control_lote_almacen
--
-- Requiere: schema.sql, objects.sql y data.sql ya ejecutados (en ese orden)
-- sobre una COPIA de trabajo (protocolo de seguridad de la catedra):
--   1) Copia:       CREATE DATABASE copia_trabajo WITH TEMPLATE food_store;
--   2) Transaccion: las pruebas destructivas corren en BEGIN; ... ROLLBACK;
--   3) Respaldo:    pg_dump antes de ejecutar este script (contiene DDL).
--
-- Adaptacion a los nombres reales del esquema Food Store:
--   la consigna escribe usuario(id), lote(id), deposito(id); el proyecto usa
--   la convencion id_<tabla>, por eso se referencia usuario(id_usuario) y las
--   tablas maestras minimas se crean como lote(id_lote) y deposito(id_deposito).
--
-- Notacion: L = LoteID, D = DepositoID, R = ResponsableControlID
--   DF1: {L, D} -> R      (para un lote y un deposito, un unico responsable)
--   DF2: R -> D           (cada responsable pertenece a un unico deposito)
-- =====================================================================


-- ---------------------------------------------------------------------
-- 1. ESQUEMA ORIGINAL + INSTANCIA DE EJEMPLO
-- ---------------------------------------------------------------------
BEGIN;

-- Tablas maestras de la extension mayorista (la consigna las asume existentes).
CREATE TABLE lote     (id_lote     BIGINT PRIMARY KEY);
CREATE TABLE deposito (id_deposito BIGINT PRIMARY KEY);

INSERT INTO lote     (id_lote)     VALUES (501), (502), (503);
-- 30 y 31 son los de la instancia; 32 y 33 se usan en las demostraciones.
INSERT INTO deposito (id_deposito) VALUES (30), (31), (32), (33);

-- Los responsables son filas de usuario. usuario.id_usuario es GENERATED ALWAYS,
-- asi que para reutilizar los ids de la consigna (801, 802, 803) hace falta
-- OVERRIDING SYSTEM VALUE. Solo es valido en la copia de trabajo.
INSERT INTO usuario (id_usuario, nombre_usuario, apellido_usuario, mail_usuario,
                     celular_usuario, contrasena_usuario)
OVERRIDING SYSTEM VALUE
VALUES (801, 'Responsable', 'Control 801', 'resp801@foodstore.com', NULL, 'hash_resp801'),
       (802, 'Responsable', 'Control 802', 'resp802@foodstore.com', NULL, 'hash_resp802'),
       (803, 'Responsable', 'Control 803', 'resp803@foodstore.com', NULL, 'hash_resp803');

-- Esquema original, tal como lo da la consigna (con los nombres reales).
CREATE TABLE control_lote_almacen (
    lote_id                BIGINT NOT NULL REFERENCES lote(id_lote),
    deposito_id            BIGINT NOT NULL REFERENCES deposito(id_deposito),
    responsable_control_id BIGINT NOT NULL REFERENCES usuario(id_usuario),
    PRIMARY KEY (lote_id, deposito_id)
);

INSERT INTO control_lote_almacen VALUES
    (501, 30, 801),
    (502, 30, 801),
    (503, 31, 802);

COMMIT;


-- ---------------------------------------------------------------------
-- 2. EVIDENCIA SOBRE LA INSTANCIA (apartados a, b y c)
-- ---------------------------------------------------------------------

-- (a) DF1 se cumple: para cada (lote, deposito) hay un unico responsable.
--     Esperado: 0 filas.
SELECT lote_id, deposito_id
FROM   control_lote_almacen
GROUP  BY lote_id, deposito_id
HAVING COUNT(DISTINCT responsable_control_id) > 1;

-- (a) DF2 se cumple: cada responsable aparece en un unico deposito.
--     Esperado: 0 filas.
SELECT responsable_control_id
FROM   control_lote_almacen
GROUP  BY responsable_control_id
HAVING COUNT(DISTINCT deposito_id) > 1;

-- (b)/(c) {R} NO es superclave: un mismo valor de R se repite en la instancia.
--     Esperado: 1 fila (responsable 801 con 2 filas). Si {R} fuera superclave,
--     no podria repetirse.
SELECT responsable_control_id, COUNT(*) AS filas
FROM   control_lote_almacen
GROUP  BY responsable_control_id
HAVING COUNT(*) > 1;


-- ---------------------------------------------------------------------
-- 3. ANOMALIAS DEL ESQUEMA ORIGINAL (apartado d)
--    Cada caso se ejecuta aislado y termina en ROLLBACK.
-- ---------------------------------------------------------------------

-- 3.1 Anomalia de INSERCION: se contrata al responsable 803 para el deposito 32
--     pero aun no tiene lotes. No hay forma de registrar el hecho "803 -> 32"
--     porque lote_id es parte de la PK y no admite NULL.
--     Esperado: NOTICE con el error not_null_violation.
DO $$
BEGIN
    INSERT INTO control_lote_almacen (lote_id, deposito_id, responsable_control_id)
    VALUES (NULL, 32, 803);
EXCEPTION WHEN not_null_violation THEN
    RAISE NOTICE 'ANOMALIA DE INSERCION: no se puede registrar 803 -> deposito 32 sin un lote (%)', SQLERRM;
END $$;

-- 3.2 Anomalia de BORRADO: el lote 503 es el unico que paso por el deposito 31.
--     Al borrar ese control se pierde tambien que el responsable 802 pertenece
--     al deposito 31 (dato maestro de personal).
--     Esperado: antes = 1 fila, despues = 0 filas.
BEGIN;
    SELECT 'antes' AS momento, COUNT(*) AS filas_que_ubican_al_resp_802
    FROM   control_lote_almacen WHERE responsable_control_id = 802;

    DELETE FROM control_lote_almacen WHERE lote_id = 503 AND deposito_id = 31;

    SELECT 'despues' AS momento, COUNT(*) AS filas_que_ubican_al_resp_802
    FROM   control_lote_almacen WHERE responsable_control_id = 802;
ROLLBACK;

-- 3.3 Anomalia de ACTUALIZACION: 801 se transfiere al deposito 33 pero solo se
--     actualiza una de sus dos filas. El motor lo acepta y la base queda
--     inconsistente (801 pertenece a dos depositos, violando DF2).
--     Esperado: 1 fila con depositos = {30,33}.
BEGIN;
    UPDATE control_lote_almacen
    SET    deposito_id = 33
    WHERE  lote_id = 501 AND responsable_control_id = 801;

    SELECT responsable_control_id,
           array_agg(DISTINCT deposito_id ORDER BY deposito_id) AS depositos
    FROM   control_lote_almacen
    GROUP  BY responsable_control_id
    HAVING COUNT(DISTINCT deposito_id) > 1;
ROLLBACK;


-- ---------------------------------------------------------------------
-- 4. DESCOMPOSICION SIN PERDIDA EN FNBC (apartado e)
--
-- Algoritmo: se toma la DF violatoria X -> Y (R -> D) y R se reemplaza por
--   R1 = X u Y         = {R, D}   -> responsable_deposito
--   R2 = R - Y         = {L, R}   -> control_lote
-- ---------------------------------------------------------------------
BEGIN;

-- R1: captura DF2. La PK sobre R garantiza R -> D por construccion.
CREATE TABLE responsable_deposito (
    responsable_control_id BIGINT NOT NULL REFERENCES usuario(id_usuario),
    deposito_id            BIGINT NOT NULL REFERENCES deposito(id_deposito),
    PRIMARY KEY (responsable_control_id)
);

-- R2: la clave candidata alternativa {L, R} detectada en el apartado (b).
CREATE TABLE control_lote (
    lote_id                BIGINT NOT NULL REFERENCES lote(id_lote),
    responsable_control_id BIGINT NOT NULL
                           REFERENCES responsable_deposito(responsable_control_id),
    PRIMARY KEY (lote_id, responsable_control_id)
);

-- Indices de apoyo a las FK que no encabezan una PK.
CREATE INDEX idx_responsable_deposito_deposito ON responsable_deposito(deposito_id);
CREATE INDEX idx_control_lote_responsable      ON control_lote(responsable_control_id);

-- Vista de compatibilidad: reconstruye la relacion original por reunion natural
-- sobre el atributo comun R.
CREATE OR REPLACE VIEW v_control_lote_almacen AS
SELECT cl.lote_id,
       rd.deposito_id,
       cl.responsable_control_id
FROM   control_lote cl
JOIN   responsable_deposito rd
       ON rd.responsable_control_id = cl.responsable_control_id;

COMMIT;


-- ---------------------------------------------------------------------
-- 5. MIGRACION DE DATOS Y VERIFICACION (apartado f)
--
-- Por que la reunion es sin perdida (teorema de Heath):
--   R1 n R2 = {R}. En R1, R es la PK, o sea que {R}+ = {R, D} = R1 y por lo
--   tanto {R} es superclave de R1. Como el atributo comun es superclave de uno
--   de los dos esquemas, R1 |x| R2 reconstruye exactamente la relacion original,
--   sin tuplas perdidas ni espurias.
-- ---------------------------------------------------------------------
BEGIN;

-- Precondicion: DF2 debe valer en los datos, si no la PK de R1 fallaria.
-- Esperado: 0 filas.
SELECT responsable_control_id
FROM   control_lote_almacen
GROUP  BY responsable_control_id
HAVING COUNT(DISTINCT deposito_id) > 1;

-- Se migra desde la tabla original (no se vuelven a tipear los datos).
INSERT INTO responsable_deposito (responsable_control_id, deposito_id)
SELECT DISTINCT responsable_control_id, deposito_id
FROM   control_lote_almacen;

INSERT INTO control_lote (lote_id, responsable_control_id)
SELECT lote_id, responsable_control_id
FROM   control_lote_almacen;

COMMIT;

-- Equivalencia: EXCEPT en ambos sentidos entre la tabla original y la vista.
-- Esperado: 0 filas en las dos primeras y conteos iguales (3 = 3).
SELECT 'original EXCEPT vista' AS prueba, COUNT(*) AS filas
FROM  (SELECT lote_id, deposito_id, responsable_control_id FROM control_lote_almacen
       EXCEPT
       SELECT lote_id, deposito_id, responsable_control_id FROM v_control_lote_almacen) t
UNION ALL
SELECT 'vista EXCEPT original', COUNT(*)
FROM  (SELECT lote_id, deposito_id, responsable_control_id FROM v_control_lote_almacen
       EXCEPT
       SELECT lote_id, deposito_id, responsable_control_id FROM control_lote_almacen) t
UNION ALL
SELECT 'conteo original', COUNT(*) FROM control_lote_almacen
UNION ALL
SELECT 'conteo vista',    COUNT(*) FROM v_control_lote_almacen;

SELECT * FROM v_control_lote_almacen ORDER BY lote_id;   -- (501,30,801) (502,30,801) (503,31,802)


-- ---------------------------------------------------------------------
-- 6. LAS TRES ANOMALIAS DESAPARECEN EN EL ESQUEMA DESCOMPUESTO
-- ---------------------------------------------------------------------

-- 6.1 Insercion: 803 se registra en el deposito 32 sin ningun lote.
BEGIN;
    INSERT INTO responsable_deposito (responsable_control_id, deposito_id) VALUES (803, 32);
    SELECT * FROM responsable_deposito WHERE responsable_control_id = 803;
ROLLBACK;

-- 6.2 Borrado: se elimina el unico control del deposito 31 y el dato maestro
--     "802 pertenece al 31" sigue en responsable_deposito.
BEGIN;
    DELETE FROM control_lote WHERE lote_id = 503 AND responsable_control_id = 802;
    SELECT * FROM responsable_deposito WHERE responsable_control_id = 802;   -- 1 fila
ROLLBACK;

-- 6.3 Actualizacion: transferir a 801 al deposito 33 es UN solo UPDATE de UNA
--     fila; todas sus filas de control reflejan el cambio y no hay estado a medias.
BEGIN;
    UPDATE responsable_deposito SET deposito_id = 33 WHERE responsable_control_id = 801;
    SELECT * FROM v_control_lote_almacen WHERE responsable_control_id = 801 ORDER BY lote_id;
ROLLBACK;


-- ---------------------------------------------------------------------
-- 7. EXTRA: DF1 NO SE PRESERVA DECLARATIVAMENTE
--
-- La descomposicion en FNBC es siempre sin perdida, pero no siempre preserva
-- dependencias. Aca {L, D} -> R ya no puede expresarse como PK/UNIQUE en una
-- sola tabla (L esta en control_lote y D en responsable_deposito). Sin mas
-- controles, se podria asignar a un mismo lote DOS responsables del MISMO
-- deposito, algo que la regla de negocio prohibe. Se lo cubre con triggers.
-- ---------------------------------------------------------------------
BEGIN;

CREATE OR REPLACE FUNCTION fn_validar_df1_control_lote()
RETURNS TRIGGER AS $$
DECLARE
    v_deposito  BIGINT;
    v_resp_vieja BIGINT;
BEGIN
    SELECT deposito_id INTO v_deposito
    FROM   responsable_deposito WHERE responsable_control_id = NEW.responsable_control_id;

    IF TG_OP = 'UPDATE' THEN
        v_resp_vieja := OLD.responsable_control_id;   -- excluye la fila que se esta modificando
    END IF;

    IF EXISTS (SELECT 1
               FROM   control_lote cl
               JOIN   responsable_deposito rd ON rd.responsable_control_id = cl.responsable_control_id
               WHERE  cl.lote_id = NEW.lote_id
                 AND  cl.responsable_control_id <> NEW.responsable_control_id
                 AND  cl.responsable_control_id IS DISTINCT FROM v_resp_vieja
                 AND  rd.deposito_id = v_deposito) THEN
        RAISE EXCEPTION 'DF1 violada: el lote % ya tiene otro responsable en el deposito %',
                        NEW.lote_id, v_deposito;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_df1_control_lote
BEFORE INSERT OR UPDATE ON control_lote
FOR EACH ROW EXECUTE FUNCTION fn_validar_df1_control_lote();

-- Mismo control cuando es el responsable quien cambia de deposito.
CREATE OR REPLACE FUNCTION fn_validar_df1_traslado_responsable()
RETURNS TRIGGER AS $$
BEGIN
    IF EXISTS (SELECT 1
               FROM   control_lote a
               JOIN   control_lote b ON b.lote_id = a.lote_id
                                    AND b.responsable_control_id <> a.responsable_control_id
               JOIN   responsable_deposito rd ON rd.responsable_control_id = b.responsable_control_id
               WHERE  a.responsable_control_id = NEW.responsable_control_id
                 AND  rd.deposito_id = NEW.deposito_id) THEN
        RAISE EXCEPTION 'DF1 violada: el traslado del responsable % al deposito % duplicaria responsables en un lote',
                        NEW.responsable_control_id, NEW.deposito_id;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_df1_traslado_responsable
BEFORE UPDATE OF deposito_id ON responsable_deposito
FOR EACH ROW EXECUTE FUNCTION fn_validar_df1_traslado_responsable();

COMMIT;

-- Prueba A (debe fallar): 803 trabaja en el deposito 30, igual que 801, y el
-- lote 501 ya esta controlado por 801 desde ese deposito.
BEGIN;
    INSERT INTO responsable_deposito VALUES (803, 30);
    DO $$
    BEGIN
        INSERT INTO control_lote VALUES (501, 803);
        RAISE NOTICE 'ERROR DE PRUEBA: se permitio violar DF1';
    EXCEPTION WHEN raise_exception THEN
        RAISE NOTICE 'OK, rechazado: %', SQLERRM;
    END $$;
ROLLBACK;

-- Prueba B (debe pasar): el lote 501 se fracciona y lo controla tambien 802
-- desde otro deposito (31). Es exactamente el caso de negocio permitido.
BEGIN;
    INSERT INTO control_lote VALUES (501, 802);
    SELECT * FROM v_control_lote_almacen WHERE lote_id = 501 ORDER BY deposito_id;
ROLLBACK;

-- Prueba C (debe fallar): trasladar a 802 al deposito 30 duplicaria
-- responsables del lote 501 si 802 llegara a controlarlo.
BEGIN;
    INSERT INTO control_lote VALUES (501, 802);
    DO $$
    BEGIN
        UPDATE responsable_deposito SET deposito_id = 30 WHERE responsable_control_id = 802;
        RAISE NOTICE 'ERROR DE PRUEBA: se permitio el traslado';
    EXCEPTION WHEN raise_exception THEN
        RAISE NOTICE 'OK, rechazado: %', SQLERRM;
    END $$;
ROLLBACK;

-- Cuando se dé por validada la migracion, la tabla original puede retirarse:
--   ALTER TABLE control_lote_almacen RENAME TO control_lote_almacen_legacy;
--   (y las aplicaciones leen v_control_lote_almacen)

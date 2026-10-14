-- =====================================================================
-- Mercado automotor argentino: ¿qué autos usados conviene tener en stock?
-- Datos: Registro Nacional de la Propiedad Automotor (DNRPA), datos.jus.gob.ar
-- Período: junio a septiembre 2026
-- Motor: Google BigQuery
-- =====================================================================


-- ---------------------------------------------------------------------
-- 1. CARGA
-- Los CSV mensuales se cargaron en dos tablas, con todas las columnas
-- como texto (STRING) para evitar errores de tipos entre archivos:
--   autos.transferencias  -> autos usados (640.279 filas)
--   autos.inscripciones   -> autos 0km    (188.953 filas)
-- ---------------------------------------------------------------------

-- Verificación de la carga: filas por mes
SELECT SUBSTR(tramite_fecha, 1, 7) AS mes, COUNT(*) AS transferencias
FROM autos.transferencias
GROUP BY mes
ORDER BY mes;

SELECT SUBSTR(tramite_fecha, 1, 7) AS mes, COUNT(*) AS inscripciones
FROM autos.inscripciones
GROUP BY mes
ORDER BY mes;


-- ---------------------------------------------------------------------
-- 2. LIMPIEZA: vista que une usados y 0km y deja los datos listos
-- - Convierte fechas y años a su tipo correcto (SAFE_CAST)
-- - Crea el "modelo base" sin versión ni motor (GOL 1.6 -> GOL)
--   con excepciones: GOL TREND es un modelo distinto, y el prefijo
--   "NUEVO" se saltea (NUEVO SANDERO -> SANDERO)
-- - Calcula la antigüedad del auto
-- - Años de modelo fuera de 1900-2027 se consideran sin dato
--   (se detectaron 63 errores, como "20", "2206" y "2720")
-- - Provincias vacías pasan a "Sin dato"
-- - Agrega marca_modelo, rango de antigüedad y tipo de operación
--   (agencia compra / agencia vende / entre particulares)
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW autos.mercado_limpio AS
WITH crudo AS (
  SELECT 'Usado' AS mercado, * FROM autos.transferencias
  UNION ALL
  SELECT '0km' AS mercado, * FROM autos.inscripciones
),
base AS (
  SELECT
    mercado,
    tramite_tipo,
    SAFE_CAST(tramite_fecha AS DATE) AS fecha,
    DATE_TRUNC(SAFE_CAST(tramite_fecha AS DATE), MONTH) AS mes,
    COALESCE(NULLIF(registro_seccional_provincia, ''), 'Sin dato') AS provincia,
    automotor_marca_descripcion AS marca,
    automotor_modelo_descripcion AS modelo_completo,
    CASE
      WHEN automotor_modelo_descripcion LIKE 'GOL TREND%' THEN 'GOL TREND'
      WHEN automotor_modelo_descripcion LIKE 'NUEVO %'
        THEN SPLIT(automotor_modelo_descripcion, ' ')[SAFE_OFFSET(1)]
      ELSE SPLIT(automotor_modelo_descripcion, ' ')[SAFE_OFFSET(0)]
    END AS modelo_base,
    automotor_tipo_descripcion AS tipo,
    automotor_origen AS origen,
    CASE WHEN SAFE_CAST(automotor_anio_modelo AS INT64) BETWEEN 1900 AND 2027
         THEN SAFE_CAST(automotor_anio_modelo AS INT64) END AS anio_modelo,
    CASE WHEN SAFE_CAST(automotor_anio_modelo AS INT64) BETWEEN 1900 AND 2027
         THEN EXTRACT(YEAR FROM SAFE_CAST(tramite_fecha AS DATE))
              - SAFE_CAST(automotor_anio_modelo AS INT64) END AS antiguedad,
    titular_tipo_persona AS tipo_persona,
    titular_genero AS genero,
    SAFE_CAST(titular_anio_nacimiento AS INT64) AS anio_nacimiento
  FROM crudo
)
SELECT
  *,
  CONCAT(marca, ' ', modelo_base) AS marca_modelo,
  CASE
    WHEN antiguedad <= 3  THEN '1) 0 a 3 años'
    WHEN antiguedad <= 7  THEN '2) 4 a 7 años'
    WHEN antiguedad <= 12 THEN '3) 8 a 12 años'
    WHEN antiguedad <= 20 THEN '4) 13 a 20 años'
    WHEN antiguedad <= 40 THEN '5) 21 a 40 años'
    WHEN antiguedad > 40  THEN '6) Más de 40 años'
    ELSE '7) Sin dato'
  END AS rango_antiguedad,
  CASE
    WHEN mercado = '0km' THEN '0km'
    WHEN tramite_tipo LIKE '% A COM. HAB%' THEN 'Agencia compra'
    WHEN tramite_tipo LIKE '%DE COM. HAB%' THEN 'Agencia vende'
    ELSE 'Entre particulares'
  END AS tipo_operacion
FROM base;

-- Control de calidad de la antigüedad
SELECT
  MIN(antiguedad) AS minima,
  MAX(antiguedad) AS maxima,
  COUNTIF(antiguedad IS NULL) AS sin_dato,
  COUNTIF(antiguedad < 0) AS negativos
FROM autos.mercado_limpio
WHERE mercado = 'Usado';

-- Revisión de años de modelo extremos (cruzando con marca y modelo)
SELECT anio_modelo, marca, modelo_completo, COUNT(*) AS cantidad
FROM autos.mercado_limpio
WHERE mercado = 'Usado' AND anio_modelo < 1960
GROUP BY anio_modelo, marca, modelo_completo
ORDER BY anio_modelo
LIMIT 60;


-- ---------------------------------------------------------------------
-- P1. ¿Cuántos usados se venden por cada 0km?
-- ---------------------------------------------------------------------
SELECT
  mes,
  COUNTIF(mercado = 'Usado') AS usados,
  COUNTIF(mercado = '0km') AS ceros,
  ROUND(COUNTIF(mercado = 'Usado') / COUNTIF(mercado = '0km'), 2) AS usados_por_cada_0km
FROM autos.mercado_limpio
GROUP BY mes
ORDER BY mes;


-- ---------------------------------------------------------------------
-- P2. ¿Qué marcas y modelos usados se venden más?
-- ---------------------------------------------------------------------
SELECT marca, COUNT(*) AS ventas
FROM autos.mercado_limpio
WHERE mercado = 'Usado'
GROUP BY marca
ORDER BY ventas DESC
LIMIT 10;

SELECT marca, modelo_base, COUNT(*) AS ventas
FROM autos.mercado_limpio
WHERE mercado = 'Usado'
GROUP BY marca, modelo_base
ORDER BY ventas DESC
LIMIT 10;


-- ---------------------------------------------------------------------
-- P3. ¿De qué antigüedad son los usados que se venden?
-- ---------------------------------------------------------------------
SELECT
  CASE
    WHEN antiguedad <= 3  THEN '1) 0 a 3 años'
    WHEN antiguedad <= 7  THEN '2) 4 a 7 años'
    WHEN antiguedad <= 12 THEN '3) 8 a 12 años'
    WHEN antiguedad <= 20 THEN '4) 13 a 20 años'
    WHEN antiguedad <= 40 THEN '5) 21 a 40 años'
    WHEN antiguedad > 40  THEN '6) Más de 40 años'
    ELSE '7) Sin dato'
  END AS rango_antiguedad,
  COUNT(*) AS ventas,
  ROUND(COUNT(*) * 100 / SUM(COUNT(*)) OVER (), 1) AS porcentaje
FROM autos.mercado_limpio
WHERE mercado = 'Usado'
GROUP BY rango_antiguedad
ORDER BY rango_antiguedad;


-- ---------------------------------------------------------------------
-- P4. ¿En qué provincias se venden más usados?
-- ---------------------------------------------------------------------
SELECT
  provincia,
  COUNT(*) AS ventas,
  ROUND(COUNT(*) * 100 / SUM(COUNT(*)) OVER (), 1) AS porcentaje
FROM autos.mercado_limpio
WHERE mercado = 'Usado'
GROUP BY provincia
ORDER BY ventas DESC;


-- ---------------------------------------------------------------------
-- P5. ¿Qué 0km se venden más? (los usados del futuro)
-- ---------------------------------------------------------------------
SELECT marca, modelo_base, COUNT(*) AS ventas
FROM autos.mercado_limpio
WHERE mercado = '0km'
GROUP BY marca, modelo_base
ORDER BY ventas DESC
LIMIT 10;


-- ---------------------------------------------------------------------
-- BONUS. ¿Qué compran las agencias (comerciantes habitualistas)?
-- ---------------------------------------------------------------------

-- Tipos de trámite existentes
SELECT tramite_tipo, COUNT(*) AS cantidad
FROM autos.mercado_limpio
WHERE mercado = 'Usado'
GROUP BY tramite_tipo
ORDER BY cantidad DESC;

-- Clasificación de las operaciones
SELECT
  CASE
    WHEN tramite_tipo LIKE '% A COM. HAB%' THEN 'Agencia compra'
    WHEN tramite_tipo LIKE '%DE COM. HAB%' THEN 'Agencia vende'
    ELSE 'Entre particulares'
  END AS tipo_operacion,
  COUNT(*) AS cantidad,
  ROUND(COUNT(*) * 100 / SUM(COUNT(*)) OVER (), 1) AS porcentaje
FROM autos.mercado_limpio
WHERE mercado = 'Usado'
GROUP BY tipo_operacion
ORDER BY cantidad DESC;

-- Modelos que más compran las agencias
SELECT marca, modelo_base, COUNT(*) AS ventas
FROM autos.mercado_limpio
WHERE mercado = 'Usado' AND tramite_tipo LIKE '% A COM. HAB%'
GROUP BY marca, modelo_base
ORDER BY ventas DESC
LIMIT 10;

-- Antigüedad promedio según tipo de operación
SELECT
  CASE
    WHEN tramite_tipo LIKE '% A COM. HAB%' THEN 'Agencia compra'
    WHEN tramite_tipo LIKE '%DE COM. HAB%' THEN 'Agencia vende'
    ELSE 'Entre particulares'
  END AS tipo_operacion,
  ROUND(AVG(antiguedad), 1) AS antiguedad_promedio
FROM autos.mercado_limpio
WHERE mercado = 'Usado'
GROUP BY tipo_operacion;

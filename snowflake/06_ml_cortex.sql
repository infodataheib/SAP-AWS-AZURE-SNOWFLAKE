-- ============================================================
-- 06 · Machine Learning — módulo "Analítica avanzada e IA"
-- Todo serverless, dentro de Snowflake, sobre las tablas de CURATED
-- (hereda RBAC + masking de la Fase 3, como dice la propuesta).
--   6.1 Forecast de ventas (SNOWFLAKE.ML.FORECAST)
--   6.2 Detección de anomalías (SNOWFLAKE.ML.ANOMALY_DETECTION)
--   6.3 Contribución / causa raíz (TOP_INSIGHTS)
--   6.4 Cortex LLM: sentimiento y clasificación de reclamos
-- Nota: las funciones Cortex LLM y Cortex Analyst requieren que la
-- región/edición de la cuenta las soporte (Enterprise en algunos casos).
-- ============================================================

USE ROLE SYSADMIN;
USE WAREHOUSE WH_DEMO;
USE SCHEMA DWH_DEMO.CURATED;

-- -----------------------------------------------------------
-- 6.1 FORECAST — pronóstico de venta mensual por línea de producto
-- -----------------------------------------------------------
-- Serie de entrenamiento: venta diaria por línea
CREATE OR REPLACE VIEW V_ML_VENTAS_DIARIAS AS
SELECT d.FULL_DATE::TIMESTAMP_NTZ AS TS,
       p.PRODUCT_LINE             AS SERIE,
       SUM(f.NET_AMOUNT)          AS VENTA
FROM FACT_BILLING f
JOIN DIM_DATE d    ON d.DATE_SK = f.DATE_SK
JOIN DIM_PRODUCT p ON p.PRODUCT_SK = f.PRODUCT_SK
WHERE f.NET_AMOUNT > 0
GROUP BY 1,2;

-- Entrenar el modelo (multi-serie)
CREATE OR REPLACE SNOWFLAKE.ML.FORECAST MODELO_FORECAST_VENTAS(
    INPUT_DATA        => SYSTEM$REFERENCE('VIEW', 'V_ML_VENTAS_DIARIAS'),
    SERIES_COLNAME    => 'SERIE',
    TIMESTAMP_COLNAME => 'TS',
    TARGET_COLNAME    => 'VENTA'
);

-- Pronóstico a 90 días con intervalos de confianza
CREATE OR REPLACE TABLE FORECAST_VENTAS_90D AS
SELECT * FROM TABLE(
    MODELO_FORECAST_VENTAS!FORECAST(FORECASTING_PERIODS => 90)
);

SELECT SERIES, TS::DATE AS FECHA, ROUND(FORECAST,0) AS PRONOSTICO,
       ROUND(LOWER_BOUND,0) AS PISO, ROUND(UPPER_BOUND,0) AS TECHO
FROM FORECAST_VENTAS_90D
ORDER BY SERIES, TS
LIMIT 20;

-- -----------------------------------------------------------
-- 6.2 ANOMALY DETECTION — facturación atípica por org de ventas
-- -----------------------------------------------------------
CREATE OR REPLACE VIEW V_ML_FACTURACION_DIARIA AS
SELECT d.FULL_DATE::TIMESTAMP_NTZ AS TS,
       f.SALES_ORG_ID             AS SERIE,
       SUM(f.NET_AMOUNT)          AS FACTURADO
FROM FACT_BILLING f
JOIN DIM_DATE d ON d.DATE_SK = f.DATE_SK
GROUP BY 1,2;

CREATE OR REPLACE SNOWFLAKE.ML.ANOMALY_DETECTION MODELO_ANOMALIAS_FACT(
    INPUT_DATA        => SYSTEM$REFERENCE('VIEW', 'V_ML_FACTURACION_DIARIA'),
    SERIES_COLNAME    => 'SERIE',
    TIMESTAMP_COLNAME => 'TS',
    TARGET_COLNAME    => 'FACTURADO',
    LABEL_COLNAME     => ''            -- no supervisado
);

-- Detectar anomalías sobre los últimos 60 días
CREATE OR REPLACE TABLE ANOMALIAS_FACTURACION AS
SELECT * FROM TABLE(
    MODELO_ANOMALIAS_FACT!DETECT_ANOMALIES(
        INPUT_DATA        => SYSTEM$QUERY_REFERENCE(
            'SELECT TS, SERIE, FACTURADO FROM V_ML_FACTURACION_DIARIA WHERE TS >= DATEADD(day,-60,CURRENT_DATE)'),
        SERIES_COLNAME    => 'SERIE',
        TIMESTAMP_COLNAME => 'TS',
        TARGET_COLNAME    => 'FACTURADO'
    )
);

SELECT SERIES, TS::DATE FECHA, Y AS FACTURADO_REAL,
       ROUND(FORECAST,0) ESPERADO, IS_ANOMALY
FROM ANOMALIAS_FACTURACION
WHERE IS_ANOMALY
ORDER BY TS DESC;

-- -----------------------------------------------------------
-- 6.3 TOP_INSIGHTS — qué segmento explica la variación (causa raíz)
-- -----------------------------------------------------------
-- Compara últimos 3 meses vs los 3 anteriores y explica el delta
CREATE OR REPLACE VIEW V_ML_CONTRIBUCION AS
SELECT
    p.PRODUCT_LINE, o.SALES_ORG_NAME, o.CHANNEL_NAME, c.REGION,
    f.NET_AMOUNT,
    IFF(d.FULL_DATE >= DATEADD(month,-3,CURRENT_DATE), TRUE, FALSE) AS ES_PERIODO_ACTUAL
FROM FACT_BILLING f
JOIN DIM_DATE d      ON d.DATE_SK = f.DATE_SK
JOIN DIM_PRODUCT p   ON p.PRODUCT_SK = f.PRODUCT_SK
JOIN DIM_SALES_ORG o ON o.SALES_ORG_ID = f.SALES_ORG_ID
JOIN DIM_CUSTOMER c  ON c.CUSTOMER_SK = f.CUSTOMER_SK
WHERE d.FULL_DATE >= DATEADD(month,-6,CURRENT_DATE);

CREATE OR REPLACE SNOWFLAKE.ML.TOP_INSIGHTS MODELO_INSIGHTS();

CREATE OR REPLACE TABLE INSIGHTS_VARIACION AS
SELECT * FROM TABLE(
    MODELO_INSIGHTS!GET_DRIVERS(
        INPUT_DATA      => SYSTEM$REFERENCE('VIEW','V_ML_CONTRIBUCION'),
        LABEL_COLNAME   => 'ES_PERIODO_ACTUAL',
        METRIC_COLNAME  => 'NET_AMOUNT'
    )
);

SELECT * FROM INSIGHTS_VARIACION ORDER BY ABS(RELATIVE_CHANGE) DESC LIMIT 10;

-- -----------------------------------------------------------
-- 6.4 Cortex LLM — reclamos de calidad: sentimiento + clasificación
-- (simula el caso "análisis de texto sobre reclamos" de la propuesta)
-- -----------------------------------------------------------
CREATE OR REPLACE TABLE RECLAMOS_DEMO (
    RECLAMO_ID NUMBER, CUSTOMER_SK NUMBER, FECHA DATE, TEXTO VARCHAR
);
INSERT INTO RECLAMOS_DEMO VALUES
 (1, 1, CURRENT_DATE-10, 'El pedido llegó con dos días de retraso y la cadena de frío estaba cortada, varios pollos en mal estado.'),
 (2, 2, CURRENT_DATE-8,  'Excelente atención del distribuidor, todo llegó en tiempo y forma.'),
 (3, 3, CURRENT_DATE-6,  'La factura no coincide con lo entregado, faltan 12 cajas de alimento balanceado.'),
 (4, 4, CURRENT_DATE-4,  'Producto correcto pero el empaque venía dañado en el 10% de las unidades.'),
 (5, 5, CURRENT_DATE-2,  'Muy conformes con la nueva línea de huevos, la rotación en góndola mejoró.');

CREATE OR REPLACE TABLE RECLAMOS_ANALIZADOS AS
SELECT
    RECLAMO_ID, FECHA, TEXTO,
    SNOWFLAKE.CORTEX.SENTIMENT(TEXTO)                                        AS SENTIMIENTO,   -- -1 a 1
    SNOWFLAKE.CORTEX.CLASSIFY_TEXT(
        TEXTO, ['Logística/Entrega','Calidad de producto','Facturación','Elogio']
    ):label::VARCHAR                                                          AS CATEGORIA,
    SNOWFLAKE.CORTEX.SUMMARIZE(TEXTO)                                         AS RESUMEN
FROM RECLAMOS_DEMO;

SELECT * FROM RECLAMOS_ANALIZADOS ORDER BY SENTIMIENTO;

-- -----------------------------------------------------------
-- 6.5 (Opcional demo "wow") COMPLETE: pregunta en lenguaje natural
-- -----------------------------------------------------------
-- SELECT SNOWFLAKE.CORTEX.COMPLETE(
--     'claude-sonnet-4-5',
--     'Resumí en 3 bullets para una gerencia comercial: ' ||
--     (SELECT LISTAGG(CATEGORIA || ' (' || ROUND(SENTIMIENTO,2) || ')', '; ')
--      FROM RECLAMOS_ANALIZADOS)
-- );

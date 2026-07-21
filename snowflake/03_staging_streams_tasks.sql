-- ============================================================
-- 03 · STAGING — tipado + cleansing de rarezas SAP + Streams & Tasks
--   · fechas '00000000' → NULL
--   · ALPHA: se quitan ceros a la izquierda en códigos
--   · signo trailing: '1234.56-' → -1234.56
-- Streams sobre RAW + Tasks que propagan cambios (patrón real
-- de la propuesta; en la demo se pueden ejecutar a mano).
-- ============================================================

USE ROLE SYSADMIN;
USE WAREHOUSE WH_DEMO;
USE SCHEMA DWH_DEMO.STAGING;

-- -----------------------------------------------------------
-- 3.1 UDFs de normalización SAP (reutilizables)
-- -----------------------------------------------------------
CREATE OR REPLACE FUNCTION F_SAP_DATE(d VARCHAR)
RETURNS DATE
AS $$ IFF(d IS NULL OR d = '00000000' OR NOT d REGEXP '^[0-9]{8}$', NULL, TO_DATE(d,'YYYYMMDD')) $$;

CREATE OR REPLACE FUNCTION F_SAP_ALPHA(v VARCHAR)
RETURNS VARCHAR
AS $$ IFF(v REGEXP '^0*[0-9]+$', LTRIM(v,'0'), v) $$;

CREATE OR REPLACE FUNCTION F_SAP_AMOUNT(a VARCHAR)
RETURNS NUMBER(18,2)
AS $$ IFF(RIGHT(a,1) = '-', -1 * TRY_TO_NUMBER(LEFT(a, LEN(a)-1), 18, 2), TRY_TO_NUMBER(a, 18, 2)) $$;

-- -----------------------------------------------------------
-- 3.2 Tablas STAGING (tipadas y limpias, con hash para SCD)
-- -----------------------------------------------------------
CREATE OR REPLACE TABLE STG_SALES_ORDERS AS
SELECT
    F_SAP_ALPHA(VBELN)                  AS ORDER_ID,
    F_SAP_ALPHA(POSNR)                  AS ITEM_NO,
    F_SAP_DATE(AUDAT)                   AS ORDER_DATE,
    F_SAP_ALPHA(KUNNR)                  AS CUSTOMER_ID,
    F_SAP_ALPHA(MATNR)                  AS PRODUCT_ID,
    VKORG                               AS SALES_ORG_ID,
    VTWEG                               AS CHANNEL_ID,
    SPART                               AS DIVISION_ID,
    TRY_TO_NUMBER(KWMENG, 18, 3)        AS QUANTITY,
    F_SAP_AMOUNT(NETWR)                 AS NET_AMOUNT,
    WAERK                               AS CURRENCY,
    _LOADED_AT
FROM DWH_DEMO.RAW.RAW_SALES_ORDERS;

CREATE OR REPLACE TABLE STG_BILLING AS
SELECT
    F_SAP_ALPHA(VBELN)                  AS BILLING_ID,
    F_SAP_ALPHA(POSNR)                  AS ITEM_NO,
    F_SAP_DATE(FKDAT)                   AS BILLING_DATE,
    F_SAP_ALPHA(KUNAG)                  AS CUSTOMER_ID,
    F_SAP_ALPHA(MATNR)                  AS PRODUCT_ID,
    VKORG                               AS SALES_ORG_ID,
    TRY_TO_NUMBER(FKIMG, 18, 3)         AS QUANTITY,
    F_SAP_AMOUNT(NETWR)                 AS NET_AMOUNT,
    WAERK                               AS CURRENCY,
    F_SAP_ALPHA(AUBEL)                  AS REF_ORDER_ID,
    _LOADED_AT
FROM DWH_DEMO.RAW.RAW_BILLING;

CREATE OR REPLACE TABLE STG_CUSTOMERS AS
SELECT
    F_SAP_ALPHA(KUNNR)                  AS CUSTOMER_ID,
    NAME1                               AS CUSTOMER_NAME,
    STCD1                               AS TAX_ID,
    SMTP_ADDR                           AS EMAIL,
    ORT01                               AS CITY,
    REGIO                               AS REGION,
    LAND1                               AS COUNTRY,
    KDGRP                               AS CUSTOMER_GROUP,
    F_SAP_DATE(ERDAT)                   AS CREATED_DATE,
    MD5(COALESCE(NAME1,'') || '|' || COALESCE(STCD1,'') || '|' ||
        COALESCE(SMTP_ADDR,'') || '|' || COALESCE(ORT01,'') || '|' ||
        COALESCE(REGIO,'') || '|' || COALESCE(KDGRP,''))  AS ROW_HASH,
    _LOADED_AT
FROM DWH_DEMO.RAW.RAW_CUSTOMERS;

CREATE OR REPLACE TABLE STG_MATERIALS AS
SELECT
    F_SAP_ALPHA(MATNR)                  AS PRODUCT_ID,
    MAKTX                               AS PRODUCT_NAME,
    MTART                               AS PRODUCT_TYPE,
    MATKL                               AS PRODUCT_LINE,
    MEINS                               AS BASE_UOM,
    SPART                               AS DIVISION_ID,
    MD5(COALESCE(MAKTX,'') || '|' || COALESCE(MATKL,'') || '|' ||
        COALESCE(MEINS,'') || '|' || COALESCE(SPART,'')) AS ROW_HASH,
    _LOADED_AT
FROM DWH_DEMO.RAW.RAW_MATERIALS;

CREATE OR REPLACE TABLE STG_SALES_ORG AS
SELECT VKORG AS SALES_ORG_ID, VTEXT AS SALES_ORG_NAME,
       VTWEG AS CHANNEL_ID, VTWEG_TXT AS CHANNEL_NAME,
       SPART AS DIVISION_ID, SPART_TXT AS DIVISION_NAME,
       _LOADED_AT
FROM DWH_DEMO.RAW.RAW_SALES_ORG;

CREATE OR REPLACE TABLE STG_BUDGET AS
SELECT TRY_TO_NUMBER(ANIO) AS BUDGET_YEAR,
       TRY_TO_NUMBER(MES)  AS BUDGET_MONTH,
       VKORG AS SALES_ORG_ID,
       MATKL AS PRODUCT_LINE,
       TRY_TO_NUMBER(IMPORTE_PPTO, 18, 2) AS BUDGET_AMOUNT,
       _LOADED_AT
FROM DWH_DEMO.RAW.RAW_BUDGET;

-- -----------------------------------------------------------
-- 3.3 Streams sobre RAW (capturan deltas de futuras cargas)
-- -----------------------------------------------------------
CREATE OR REPLACE STREAM DWH_DEMO.RAW.STR_SALES_ORDERS ON TABLE DWH_DEMO.RAW.RAW_SALES_ORDERS APPEND_ONLY = TRUE;
CREATE OR REPLACE STREAM DWH_DEMO.RAW.STR_BILLING      ON TABLE DWH_DEMO.RAW.RAW_BILLING      APPEND_ONLY = TRUE;
CREATE OR REPLACE STREAM DWH_DEMO.RAW.STR_CUSTOMERS    ON TABLE DWH_DEMO.RAW.RAW_CUSTOMERS    APPEND_ONLY = TRUE;

-- -----------------------------------------------------------
-- 3.4 Task de ejemplo: propaga deltas de órdenes RAW → STAGING
--     (MERGE idempotente por clave natural, como en la propuesta)
--     Para la demo queda SUSPENDIDA; se muestra y se ejecuta a mano.
-- -----------------------------------------------------------
CREATE OR REPLACE TASK TSK_LOAD_STG_SALES_ORDERS
  WAREHOUSE = WH_DEMO
  SCHEDULE  = '180 MINUTE'          -- refresco 2–3 hs, como Comercial en la propuesta
  WHEN SYSTEM$STREAM_HAS_DATA('DWH_DEMO.RAW.STR_SALES_ORDERS')
AS
MERGE INTO STG_SALES_ORDERS t
USING (
    SELECT F_SAP_ALPHA(VBELN) ORDER_ID, F_SAP_ALPHA(POSNR) ITEM_NO,
           F_SAP_DATE(AUDAT) ORDER_DATE, F_SAP_ALPHA(KUNNR) CUSTOMER_ID,
           F_SAP_ALPHA(MATNR) PRODUCT_ID, VKORG SALES_ORG_ID, VTWEG CHANNEL_ID,
           SPART DIVISION_ID, TRY_TO_NUMBER(KWMENG,18,3) QUANTITY,
           F_SAP_AMOUNT(NETWR) NET_AMOUNT, WAERK CURRENCY, _LOADED_AT
    FROM DWH_DEMO.RAW.STR_SALES_ORDERS
    QUALIFY ROW_NUMBER() OVER (PARTITION BY VBELN, POSNR ORDER BY _LOADED_AT DESC) = 1
) s
ON t.ORDER_ID = s.ORDER_ID AND t.ITEM_NO = s.ITEM_NO
WHEN MATCHED THEN UPDATE SET
    t.ORDER_DATE = s.ORDER_DATE, t.CUSTOMER_ID = s.CUSTOMER_ID,
    t.PRODUCT_ID = s.PRODUCT_ID, t.QUANTITY = s.QUANTITY,
    t.NET_AMOUNT = s.NET_AMOUNT, t._LOADED_AT = s._LOADED_AT
WHEN NOT MATCHED THEN INSERT
    (ORDER_ID, ITEM_NO, ORDER_DATE, CUSTOMER_ID, PRODUCT_ID, SALES_ORG_ID,
     CHANNEL_ID, DIVISION_ID, QUANTITY, NET_AMOUNT, CURRENCY, _LOADED_AT)
VALUES
    (s.ORDER_ID, s.ITEM_NO, s.ORDER_DATE, s.CUSTOMER_ID, s.PRODUCT_ID, s.SALES_ORG_ID,
     s.CHANNEL_ID, s.DIVISION_ID, s.QUANTITY, s.NET_AMOUNT, s.CURRENCY, s._LOADED_AT);

-- ALTER TASK TSK_LOAD_STG_SALES_ORDERS RESUME;   -- activarla solo si querés mostrarla viva
-- EXECUTE TASK TSK_LOAD_STG_SALES_ORDERS;        -- o dispararla a mano en la demo

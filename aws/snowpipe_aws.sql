-- ============================================================
-- snowpipe_aws.sql — DataHeiß · ingesta automática S3 → RAW
-- Reemplaza al INSERT simulado del script 02 del kit demo:
-- acá RAW se alimenta con lo que la Lambda deja en S3.
--
-- Prerrequisitos: scripts snowflake/00 y 01 ejecutados;
-- bucket creado por deploy_aws.sh.
-- Doc oficial: https://docs.snowflake.com/en/user-guide/data-load-snowpipe-auto-s3
-- ============================================================

USE ROLE ACCOUNTADMIN;
USE DATABASE DWH_DEMO;
USE SCHEMA RAW;

-- -----------------------------------------------------------
-- 1) Storage Integration: Snowflake asume un rol IAM de tu cuenta
--    (el patrón seguro: sin access keys hardcodeadas)
-- -----------------------------------------------------------
CREATE OR REPLACE STORAGE INTEGRATION INT_S3_LANDING
  TYPE = EXTERNAL_STAGE
  STORAGE_PROVIDER = 'S3'
  ENABLED = TRUE
  STORAGE_AWS_ROLE_ARN = 'arn:aws:iam::<TU_ACCOUNT_ID>:role/dataheiss-snowflake-access'
  STORAGE_ALLOWED_LOCATIONS = ('s3://<TU_BUCKET>/landing/');

-- Ver los valores que hay que poner en el trust policy del rol IAM:
DESC INTEGRATION INT_S3_LANDING;
-- → STORAGE_AWS_IAM_USER_ARN y STORAGE_AWS_EXTERNAL_ID
-- Crear en AWS el rol 'dataheiss-snowflake-access' con:
--   · trust policy: Principal = STORAGE_AWS_IAM_USER_ARN,
--     Condition sts:ExternalId = STORAGE_AWS_EXTERNAL_ID
--   · permisos: s3:GetObject, s3:GetObjectVersion, s3:ListBucket
--     sobre el bucket/prefijo de landing.
-- (Paso a paso completo en el doc oficial linkeado arriba.)

-- -----------------------------------------------------------
-- 2) File format + Stage externo
-- -----------------------------------------------------------
CREATE OR REPLACE FILE FORMAT FF_PARQUET TYPE = PARQUET;

CREATE OR REPLACE STAGE STG_LANDING_S3
  URL = 's3://<TU_BUCKET>/landing/'
  STORAGE_INTEGRATION = INT_S3_LANDING
  FILE_FORMAT = FF_PARQUET;

-- Probar visibilidad (después de la primera corrida de la Lambda):
LIST @STG_LANDING_S3;

-- -----------------------------------------------------------
-- 3) Ajuste a las tablas RAW: el extractor escribe _EXTRACTED_AT
-- -----------------------------------------------------------
ALTER TABLE RAW_SALES_ORDERS ADD COLUMN IF NOT EXISTS _EXTRACTED_AT VARCHAR;
ALTER TABLE RAW_BILLING      ADD COLUMN IF NOT EXISTS _EXTRACTED_AT VARCHAR;
ALTER TABLE RAW_CUSTOMERS    ADD COLUMN IF NOT EXISTS _EXTRACTED_AT VARCHAR;
ALTER TABLE RAW_MATERIALS    ADD COLUMN IF NOT EXISTS _EXTRACTED_AT VARCHAR;

-- -----------------------------------------------------------
-- 4) Pipes con auto-ingest: un pipe por entidad/prefijo
--    MATCH_BY_COLUMN_NAME: el parquet ya trae los nombres RAW.
-- -----------------------------------------------------------
CREATE OR REPLACE PIPE PIPE_SALES_ORDERS AUTO_INGEST = TRUE AS
  COPY INTO RAW_SALES_ORDERS
  FROM @STG_LANDING_S3/sales_orders/
  FILE_FORMAT = FF_PARQUET
  MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE;

CREATE OR REPLACE PIPE PIPE_BILLING AUTO_INGEST = TRUE AS
  COPY INTO RAW_BILLING
  FROM @STG_LANDING_S3/billing/
  FILE_FORMAT = FF_PARQUET
  MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE;

CREATE OR REPLACE PIPE PIPE_CUSTOMERS AUTO_INGEST = TRUE AS
  COPY INTO RAW_CUSTOMERS
  FROM @STG_LANDING_S3/customers/
  FILE_FORMAT = FF_PARQUET
  MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE;

CREATE OR REPLACE PIPE PIPE_MATERIALS AUTO_INGEST = TRUE AS
  COPY INTO RAW_MATERIALS
  FROM @STG_LANDING_S3/materials/
  FILE_FORMAT = FF_PARQUET
  MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE;

-- -----------------------------------------------------------
-- 5) Conectar el bucket a los pipes (lado AWS)
-- -----------------------------------------------------------
SHOW PIPES;
-- Copiar 'notification_channel' (es UNA sola SQS para todos los pipes
-- del stage) y configurar la notificación del bucket con el comando
-- que imprime deploy_aws.sh en su paso 7.

-- -----------------------------------------------------------
-- 6) Verificación y troubleshooting
-- -----------------------------------------------------------
-- Estado del pipe:
SELECT SYSTEM$PIPE_STATUS('PIPE_SALES_ORDERS');
-- Historial de cargas (última hora):
SELECT * FROM TABLE(INFORMATION_SCHEMA.COPY_HISTORY(
    TABLE_NAME => 'RAW_SALES_ORDERS',
    START_TIME => DATEADD(hour, -1, CURRENT_TIMESTAMP())));
-- Forzar refresh manual (relee el stage; útil la primera vez):
ALTER PIPE PIPE_SALES_ORDERS REFRESH;

-- A partir de acá, el flujo continúa con los scripts 03→06 del kit:
-- los streams sobre RAW capturan lo que Snowpipe inserta, y la task
-- TSK_LOAD_STG_SALES_ORDERS (ahora sí, RESUME) propaga a STAGING.

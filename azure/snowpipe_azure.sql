-- ============================================================
-- snowpipe_azure.sql — DataHeiß · ingesta automática ADLS → RAW
-- Espejo de snowpipe_aws.sql para la rama Azure.
-- Prerrequisitos: scripts snowflake/00 y 01 ejecutados; storage,
-- queue y event-grid subscription creados por deploy_azure.sh.
-- Doc oficial: https://docs.snowflake.com/en/user-guide/data-load-snowpipe-auto-azure
-- ============================================================

USE ROLE ACCOUNTADMIN;
USE DATABASE DWH_DEMO;
USE SCHEMA RAW;

-- -----------------------------------------------------------
-- 1) Storage Integration (acceso al ADLS con service principal
--    que Snowflake crea en tu tenant al dar consentimiento)
-- -----------------------------------------------------------
CREATE OR REPLACE STORAGE INTEGRATION INT_ADLS_LANDING
  TYPE = EXTERNAL_STAGE
  STORAGE_PROVIDER = 'AZURE'
  ENABLED = TRUE
  AZURE_TENANT_ID = '<TU_TENANT_ID>'
  STORAGE_ALLOWED_LOCATIONS = ('azure://<TU_STORAGE>.blob.core.windows.net/landing/');

DESC INTEGRATION INT_ADLS_LANDING;
-- → AZURE_CONSENT_URL: abrirla en el navegador y aceptar (crea el
--   service principal de Snowflake en el tenant).
-- → AZURE_MULTI_TENANT_APP_NAME: a ese principal darle el rol
--   'Storage Blob Data Reader' sobre la cuenta de storage:
--   az role assignment create --assignee "<app_name sin sufijo>" \
--     --role "Storage Blob Data Reader" --scope <id de la storage account>

-- -----------------------------------------------------------
-- 2) Notification Integration (Event Grid → Storage Queue)
-- -----------------------------------------------------------
CREATE OR REPLACE NOTIFICATION INTEGRATION INT_EVGRID_LANDING
  ENABLED = TRUE
  TYPE = QUEUE
  NOTIFICATION_PROVIDER = AZURE_STORAGE_QUEUE
  AZURE_STORAGE_QUEUE_PRIMARY_URI = 'https://<TU_STORAGE>.queue.core.windows.net/snowpipe-queue'
  AZURE_TENANT_ID = '<TU_TENANT_ID>';

DESC INTEGRATION INT_EVGRID_LANDING;
-- → misma mecánica: AZURE_CONSENT_URL + dar al principal el rol
--   'Storage Queue Data Contributor' sobre la cuenta de storage.

-- -----------------------------------------------------------
-- 3) File format + Stage externo
-- -----------------------------------------------------------
CREATE OR REPLACE FILE FORMAT FF_PARQUET TYPE = PARQUET;

CREATE OR REPLACE STAGE STG_LANDING_ADLS
  URL = 'azure://<TU_STORAGE>.blob.core.windows.net/landing/'
  STORAGE_INTEGRATION = INT_ADLS_LANDING
  FILE_FORMAT = FF_PARQUET;

LIST @STG_LANDING_ADLS;

-- -----------------------------------------------------------
-- 4) Columna extra en RAW (si no se corrió snowpipe_aws.sql)
-- -----------------------------------------------------------
ALTER TABLE RAW_SALES_ORDERS ADD COLUMN IF NOT EXISTS _EXTRACTED_AT VARCHAR;
ALTER TABLE RAW_BILLING      ADD COLUMN IF NOT EXISTS _EXTRACTED_AT VARCHAR;
ALTER TABLE RAW_CUSTOMERS    ADD COLUMN IF NOT EXISTS _EXTRACTED_AT VARCHAR;
ALTER TABLE RAW_MATERIALS    ADD COLUMN IF NOT EXISTS _EXTRACTED_AT VARCHAR;

-- -----------------------------------------------------------
-- 5) Pipes con auto-ingest (nótese INTEGRATION = la notification)
-- -----------------------------------------------------------
CREATE OR REPLACE PIPE PIPE_SALES_ORDERS_AZ AUTO_INGEST = TRUE
  INTEGRATION = 'INT_EVGRID_LANDING' AS
  COPY INTO RAW_SALES_ORDERS
  FROM @STG_LANDING_ADLS/sales_orders/
  FILE_FORMAT = FF_PARQUET
  MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE;

CREATE OR REPLACE PIPE PIPE_BILLING_AZ AUTO_INGEST = TRUE
  INTEGRATION = 'INT_EVGRID_LANDING' AS
  COPY INTO RAW_BILLING
  FROM @STG_LANDING_ADLS/billing/
  FILE_FORMAT = FF_PARQUET
  MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE;

CREATE OR REPLACE PIPE PIPE_CUSTOMERS_AZ AUTO_INGEST = TRUE
  INTEGRATION = 'INT_EVGRID_LANDING' AS
  COPY INTO RAW_CUSTOMERS
  FROM @STG_LANDING_ADLS/customers/
  FILE_FORMAT = FF_PARQUET
  MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE;

CREATE OR REPLACE PIPE PIPE_MATERIALS_AZ AUTO_INGEST = TRUE
  INTEGRATION = 'INT_EVGRID_LANDING' AS
  COPY INTO RAW_MATERIALS
  FROM @STG_LANDING_ADLS/materials/
  FILE_FORMAT = FF_PARQUET
  MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE;

-- -----------------------------------------------------------
-- 6) Verificación
-- -----------------------------------------------------------
SELECT SYSTEM$PIPE_STATUS('PIPE_SALES_ORDERS_AZ');
SELECT * FROM TABLE(INFORMATION_SCHEMA.COPY_HISTORY(
    TABLE_NAME => 'RAW_SALES_ORDERS',
    START_TIME => DATEADD(hour, -1, CURRENT_TIMESTAMP())));
ALTER PIPE PIPE_SALES_ORDERS_AZ REFRESH;

-- Igual que en AWS: de acá en más siguen los scripts 03→06 del kit.

-- ============================================================
-- 01 · Capa RAW — landing 1:1 de la extracción CDS/OData (simulada)
-- Todo llega como VARCHAR, tal cual vendría del OData de SAP:
-- fechas '00000000', ceros a la izquierda (ALPHA), signo trailing.
-- Cada tabla lleva metadata de ingesta (como si viniera de Snowpipe).
-- ============================================================

USE ROLE SYSADMIN;
USE WAREHOUSE WH_DEMO;
USE SCHEMA DWH_DEMO.RAW;

-- Órdenes de venta (simula CDS I_SalesDocument / VBAK+VBAP aplanado)
CREATE OR REPLACE TABLE RAW_SALES_ORDERS (
    VBELN        VARCHAR,      -- nro de orden (con ceros a la izquierda)
    POSNR        VARCHAR,      -- posición
    AUDAT        VARCHAR,      -- fecha documento YYYYMMDD ('00000000' si falta)
    KUNNR        VARCHAR,      -- cliente
    MATNR        VARCHAR,      -- material
    VKORG        VARCHAR,      -- org. de ventas
    VTWEG        VARCHAR,      -- canal
    SPART        VARCHAR,      -- sector
    KWMENG       VARCHAR,      -- cantidad
    NETWR        VARCHAR,      -- importe neto (puede venir '1234.56-' signo trailing)
    WAERK        VARCHAR,      -- moneda
    -- metadata de ingesta (Snowpipe la agrega en la realidad)
    _SOURCE_FILE VARCHAR DEFAULT 'demo_generator',
    _LOADED_AT   TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

-- Facturación (simula CDS I_BillingDocumentItem / VBRK+VBRP)
CREATE OR REPLACE TABLE RAW_BILLING (
    VBELN        VARCHAR,      -- nro de factura
    POSNR        VARCHAR,
    FKDAT        VARCHAR,      -- fecha de factura YYYYMMDD
    KUNAG        VARCHAR,      -- cliente pagador
    MATNR        VARCHAR,
    VKORG        VARCHAR,
    FKIMG        VARCHAR,      -- cantidad facturada
    NETWR        VARCHAR,      -- importe (signo trailing posible: nota de crédito)
    WAERK        VARCHAR,
    AUBEL        VARCHAR,      -- orden de venta de referencia
    _SOURCE_FILE VARCHAR DEFAULT 'demo_generator',
    _LOADED_AT   TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

-- Maestro de clientes (simula I_Customer / KNA1) — incluye PII
CREATE OR REPLACE TABLE RAW_CUSTOMERS (
    KUNNR        VARCHAR,
    NAME1        VARCHAR,      -- razón social (PII)
    STCD1        VARCHAR,      -- RUC (PII)
    SMTP_ADDR    VARCHAR,      -- email (PII)
    ORT01        VARCHAR,      -- ciudad
    REGIO        VARCHAR,      -- región
    LAND1        VARCHAR,      -- país
    KDGRP        VARCHAR,      -- grupo de clientes
    ERDAT        VARCHAR,      -- fecha alta YYYYMMDD
    _SOURCE_FILE VARCHAR DEFAULT 'demo_generator',
    _LOADED_AT   TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

-- Maestro de materiales (simula I_Product / MARA)
CREATE OR REPLACE TABLE RAW_MATERIALS (
    MATNR        VARCHAR,
    MAKTX        VARCHAR,      -- descripción
    MTART        VARCHAR,      -- tipo de material
    MATKL        VARCHAR,      -- grupo (línea de producto)
    MEINS        VARCHAR,      -- unidad base
    SPART        VARCHAR,      -- sector
    _SOURCE_FILE VARCHAR DEFAULT 'demo_generator',
    _LOADED_AT   TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

-- Organización de ventas (simula TVKO + textos)
CREATE OR REPLACE TABLE RAW_SALES_ORG (
    VKORG        VARCHAR,
    VTEXT        VARCHAR,
    VTWEG        VARCHAR,
    VTWEG_TXT    VARCHAR,
    SPART        VARCHAR,
    SPART_TXT    VARCHAR,
    _SOURCE_FILE VARCHAR DEFAULT 'demo_generator',
    _LOADED_AT   TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

-- Presupuesto comercial (simula el Excel fuera de SAP)
CREATE OR REPLACE TABLE RAW_BUDGET (
    ANIO         VARCHAR,
    MES          VARCHAR,
    VKORG        VARCHAR,
    MATKL        VARCHAR,      -- línea de producto
    IMPORTE_PPTO VARCHAR,
    _SOURCE_FILE VARCHAR DEFAULT 'excel_presupuesto_demo',
    _LOADED_AT   TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

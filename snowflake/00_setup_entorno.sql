-- ============================================================
-- DEMO DataHeiß — Plataforma Analítica (simulación Montana)
-- 00 · Setup de entorno: warehouse, database, schemas
-- Ejecutar como: ACCOUNTADMIN (solo esta vez)
-- ============================================================

USE ROLE ACCOUNTADMIN;

-- Warehouse chico para la demo (auto-suspend agresivo = costo mínimo)
CREATE WAREHOUSE IF NOT EXISTS WH_DEMO
  WAREHOUSE_SIZE = 'XSMALL'
  AUTO_SUSPEND = 60
  AUTO_RESUME = TRUE
  INITIALLY_SUSPENDED = TRUE
  COMMENT = 'Warehouse XS para demo comercial DataHeiß';

-- Database de la demo (simula el ambiente PROD del cliente)
CREATE DATABASE IF NOT EXISTS DWH_DEMO
  COMMENT = 'Demo Data Warehouse — dominio Comercial (SAP SD simulado)';

USE DATABASE DWH_DEMO;

-- Medallion: RAW → STAGING → CURATED (igual que la propuesta)
CREATE SCHEMA IF NOT EXISTS RAW      COMMENT = 'Landing 1:1 desde la fuente (CDS/OData simulado). Sin transformar.';
CREATE SCHEMA IF NOT EXISTS STAGING  COMMENT = 'Tipado, cleansing, normalización de rarezas SAP.';
CREATE SCHEMA IF NOT EXISTS CURATED  COMMENT = 'Modelo dimensional: facts + dims con SCD2. Consumo Power BI.';
CREATE SCHEMA IF NOT EXISTS GOVERNANCE COMMENT = 'DQ, cuarentena, auditoría, políticas de masking.';

USE WAREHOUSE WH_DEMO;
USE SCHEMA RAW;

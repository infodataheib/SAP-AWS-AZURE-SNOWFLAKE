-- ============================================================
-- 02 · Datos genéricos — generación 100% SQL (GENERATOR)
-- Inyecta a propósito las "rarezas SAP" que la Fase 3 va a limpiar:
--   · fechas '00000000'
--   · ceros a la izquierda (conversión ALPHA)
--   · signo trailing en importes ('1234.56-')
--   · duplicados, huérfanos y nulos para que las reglas DQ tengan
--     algo que atrapar en la demo.
-- Volumen: ~24 meses de historia, ~50k posiciones de orden.
-- ============================================================

USE ROLE SYSADMIN;
USE WAREHOUSE WH_DEMO;
USE SCHEMA DWH_DEMO.RAW;

-- -----------------------------------------------------------
-- 2.1 Organización de ventas (fija, chica)
-- -----------------------------------------------------------
INSERT INTO RAW_SALES_ORG (VKORG, VTEXT, VTWEG, VTWEG_TXT, SPART, SPART_TXT) VALUES
 ('1000','Ventas Lima',      '10','Directo',      '01','Aves'),
 ('1000','Ventas Lima',      '20','Distribuidores','02','Cerdos'),
 ('2000','Ventas Norte',     '10','Directo',      '01','Aves'),
 ('2000','Ventas Norte',     '20','Distribuidores','03','Alimentos'),
 ('3000','Ventas Sur',       '10','Directo',      '02','Cerdos'),
 ('3000','Ventas Sur',       '20','Distribuidores','03','Alimentos');

-- -----------------------------------------------------------
-- 2.2 Clientes: 300, con PII sintética y ~2% de datos sucios
-- -----------------------------------------------------------
INSERT INTO RAW_CUSTOMERS (KUNNR, NAME1, STCD1, SMTP_ADDR, ORT01, REGIO, LAND1, KDGRP, ERDAT)
SELECT
    LPAD(TO_VARCHAR(1000 + SEQ4()), 10, '0')                             AS KUNNR,
    'Cliente Demo ' || TO_VARCHAR(1000 + SEQ4())                          AS NAME1,
    '20' || LPAD(TO_VARCHAR(ABS(RANDOM()) % 999999999), 9, '0')           AS STCD1,
    'contacto' || TO_VARCHAR(1000 + SEQ4()) || '@clientedemo.pe'          AS SMTP_ADDR,
    DECODE(ABS(RANDOM()) % 5, 0,'Lima',1,'Arequipa',2,'Trujillo',3,'Cusco','Piura') AS ORT01,
    DECODE(ABS(RANDOM()) % 5, 0,'LIM',1,'ARE',2,'LAL',3,'CUS','PIU')      AS REGIO,
    'PE'                                                                   AS LAND1,
    DECODE(ABS(RANDOM()) % 3, 0,'01',1,'02','03')                          AS KDGRP,
    -- ~2% con fecha basura '00000000' (rareza SAP)
    IFF(ABS(RANDOM()) % 50 = 0, '00000000',
        TO_VARCHAR(DATEADD(day, -1 * (ABS(RANDOM()) % 2000), CURRENT_DATE), 'YYYYMMDD')) AS ERDAT
FROM TABLE(GENERATOR(ROWCOUNT => 300));

-- Un par de clientes SIN email ni RUC (para la regla de obligatorios)
UPDATE RAW_CUSTOMERS SET SMTP_ADDR = NULL, STCD1 = NULL
WHERE KUNNR IN (SELECT KUNNR FROM RAW_CUSTOMERS SAMPLE (3 ROWS));

-- -----------------------------------------------------------
-- 2.3 Materiales: 80, en 4 líneas de producto
-- -----------------------------------------------------------
INSERT INTO RAW_MATERIALS (MATNR, MAKTX, MTART, MATKL, MEINS, SPART)
SELECT
    LPAD(TO_VARCHAR(500000 + SEQ4()), 18, '0')                             AS MATNR,
    DECODE(ABS(RANDOM()) % 4,
        0,'Pollo entero ', 1,'Cerdo corte ', 2,'Alimento balanceado ', 'Huevos pack ')
      || TO_VARCHAR(SEQ4())                                                AS MAKTX,
    'FERT'                                                                 AS MTART,
    DECODE(ABS(RANDOM()) % 4, 0,'AVES',1,'CERDOS',2,'ALIM','HUEVOS')       AS MATKL,
    'KG'                                                                   AS MEINS,
    DECODE(ABS(RANDOM()) % 3, 0,'01',1,'02','03')                          AS SPART
FROM TABLE(GENERATOR(ROWCOUNT => 80));

-- -----------------------------------------------------------
-- 2.4 Órdenes de venta: ~50.000 posiciones, 24 meses,
--     con estacionalidad y tendencia (para que el forecast luzca)
-- -----------------------------------------------------------
INSERT INTO RAW_SALES_ORDERS (VBELN, POSNR, AUDAT, KUNNR, MATNR, VKORG, VTWEG, SPART, KWMENG, NETWR, WAERK)
WITH base AS (
    SELECT
        SEQ4() AS n,
        DATEADD(day, -1 * (ABS(RANDOM()) % 730), CURRENT_DATE) AS fecha,
        ABS(RANDOM())  AS r1,
        ABS(RANDOM())  AS r2,
        ABS(RANDOM())  AS r3
    FROM TABLE(GENERATOR(ROWCOUNT => 50000))
)
SELECT
    LPAD(TO_VARCHAR(3000000 + FLOOR(n / 3)), 10, '0')                      AS VBELN,   -- ~3 posiciones por orden
    LPAD(TO_VARCHAR((n % 3) * 10 + 10), 6, '0')                            AS POSNR,
    -- ~1% de fechas basura
    IFF(r1 % 100 = 0, '00000000', TO_VARCHAR(fecha, 'YYYYMMDD'))           AS AUDAT,
    LPAD(TO_VARCHAR(1000 + (r2 % 300)), 10, '0')                           AS KUNNR,
    LPAD(TO_VARCHAR(500000 + (r3 % 80)), 18, '0')                          AS MATNR,
    DECODE(r1 % 3, 0,'1000',1,'2000','3000')                               AS VKORG,
    DECODE(r2 % 2, 0,'10','20')                                            AS VTWEG,
    DECODE(r3 % 3, 0,'01',1,'02','03')                                     AS SPART,
    TO_VARCHAR(10 + (r1 % 490))                                            AS KWMENG,
    -- Importe con estacionalidad (más venta a fin de año) + tendencia +
    -- ~1,5% de notas con signo trailing ('-' al final, formato SAP)
    IFF(r2 % 65 = 0,
        TO_VARCHAR(ROUND(500 + (r3 % 3000) * 1.1, 2)) || '-',
        TO_VARCHAR(ROUND(
            (500 + (r3 % 3000))
            * (1 + 0.35 * SIN(MONTH(fecha) / 12 * 2 * PI()))              -- estacionalidad
            * (1 + DATEDIFF(day, DATEADD(day,-730,CURRENT_DATE), fecha) / 3650) -- tendencia leve
        , 2)))                                                             AS NETWR,
    'PEN'                                                                  AS WAERK
FROM base;

-- Duplicados intencionales (~30 filas) para la regla de unicidad
INSERT INTO RAW_SALES_ORDERS (VBELN, POSNR, AUDAT, KUNNR, MATNR, VKORG, VTWEG, SPART, KWMENG, NETWR, WAERK)
SELECT VBELN, POSNR, AUDAT, KUNNR, MATNR, VKORG, VTWEG, SPART, KWMENG, NETWR, WAERK
FROM RAW_SALES_ORDERS SAMPLE (30 ROWS);

-- Huérfanos: órdenes con cliente inexistente (integridad referencial)
INSERT INTO RAW_SALES_ORDERS (VBELN, POSNR, AUDAT, KUNNR, MATNR, VKORG, VTWEG, SPART, KWMENG, NETWR, WAERK)
SELECT LPAD(TO_VARCHAR(9900000 + SEQ4()),10,'0'), '000010',
       TO_VARCHAR(CURRENT_DATE - 5, 'YYYYMMDD'),
       '0000099999',                                    -- KUNNR que no existe
       (SELECT MAX(MATNR) FROM RAW_MATERIALS),
       '1000','10','01','25','1250.00','PEN'
FROM TABLE(GENERATOR(ROWCOUNT => 10));

-- -----------------------------------------------------------
-- 2.5 Facturación: ~85% de las órdenes se facturan, 0–5 días después
-- -----------------------------------------------------------
INSERT INTO RAW_BILLING (VBELN, POSNR, FKDAT, KUNAG, MATNR, VKORG, FKIMG, NETWR, WAERK, AUBEL)
SELECT
    LPAD(TO_VARCHAR(9000000 + ROW_NUMBER() OVER (ORDER BY VBELN, POSNR)), 10, '0') AS VBELN,
    POSNR,
    IFF(AUDAT = '00000000', '00000000',
        TO_VARCHAR(DATEADD(day, ABS(RANDOM()) % 6, TO_DATE(AUDAT,'YYYYMMDD')), 'YYYYMMDD')) AS FKDAT,
    KUNNR, MATNR, VKORG, KWMENG,
    NETWR, WAERK,
    VBELN AS AUBEL
FROM RAW_SALES_ORDERS
WHERE ABS(RANDOM()) % 100 < 85;

-- -----------------------------------------------------------
-- 2.6 Presupuesto (simula el Excel): 24 meses × org × línea
-- -----------------------------------------------------------
INSERT INTO RAW_BUDGET (ANIO, MES, VKORG, MATKL, IMPORTE_PPTO)
WITH meses AS (
    SELECT DATEADD(month, -1 * SEQ4(), DATE_TRUNC('month', CURRENT_DATE)) AS m
    FROM TABLE(GENERATOR(ROWCOUNT => 24))
),
combos AS (
    SELECT DISTINCT o.VKORG, m2.MATKL
    FROM RAW_SALES_ORG o
    CROSS JOIN (SELECT DISTINCT MATKL FROM RAW_MATERIALS) m2
)
SELECT
    TO_VARCHAR(YEAR(m)), TO_VARCHAR(MONTH(m)),
    c.VKORG, c.MATKL,
    TO_VARCHAR(ROUND(80000 + ABS(RANDOM()) % 120000, 0))
FROM meses CROSS JOIN combos c;

-- Chequeo rápido
SELECT 'RAW_SALES_ORDERS' t, COUNT(*) filas FROM RAW_SALES_ORDERS
UNION ALL SELECT 'RAW_BILLING', COUNT(*) FROM RAW_BILLING
UNION ALL SELECT 'RAW_CUSTOMERS', COUNT(*) FROM RAW_CUSTOMERS
UNION ALL SELECT 'RAW_MATERIALS', COUNT(*) FROM RAW_MATERIALS
UNION ALL SELECT 'RAW_BUDGET', COUNT(*) FROM RAW_BUDGET;

# Kit End-to-End DataHeiß — SAP → Cloud → Snowflake
**USO INTERNO — NO COMPARTIR**

Guía para replicar de punta a punta la arquitectura propuesta (Propuesta V2.2): extracción SAP vía CDS/OData → cómputo serverless → landing cloud → Snowpipe → Snowflake (RAW → STAGING → CURATED) → Fase 3 (calidad y gobierno) → ML. Dos ramas en paralelo: **AWS** y **Azure**, compartiendo el mismo extractor y el mismo warehouse.

Doble audiencia: sirve como mapa de arquitectura (Simón) y como guía de ejecución paso a paso (DE junior). Las secciones marcadas 🔧 son las que ejecuta el junior; las marcadas 🏛 son decisiones/gestiones del arquitecto.

---

## 0. Estructura del repo

```
kit_e2e_dataheiss/
├── README.md                  ← esta guía
├── extractor/                 ← código compartido entre ambas nubes
│   ├── sap_odata_extractor.py   (cliente OData + backends S3/ADLS + orquestación)
│   ├── entities.yaml            (config de entidades: sandbox api.sap.com y S/4HANA)
│   └── requirements.txt
├── aws/
│   ├── lambda_handler.py        (handler que invoca el extractor)
│   ├── deploy_aws.sh            (S3 + Secrets + IAM + Lambda + EventBridge)
│   └── snowpipe_aws.sql         (storage integration + stage + pipes)
├── azure/
│   ├── function_app.py          (Timer trigger, espejo de la Lambda)
│   ├── deploy_azure.sh          (ADLS + Key Vault + Function + Event Grid)
│   └── snowpipe_azure.sql       (notification/storage integration + pipes)
└── snowflake/                 ← warehouse completo (común a ambas ramas)
    ├── 00_setup_entorno.sql
    ├── 01_raw_landing.sql
    ├── 02_datos_genericos.sql       (OPCIONAL: solo si no hay SAP disponible)
    ├── 03_staging_streams_tasks.sql
    ├── 04_curated_modelo_dimensional.sql
    ├── 05_fase3_calidad_gobierno.sql
    └── 06_ml_cortex.sql
```

Principio de diseño: **la única parte específica de cada nube es cómo se dispara el extractor y dónde aterriza el archivo**. Todo lo demás (lógica OData, warehouse, Fase 3, ML) es idéntico. Por eso la rama Azure es un port, no un segundo desarrollo — y por eso la futura rama Databricks reutiliza extractor + landing sin tocar una línea.

---

## 1. Cuentas y accesos (🏛 gestiona Simón, usa el junior)

| Recurso | Link | Costo | Notas |
|---|---|---|---|
| Sandbox SAP Business Accelerator Hub | https://api.sap.com (botón "Get API Key" con cuenta SAP gratuita) | Gratis | Reemplaza a ES5 (discontinuado). Mismas APIs de S/4HANA en modo solo lectura, auth por header APIKey. Para desarrollar la mecánica OData antes de tocar el CAL. |
| SAP CAL (S/4HANA Fully-Activated Appliance) | https://cal.sap.com | Licencia trial 30 días gratis; **infra ~USD 3–6/h prendido** | Se despliega en TU cuenta AWS o Azure. Ver disciplina de costos (§2). |
| SAP Business Accelerator Hub (doc de las APIs) | https://api.sap.com | Gratis | Referencia de API_SALES_ORDER_SRV, API_BILLING_DOCUMENT_SRV, API_BUSINESS_PARTNER, API_PRODUCT_SRV. Tiene sandbox para probar requests. |
| AWS | https://aws.amazon.com/free | Free tier cubre Lambda/SQS; S3 centavos | Crear cuenta propia de DataHeiß, activar MFA, budget alert de USD 50. |
| Azure | https://azure.microsoft.com/free | USD 200 de crédito 30 días | Ídem: budget alert desde el día uno. |
| Snowflake | https://signup.snowflake.com | Trial 30 días, USD 400 en créditos | Elegir **Enterprise** (masking de Fase 3 + Cortex). Cloud/región: una cuenta en AWS us-east-1 y, si quieren pureza total en la rama Azure, otra en Azure — aunque para la práctica UNA cuenta alcanza: Snowflake en AWS puede leer un stage de Azure sin problema; solo se paga un egress menor. |
| Docs Snowpipe S3 | https://docs.snowflake.com/en/user-guide/data-load-snowpipe-auto-s3 | — | El paso a paso oficial del trust policy IAM. |
| Docs Snowpipe Azure | https://docs.snowflake.com/en/user-guide/data-load-snowpipe-auto-azure | — | Ídem para Event Grid + consent. |

🏛 Los tres trials (CAL, Snowflake, Azure) duran 30 días: **no los actives todos el mismo día**. Secuencia sugerida: semana 1–2 solo sandbox api.sap.com + AWS (sin CAL), recién ahí activar CAL y Snowflake, y Azure cuando la rama AWS esté cerrada.

---

## 2. El SAP de práctica y la disciplina de costos (🏛)

En https://cal.sap.com buscar el appliance **"SAP S/4HANA Fully-Activated Appliance"** (la versión más reciente disponible), conectar la cuenta AWS o Azure de DataHeiß y desplegar. Incluye datos de ejemplo del módulo SD: órdenes, facturas, clientes y materiales reales de best practices — exactamente el dominio Comercial de la propuesta, con rarezas SAP auténticas incluidas.

Reglas de oro:

1. **El appliance vive apagado.** Se prende para sesiones planificadas de extracción/desarrollo contra SAP y se apaga al terminar (CAL tiene suspend programado: usarlo). Prendido cuesta USD 3–6/h; apagado, solo los discos (~USD 100–200/mes mientras exista).
2. **Concentrar el trabajo contra SAP en pocas sesiones.** Una vez que el landing tiene archivos parquet, TODO lo de aguas abajo (Snowpipe, staging, modelo, Fase 3, ML) se desarrolla sin SAP prendido. El extractor se desarrolla antes contra el sandbox de api.sap.com, que es gratis.
3. **Al terminar la práctica, destruir la instancia CAL** (no solo suspenderla) para cortar el costo de discos.
4. Usuario de extracción en SAP: no usar el usuario dialog del appliance para la Lambda/Function; crear un usuario técnico con permisos de solo lectura sobre los servicios OData (buen ejercicio de mínimo privilegio para el junior, con guía de Simón).
5. Activar los servicios OData en el appliance: transacción `/n/IWFND/MAINT_SERVICE` (los servicios API_* suelen venir activos en el fully-activated; verificar con `/IWFND/GW_CLIENT`).

---

## 3. Plan de trabajo del junior (🔧) — Rama AWS primero

### Etapa A — Extractor contra el sandbox de api.sap.com (sin costo, ~1 semana)
> ES5 fue discontinuado (registro deshabilitado). El reemplazo es el sandbox del SAP Business Accelerator Hub: mismas APIs del perfil S/4HANA, solo lectura, auth por header `APIKey`.
1. Crear cuenta gratuita en https://api.sap.com, entrar a la API `API_SALES_ORDER_SRV` y generar el API key ("Get API Key"). Probar con curl o Postman:
   `https://sandbox.api.sap.com/s4hanacloud/sap/opu/odata/sap/API_SALES_ORDER_SRV/A_SalesOrderItem?$format=json&$top=5` con header `APIKey: <tu key>`
2. Clonar el repo, `pip install -r extractor/requirements.txt`.
3. Configurar el secreto/entorno con `api_key` (ver comentarios en `entities.yaml`; las entidades del perfil S/4HANA aplican tal cual) y correr el extractor **local** con un backend de archivos (ejercicio: escribir un `LocalBackend` de 15 líneas espejando `S3Backend`).
4. Validar: paginado (bajar PAGE_SIZE a 50 y confirmar que trae todo), watermark (la segunda corrida trae 0 filas — ojo: los datos mock del sandbox no cambian, así que el incremental real se valida recién en la Etapa D), manejo de errores (API key inválida → la corrida reporta ERROR sin explotar).
   ✅ Criterio de salida: parquets locales con columnas RAW correctas y watermark funcionando. Bonus: los nombres de campo que ves son los MISMOS del CAL — el salto de la Etapa D va a ser solo cambiar URL y autenticación.

### Etapa B — Infra AWS + Lambda (free tier, ~3 días)
1. Editar parámetros de `aws/deploy_aws.sh` y ejecutarlo (leerlo ANTES: cada bloque está comentado; la gracia es entender cada pieza, no solo correrlo).
2. Invocar la Lambda a mano (comando al final del script) apuntando todavía al sandbox de api.sap.com. Verificar: parquets en `s3://<bucket>/landing/...`, logs en CloudWatch, watermark en `_state/`.
3. Dejar el EventBridge Scheduler corriendo cada 3 hs un día entero y revisar que las corridas incrementales traen solo deltas.
   ✅ Criterio de salida: pipeline SAP(sandbox) → Lambda → S3 corriendo solo.

### Etapa C — Snowflake + Snowpipe (trial, ~3 días)
1. Crear el trial de Snowflake (Enterprise, AWS us-east-1). Ejecutar `snowflake/00` y `01`.
2. Ejecutar `aws/snowpipe_aws.sql` paso a paso: storage integration → rol IAM con trust policy (doc oficial linkeada en el script) → stage → pipes → notificación del bucket.
3. Disparar la Lambda y ver las filas aparecer en RAW sin tocar nada. Troubleshooting típico: `SYSTEM$PIPE_STATUS` y `COPY_HISTORY` (queries incluidas en el script).
4. Ejecutar `snowflake/03` a `06` en orden. La task del 03 ahora sí: `ALTER TASK ... RESUME`. El script 02 **no se corre** en este modo (los datos vienen de SAP); solo se usa si se trabaja sin CAL ni sandbox.
   ✅ Criterio de salida: end-to-end sandbox → S3 → Snowpipe → RAW → STAGING → CURATED → vistas de KPI con datos.

### Etapa D — Cambiar el sandbox por S/4HANA real (CAL) (~1 semana, sesiones cortas)
1. 🏛 Simón despliega el CAL y comparte host + credenciales del usuario técnico (por el Secrets Manager, nunca por chat/mail).
2. Actualizar el secreto (`base_url`, credenciales, `verify_ssl: false` por el certificado self-signed del appliance) y el `entities.yaml` al perfil S/4HANA. Ojo: cada API es un servicio OData distinto — el handler debe iterar una config por servicio o consolidarse con un `base_url` por entidad (ejercicio de mejora para el junior: mover `base_url` adentro de cada entrada del YAML).
3. `FULL_LOAD=true` para la carga inicial; después volver a incremental.
4. Correr todo el flujo aguas abajo. Acá aparecen las rarezas SAP DE VERDAD (fechas, ALPHA, signos): verificar que STAGING las limpia y que la Fase 3 encuarentena lo que corresponde.
5. Nota de alcance: el appliance no trae la "transacción Z" ni el Excel de presupuesto; el presupuesto se simula subiendo un parquet a mano al prefijo `budget/` (agregar el pipe correspondiente: ejercicio).
   ✅ Criterio de salida: mismo end-to-end pero con S/4HANA como fuente. **Hito principal de toda la práctica.**

### Etapa E — Fase 3 y ML sobre datos reales (~3 días)
Re-ejecutar 05 y 06 con los datos del CAL. Documentar en un doc corto: cuántos registros atrapó cada regla DQ, capturas del masking por rol, el forecast y las anomalías. Ese doc es el insumo de la demo grabada.

### Etapa F — Port a Azure (~1 semana)
1. Ejecutar `azure/deploy_azure.sh` (leerlo antes; es el espejo del de AWS con la tabla de equivalencias de la propuesta §4.1).
2. Deploy de la Function y prueba manual. Misma fuente SAP, distinto landing.
3. `azure/snowpipe_azure.sql`: acá aparecen dos integraciones (storage + notification) y el consent flow de Entra ID — es la diferencia conceptual más grande vs AWS, prestarle atención.
4. End-to-end completo por la rama Azure.
   ✅ Criterio de salida: las dos ramas alimentando el mismo warehouse (o dos cuentas, según lo decidido en §1).

**⚠️ Por qué NO usamos Azure Data Factory con conector SAP CDC:** ese conector usa el framework ODP por debajo, que es exactamente lo que la Nota SAP 3255746 restringe para herramientas de terceros. Nuestra vía compatible es Function → OData. Si algún cliente pregunta por ADF, la respuesta es: "para orquestación general sí; para extraer de SAP, solo por las vías que SAP permite".

---

## 4. Qué queda listo

Al completar A–F, el día uno de la Fase 2 real se tiene: extractor probado contra un S/4HANA verdadero, infra de ambas nubes como scripts reproducibles, warehouse completo con Fase 3 y ML, y un junior (o el DE contratado) que ya recorrió cada pieza. Los deltas contra el proyecto real: confirmar qué CDS views están liberadas y son Delta-Enabled en el sistema del cliente  (Fase 1, contra el Order Form), la transacción Z (requiere su propio servicio OData o CDS custom — se diseña en Fase 1), el Excel de presupuesto real, y ambientes DEV → PROD (duplicar database + warehouse; trivial con estos scripts porque todo es código).

## 5. Rama Databricks (🏛 Simón) — mapa de porteo

Reutiliza intactos: extractor, ambas infras de landing, y la lógica de negocio de los scripts SQL (que se traducen, no se reescriben):

| Pieza Snowflake | Equivalente Databricks |
|---|---|
| Snowpipe auto-ingest | Auto Loader (`cloudFiles`) sobre el mismo S3/ADLS |
| RAW / STAGING / CURATED | bronze / silver / gold en Delta Lake + Unity Catalog |
| Streams & Tasks + MERGE | DLT (Lakeflow) pipelines o Jobs + `MERGE INTO` Delta |
| UDFs de limpieza SAP | mismas expresiones en PySpark/SQL UDFs |
| Reglas DQ + cuarentena | DLT expectations (`expect_or_drop` + quarantine table) |
| PIPELINE_AUDIT | tabla Delta + event log de DLT |
| RBAC + masking | Unity Catalog: grants + row filters/column masks |
| FORECAST / ANOMALY / TOP_INSIGHTS | AutoML / prophet en notebooks + MLflow |
| Cortex (sentimiento, clasificación) | `ai_query()` / Foundation Model APIs |

## 6. Presupuesto total estimado de la práctica

| Concepto | Estimación |
|---|---|
| Sandbox api.sap.com, cuentas, docs | USD 0 |
| CAL (infra, con disciplina on/off, ~1 mes) | USD 200–400 |
| AWS (S3/Lambda/SQS/Secrets) | USD 0–10 (free tier) |
| Azure (con el crédito de USD 200) | USD 0 |
| Snowflake (trial USD 400 en créditos) | USD 0 |
| **Total efectivo** | **USD 200–400, casi todo CAL** |

El único costo real es el appliance SAP: la disciplina de prender/apagar es lo que mantiene este número. Un CAL olvidado prendido un fin de semana son ~USD 300 solos.

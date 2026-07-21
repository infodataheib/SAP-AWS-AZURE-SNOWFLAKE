"""
function_app.py — DataHeiß · rama Azure
Azure Function (modelo v2, Python) con Timer trigger cada 180 min.
Espejo exacto de la Lambda: invoca el mismo extractor compartido.

Secretos: Key Vault vía referencias en App Settings (la Function los
  ve como variables de entorno; no hay código de Key Vault acá).
Identidad: Managed Identity de la Function (DefaultAzureCredential),
  con rol 'Storage Blob Data Contributor' sobre la cuenta de landing.
Landing: ADLS Gen2 → Event Grid → Snowpipe auto-ingest.
Logs: Application Insights (logging estándar).

App settings esperadas (ver deploy_azure.sh):
  LANDING_ACCOUNT_URL = https://<cuenta>.blob.core.windows.net
  LANDING_CONTAINER   = landing
  SAP_BASE_URL / SAP_USER / SAP_PASSWORD  (referencias a Key Vault)
  FULL_LOAD           = "true" opcional
"""

import json
import logging
import os

import azure.functions as func

from sap_odata_extractor import ODataClient, AdlsBackend, run_extraction

app = func.FunctionApp()
log = logging.getLogger("function")

# La config de entidades viaja empaquetada con la Function
ENTITIES_PATH = os.path.join(os.path.dirname(__file__), "entities.yaml")


@app.schedule(schedule="0 0 */3 * * *",        # cada 3 horas
              arg_name="timer", run_on_startup=False)
def sap_extractor(timer: func.TimerRequest) -> None:
    with open(ENTITIES_PATH, encoding="utf-8") as f:
        config_yaml = f.read()

    client = ODataClient(
        base_url=os.environ["SAP_BASE_URL"],
        user=os.environ.get("SAP_USER"),
        password=os.environ.get("SAP_PASSWORD"),
        api_key=os.environ.get("SAP_API_KEY"),   # sandbox api.sap.com usa APIKey
        verify_ssl=os.environ.get("SAP_VERIFY_SSL", "true").lower() == "true",
    )
    backend = AdlsBackend(
        account_url=os.environ["LANDING_ACCOUNT_URL"],
        container=os.environ["LANDING_CONTAINER"],
        prefix="landing",
    )
    full_load = os.environ.get("FULL_LOAD", "false").lower() == "true"

    summary = run_extraction(config_yaml, client, backend, full_load=full_load)
    log.info("Resumen de corrida: %s", json.dumps(summary, default=str))

    if any(s["status"] == "ERROR" for s in summary):
        # Falla la ejecución para que App Insights genere la alerta
        raise RuntimeError(f"Extracción con errores: {summary}")

"""
sap_odata_extractor.py — DataHeiß
Extractor genérico SAP OData (V2) → archivos Parquet en landing.

Diseño:
  - El MISMO módulo corre en AWS Lambda y en Azure Functions: toda la
    lógica de extracción vive acá; los handlers solo lo invocan.
  - Extracción incremental por campo de última modificación (simula el
    delta de las CDS Delta-Enabled). El watermark se persiste como un
    archivito JSON en el propio landing (_state/<entidad>.json).
  - Compatible con la política de SAP: consume OData estándar (Nota
    3255746: no usamos ODP).
  - Salida: parquet con nombres de columna = nombres RAW de Snowflake,
    más _SOURCE_FILE y _EXTRACTED_AT (Snowpipe hace COPY con
    MATCH_BY_COLUMN_NAME, ver snowpipe_*.sql).

Config: entities.yaml (una entrada por entidad OData a extraer).
"""

from __future__ import annotations
import io
import json
import logging
from datetime import datetime, timezone

import requests
import pandas as pd
import yaml

log = logging.getLogger("sap_extractor")
log.setLevel(logging.INFO)

PAGE_SIZE = 5000          # $top por página
TIMEOUT = 120             # segundos por request


# ----------------------------------------------------------------------
# Storage backends: la única parte específica de cada nube
# ----------------------------------------------------------------------
class S3Backend:
    """Landing en Amazon S3."""
    def __init__(self, bucket: str, prefix: str = "landing"):
        import boto3
        self.s3 = boto3.client("s3")
        self.bucket = bucket
        self.prefix = prefix.strip("/")

    def write_bytes(self, relative_path: str, data: bytes) -> str:
        key = f"{self.prefix}/{relative_path}"
        self.s3.put_object(Bucket=self.bucket, Key=key, Body=data)
        return f"s3://{self.bucket}/{key}"

    def read_json(self, relative_path: str) -> dict | None:
        key = f"{self.prefix}/{relative_path}"
        try:
            obj = self.s3.get_object(Bucket=self.bucket, Key=key)
            return json.loads(obj["Body"].read())
        except self.s3.exceptions.NoSuchKey:
            return None

    def write_json(self, relative_path: str, payload: dict) -> None:
        self.write_bytes(relative_path, json.dumps(payload).encode())


class AdlsBackend:
    """Landing en Azure Data Lake Storage Gen2 (API de blobs)."""
    def __init__(self, account_url: str, container: str, prefix: str = "landing",
                 credential=None):
        # account_url: https://<cuenta>.blob.core.windows.net
        # credential: DefaultAzureCredential (managed identity) o connection string
        from azure.storage.blob import BlobServiceClient
        if credential is None:
            from azure.identity import DefaultAzureCredential
            credential = DefaultAzureCredential()
        svc = BlobServiceClient(account_url=account_url, credential=credential)
        self.container = svc.get_container_client(container)
        self.prefix = prefix.strip("/")
        self.account_url = account_url
        self.container_name = container

    def write_bytes(self, relative_path: str, data: bytes) -> str:
        blob = f"{self.prefix}/{relative_path}"
        self.container.upload_blob(name=blob, data=data, overwrite=True)
        return f"{self.account_url}/{self.container_name}/{blob}"

    def read_json(self, relative_path: str) -> dict | None:
        blob = f"{self.prefix}/{relative_path}"
        try:
            data = self.container.download_blob(blob).readall()
            return json.loads(data)
        except Exception:
            return None

    def write_json(self, relative_path: str, payload: dict) -> None:
        self.write_bytes(relative_path, json.dumps(payload).encode())


# ----------------------------------------------------------------------
# Cliente OData V2
# ----------------------------------------------------------------------
class ODataClient:
    """
    Autenticación soportada:
      - basic: usuario/contraseña (CAL, RISE, on-premise)
      - api_key: header APIKey (sandbox del SAP Business Accelerator Hub,
        https://api.sap.com — botón "Get API Key" con cuenta SAP gratuita)
    """
    def __init__(self, base_url: str, user: str = None, password: str = None,
                 api_key: str = None, verify_ssl: bool = True):
        self.base_url = base_url.rstrip("/")
        self.session = requests.Session()
        if api_key:
            self.session.headers.update({"APIKey": api_key})
        elif user is not None:
            self.session.auth = (user, password)
        self.session.headers.update({"Accept": "application/json"})
        self.verify_ssl = verify_ssl

    def fetch_entity(self, entity_set: str, select: list[str] | None = None,
                     filter_expr: str | None = None) -> list[dict]:
        """Trae TODAS las páginas de un entity set (client-driven paging)."""
        records: list[dict] = []
        skip = 0
        while True:
            params = {"$format": "json", "$top": PAGE_SIZE, "$skip": skip}
            if select:
                params["$select"] = ",".join(select)
            if filter_expr:
                params["$filter"] = filter_expr
            url = f"{self.base_url}/{entity_set}"
            log.info("GET %s skip=%s", entity_set, skip)
            resp = self.session.get(url, params=params, timeout=TIMEOUT,
                                    verify=self.verify_ssl)
            resp.raise_for_status()
            body = resp.json()
            # OData V2: {"d": {"results": [...]}} · V4: {"value": [...]}
            page = body.get("d", {}).get("results") or body.get("value") or []
            records.extend(page)
            if len(page) < PAGE_SIZE:
                break
            skip += PAGE_SIZE
        return records


# ----------------------------------------------------------------------
# Normalización de tipos OData V2 (fechas /Date(ms)/, decimales string)
# ----------------------------------------------------------------------
def _normalize_value(v):
    if isinstance(v, str) and v.startswith("/Date("):
        try:
            ms = int(v[6:].split(")")[0].split("+")[0])
            return datetime.fromtimestamp(ms / 1000, tz=timezone.utc) \
                           .strftime("%Y%m%d")
        except (ValueError, IndexError):
            return v
    return v


def records_to_dataframe(records: list[dict], rename: dict[str, str]) -> pd.DataFrame:
    """Aplana, renombra a nombres RAW y descarta metadata OData."""
    clean = []
    for r in records:
        r = {k: _normalize_value(v) for k, v in r.items() if k != "__metadata"}
        clean.append(r)
    df = pd.DataFrame(clean)
    df = df.rename(columns=rename)
    keep = [c for c in rename.values() if c in df.columns]
    df = df[keep]
    # Todo a string: la capa RAW es VARCHAR a propósito (rarezas SAP
    # incluidas); el tipado ocurre en STAGING dentro de Snowflake.
    return df.astype("string")


# ----------------------------------------------------------------------
# Orquestación de una corrida
# ----------------------------------------------------------------------
def run_extraction(config_yaml: str, client: ODataClient, backend,
                   full_load: bool = False) -> list[dict]:
    """
    Ejecuta la extracción de todas las entidades del YAML.
    Devuelve un resumen por entidad (para PIPELINE_AUDIT / logs).
    """
    cfg = yaml.safe_load(config_yaml)
    run_ts = datetime.now(timezone.utc)
    stamp = run_ts.strftime("%Y%m%d_%H%M%S")
    summary = []

    for ent in cfg["entities"]:
        name = ent["name"]                      # ej: sales_orders
        entity_set = ent["entity_set"]          # ej: A_SalesOrderItem
        rename = ent["rename"]                  # OData → columnas RAW
        inc_field = ent.get("incremental_field")  # ej: LastChangeDateTime

        # Watermark para extracción incremental
        filter_expr = ent.get("static_filter")
        state = backend.read_json(f"_state/{name}.json") or {}
        if inc_field and not full_load and state.get("watermark"):
            inc = f"{inc_field} gt datetime'{state['watermark']}'"
            filter_expr = f"({filter_expr}) and ({inc})" if filter_expr else inc

        try:
            records = client.fetch_entity(
                entity_set,
                select=list(rename.keys()) or None,
                filter_expr=filter_expr,
            )
        except requests.HTTPError as e:
            log.error("Entidad %s falló: %s", name, e)
            summary.append({"entity": name, "status": "ERROR", "detail": str(e)})
            continue

        if not records:
            summary.append({"entity": name, "status": "OK", "rows": 0})
            continue

        df = records_to_dataframe(records, rename)
        fname = f"{name}/{name}_{stamp}.parquet"
        df["_SOURCE_FILE"] = fname
        df["_EXTRACTED_AT"] = run_ts.isoformat()

        buf = io.BytesIO()
        df.to_parquet(buf, index=False)         # requiere pyarrow
        uri = backend.write_bytes(fname, buf.getvalue())

        backend.write_json(f"_state/{name}.json",
                           {"watermark": run_ts.strftime("%Y-%m-%dT%H:%M:%S"),
                            "last_file": fname})
        log.info("Entidad %s: %s filas → %s", name, len(df), uri)
        summary.append({"entity": name, "status": "OK",
                        "rows": len(df), "file": uri})

    return summary

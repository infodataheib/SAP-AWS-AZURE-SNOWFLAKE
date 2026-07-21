"""
lambda_handler.py — DataHeiß · rama AWS
Handler de AWS Lambda que invoca el extractor compartido.

Disparo: EventBridge Scheduler cada 180 min (refresco 2–3 hs de Comercial).
Secretos: Secrets Manager (JSON con base_url, user, password).
Landing: S3 (el put_object dispara S3 → SQS → Snowpipe auto-ingest).
Logs: CloudWatch (logging estándar).

Variables de entorno esperadas:
  LANDING_BUCKET   = nombre del bucket de landing
  SECRET_NAME      = nombre del secreto en Secrets Manager
  ENTITIES_S3_KEY  = key del entities.yaml en el bucket (config versionada)
  FULL_LOAD        = "true" para ignorar watermark (opcional)
"""

import json
import logging
import os

import boto3

from sap_odata_extractor import ODataClient, S3Backend, run_extraction

logging.basicConfig(level=logging.INFO)
log = logging.getLogger("lambda")


def _get_secret(name: str) -> dict:
    sm = boto3.client("secretsmanager")
    return json.loads(sm.get_secret_value(SecretId=name)["SecretString"])


def handler(event, context):
    bucket = os.environ["LANDING_BUCKET"]
    secret = _get_secret(os.environ["SECRET_NAME"])
    full_load = os.environ.get("FULL_LOAD", "false").lower() == "true"

    # Config de entidades versionada en el propio bucket (prefijo _config/)
    s3 = boto3.client("s3")
    cfg_key = os.environ.get("ENTITIES_S3_KEY", "_config/entities.yaml")
    config_yaml = s3.get_object(Bucket=bucket, Key=cfg_key)["Body"].read().decode()

    client = ODataClient(
        base_url=secret["base_url"],
        user=secret.get("user"),
        password=secret.get("password"),
        api_key=secret.get("api_key"),      # sandbox api.sap.com usa APIKey
        verify_ssl=secret.get("verify_ssl", True),  # CAL suele ir con cert self-signed
    )
    backend = S3Backend(bucket=bucket, prefix="landing")

    summary = run_extraction(config_yaml, client, backend, full_load=full_load)
    log.info("Resumen de corrida: %s", json.dumps(summary, default=str))

    # Si alguna entidad falló, hacemos fallar la Lambda para que
    # CloudWatch Alarm lo levante.
    if any(s["status"] == "ERROR" for s in summary):
        raise RuntimeError(f"Extracción con errores: {summary}")

    return {"statusCode": 200, "body": summary}

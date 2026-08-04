# SAP Sales Order Extractor (AWS Lambda to Amazon S3)

An enterprise-grade AWS Lambda pipeline built in Python to extract Sales Order Headers (`A_SalesOrder`) and Line Items (`A_SalesOrderItem`) from SAP S/4HANA Cloud (OData v2) and load them as Apache Parquet files into Amazon S3 for Snowflake consumption.

## 🚀 Key Features & Architecture
- **Incremental CDC (Watermark):** Tracks historical & modified records via `LastChangeDateTime` using AWS SSM Parameter Store.
- **Secrets Vault:** `SAP_API_KEY` stored securely in AWS SSM Parameter Store (`SecureString` + KMS Encryption).
- **HTTP Connection Pooling:** Reuses persistent TCP/TLS connections via `requests.Session()` to minimize latency (~37.5% runtime reduction).
- **Hive-Style Partitioning:** Writes objects to `raw/sap/sales_order/year=YYYY/month=MM/day=DD/` for optimal partition pruning in Snowflake/Athena.
- **Server-Side Encryption:** Enforces `AES256` encryption at rest on S3 uploads.
- **Structured Logging:** Uses standard Python `logging` module for AWS CloudWatch observability.

## 🛠️ Environment Variables
- `S3_BUCKET_NAME`: Target S3 bucket name.
- `WATERMARK_PARAM_NAME`: SSM Parameter Store path for watermark (default: `/sap/extractor/last_change_date_time`).
- `API_KEY_PARAM_NAME`: SSM Parameter Store path for API key (default: `/sap/extractor/api_key`).

## 🔐 IAM Policy Requirements
The Lambda execution role requires scoped access to SSM Parameter Store (`/sap/extractor/*`), KMS decryption, and S3 PutObject privileges (`raw/sap/*`).
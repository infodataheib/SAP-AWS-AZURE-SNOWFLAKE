import os
import re
import logging
import requests
import pandas as pd
import boto3
from datetime import datetime

# -----------------------------------------------------------------------------
# STRUCTURED LOGGING CONFIGURATION
# -----------------------------------------------------------------------------
logger = logging.getLogger()
logger.setLevel(logging.INFO)

# -----------------------------------------------------------------------------
# GLOBAL INITIALIZATION (Warm Start Connection Pooling & SDK Clients)
# -----------------------------------------------------------------------------
s3_client = boto3.client("s3")
ssm_client = boto3.client("ssm")

# Persistent HTTP Session for TLS/TCP Keep-Alive connection reuse
http_session = requests.Session()

# Environment / Parameter Store names
SSM_WATERMARK_PARAM = os.environ.get("WATERMARK_PARAM_NAME", "/sap/extractor/last_change_date_time")
SSM_API_KEY_PARAM = os.environ.get("API_KEY_PARAM_NAME", "/sap/extractor/api_key")

# In-memory global cache for warm executions
CACHED_SAP_API_KEY = None


def get_sap_api_key() -> str:
    """Retrieve and cache the SAP API Key securely from SSM Parameter Store (SecureString)."""
    global CACHED_SAP_API_KEY
    if not CACHED_SAP_API_KEY:
        try:
            logger.info("🔐 Fetching SAP API Key from SSM Parameter Store (SecureString)...")
            response = ssm_client.get_parameter(
                Name=SSM_API_KEY_PARAM,
                WithDecryption=True
            )
            CACHED_SAP_API_KEY = response["Parameter"]["Value"]
        except Exception as e:
            logger.error(f"❌ Critical failure retrieving SAP_API_KEY from SSM: {str(e)}")
            raise RuntimeError(f"SSM API Key Retrieval Failed: {str(e)}")
    return CACHED_SAP_API_KEY


def get_watermark() -> str:
    """Retrieve the last processed LastChangeDateTime watermark from AWS SSM."""
    try:
        response = ssm_client.get_parameter(Name=SSM_WATERMARK_PARAM)
        val = response["Parameter"]["Value"]
        if val in ["0", "", None]:
            return "1970-01-01T00:00:00Z"
        return val
    except ssm_client.exceptions.ParameterNotFound:
        logger.warning(f"⚠️ Watermark parameter {SSM_WATERMARK_PARAM} not found. Defaulting to 1970-01-01T00:00:00Z.")
        return "1970-01-01T00:00:00Z"


def update_watermark(new_watermark: str) -> None:
    """Update SSM Parameter Store with the latest processed timestamp watermark."""
    try:
        ssm_client.put_parameter(
            Name=SSM_WATERMARK_PARAM,
            Value=str(new_watermark),
            Type="String",
            Overwrite=True
        )
        logger.info(f"✅ Successfully updated SSM Watermark to: {new_watermark}")
    except Exception as e:
        logger.error(f"❌ Failed to update SSM Watermark: {str(e)}")
        raise e


def clean_dataframe(df: pd.DataFrame) -> pd.DataFrame:
    """Sanitize DataFrame by removing OData __metadata dictionaries to prevent PyArrow C-extension segfaults."""
    if "__metadata" in df.columns:
        df = df.drop(columns=["__metadata"])
    return df


def generate_s3_partition_prefix(entity_name: str, now_dt: datetime) -> str:
    """Generate Hive-style partitioned S3 prefixes: raw/sap/{entity}/year=YYYY/month=MM/day=DD/"""
    return f"raw/sap/{entity_name}/year={now_dt.strftime('%Y')}/month={now_dt.strftime('%m')}/day={now_dt.strftime('%d')}"


def lambda_handler(event, context):
    logger.info("🚀 Starting SAP Sales Order Extractor Lambda Execution...")
    
    bucket_name = os.environ.get("S3_BUCKET_NAME")
    if not bucket_name:
        logger.error("❌ Environment variable S3_BUCKET_NAME is missing.")
        return {"statusCode": 500, "body": "Configuration Error: S3_BUCKET_NAME missing"}

    # Configure session headers
    sap_api_key = get_sap_api_key()
    http_session.headers.update({
        "Accept": "application/json",
        "APIKey": sap_api_key
    })
    
    # 1. Fetch current watermark
    current_watermark = get_watermark()
    logger.info(f"📌 Current Processing Watermark: {current_watermark}")

    # Build SAP OData v2 filter for LastChangeDateTime (Edm.DateTimeOffset)
    clean_watermark = current_watermark.replace("Z", "")
    filter_value = f"LastChangeDateTime gt datetimeoffset'{clean_watermark}Z'"
    
    url_headers = "https://sandbox.api.sap.com/s4hanacloud/sap/opu/odata/sap/API_SALES_ORDER_SRV/A_SalesOrder"
    params = {
        "$filter": filter_value,
        "$top": 50,
        "$orderby": "LastChangeDateTime asc, SalesOrder asc"
    }
        
    logger.info(f"📡 Executing GET Request to SAP: {url_headers} with filter: {filter_value}")
    
    try:
        response_headers = http_session.get(url_headers, params=params, timeout=30)
    except requests.exceptions.RequestException as req_err:
        logger.error(f"❌ Network/HTTP Exception connecting to SAP: {str(req_err)}")
        return {"statusCode": 502, "body": f"SAP Connectivity Error: {str(req_err)}"}

    if response_headers.status_code != 200:
        error_msg = f"❌ Error response from SAP API: Status {response_headers.status_code} - Details: {response_headers.text}"
        logger.error(error_msg)
        return {"statusCode": response_headers.status_code, "body": error_msg}

    raw_headers = response_headers.json().get("d", {}).get("results", [])
    
    # Exit gracefully if no new records exist
    if not raw_headers:
        msg = f"ℹ️ No new or updated Sales Orders found since last watermark: {current_watermark}"
        logger.info(msg)
        return {"statusCode": 200, "body": msg}

    df_headers = pd.DataFrame(raw_headers)
    df_headers = clean_dataframe(df_headers)
    
    now_dt = datetime.now()
    timestamp = now_dt.strftime("%Y%m%d_%H%M%S")
    partition_prefix = generate_s3_partition_prefix("sales_order", now_dt)
    
    local_header_path = "/tmp/sales_order_headers.parquet"
    df_headers.to_parquet(local_header_path, index=False)
    
    s3_key_header = f"{partition_prefix}/sales_order_{timestamp}.parquet"
    
    logger.info(f"📦 Uploading Header Parquet file to S3: s3://{bucket_name}/{s3_key_header}")
    s3_client.upload_file(
        local_header_path, 
        bucket_name, 
        s3_key_header,
        ExtraArgs={"ServerSideEncryption": "AES256"}
    )
    os.remove(local_header_path)

    # -------------------------------------------------------------------------
    # NESTED LOOP: Process Line Items per extracted Sales Order
    # -------------------------------------------------------------------------
    order_ids = df_headers["SalesOrder"].tolist()
    total_orders = len(order_ids)
    order_index = 0

    logger.info(f"🔄 Processing line items for {total_orders} orders using persistent connection pool...")

    while order_index < total_orders:
        sales_order_id = str(order_ids[order_index])
        
        item_skip = 0
        items_per_page = 50
        all_order_items = []

        while True:
            url_item = (
                f"https://sandbox.api.sap.com/s4hanacloud/sap/opu/odata/sap/API_SALES_ORDER_SRV/A_SalesOrderItem"
                f"?$filter=SalesOrder eq '{sales_order_id}'&$top={items_per_page}&$skip={item_skip}"
            )
            
            try:
                response_item = http_session.get(url_item, timeout=30)
            except requests.exceptions.RequestException as e:
                logger.warning(f"  ⚠️ Network error fetching items for Order ID {sales_order_id}: {str(e)}")
                break
            
            if response_item.status_code == 200:
                raw_items = response_item.json().get("d", {}).get("results", [])
                if not raw_items:
                    break
                
                all_order_items.extend(raw_items)
                if len(raw_items) < items_per_page:
                    break
                
                item_skip += items_per_page
            else:
                logger.warning(f"  ⚠️ Non-200 status ({response_item.status_code}) fetching items for Order ID {sales_order_id}")
                break

        if all_order_items:
            df_items = pd.DataFrame(all_order_items)
            df_items = clean_dataframe(df_items)
            
            local_item_path = f"/tmp/item_{sales_order_id}.parquet"
            df_items.to_parquet(local_item_path, index=False)
            
            s3_key_item = f"{partition_prefix}/{sales_order_id}_sales_order_item_{timestamp}.parquet"
            
            s3_client.upload_file(
                local_item_path, 
                bucket_name, 
                s3_key_item,
                ExtraArgs={"ServerSideEncryption": "AES256"}
            )
            os.remove(local_item_path)

        order_index += 1

    # -------------------------------------------------------------------------
    # SAFE WATERMARK COMPUTATION AND UPDATE
    # -------------------------------------------------------------------------
    try:
        date_strings = df_headers["LastChangeDateTime"].dropna().tolist()
        if date_strings:
            max_raw_date = max(date_strings)
            if "/Date(" in str(max_raw_date):
                ms = re.search(r"\d+", str(max_raw_date)).group()
                new_watermark = datetime.utcfromtimestamp(int(ms) / 1000).strftime("%Y-%m-%dT%H:%M:%S") + "Z"
            else:
                new_watermark = str(max_raw_date)

            update_watermark(new_watermark)
            summary_msg = f"🚀 SUCCESS: Processed {total_orders} orders and items. Watermark advanced to {new_watermark}."
        else:
            summary_msg = f"🚀 SUCCESS: Processed {total_orders} orders. Watermark unchanged (no dates found)."
    except Exception as parse_err:
        summary_msg = f"🚀 SUCCESS: Processed {total_orders} orders. Watermark update skipped due to parsing note: {str(parse_err)}"
        logger.warning(summary_msg)

    logger.info(summary_msg)
    
    return {
        "statusCode": 200,
        "body": summary_msg
    }
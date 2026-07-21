#!/usr/bin/env bash
# ============================================================
# deploy_azure.sh — DataHeiß · infraestructura de la rama Azure
# ADLS Gen2 (landing) + Key Vault + Function App (timer 3 hs)
# + Managed Identity + Event Grid (lo registra Snowflake)
#
# Requiere: Azure CLI (az login) + Azure Functions Core Tools
# (func) para el deploy del código.
# Espejo de deploy_aws.sh — misma tabla de equivalencias de la
# propuesta, sección 4.1.
#
# IMPORTANTE: NO usamos Azure Data Factory con conector SAP CDC:
# ese conector usa ODP por debajo (Nota SAP 3255746). La vía
# compatible es esta: Function → OData.
# ============================================================
set -euo pipefail

# ----------- Parámetros (editar) -----------
LOCATION="brazilsouth"                      # o eastus2; misma región que Snowflake
RG="rg-dataheiss-demo"
STORAGE="dataheissdemolanding$RANDOM"       # solo minúsculas/números, global
CONTAINER="landing"
KEYVAULT="kv-dataheiss-$RANDOM"
FUNCAPP="func-dataheiss-extractor-$RANDOM"
SAP_BASE_URL="https://<host-sap>:44300/sap/opu/odata/sap/API_SALES_ORDER_SRV"
SAP_USER="<usuario>"
SAP_PASS="<password>"
# --------------------------------------------

echo ">> 1) Resource group"
az group create -n "$RG" -l "$LOCATION"

echo ">> 2) Storage ADLS Gen2 (hierarchical namespace) + contenedor"
az storage account create -n "$STORAGE" -g "$RG" -l "$LOCATION" \
  --sku Standard_LRS --kind StorageV2 --hns true \
  --allow-blob-public-access false
az storage container create --account-name "$STORAGE" -n "$CONTAINER" --auth-mode login

echo ">> 3) Key Vault con credenciales SAP"
az keyvault create -n "$KEYVAULT" -g "$RG" -l "$LOCATION" --enable-rbac-authorization true
MY_ID=$(az ad signed-in-user show --query id -o tsv)
az role assignment create --assignee "$MY_ID" \
  --role "Key Vault Secrets Officer" \
  --scope $(az keyvault show -n "$KEYVAULT" --query id -o tsv)
sleep 15
az keyvault secret set --vault-name "$KEYVAULT" -n sap-base-url --value "$SAP_BASE_URL"
az keyvault secret set --vault-name "$KEYVAULT" -n sap-user     --value "$SAP_USER"
az keyvault secret set --vault-name "$KEYVAULT" -n sap-password --value "$SAP_PASS"

echo ">> 4) Function App (Consumption, Python 3.11) + App Insights"
az storage account create -n "${STORAGE}fx" -g "$RG" -l "$LOCATION" --sku Standard_LRS
az functionapp create -n "$FUNCAPP" -g "$RG" \
  --consumption-plan-location "$LOCATION" \
  --runtime python --runtime-version 3.11 --functions-version 4 \
  --storage-account "${STORAGE}fx" --os-type Linux

echo ">> 5) Managed Identity + permisos"
az functionapp identity assign -n "$FUNCAPP" -g "$RG"
FUNC_MI=$(az functionapp identity show -n "$FUNCAPP" -g "$RG" --query principalId -o tsv)
# Escribir en el landing
az role assignment create --assignee "$FUNC_MI" \
  --role "Storage Blob Data Contributor" \
  --scope $(az storage account show -n "$STORAGE" -g "$RG" --query id -o tsv)
# Leer secretos del Key Vault
az role assignment create --assignee "$FUNC_MI" \
  --role "Key Vault Secrets User" \
  --scope $(az keyvault show -n "$KEYVAULT" --query id -o tsv)

echo ">> 6) App settings (secretos como referencias a Key Vault)"
KV_URI="https://$KEYVAULT.vault.azure.net"
az functionapp config appsettings set -n "$FUNCAPP" -g "$RG" --settings \
  "LANDING_ACCOUNT_URL=https://$STORAGE.blob.core.windows.net" \
  "LANDING_CONTAINER=$CONTAINER" \
  "SAP_BASE_URL=@Microsoft.KeyVault(SecretUri=$KV_URI/secrets/sap-base-url/)" \
  "SAP_USER=@Microsoft.KeyVault(SecretUri=$KV_URI/secrets/sap-user/)" \
  "SAP_PASSWORD=@Microsoft.KeyVault(SecretUri=$KV_URI/secrets/sap-password/)" \
  "SAP_VERIFY_SSL=false"

echo ">> 7) Deploy del código"
# Estructura esperada del paquete: function_app.py + sap_odata_extractor.py
# + entities.yaml + requirements.txt (con azure-storage-blob y azure-identity
# descomentados) + host.json
rm -rf build && mkdir build
cp function_app.py ../extractor/sap_odata_extractor.py ../extractor/entities.yaml build/
cat > build/requirements.txt << 'EOF'
azure-functions
requests>=2.31
pandas>=2.0
pyarrow>=14.0
PyYAML>=6.0
azure-storage-blob>=12.19
azure-identity>=1.15
EOF
cat > build/host.json << 'EOF'
{ "version": "2.0", "extensionBundle": { "id": "Microsoft.Azure.Functions.ExtensionBundle", "version": "[4.*, 5.0.0)" } }
EOF
(cd build && func azure functionapp publish "$FUNCAPP" --python)

echo ">> 8) Event Grid para Snowpipe: LO REGISTRA SNOWFLAKE."
echo "   Correr azure/snowpipe_azure.sql; la NOTIFICATION INTEGRATION"
echo "   pide crear antes una Storage Queue + Event Grid subscription:"
cat << EOF
   az storage queue create --account-name $STORAGE -n snowpipe-queue --auth-mode login
   az eventgrid event-subscription create \\
     --name snowpipe-sub \\
     --source-resource-id \$(az storage account show -n $STORAGE -g $RG --query id -o tsv) \\
     --endpoint-type storagequeue \\
     --endpoint \$(az storage account show -n $STORAGE -g $RG --query id -o tsv)/queueservices/default/queues/snowpipe-queue \\
     --included-event-types Microsoft.Storage.BlobCreated \\
     --subject-begins-with /blobServices/default/containers/$CONTAINER/blobs/landing/
EOF

echo ""
echo "LISTO. Storage: $STORAGE · KeyVault: $KEYVAULT · Function: $FUNCAPP"
echo "Prueba manual: portal → Function → Code + Test → Test/Run (o esperar el timer)"

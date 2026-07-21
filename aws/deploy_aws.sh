#!/usr/bin/env bash
# ============================================================
# deploy_aws.sh — DataHeiß · infraestructura de la rama AWS
# S3 (landing) + SQS (notificación p/ Snowpipe) + Secrets Manager
# + IAM + Lambda + EventBridge Scheduler (cada 180 min)
#
# Requiere: AWS CLI v2 configurado (aws configure), permisos admin
# en la cuenta de práctica. Región sugerida: la misma del Snowflake.
# Es un script didáctico: comandos explícitos, sin Terraform, para
# que el junior VEA cada pieza. (Migrarlo a Terraform es un buen
# ejercicio posterior.)
# ============================================================
set -euo pipefail

# ----------- Parámetros (editar) -----------
REGION="us-east-1"
BUCKET="dataheiss-demo-landing-$RANDOM"     # los buckets son globales: sufijo único
SECRET_NAME="dataheiss/sap-odata"
LAMBDA_NAME="dataheiss-sap-extractor"
ROLE_NAME="dataheiss-lambda-extractor-role"
SCHEDULE_NAME="dataheiss-extractor-cada-3hs"
SAP_BASE_URL="https://<host-sap>:44300/sap/opu/odata/sap/API_SALES_ORDER_SRV"
SAP_USER="<usuario>"
SAP_PASS="<password>"
# --------------------------------------------

echo ">> 1) Bucket de landing"
aws s3api create-bucket --bucket "$BUCKET" --region "$REGION" \
  $( [ "$REGION" != "us-east-1" ] && echo --create-bucket-configuration LocationConstraint=$REGION )
aws s3api put-public-access-block --bucket "$BUCKET" \
  --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

echo ">> 2) Secreto con credenciales SAP"
aws secretsmanager create-secret --region "$REGION" --name "$SECRET_NAME" \
  --secret-string "{\"base_url\":\"$SAP_BASE_URL\",\"user\":\"$SAP_USER\",\"password\":\"$SAP_PASS\",\"verify_ssl\":false}"

echo ">> 3) Subir config de entidades al bucket"
aws s3 cp ../extractor/entities.yaml "s3://$BUCKET/_config/entities.yaml"

echo ">> 4) Rol IAM de la Lambda (mínimo privilegio)"
aws iam create-role --role-name "$ROLE_NAME" --assume-role-policy-document '{
  "Version":"2012-10-17",
  "Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]
}'
aws iam put-role-policy --role-name "$ROLE_NAME" --policy-name landing-access --policy-document "{
  \"Version\":\"2012-10-17\",
  \"Statement\":[
    {\"Effect\":\"Allow\",\"Action\":[\"s3:PutObject\",\"s3:GetObject\"],\"Resource\":\"arn:aws:s3:::$BUCKET/*\"},
    {\"Effect\":\"Allow\",\"Action\":\"secretsmanager:GetSecretValue\",\"Resource\":\"*\"},
    {\"Effect\":\"Allow\",\"Action\":[\"logs:CreateLogGroup\",\"logs:CreateLogStream\",\"logs:PutLogEvents\"],\"Resource\":\"*\"}
  ]
}"
ROLE_ARN=$(aws iam get-role --role-name "$ROLE_NAME" --query 'Role.Arn' --output text)
sleep 10   # propagación IAM

echo ">> 5) Empaquetar y crear la Lambda"
# El paquete lleva el handler + el extractor + dependencias
rm -rf build && mkdir build
pip install -r ../extractor/requirements.txt -t build/ --quiet
cp ../extractor/sap_odata_extractor.py lambda_handler.py build/
(cd build && zip -qr ../lambda_package.zip .)

aws lambda create-function --region "$REGION" \
  --function-name "$LAMBDA_NAME" \
  --runtime python3.12 --handler lambda_handler.handler \
  --role "$ROLE_ARN" \
  --zip-file fileb://lambda_package.zip \
  --timeout 900 --memory-size 1024 \
  --environment "Variables={LANDING_BUCKET=$BUCKET,SECRET_NAME=$SECRET_NAME}"

echo ">> 6) EventBridge Scheduler: cada 180 minutos"
SCHED_ROLE="dataheiss-scheduler-role"
aws iam create-role --role-name "$SCHED_ROLE" --assume-role-policy-document '{
  "Version":"2012-10-17",
  "Statement":[{"Effect":"Allow","Principal":{"Service":"scheduler.amazonaws.com"},"Action":"sts:AssumeRole"}]
}'
LAMBDA_ARN=$(aws lambda get-function --function-name "$LAMBDA_NAME" --region "$REGION" --query 'Configuration.FunctionArn' --output text)
aws iam put-role-policy --role-name "$SCHED_ROLE" --policy-name invoke-lambda --policy-document "{
  \"Version\":\"2012-10-17\",
  \"Statement\":[{\"Effect\":\"Allow\",\"Action\":\"lambda:InvokeFunction\",\"Resource\":\"$LAMBDA_ARN\"}]
}"
SCHED_ROLE_ARN=$(aws iam get-role --role-name "$SCHED_ROLE" --query 'Role.Arn' --output text)
sleep 10
aws scheduler create-schedule --region "$REGION" --name "$SCHEDULE_NAME" \
  --schedule-expression "rate(180 minutes)" \
  --flexible-time-window Mode=OFF \
  --target "{\"Arn\":\"$LAMBDA_ARN\",\"RoleArn\":\"$SCHED_ROLE_ARN\"}"

echo ">> 7) SQS para Snowpipe: LA CREA SNOWFLAKE."
echo "   Después de correr snowpipe_aws.sql, ejecutá:"
echo "     SHOW PIPES;  →  columna notification_channel = ARN de la SQS"
echo "   y configurá la notificación del bucket:"
cat << 'EOF'
   aws s3api put-bucket-notification-configuration --bucket $BUCKET \
     --notification-configuration '{
       "QueueConfigurations":[{
         "QueueArn":"<ARN de notification_channel>",
         "Events":["s3:ObjectCreated:*"],
         "Filter":{"Key":{"FilterRules":[{"Name":"prefix","Value":"landing/"}]}}
       }]}'
EOF

echo ""
echo "LISTO. Bucket: $BUCKET  ·  Lambda: $LAMBDA_NAME"
echo "Prueba manual:  aws lambda invoke --function-name $LAMBDA_NAME --region $REGION out.json && cat out.json"

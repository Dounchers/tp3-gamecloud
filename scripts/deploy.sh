#!/bin/bash
# Despliegue completo de GameCloud sobre MiniStack.
# Uso (desde la raiz del repo):  bash scripts/deploy.sh
# Requiere: MiniStack corriendo en el puerto 4566, aws cli, zip.
set -e

export AWS_ACCESS_KEY_ID=test
export AWS_SECRET_ACCESS_KEY=test
export AWS_DEFAULT_REGION=us-east-1
REGION=us-east-1
ACCOUNT=000000000000

# En un script los alias no se expanden, por eso se usa una funcion.
awsl() { aws --endpoint-url=http://localhost:4566 "$@"; }

for f in web/index.html iam/trust-lambda.json iam/politica-lambdas.json \
         lambdas/ranking.py lambdas/recibir_puntaje.py lambdas/procesar_puntaje.py; do
  [ -f "$f" ] || { echo "ERROR: falta $f (ejecutar desde la raiz del repo)"; exit 1; }
done

echo "== 1. S3 + static website hosting =="
awsl s3 mb s3://gamecloud-web > /dev/null
awsl s3 website s3://gamecloud-web --index-document index.html
awsl s3 cp web/index.html s3://gamecloud-web/index.html

echo "== 1b. CloudFront (solo a nivel API en MiniStack) =="
awsl cloudfront create-distribution \
  --origin-domain-name gamecloud-web.s3.amazonaws.com \
  --default-root-object index.html > /dev/null

echo "== 2. DynamoDB =="
awsl dynamodb create-table \
  --table-name Puntajes \
  --attribute-definitions AttributeName=juego,AttributeType=S AttributeName=jugador,AttributeType=S \
  --key-schema AttributeName=juego,KeyType=HASH AttributeName=jugador,KeyType=RANGE \
  --billing-mode PAY_PER_REQUEST > /dev/null
awsl dynamodb describe-table --table-name Puntajes --query "Table.TableStatus"

echo "== 3. SQS + DLQ =="
awsl sqs create-queue --queue-name puntajes-dlq > /dev/null
DLQ_ARN=$(awsl sqs get-queue-attributes \
  --queue-url http://localhost:4566/$ACCOUNT/puntajes-dlq \
  --attribute-names QueueArn --query "Attributes.QueueArn" --output text)
echo "DLQ_ARN=$DLQ_ARN"

cat > /tmp/queue-attrs.json <<EOF
{"VisibilityTimeout":"30","RedrivePolicy":"{\"deadLetterTargetArn\":\"$DLQ_ARN\",\"maxReceiveCount\":\"3\"}"}
EOF
awsl sqs create-queue --queue-name puntajes --attributes file:///tmp/queue-attrs.json > /dev/null
QUEUE_URL=http://localhost:4566/$ACCOUNT/puntajes
awsl sqs get-queue-attributes --queue-url "$QUEUE_URL" \
  --attribute-names VisibilityTimeout RedrivePolicy

echo "== 4. IAM =="
awsl iam create-role --role-name gamecloud-lambda-role \
  --assume-role-policy-document file://iam/trust-lambda.json > /dev/null
awsl iam put-role-policy --role-name gamecloud-lambda-role \
  --policy-name gamecloud-permissions \
  --policy-document file://iam/politica-lambdas.json
ROLE_ARN="arn:aws:iam::$ACCOUNT:role/gamecloud-lambda-role"

echo "== 4b. Lambdas =="
crear_lambda() { # $1=nombre  $2=variables de entorno
  (cd lambdas && rm -f "$1.zip" && zip -q "$1.zip" "$1.py")
  awsl lambda create-function --function-name "$1" \
    --runtime python3.12 --handler "$1.handler" \
    --role "$ROLE_ARN" --zip-file "fileb://lambdas/$1.zip" \
    --environment "Variables={$2}" > /dev/null
  echo "  funcion $1 creada"
}
crear_lambda ranking "TABLE_NAME=Puntajes"
crear_lambda recibir_puntaje "QUEUE_URL=$QUEUE_URL"
crear_lambda procesar_puntaje "TABLE_NAME=Puntajes"

echo "== 4c. Event source mapping (cola -> procesar_puntaje) =="
awsl lambda create-event-source-mapping \
  --function-name procesar_puntaje \
  --event-source-arn "arn:aws:sqs:$REGION:$ACCOUNT:puntajes" \
  --batch-size 5 > /dev/null
# Solo si usas la version de procesar_puntaje con batchItemFailures:
# ESM_UUID=$(awsl lambda list-event-source-mappings --function-name procesar_puntaje \
#   --query "EventSourceMappings[0].UUID" --output text)
# awsl lambda update-event-source-mapping --uuid "$ESM_UUID" \
#   --function-response-types ReportBatchItemFailures

echo "== 5. API Gateway =="
API_ID=$(awsl apigatewayv2 create-api --name gamecloud-api --protocol-type HTTP \
  --cors-configuration "AllowOrigins='*',AllowMethods='GET,POST,OPTIONS',AllowHeaders='*'" \
  --query ApiId --output text)
echo "API_ID=$API_ID"

crear_ruta() { # $1=route-key  $2=funcion  $3=statement-id
  INT_ID=$(awsl apigatewayv2 create-integration --api-id "$API_ID" \
    --integration-type AWS_PROXY \
    --integration-uri "arn:aws:lambda:$REGION:$ACCOUNT:function:$2" \
    --payload-format-version 2.0 --query IntegrationId --output text)
  awsl apigatewayv2 create-route --api-id "$API_ID" \
    --route-key "$1" --target "integrations/$INT_ID" > /dev/null
  awsl lambda add-permission --function-name "$2" --statement-id "$3" \
    --action lambda:InvokeFunction --principal apigateway.amazonaws.com \
    --source-arn "arn:aws:execute-api:$REGION:$ACCOUNT:$API_ID/*/*" > /dev/null
  echo "  ruta $1 -> $2"
}
crear_ruta "GET /ranking" ranking apigatewayv2-ranking
crear_ruta "POST /scores" recibir_puntaje apigatewayv2-scores

awsl apigatewayv2 create-stage --api-id "$API_ID" --stage-name '$default' \
  --auto-deploy \
  --default-route-settings "ThrottlingBurstLimit=200,ThrottlingRateLimit=100" > /dev/null

echo "== 5b. config.js =="
echo "window.GAMECLOUD_API = \"http://$API_ID.execute-api.localhost:4566\";" > /tmp/config.js
awsl s3 cp /tmp/config.js s3://gamecloud-web/config.js

echo
echo "============================================================"
echo " Despliegue completo."
echo " Web:  http://localhost:4566/gamecloud-web/index.html"
echo " Para las pruebas, ejecuta en tu terminal:"
echo "   export API_URL=http://$API_ID.execute-api.localhost:4566"
echo "   export QUEUE_URL=$QUEUE_URL"
echo "============================================================"

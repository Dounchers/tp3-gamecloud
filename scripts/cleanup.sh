#!/bin/bash
# Elimina los recursos creados por scripts/deploy.sh.
# Uso:  bash scripts/cleanup.sh
# Es tolerante a errores: si un recurso ya no existe, sigue con el siguiente.

export AWS_ACCESS_KEY_ID=test
export AWS_SECRET_ACCESS_KEY=test
export AWS_DEFAULT_REGION=us-east-1
awsl() { aws --endpoint-url=http://localhost:4566 "$@"; }

echo "== Event source mappings =="
for u in $(awsl lambda list-event-source-mappings --function-name procesar_puntaje \
            --query "EventSourceMappings[].UUID" --output text 2>/dev/null); do
  awsl lambda delete-event-source-mapping --uuid "$u" > /dev/null && echo "  mapping $u eliminado"
done

echo "== Lambdas =="
for f in ranking recibir_puntaje procesar_puntaje; do
  awsl lambda delete-function --function-name "$f" 2>/dev/null && echo "  $f eliminada"
done

echo "== API Gateway =="
for id in $(awsl apigatewayv2 get-apis \
            --query "Items[?Name=='gamecloud-api'].ApiId" --output text 2>/dev/null); do
  awsl apigatewayv2 delete-api --api-id "$id" && echo "  API $id eliminada"
done

echo "== IAM =="
awsl iam delete-role-policy --role-name gamecloud-lambda-role \
  --policy-name gamecloud-permissions 2>/dev/null
awsl iam delete-role --role-name gamecloud-lambda-role 2>/dev/null && echo "  rol eliminado"

echo "== SQS =="
for q in puntajes puntajes-dlq; do
  awsl sqs delete-queue --queue-url "http://localhost:4566/000000000000/$q" 2>/dev/null \
    && echo "  cola $q eliminada"
done

echo "== DynamoDB =="
awsl dynamodb delete-table --table-name Puntajes > /dev/null 2>&1 && echo "  tabla eliminada"

echo "== S3 =="
awsl s3 rb s3://gamecloud-web --force 2>/dev/null && echo "  bucket eliminado"

echo "Listo. (La distribución de CloudFront se elimina al reiniciar MiniStack.)"

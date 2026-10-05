#!/bin/bash
# Prueba 6.6: mensaje no-JSON -> 3 intentos -> DLQ
# Uso:  bash scripts/prueba6_dlq.sh   (tarda ~2 min 30 s)

export AWS_ACCESS_KEY_ID=test
export AWS_SECRET_ACCESS_KEY=test
export AWS_DEFAULT_REGION=us-east-1
awsl() { aws --endpoint-url=http://localhost:4566 "$@"; }

QUEUE_URL=http://localhost:4566/000000000000/puntajes
DLQ_URL=http://localhost:4566/000000000000/puntajes-dlq
MARCA="CORRUPTO_$(date +%s)"
T0=$(( $(date +%s) * 1000 ))   # milisegundos, como espera CloudWatch Logs

contar_dlq() {
  awsl sqs get-queue-attributes --queue-url "$DLQ_URL" \
    --attribute-names ApproximateNumberOfMessages \
    --query "Attributes.ApproximateNumberOfMessages" --output text
}

echo "== 0. Limpiar la DLQ =="
awsl sqs purge-queue --queue-url "$DLQ_URL"; sleep 5

echo "== 1. DLQ antes (esperado: 0) =="
contar_dlq

echo "== 2. Enviar UN mensaje no-JSON: $MARCA =="
# curl contra la API HTTP de SQS: 'aws sqs send-message' falla en este
# entorno al mostrar la respuesta ("badly formed help string").
curl -s "$QUEUE_URL?Action=SendMessage&MessageBody=$MARCA" > /dev/null

echo "== 3. Esperando los 3 intentos (3 x 30 s de visibility timeout) =="
sleep 130

echo "== 4. DLQ despues (esperado: 1) =="
contar_dlq

echo "== 5. Mensaje en la DLQ (debe coincidir con la marca) =="
curl -s "$DLQ_URL?Action=ReceiveMessage&MaxNumberOfMessages=10&VisibilityTimeout=0" \
  | grep -oE '<(MessageId|Body)>[^<]*'

echo "== 6. Intentos fallidos de esta corrida (esperado: 3, ~30 s entre cada uno) =="
awsl logs filter-log-events --log-group-name /aws/lambda/procesar_puntaje \
  --start-time $T0 \
  --query "events[?contains(message, 'json.decoder.JSONDecodeError')].[timestamp,message]" \
  --output text

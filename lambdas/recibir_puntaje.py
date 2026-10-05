import json
import os
import boto3

sqs = boto3.client('sqs')
QUEUE_URL = os.environ.get('QUEUE_URL')
JUEGOS_VALIDOS = {"doom", "pacman"}

def handler(event, context):
    try:
        body = json.loads(event.get('body') or '{}')
        jugador = body.get('jugador')
        juego = body.get('juego')
        puntaje = body.get('puntaje')

        if not jugador or not isinstance(jugador, str):
            return {
                "statusCode": 400,
                "headers": {"Content-Type": "application/json", "Access-Control-Allow-Origin": "*"},
                "body": json.dumps({"error": "Jugador invalido"})
            }

        if juego not in JUEGOS_VALIDOS:
            return {
                "statusCode": 400,
                "headers": {"Content-Type": "application/json", "Access-Control-Allow-Origin": "*"},
                "body": json.dumps({"error": "Juego inexistente o invalido"})
            }

        if puntaje is None or not isinstance(puntaje, int) or isinstance(puntaje, bool):
            return {
                "statusCode": 400,
                "headers": {"Content-Type": "application/json", "Access-Control-Allow-Origin": "*"},
                "body": json.dumps({"error": "Puntaje debe ser un entero"})
            }

        mensaje = {
            "jugador": jugador.strip(),
            "juego": juego,
            "puntaje": puntaje
        }

        sqs.send_message(
            QueueUrl=QUEUE_URL,
            MessageBody=json.dumps(mensaje)
        )

        return {
            "statusCode": 202,
            "headers": {"Content-Type": "application/json", "Access-Control-Allow-Origin": "*"},
            "body": json.dumps({"status": "Accepted"})
        }

    except Exception as e:
        return {
            "statusCode": 400,
            "headers": {"Content-Type": "application/json", "Access-Control-Allow-Origin": "*"},
            "body": json.dumps({"error": str(e)})
        }

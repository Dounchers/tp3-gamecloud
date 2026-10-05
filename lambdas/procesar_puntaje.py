import json
import os
import boto3

dynamodb = boto3.resource('dynamodb')
TABLE_NAME = os.environ.get('TABLE_NAME', 'Puntajes')
table = dynamodb.Table(TABLE_NAME)

def handler(event, context):
    for record in event.get('Records', []):
        body = json.loads(record['body'])
        jugador = body['jugador']
        juego = body['juego']
        puntaje = int(body['puntaje'])

        resp = table.get_item(Key={'juego': juego, 'jugador': jugador})
        item = resp.get('Item')

        if item is None or puntaje > int(item.get('puntaje', 0)):
            table.put_item(
                Item={
                    'juego': juego,
                    'jugador': jugador,
                    'puntaje': puntaje
                }
            )
            print(f"Nuevo record guardado: {jugador} en {juego} -> {puntaje}")
        else:
            print(f"Puntaje {puntaje} no supera el record previo para {jugador}")
    return {"statusCode": 200}

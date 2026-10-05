import json
import os
import boto3

dynamodb = boto3.resource('dynamodb')
TABLE_NAME = os.environ.get('TABLE_NAME', 'Puntajes')
table = dynamodb.Table(TABLE_NAME)

def handler(event, context):
    query_params = event.get('queryStringParameters') or {}
    filtro_juego = query_params.get('juego')

    resp = table.scan()
    items = resp.get('Items', [])

    ranking = {
        "doom": [],
        "pacman": []
    }

    for item in items:
        juego = item.get('juego')
        if juego in ranking:
            ranking[juego].append({
                "jugador": item.get('jugador'),
                "puntaje": int(item.get('puntaje', 0))
            })

    for juego in ranking:
        ranking[juego].sort(key=lambda x: x['puntaje'], reverse=True)
        ranking[juego] = ranking[juego][:10]

    if filtro_juego:
        juego_req = filtro_juego.lower()
        items_filtrados = ranking.get(juego_req, [])
        return {
            "statusCode": 200,
            "headers": {"Content-Type": "application/json", "Access-Control-Allow-Origin": "*"},
            "body": json.dumps(items_filtrados)
        }

    return {
        "statusCode": 200,
        "headers": {"Content-Type": "application/json", "Access-Control-Allow-Origin": "*"},
        "body": json.dumps(ranking)
    }

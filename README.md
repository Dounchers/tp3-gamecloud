# TP3 – GameCloud migra a AWS (arquitectura serverless sobre MiniStack)

Actividad N°3 de *Administración Avanzada de Redes y Servidores* (UNNOBA).

Ranking online de puntajes para Doom y Pac-Man construido con servicios gestionados de AWS
(S3, CloudFront, API Gateway, Lambda, SQS con dead-letter queue, DynamoDB e IAM) y desplegado
sobre **MiniStack**, un emulador local de AWS, usando las mismas herramientas (AWS CLI) que se
emplearían contra una cuenta real.

**Alumno:** `<Robertino Mollo>`

## Arquitectura

```
                 ┌────────────┐     ┌──────────────┐
Jugador ────────►│ CloudFront │────►│ S3 (web)     │
   │             └────────────┘     └──────────────┘
   │
   │ GET /ranking   ┌──────────────┐     ┌──────────┐
   ├───────────────►│ API Gateway  │────►│ Lambda   │──────┐
   │                │ (HTTP API)   │     │ ranking  │      ▼
   │ POST /scores   │              │     └──────────┘  ┌──────────┐
   └───────────────►│              │────►┌──────────┐  │ DynamoDB │
                    └──────────────┘     │ Lambda   │  │ Puntajes │
                                         │ recibir  │  └──────────┘
                                         └────┬─────┘       ▲
                                              ▼             │
                    ┌──────────┐  3x  ┌──────────┐     ┌────┴─────┐
                    │   DLQ    │◄─────│   SQS    │────►│ Lambda   │
                    └──────────┘      │ puntajes │     │ procesar │
                                      └──────────┘     └──────────┘
```

## Requisitos

- Docker y Docker Compose
- AWS CLI
- bash, curl y zip (en Windows se usa WSL)

## Cómo reproducir la práctica

Todos los comandos se ejecutan desde la raíz del repositorio.

### 1. Levantar MiniStack

```bash
docker compose up -d
```

Equivale a:

```bash
docker run -d --name ministack -p 4566:4566 \
  -v /var/run/docker.sock:/var/run/docker.sock ministackorg/ministack
```

### 2. Credenciales ficticias

```bash
export AWS_ACCESS_KEY_ID=test
export AWS_SECRET_ACCESS_KEY=test
export AWS_DEFAULT_REGION=us-east-1
alias awsl='aws --endpoint-url=http://localhost:4566'   # solo en la terminal interactiva
awsl s3 ls
```

Los scripts de `scripts/` definen su propia función `awsl`, porque los alias no se expanden
dentro de un script.

### 3. Desplegar toda la arquitectura

```bash
bash scripts/deploy.sh
```

El script crea, en orden: bucket S3 con static website hosting y distribución CloudFront,
tabla `Puntajes`, colas `puntajes-dlq` y `puntajes` (visibility timeout de 30 s y 3 intentos),
rol IAM `gamecloud-lambda-role` con su política, las tres funciones Lambda (Python 3.12),
el event source mapping, la HTTP API `gamecloud-api` (rutas, permisos y stage `$default` con
throttling) y el archivo `config.js`.

Al terminar imprime dos líneas `export`. Copialas en tu terminal para definir `API_URL` y
`QUEUE_URL`, que se usan en las pruebas.

### 4. Probar

- Web: <http://localhost:4566/gamecloud-web/index.html>
  (CloudFront en MiniStack solo funciona a nivel API, por eso el sitio se prueba desde S3).
- Enviar un puntaje:

```bash
curl -X POST "$API_URL/scores" -H 'Content-Type: application/json' \
  -d '{"jugador":"ana","juego":"doom","puntaje":9800}'
```

## Pruebas de la arquitectura (sección 6 del informe)

| # | Prueba | Cómo |
|---|--------|------|
| 1 | 5 puntajes válidos → `202` | `curl -s -o /dev/null -w "%{http_code}\n" -X POST "$API_URL/scores" -H 'Content-Type: application/json' -d '{"jugador":"Alice","juego":"doom","puntaje":2400}'` (repetir con otros jugadores y juegos) |
| 2 | Juego inexistente → `400` | mismo `curl` con `"juego":"tetris"` |
| 3 | Puntaje menor no cambia el ranking | `GET /ranking?juego=doom`, `POST` de un puntaje menor, `sleep 4`, `GET /ranking?juego=doom` |
| 4 | Consultar ranking | `curl -s "$API_URL/ranking"` y `curl -s "$API_URL/ranking?juego=doom"` |
| 5 | Pico de 50 puntajes | pausar el consumidor (`update-event-source-mapping --no-enabled`), enviar 50 `POST` en paralelo, `get-queue-attributes`, reactivar (`--enabled`) y volver a consultar la cola |
| 6 | Mensaje inválido → DLQ | `bash scripts/prueba6_dlq.sh` |
| 7 | Logs de `procesar_puntaje` | `awsl logs filter-log-events --log-group-name /aws/lambda/procesar_puntaje --filter-pattern "Nuevo record guardado"` |

## Estructura del repositorio

```
tp3-gamecloud/
├── README.md
├── docker-compose.yml
├── iam/
│   ├── trust-lambda.json        # trust policy: Lambda puede asumir el rol
│   └── politica-lambdas.json    # permisos sobre la tabla, la cola y los logs
├── lambdas/
│   ├── ranking.py               # GET /ranking
│   ├── recibir_puntaje.py       # POST /scores → valida y encola en SQS
│   └── procesar_puntaje.py      # consume la cola y escribe en DynamoDB
├── scripts/
│   ├── deploy.sh                # despliegue completo
│   ├── prueba6_dlq.sh           # prueba 6.6 (mensaje inválido → DLQ)
│   └── cleanup.sh               # elimina los recursos creados
└── web/
    └── index.html
```

## Notas de diseño y limitaciones

- **Idempotencia:** `procesar_puntaje` guarda el puntaje solo si supera el récord del jugador, así
  que procesar dos veces el mismo mensaje deja el mismo estado final. La lectura y la escritura
  son operaciones separadas (no atómicas); la mejora sería un `put_item` con
  `ConditionExpression`.
- **Mínimo privilegio:** la política (`iam/politica-lambdas.json`) limita las acciones de DynamoDB
  (`GetItem`, `PutItem`, `Scan`) a la tabla `Puntajes`, las de SQS a la cola `puntajes` y los logs a
  los log groups de las tres funciones. Como el rol es único y compartido (lo pide la consigna),
  cada función termina con permisos que no necesita (por ejemplo, `ranking` puede escribir en la
  tabla). En un entorno real conviene un rol por función.
- **API abierta:** no hay autenticación en la API; en producción se agregaría un authorizer.
- **AWS CLI en este entorno:** `aws sqs send-message` y `aws sqs receive-message` fallaron con
  `badly formed help string` al mostrar la respuesta, por lo que esos pasos de la prueba 6.6 se
  hacen con `curl` contra la API HTTP de SQS.

## Limpieza

```bash
bash scripts/cleanup.sh
```

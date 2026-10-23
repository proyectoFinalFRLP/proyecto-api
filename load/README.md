# Pruebas de carga (TESIS-96)

Scripts de [k6](https://grafana.com/docs/k6/latest/) sobre los endpoints críticos de la API.
Los resultados de la corrida de referencia, con la máquina, las salvedades y las conclusiones,
están en [`docs/guides/carga.md`](../docs/guides/carga.md).

| Script                | Qué mide                                                      | Carga nominal                  |
| --------------------- | ------------------------------------------------------------- | ------------------------------ |
| `orders_create.js`    | `POST /api/v1/orders` (alta manual, descuenta stock con lock) | 50 req/s durante 60 s          |
| `webhooks.js`         | `POST /api/webhooks/integrations/:id` firmado (ingesta)       | 100 req/s durante 60 s         |
| `stock_contention.js` | `POST /api/v1/orders` sobre **un mismo SKU** + consistencia   | 20 workers sin pausa, 30 s     |
| `listings.js`         | `GET /orders` paginado/filtrado/búsqueda, `/products`, `/shipments` | 30 + 10 + 10 req/s, 60 s |
| `login.js`            | `POST /api/v1/auth/login` con credenciales válidas            | 5 req/s durante 30 s           |

Todos tienen **thresholds**: p95 < 500 ms (el umbral de la card, ajustable con `-e P95_MS=`),
tasa de error < 1 % y cero iteraciones descartadas (si k6 no llega a despachar la tasa pedida
porque el servidor no da abasto, la corrida falla aunque lo que sí salió haya sido rápido).
`stock_contention.js` además exige que el stock final cuadre con las órdenes creadas.
k6 sale con código distinto de cero si algún threshold no se cumple.

## Instalar k6

Un binario sin dependencias: [releases de k6](https://github.com/grafana/k6/releases). La
corrida de referencia usó **k6 v1.3.0**. En Windows alcanza con bajar
`k6-v1.3.0-windows-amd64.zip` y descomprimirlo en cualquier carpeta; no hace falta
instalarlo en el sistema. En macOS `brew install k6`; en Linux, el `.deb`/`.rpm` de la misma
página o `docker run --rm -i grafana/k6:1.3.0`.

## Correr contra una API local (el default)

Los scripts apuntan por default a `http://localhost:3000`. **No** se corren contra la base de
desarrollo de todos los días: crean miles de órdenes y una integración con un secreto conocido.
Se usa una base propia, que se tira al terminar.

### 1. Base propia de la prueba

Rails toma la URL de cada base de `DATABASE_URL` y de `<NOMBRE>_DATABASE_URL`. Para que **todas**
queden aisladas —incluida la de la cola, donde caen los jobs que encolan las órdenes y los
webhooks— se apuntan las cuatro:

```bash
export RAILS_ENV=production   # o development, ver más abajo
export DATABASE_URL=postgres://postgres:postgres@127.0.0.1/proyecto_api_loadtest
export CACHE_DATABASE_URL=postgres://postgres:postgres@127.0.0.1/proyecto_api_loadtest_cache
export QUEUE_DATABASE_URL=postgres://postgres:postgres@127.0.0.1/proyecto_api_loadtest_queue
export CABLE_DATABASE_URL=postgres://postgres:postgres@127.0.0.1/proyecto_api_loadtest_cable
```

**Producción local** es lo más parecido al despliegue (sin recarga de código, `eager_load`,
logs en `warn`, caché en Solid Cache). Pide además lo que exige `config/environments/production.rb`:

```bash
export SECRET_KEY_BASE=$(bin/rails secret) DEVISE_JWT_SECRET_KEY=$(bin/rails secret)
export CORS_ALLOWED_ORIGINS=http://localhost:5173 RAILS_ALLOWED_HOSTS=localhost,127.0.0.1
export SEED_USER_PASSWORD='Carga-2026-usuario' SEED_ADMIN_PASSWORD='Carga-2026-admin'
export RAILS_LOG_LEVEL=warn
```

(`SECRET_KEY_BASE` tiene que ser el mismo en los tres pasos: con él se cifran las credenciales
de la integración que siembra `fixtures.rb`.) Con `RAILS_ENV=development` no hace falta nada de
eso, la contraseña de los seeds es `password123` y las latencias salen más altas por los logs
y la recarga: sirve para probar los scripts, no para sacar números.

```bash
bin/rails db:prepare db:seed
bin/rails runner load/fixtures.rb     # deja load/fixtures.json
```

> **PostgreSQL en Windows:** si `db:prepare` corta con *server closed the connection
> unexpectedly*, el servidor se está cayendo al rechazar una base que todavía no existe (pasa
> con el locale en español). Crear las cuatro bases a mano con `psql -c "CREATE DATABASE ..."`
> y repetir.

`fixtures.rb` se niega a correr contra una base que no se llame `*loadtest*`. Crea 200
productos con 1 000 000 de unidades en el primer depósito de `norte`, un producto caliente
(`LOAD-HOT`) para la contención, la integración de Shopify con un secreto conocido y una
variante vinculada a cada producto, y 20 000 órdenes históricas para que el listado pagine
sobre volumen (`LOAD_HISTORIC_ORDERS=0` para no sumar más en una segunda pasada).

### 2. Servidor

```bash
bundle exec puma -C config/puma.rb -b tcp://127.0.0.1:3100
```

Puma con la config del repo: un proceso, `RAILS_MAX_THREADS` hilos (3 por default, igual que
el despliegue). El `-b` fija IPv4: en Windows `localhost` puede resolver a `::1` o a
`127.0.0.1` según quién pregunte.

### 3. Scripts

Desde la carpeta `load/` (los JSON de resultados quedan en `load/results/`, ignorada por git):

```bash
cd load
k6 run -e BASE_URL=http://127.0.0.1:3100 -e LOAD_PASSWORD="$SEED_USER_PASSWORD" orders_create.js
k6 run -e BASE_URL=http://127.0.0.1:3100 webhooks.js
k6 run -e BASE_URL=http://127.0.0.1:3100 -e LOAD_PASSWORD="$SEED_USER_PASSWORD" stock_contention.js
k6 run -e BASE_URL=http://127.0.0.1:3100 -e LOAD_PASSWORD="$SEED_USER_PASSWORD" listings.js
k6 run -e BASE_URL=http://127.0.0.1:3100 -e LOAD_PASSWORD="$SEED_USER_PASSWORD" login.js
```

De a uno: corridos en paralelo se reparten el mismo proceso de Puma y ninguno mide lo suyo.

Variables útiles: `RATE` (req/s de `orders_create`, `webhooks` y `login`), `WORKERS`
(`stock_contention`), `ORDERS_RATE`/`PRODUCTS_RATE`/`SHIPMENTS_RATE` (`listings`), `P95_MS`,
`SCALE` (multiplica la duración: `-e SCALE=0.1` es una corrida de humo de pocos segundos),
`FIXTURES` (otra ruta para el JSON de fixtures), `RESULTS_DIR`.

### 4. Limpieza

```bash
psql -U postgres -c "DROP DATABASE proyecto_api_loadtest" \
     -c "DROP DATABASE proyecto_api_loadtest_cache" \
     -c "DROP DATABASE proyecto_api_loadtest_queue" \
     -c "DROP DATABASE proyecto_api_loadtest_cable"
rm load/fixtures.json
```

## Límites de la API que afectan a las pruebas

- **Login:** 10 intentos **fallidos** por IP cada 3 minutos (`FailedAttemptLimit`). Los logins
  exitosos no cuentan. Por eso los scripts se autentican **una sola vez** en `setup()` y
  reparten el token (dura 24 h) a todos los VUs; una contraseña equivocada corta la corrida
  en el primer intento en vez de quemar el cupo.
- **Registro:** `rate_limit` de Rails sobre `POST /auth/register`. **Cotizaciones:**
  `rate_limit` sobre `POST /quotes`. Ninguno de los dos está en estos scripts.
- **Alta de órdenes:** el lock de stock se toma **sin esperar** (`wait: false`, ADR-009). Dos
  órdenes simultáneas del mismo producto: una pasa y la otra recibe 409 al instante. Por eso
  `orders_create.js` reparte los productos en ronda y `stock_contention.js` cuenta el 409 como
  respuesta esperada.
- **Webhooks:** sin límite de tasa; sí verifican la firma HMAC, que el script calcula con el
  secreto de `fixtures.json`.

## Workers y webhooks

Los webhooks se **aceptan** en el request (firma → `WebhookLog` → job encolado → 202) y se
**procesan** después en Solid Queue. `webhooks.js` mide la aceptación. En Windows ni `bin/jobs`
ni `SOLID_QUEUE_IN_PUMA` arrancan (`architecture.md` §8.3), así que durante la corrida la cola
sólo crece. Para medir el drenaje después, con las mismas variables de entorno de la base:

```bash
QUEUES=realtime bundle exec rails runner bin/worker_windows.rb
```

y mirar cuánto tardan en desaparecer los `pending` de `webhook_logs`. `QUEUES=realtime` deja
afuera la cola `low`, donde están los `SyncStockToChannelsJob` que encolan las órdenes: con los
productos vinculados a Shopify, correrlos intentaría pegarle a la tienda de verdad. En Linux o
Docker, `SOLID_QUEUE_IN_PUMA=1` mide API y workers juntos, como en el despliegue (pero con la
misma salvedad sobre la cola `low`).

## Contra el entorno desplegado

**No se corre contra producción sin el OK explícito del equipo**: el servidor es uno solo, con
la API, los workers y la base en la misma máquina, y estos scripts lo saturan a propósito. Además
crean órdenes reales y, con productos vinculados a canales, encolan syncs de stock salientes
hacia Mercado Libre/Shopify.

Si el equipo lo habilita (idealmente sobre un entorno de staging con una empresa de prueba):

1. Crear la empresa, el usuario y los productos de prueba **por la API o el backoffice**, nunca
   con `fixtures.rb` (que escribe directo en la base y sólo corre contra `*loadtest*`). Armar a
   mano un `fixtures.json` con la misma forma y pasarlo con `-e FIXTURES=/ruta/fixtures.json`.
2. Los scripts se niegan a apuntar a un host que no sea local salvo que se diga explícitamente:

   ```bash
   k6 run -e BASE_URL=https://api.ejemplo.com -e ALLOW_REMOTE=1 -e RATE=10 -e SCALE=0.5 ...
   ```

3. Empezar con una fracción de la tasa nominal (`RATE`, `SCALE`) y subir mirando el servidor.

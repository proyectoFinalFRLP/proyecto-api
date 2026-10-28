# Guía de setup local

Cómo levantar OneStock en una máquina propia, con datos de ejemplo, para recorrerlo y evaluarlo. Está pensada para alguien que no participó del desarrollo. No hace falta ninguna cuenta externa: todo corre local, y las integraciones con proveedores reales son opcionales (§9).

---

## 1. Qué se levanta

| Pieza | Dónde | Para qué |
| --- | --- | --- |
| PostgreSQL | puerto 5432 | Datos (`proyecto_api_development`) y cola de jobs (`proyecto_api_development_queue`) |
| API Rails | http://localhost:3000 | La API REST (`/api/v1`), los webhooks públicos (`/api/webhooks`) y el backoffice (`/admin`) |
| Workers de Solid Queue | mismo proceso que la API (o aparte) | Ingesta de webhooks, sync de stock, reintentos de la DLQ, tracking |
| Front React (opcional) | http://localhost:5173 | La aplicación de las empresas (repo [`proyecto-web`](https://github.com/proyectoFinalFRLP/proyecto-web)) |

No hay Redis ni otro broker: la cola de jobs vive en PostgreSQL ([ADR-020](../adr/ADR-020-decisiones-tardias-broker-dlq-identity-mapping.md)).

Hay dos caminos. **Elegí uno:**

- **A. Con Docker** (§2): sólo pide Docker. Es el camino recomendado en Windows y el que menos se rompe.
- **B. Instalación nativa** (§3): Ruby y PostgreSQL instalados en la máquina. Linux, macOS o WSL.

Los comandos de esta guía son de `bash`. En Windows, usá **Git Bash** (viene con Git para Windows): PowerShell 5 altera las comillas de los JSON que se le pasan a `curl`.

---

## 2. Camino A: con Docker (sin instalar Ruby)

Requisitos: Docker (Docker Desktop en Windows o macOS) y git.

```bash
git clone https://github.com/proyectoFinalFRLP/proyecto-api.git
cd proyecto-api
```

**1. Una red y un PostgreSQL.** La contraseña `admin` es la que `config/database.yml` usa por defecto en desarrollo.

```bash
docker network create onestock
docker run -d --name onestock-pg --network onestock -e POSTGRES_PASSWORD=admin postgres:16-alpine
```

**2. Un contenedor de Ruby con el repo montado.** Queda corriendo en segundo plano y los comandos de abajo se ejecutan adentro con `docker exec`.

```bash
docker run -d --name onestock-api --network onestock -p 3000:3000 -v "$(pwd):/rails" -w /rails -e PROYECTO_API_DATABASE_HOST=onestock-pg ruby:4.0.2-slim sleep infinity
```

En Windows, Git Bash convierte las rutas y el montaje falla. Anteponé `MSYS_NO_PATHCONV=1` y usá `$(pwd -W)`:

```bash
MSYS_NO_PATHCONV=1 docker run -d --name onestock-api --network onestock -p 3000:3000 -v "$(pwd -W):/rails" -w /rails -e PROYECTO_API_DATABASE_HOST=onestock-pg ruby:4.0.2-slim sleep infinity
```

**3. Dependencias del sistema y gemas** (unos minutos la primera vez):

```bash
docker exec onestock-api bash -c "apt-get update -qq && apt-get install -qq -y --no-install-recommends build-essential libpq-dev libyaml-dev pkg-config git && bundle install"
```

**4. Bases de datos y datos de ejemplo.** `db:prepare` crea las bases de desarrollo, de la cola y de test, carga los esquemas y, como las bases son nuevas, corre los seeds. Al final imprime un resumen (`Seeds cargados: 3 empresas, 5 usuarios, ...`).

```bash
docker exec onestock-api bundle exec rails db:prepare
```

> Dentro del contenedor se usa `bundle exec rails` y no `bin/rails`. Un clon hecho en Windows convierte los finales de línea de `bin/*` a CRLF, y `bin/rails` falla en Linux con `env: 'ruby\r': No such file or directory`. `bundle exec rails` no depende del shebang. El aviso `shebang line ending with \r may cause problems` que imprime es inofensivo.

**5. La API con los workers adentro:**

```bash
docker exec -it -e SOLID_QUEUE_IN_PUMA=1 onestock-api bundle exec rails server -b 0.0.0.0
```

Con `SOLID_QUEUE_IN_PUMA=1`, Puma levanta también el supervisor de Solid Queue: workers, dispatcher y tareas programadas. Es la misma topología del despliegue. La API queda en http://localhost:3000 y se corta con `Ctrl-C`. Con el repo montado desde Windows, el primer arranque tarda cerca de un minuto.

Seguí en [§4](#4-verificar-que-anda).

**Para limpiar todo después:**

```bash
docker rm -f onestock-api onestock-pg
docker network rm onestock
```

---

## 3. Camino B: instalación nativa

Requisitos:

| Herramienta | Versión |
| --- | --- |
| Ruby | 4.0.2 (la de `.ruby-version`; con rbenv, asdf o mise) |
| Bundler | 4.x (viene con Ruby 4) |
| PostgreSQL | 14 o superior (probado con 16) |
| Paquetes del sistema | `libpq-dev` (o `postgresql-libs`), `libyaml-dev`, compilador de C |

**1. Clonar e instalar las gemas:**

```bash
git clone https://github.com/proyectoFinalFRLP/proyecto-api.git
cd proyecto-api
bundle install
```

**2. Conexión a PostgreSQL.** Por defecto la app se conecta a `127.0.0.1:5432` con el usuario `postgres` y la contraseña `admin`. Si tu PostgreSQL usa otros valores, exportalos antes de seguir (ver §5):

```bash
export PROYECTO_API_DATABASE_USER=postgres
export PROYECTO_API_DATABASE_PASSWORD=<tu contraseña>
```

**3. Bases de datos y datos de ejemplo:**

```bash
bin/setup --skip-server     # bundle install + db:prepare (que corre los seeds) + limpieza de logs
```

**4. La API y los workers.** Dos opciones:

```bash
# Todo en un proceso, como en el despliegue
SOLID_QUEUE_IN_PUMA=1 bin/rails server

# O separados, en dos terminales
bin/rails server
bin/jobs
```

> **macOS:** los workers se caen al arrancar (`Abort trap: 6` o `Segmentation fault` en `pg`) por cómo macOS trata el `fork`. Anteponé `OBJC_DISABLE_INITIALIZE_FORK_SAFETY=YES PGGSSENCMODE=disable` a cualquiera de los dos comandos ([architecture.md §8.3](../guidelines/architecture.md#83-correr-los-workers)).
>
> **Windows sin WSL:** ni `bin/jobs` ni `SOLID_QUEUE_IN_PUMA` arrancan, porque el supervisor de Solid Queue registra `SIGQUIT`, que no existe en Windows. Usá `bin/rails server` y, en otra terminal, `bundle exec rails runner bin/worker_windows.rb`. Ese worker procesa la cola pero **no** corre las tareas programadas ni los jobs diferidos, así que la DLQ no reintenta sola: el reintento manual por API sí funciona. Para una evaluación completa en Windows conviene el camino A.

---

## 4. Verificar que anda

**La API responde:**

```bash
curl -s -o /dev/null -w "%{http_code}\n" http://localhost:3000/up
```

Tiene que imprimir `200`.

**Login.** El login es por empresa: el header `X-Tenant-Slug` dice en qué empresa se entra (en el front lo resuelve el subdominio).

```bash
curl -s -X POST http://localhost:3000/api/v1/auth/login -H "Content-Type: application/json" -H "X-Tenant-Slug: norte" -d '{"email":"admin@norte.com","password":"password123"}'
```

Devuelve `{"token":"eyJ..."}`. Ese token va en el header `Authorization: Bearer <token>` de los demás requests:

```bash
TOKEN=<el token>
curl -s http://localhost:3000/api/v1/products -H "Authorization: Bearer $TOKEN"
```

**El backoffice** (administración de la plataforma, con todas las empresas): http://localhost:3000/admin.

### Cuentas de los seeds

Todas son de desarrollo. En producción los seeds no usan estas contraseñas.

| Empresa (slug) | Usuario | Contraseña | Notas |
| --- | --- | --- | --- |
| Distribuidora Norte S.A. (`norte`) | `admin@norte.com`, `operador@norte.com` | `password123` | La empresa con más datos: productos, depósitos, órdenes, envíos, integraciones y cuatro semanas de actividad |
| Comercial Sur S.R.L. (`sur`) | `admin@sur.com`, `deposito@sur.com` | `password123` | Sirve para comprobar el aislamiento entre empresas |
| Importadora Vieja S.A. (`importadora`) | `admin@vieja.com` | `password123` | Empresa dada de baja: el login se rechaza |
| Backoffice | `admin@backoffice.com` | `admin123` | Sólo en `/admin` |

Para ver el aislamiento multi-tenant: con el token de Norte, pedir un recurso de Sur por id responde **404**, no 403 ([ADR-003](../adr/ADR-003-multitenancy.md)).

---

## 5. Variables de entorno

**En desarrollo no hace falta ninguna.** Todas tienen un valor por defecto pensado para una máquina local.

Rails **no lee el archivo `.env`** (el proyecto no usa `dotenv`). Las variables se exportan en la terminal o se pasan con `-e` a Docker. `.env.example` documenta cuáles existen. Los únicos que lo leen son las tareas de Shopify y OCA de §9.

| Variable | Default en desarrollo | Para qué |
| --- | --- | --- |
| `PROYECTO_API_DATABASE_HOST` | `127.0.0.1` | Host de PostgreSQL |
| `PROYECTO_API_DATABASE_USER` | `postgres` | Usuario de PostgreSQL |
| `PROYECTO_API_DATABASE_PASSWORD` | `admin` | Contraseña de PostgreSQL |
| `DEVISE_JWT_SECRET_KEY` | `secret_key_base` | Firma de los JWT |
| `ENCRYPTION_KEY`, `ENCRYPTION_KEY_DERIVATION_SALT` | `secret_key_base` | Cifrado de las credenciales de las integraciones |
| `SOLID_QUEUE_IN_PUMA` | sin definir | Si está, Puma levanta también los workers |
| `PUBLIC_WEBHOOK_BASE_URL` | sin definir | URL pública (un túnel) para que un proveedor real alcance los webhooks (§9) |

---

## 6. El front (opcional)

Requisitos: Node.js 20 o superior.

```bash
git clone https://github.com/proyectoFinalFRLP/proyecto-web.git
cd proyecto-web
npm install
cp .env.example .env     # VITE_API_URL=http://localhost:3000/api/v1, VITE_TENANT=norte
npm run dev
```

Queda en http://localhost:5173 con la empresa Norte. En local la empresa no sale del subdominio: se cambia con `?tenant=sur` en la URL o con `VITE_TENANT`.

---

## 7. Demo: una venta por webhook, de punta a punta

Este recorrido ejercita la pieza central del sistema: un webhook entra por el gateway público, falla porque el producto no está vinculado, queda en la Dead Letter Queue, se corrige el vínculo y el reintento registra la venta con su stock descontado. El detalle de cada paso está en [`flujo-de-un-webhook.md`](flujo-de-un-webhook.md).

Necesita la API **con los workers** corriendo (§2 paso 5 o §3 paso 4) y el `TOKEN` de Norte de §4. Se usa la integración de Mercado Libre de Norte, que no firma sus webhooks, así que se le puede mandar un evento con `curl`.

En el camino A, reemplazá `bin/rails` por `docker exec onestock-api bundle exec rails`.

**1. El id de la integración y del producto** (en una base recién sembrada son `1` y `1`):

```bash
bin/rails runner 'puts "integracion=#{CompanyIntegration.unscoped.joins(:service).find_by!(services: { service_name: "Mercado Libre" }).id} producto=#{Product.unscoped.find_by!(sku: "NOR-001").id}"'
```

```bash
INTEGRACION=<id de la integración>
PRODUCTO=<id del producto>
```

**2. El stock antes de la venta:**

```bash
curl -s http://localhost:3000/api/v1/products/$PRODUCTO -H "Authorization: Bearer $TOKEN"
```

Anotá el `total_stock`.

**3. Mercado Libre avisa una venta.** El gateway no pide JWT:

```bash
curl -s -i -X POST http://localhost:3000/api/webhooks/integrations/$INTEGRACION -H "Content-Type: application/json" -d '{"id":"DEMO-0001","status":"paid","buyer":{"nickname":"COMPRADOR_DEMO"},"order_items":[{"item":{"id":"MLA-DEMO-1"},"quantity":2,"unit_price":1500}]}'
```

Responde `202 Accepted` enseguida: el evento quedó guardado y encolado.

**4. La venta no entró: el producto no está vinculado.** El worker intentó procesarla, no encontró el id `MLA-DEMO-1` en los vínculos de esa integración y la derivó a la DLQ:

```bash
curl -s "http://localhost:3000/api/v1/failed-events?status=pending" -H "Authorization: Bearer $TOKEN"
```

Entre los eventos (los seeds ya traen alguno de ejemplo) aparece uno `webhooks.order_ingestion`, `direction: inbound`, con `error_code` `ORD-002` y `error_message` «La venta trae un producto sin vincular» (el detalle técnico queda en `last_error`: `UnmappedProductError: external product 'MLA-DEMO-1' is not mapped to any internal product`). Anotá su `id` como `EVENTO`. Si nadie lo corrige, el motor lo reintenta solo (1, 2, 4, 8 y 16 minutos) y lo da por muerto (`dead`).

**5. Se vincula el producto con su publicación en el canal:**

```bash
curl -s -X POST http://localhost:3000/api/v1/products/$PRODUCTO/mappings -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" -d "{\"product_mapping\":{\"company_integration_id\":$INTEGRACION,\"external_product_id\":\"MLA-DEMO-1\"}}"
```

Responde `201`.

**6. Se reintenta el evento, sin esperar al motor:**

```bash
curl -s -X POST http://localhost:3000/api/v1/failed-events/$EVENTO/retry -H "Authorization: Bearer $TOKEN"
```

**7. La venta entró:**

```bash
curl -s "http://localhost:3000/api/v1/orders?search=DEMO-0001" -H "Authorization: Bearer $TOKEN"
curl -s http://localhost:3000/api/v1/products/$PRODUCTO -H "Authorization: Bearer $TOKEN"
```

La orden `DEMO-0001` existe (`status: paid`, `total_amount: 3000.0`), el `total_stock` bajó 2 unidades y el evento de la DLQ quedó `succeeded` (`GET /api/v1/failed-events?status=succeeded`).

**8. Idempotencia.** Repetí el `curl` del paso 3: responde `202` y el evento queda `processed`, pero la búsqueda del paso 7 sigue devolviendo una sola orden y el stock no vuelve a bajar.

---

## 8. Tests, lint y seguridad

```bash
bundle exec rspec                         # suite completa (crea proyecto_api_test)
bundle exec rubocop                       # estilo
bundle exec brakeman -q                   # análisis estático de seguridad
bundle exec bundle-audit check --update   # gemas con vulnerabilidades conocidas
```

En el camino A, con `docker exec -e RAILS_ENV=test onestock-api bundle exec rspec` (antes, una vez: `docker exec -e RAILS_ENV=test onestock-api bundle exec rails db:prepare`). La suite reporta la cobertura en `coverage/`. Son los mismos chequeos que corre el CI en cada PR.

---

## 9. Opcional: Shopify real

La integración con Shopify funciona contra una tienda de prueba (*dev store*) del Partner Program: publica el stock, vincula productos por SKU y recibe las ventas con firma HMAC. Necesita una app propia en el Dev Dashboard de Shopify y un túnel público (`ngrok http 3000`) para que la tienda alcance el gateway. El paso a paso y las tareas `bin/rails "integrations:shopify:*"` están en `lib/tasks/integrations.rake`. Las decisiones, en [ADR-018](../adr/ADR-018-conexion-con-proveedores-reales.md) y [ADR-019](../adr/ADR-019-ventas-entrantes-de-shopify.md).

**La ubicación de stock es obligatoria para publicar** (TESIS-177). `integrations:shopify:connect` prueba la conexión al terminar y completa `location_id` si la tienda tiene una sola ubicación. Si tiene varias, no elige: hay que elegirla en el backoffice con «Configure connection», que la ofrece en una lista. Sin ubicación, el sync no llama a Shopify: el vínculo guarda el motivo (`last_sync_error`) y `GET /api/v1/integrations` la muestra en `stock_sync.missing_settings`. Para ver el estado:

```bash
bin/rails "integrations:shopify:test[norte]"     # prueba la conexión y dice si puede publicar el stock
```

#### Volver a publicar el stock (también en producción)

Después de completar la ubicación, o de cualquier incidente que dejó a Shopify con otro stock que el OMS:

```bash
bin/rails "integrations:shopify:resync[norte]"   # sólo Shopify
bin/rails "integrations:resync_stock[norte]"     # todos los canales activos de la empresa
```

Encolan un job por producto vinculado (necesita los workers corriendo, `SOLID_QUEUE_IN_PUMA=1` en el deploy) y publican el stock vigente. Si a la integración le falta configuración no encolan nada y dicen qué falta; un vínculo sin `inventory_item_id` se saltea y se lista: hay que volver a vincularlo desde «Canales de venta» del producto. En producción se corren dentro del contenedor (`bin/kamal app exec --reuse "bin/rails 'integrations:shopify:resync[<slug>]'"`).

### OCA e-Pak (entorno de prueba)

**No hace falta configurar nada.** En desarrollo, `db:seed` carga las plantillas de **OCA e-Pak** y deja a Norte conectada con la **cuenta de prueba pública** de OCA (la que publica la propia OCA en developers.oca.com.ar, sólo válida en su entorno de prueba). Con internet, alcanza con levantar la API y la web: el alta manual cotiza con OCA, despacha, imprime la etiqueta y sigue el envío.

Para probar la cuenta o recorrer el flujo sin la web:

```bash
bin/rails "integrations:oca:test[norte]"      # prueba la cuenta (GetOperativasByUsuario)
bin/rails "integrations:oca:smoke[norte]"     # cotiza, despacha, baja la etiqueta a tmp/ y pregunta el estado
```

Para usar **otra cuenta** (una propia de OCA), se cargan `OCA_<SLUG>_*` en el entorno o en `.env` (ver `.env.example`) y se corre `bin/rails "integrations:oca:connect[norte]"`, igual que Shopify: reemplaza la cuenta de demo. En producción los seeds sólo cargan las plantillas y cada empresa conecta la suya.

Con Norte conectada, cotizar un envío o un alta manual le pide tarifa al entorno de prueba de OCA; despachar con OCA crea una orden de retiro de prueba, y la etiqueta se baja desde `GET /api/v1/shipments/:id/label`. Sin internet, OCA simplemente no aparece entre las opciones. Las tareas sólo corren en desarrollo, y la smoke se niega a correr si la plantilla no apunta al entorno de prueba.

Las decisiones están en [ADR-022](../adr/ADR-022-oca-epak-con-el-adaptador-generico.md).

---

## 10. Problemas frecuentes

| Síntoma | Causa y solución |
| --- | --- |
| `password authentication failed for user "postgres"` | La contraseña de tu PostgreSQL no es `admin`: exportá `PROYECTO_API_DATABASE_PASSWORD`. En Docker, `POSTGRES_PASSWORD` sólo se aplica la **primera** vez que se crea el volumen: si cambiaste el valor después, borrá el contenedor y empezá de nuevo |
| `connection refused` a `::1` en Windows | Usá `127.0.0.1` y no `localhost` (es el default) |
| `Solid Queue is configured to use N threads but the database connection pool is M` | `RAILS_MAX_THREADS` quedó por debajo de 15: no la definas en desarrollo |
| `db:prepare` no puede crear la base de la cola | Ver [architecture.md §8.5](../guidelines/architecture.md#85-la-base-de-datos-de-la-cola) para crearla a mano |
| El webhook responde `202` pero el evento queda `pending` | Los workers no están corriendo: levantá la API con `SOLID_QUEUE_IN_PUMA=1` o `bin/jobs` aparte |
| El login responde `401` con credenciales correctas | Falta el header `X-Tenant-Slug`, o el slug es de otra empresa |
| El login responde `429` | 10 intentos fallidos desde la misma IP en 3 minutos: esperá 3 minutos |
| `env: 'ruby\r': No such file or directory` | Un clon de Windows dejó `bin/*` con CRLF: usá `bundle exec rails` en vez de `bin/rails` (ver §2) |
| `bin/jobs` muere en macOS | Ver la nota de macOS en §3 |

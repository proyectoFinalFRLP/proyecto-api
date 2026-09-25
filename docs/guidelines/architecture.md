# Arquitectura del proyecto

## 1. Descripción general

Backend del trabajo final de la carrera de Ingeniería en Sistemas de Información (FRLP). API REST en Ruby on Rails (API-only) que actúa como OMS (Order Management System) multi-tenant para la gestión de catálogo, stock, órdenes e integraciones con plataformas externas.

**Repositorio:** `proyectoFinalFRLP/proyecto-api`  
**Frontend:** `proyectoFinalFRLP/proyecto-web`  
**Gestor de tareas:** Jira (proyecto `TESIS`)

---

## 2. Stack tecnológico

| Tecnología      | Versión | Rol                                   |
| --------------- | ------- | ------------------------------------- |
| Ruby            | 4.0.2   | Lenguaje                              |
| Rails           | 8.1.2.1 | Framework (API-only)                  |
| PostgreSQL      | —       | Base de datos principal               |
| Puma            | 7.2.0   | Servidor web                          |
| Devise          | 5.0.3   | Autenticación                         |
| devise-jwt      | 0.13.0  | Tokens JWT                            |
| Pundit          | 2.5.2   | Autorización por políticas            |
| Blueprinter     | 1.2.1   | Serialización JSON                    |
| Solid Queue     | 1.4.0   | Background jobs (DB-backed)           |
| Solid Cache     | 1.0.10  | Caché (DB-backed)                     |
| Solid Cable     | 3.0.12  | Action Cable (DB-backed)              |
| RuboCop         | 1.86.0  | Linter (+ rails, performance, rspec)  |
| RSpec           | 8.0.4   | Testing                               |
| Lefthook        | 2.1.4   | Git hooks                             |
| Kamal           | 2.11.0  | Despliegue Docker                     |

### Variable de entorno

```bash
DEVISE_JWT_SECRET_KEY=<rails secret>   # Clave para firmar los tokens JWT
PROYECTO_API_DATABASE_PASSWORD=admin  # Contraseña de PostgreSQL (producción)
```

---

## 3. Estructura de carpetas

```
app/
├── controllers/
│   ├── application_controller.rb    # Base: authenticate_user!, set_current_tenant, error handling
│   ├── concerns/                    # Módulos reutilizables entre controllers
│   └── api/
│       └── v1/                      # Versión de la API
│           └── [recurso]_controller.rb
│
├── models/
│   ├── application_record.rb        # Base abstracta (sin scope: ver concerns/company_scoped.rb)
│   ├── current.rb                   # ActiveSupport::CurrentAttributes (company_id, user)
│   ├── concerns/
│   │   └── company_scoped.rb        # Multi-tenancy: default scope + company_id forzado e inmutable
│   └── [entidad].rb
│
├── poros/                           # Plain Old Ruby Objects — lógica de negocio
│   ├── application_poro.rb          # Base class
│   └── [dominio]/
│       └── [caso_de_uso].rb         # Un PORO = un caso de uso
│
├── serializers/
│   ├── application_serializer.rb    # Base Blueprinter::Base
│   └── [entidad]_serializer.rb
│
├── policies/
│   ├── application_policy.rb        # Base Pundit::Policy
│   └── [entidad]_policy.rb
│
├── jobs/
│   ├── application_job.rb           # Base ApplicationJob (Solid Queue)
│   └── [dominio]/
│       └── [nombre]_job.rb
│
└── mailers/
    └── application_mailer.rb

config/
├── routes.rb                        # namespace :api > namespace :v1
├── database.yml                     # PostgreSQL (dev, test, prod + cache/queue DBs)
├── initializers/
│   ├── cors.rb                      # rack-cors: todos los orígenes (dev)
│   └── devise.rb                    # Configuración de Devise
└── environments/

db/
├── schema.rb                        # Schema autogenerado (no editar manualmente)
├── migrate/                         # Migraciones en orden cronológico
└── seeds.rb                         # Datos iniciales de desarrollo

spec/
├── rails_helper.rb
├── spec_helper.rb
├── models/
├── requests/api/v1/                 # Request specs (integration tests)
├── policies/
├── poros/
└── factories/                       # FactoryBot factories

.github/
├── workflows/
│   ├── ci.yml                       # Security + Lint + Test
│   ├── auto-assign-reviewer.yml
│   └── pr-title.yml
└── pull_request_template.md
```

---

## 4. Flujo de un request

```
Request (con Authorization: Bearer <jwt>)
  ↓
ApplicationController
  - before_action :authenticate_user!     (Devise JWT — verifica token)
  - before_action :set_current_tenant     (extrae company_id del JWT → Current.company_id)
  ↓
Controller específico (app/controllers/api/v1/)
  - before_action :set_[recurso]          (Model.find → aplica scope multi-tenant automáticamente)
  - authorize @recurso                    (Pundit — verifica que el usuario tiene permiso)
  - PORO.new(...).call                    (delega la lógica de negocio)
  ↓
PORO (app/poros/[dominio]/)
  - Orquesta Models, Jobs, otras clases
  ↓
Serializer (Blueprinter)
  - Formatea el objeto Ruby → JSON
  ↓
render json: ...
```

### 4.0 Forma de la respuesta

Una sola regla, fijada en [ADR-015](../adr/ADR-015-convencion-de-respuesta-de-la-api.md): **una colección viaja envuelta, un recurso solo viaja pelado.**

```
GET  /api/v1/products      → { "data": [ ... ], "meta": { page, per_page, total } }
GET  /api/v1/warehouses    → { "data": [ ... ], "meta": { page, per_page, total } }
GET  /api/v1/products/:id  → { "id": 1, "sku": "...", ... }
POST /api/v1/products      → { "id": 1, "sku": "...", ... }
cualquier error            → { "error": "..." }
```

`meta` cuenta el scope **ya filtrado**, no la tabla entera, y lo lleva todo **listado de registros**: ninguno devuelve una cantidad ilimitada de filas. Los vocabularios fijos (`/orders/provinces`, `/products/categories`) y el resultado de una acción (`/orders/:id/quotes`) viajan en `data` sin `meta`, porque su largo lo decide el código y no los datos de la empresa (ver ADR-015).

El cálculo vive en un solo lugar, el concern `Api::V1::Paginatable`, con el techo (`MAX_PER_PAGE = 100`) y los dos defaults: 20 para una pantalla paginada y 100 para los listados que el consumidor lee enteros —depósitos, mapeos, integraciones— y usa para llenar un select. `page` y `per_page` fuera de rango se acotan en vez de romper.

`spec/requests/api/v1/pagination_spec.rb` fija los bordes una vez y recorre los listados que enumera, verificando que cada uno traiga `meta` y respete el techo; `api_contract_spec.rb` fija las formas de los endpoints que enumera. Las dos listas están escritas a mano: **un listado nuevo hay que sumarlo ahí**, o la suite no se entera de que existe.

### 4.1 Flujo de un webhook entrante

Los eventos de las plataformas externas no siguen el flujo de arriba: no hay JWT, no hay usuario y el proveedor no espera detrás de la lógica de negocio. El gateway persiste y suelta la conexión; el procesamiento corre en un worker (ver [ADR-010](../adr/ADR-010-ingesta-de-ordenes-de-webhooks.md)).

```
POST /api/webhooks/integrations/:company_integration_id   (sin autenticación)
  ↓
Api::Webhooks::IntegrationsController
  - El tenant sale de la integración, no de Current
  - WebhookLog.create!(status: 'pending')                 (auditoría del evento crudo)
  - Orders::ProcessWebhookEventJob.perform_later          (sólo canales de e-commerce)
  - head :accepted                                        (202, cuerpo vacío)
  ↓
Orders::ProcessWebhookEventJob                            (cola realtime)
  - with_tenant(company_id)
  ↓
Orders::ProcessWebhookOrder
  - Traduce el payload con el response_mapper del Service
  - Resuelve cada ítem contra ProductMapping (Identity Mapping)
  - Transacción: Order + OrderItems + descuento de stock
  - Marca el WebhookLog 'processed' o 'failed' + error_message
  ↓
(si falló) FailedEvent direction: 'inbound' → motor de reintentos (ADR-008)
```

### 4.2 Flujo de un webhook de courier (push tracking)

Los eventos de courier tampoco siguen el flujo de arriba: no hay JWT, no hay usuario, y el proveedor no espera detrás de la lógica de negocio — el gateway persiste el evento crudo y suelta la conexión; la traducción y la actualización del envío corren en un worker aparte (ver [ADR-011](../adr/ADR-011-push-tracking-de-couriers.md)).

```
POST /api/webhooks/couriers/:company_integration_id   (sin autenticación)
  ↓
Api::Webhooks::CouriersController
  - El tenant sale de la integración, no de Current
  - WebhookLog.create!(status: 'pending')              (auditoría del evento crudo)
  - Shipments::ProcessTrackingEventJob.perform_later   (sólo integraciones de tipo courier)
  - head :accepted                                     (202, cuerpo vacío)
  ↓
Shipments::ProcessTrackingEventJob                     (cola realtime)
  - with_tenant(company_id)
  ↓
Shipments::ProcessTrackingUpdate
  - Traduce el payload con el response_mapper del Service (Shipments::TranslateTrackingPayload)
  - Ubica el Shipment por tracking_number + company_integration_id
  - Registra el movimiento con Shipments::RegisterTrackingEvent:
    transacción shipment.lock! + ShipmentEvent + actualización de shipments.status
  - Marca el WebhookLog 'processed' o 'failed' + error_message
  ↓
(si falló) FailedEvent direction: 'inbound' → motor de reintentos (ADR-008)
```

### 4.3 Consulta periódica a couriers sin webhooks (pull tracking)

Con los couriers que no empujan el tracking, el sistema pregunta: un cronjob barre los envíos en curso y consulta al courier con su plantilla de seguimiento (`Service#tracking_service`). Lo que contesta pasa por el mismo núcleo que el push (ver [ADR-014](../adr/ADR-014-pull-tracking-de-couriers.md)).

```
config/recurring.yml (every 30 minutes)
  ↓
Shipments::ScanPullTrackingJob                         (cola low, sin tenant: unscoped)
  - Integraciones activas cuyo Service tiene tracking_service
  - Shipment.in_flight de cada una (ready_to_ship | in_transit, con tracking)
  - PollTrackingJob escalonado: 1 por envío, o 1 por lote si la plantilla es masiva
  ↓
Shipments::PollTrackingJob                             (cola low, 1 a la vez por integración)
  - with_tenant(company_id)
  ↓
Shipments::PollTrackingStatus
  - HttpAdapter#fetch con la plantilla de seguimiento y las credenciales de la integración
  - Shipments::TranslateTrackingPayload + Shipments::RegisterTrackingEvent
  - Fallo del courier → Rails.logger y sigue (sin DLQ: el próximo ciclo es el reintento)
```

---

## 5. Multi-tenancy en detalle

### 5.1 Global Default Scope (concern `CompanyScoped`)

> **Nota de diseño:** el enfoque original de este documento y del ADR-003 ponía el
> `default_scope` directamente en `ApplicationRecord`. En TESIS-41 se cambió a un
> concern **opt-in por modelo** (`CompanyScoped`), porque las tablas globales
> (`companies`, `services`) no tienen columna `company_id` y un scope global las
> rompería. `ApplicationRecord` queda sin scope: todo modelo nuevo con tenencia
> **debe** incluir el concern.

```ruby
# app/models/concerns/company_scoped.rb
module CompanyScoped
  extend ActiveSupport::Concern

  included do
    default_scope { where(company_id: Current.company_id) if Current.company_id }

    before_validation :assign_current_company, on: :create
    validate :company_id_is_immutable, on: :update
  end

  private

  def assign_current_company
    self.company_id = Current.company_id if Current.company_id
  end

  def company_id_is_immutable
    errors.add(:company_id, 'cannot be changed') if company_id_changed?
  end
end
```

El scope se aplica automáticamente a toda query: `Order.all` es equivalente a `Order.where(company_id: Current.company_id)`. Al crear registros, el `company_id` del contexto se fuerza siempre, ignorando cualquier valor del payload; al actualizar, el `company_id` es **inmutable** (no se puede mover un registro de tenant). Las tablas globales (`companies`, `services`) no incluyen el concern. Los procesos que necesitan operar fuera del contexto de un tenant (workers, seeds, consola) usan `Model.unscoped`.

### 5.2 Inicialización del contexto

```ruby
# app/controllers/application_controller.rb
before_action :set_current_tenant

def set_current_tenant
  Current.company_id = current_user&.company_id
end
```

### 5.3 Reglas para tablas

Toda tabla de dominio debe incluir:

```ruby
t.references :company, null: false, foreign_key: true
```

Las tablas de configuración del sistema (sin datos de tenant) como `services` (plantillas de APIs) no llevan `company_id`.

### 5.4 Workers y cronjobs

Los jobs no tienen contexto HTTP: el tenant viaja como argumento y se activa con el helper `with_tenant` de `ApplicationJob`, que además limpia `Current` al terminar (los workers reutilizan threads: sin el reset, un job heredaría el tenant del anterior).

```ruby
module Catalog
  class SyncStockJob < ApplicationJob
    queue_as :low

    def perform(product_id, company_id)
      with_tenant(company_id) do
        product = Product.find(product_id)  # El scope ya filtra por company_id
        # ...
      end
    end
  end
end
```

Ver detalle de colas y reintentos en la sección 8.

---

## 6. Dominios de negocio

El proyecto está organizado en 6 dominios correspondientes a los epics de Jira:

| Dominio      | Epic       | Descripción                                              |
| ------------ | ---------- | -------------------------------------------------------- |
| `auth`       | TESIS-19   | Empresas, usuarios, depósitos, autenticación JWT         |
| `integrations` | TESIS-20 | Plantillas de APIs externas, credenciales por empresa    |
| `catalog`    | TESIS-21   | Productos, stock por depósito, transferencias entre depósitos, sincronización multicanal |
| `webhooks`   | TESIS-22   | Gateway de webhooks, cola de mensajes, reintentos        |
| `orders`     | TESIS-23   | Órdenes de compra, ítems, consolidación multicanal       |
| `shipments`  | TESIS-24   | Envíos, cotización de couriers, tracking                 |

> **Unidades en vuelo.** `stocks` responde "cuántas unidades hay en este
> depósito", y no puede expresar unidades que salieron de uno y todavía no
> llegaron a otro. Eso vive en `stock_transfers` (TESIS-103): al despachar se
> descuentan del origen, al recibir se suman al destino, y mientras viajan no
> pertenecen a ningún nodo — por eso **no** entran en `Product#total_stock` y se
> exponen aparte como `in_transit_quantity`.
>
> Las tres transiciones mueven stock real bajo el advisory lock del producto
> (§9), y el listado del catálogo agrega las unidades en vuelo con una
> **subconsulta escalar**, no con un segundo `left_joins`: `with_total_stock` ya
> hace join con `stocks` y agrupa, así que un segundo join a una tabla hija daría
> producto cartesiano y multiplicaría el `SUM` de stock.

Los POROs y Jobs se organizan por dominio:

```
app/poros/
├── auth/
├── catalog/
├── orders/
└── shipments/

app/jobs/
├── catalog/
├── orders/
└── shipments/
```

---

## 7. Cómo agregar nuevas funcionalidades

### 7.1 Nuevo recurso

1. Crear migración con `company_id NOT NULL` + `FK`
2. Crear model en `app/models/`
3. Crear policy en `app/policies/`
4. Crear serializer en `app/serializers/`
5. Crear PORO(s) en `app/poros/[dominio]/` para los casos de uso
6. Crear controller en `app/controllers/api/v1/`
7. Registrar rutas en `config/routes.rb`
8. Crear specs en `spec/models/`, `spec/requests/`, `spec/policies/`, `spec/poros/`

### 7.2 Nuevo job de background

1. Crear en `app/jobs/[dominio]/[nombre]_job.rb`
2. El job recibe `company_id` como parámetro y setea `Current.company_id` al inicio
3. Encolar con `[Nombre]Job.perform_later(resource_id, Current.company_id)`

### 7.3 Nueva integración con plataforma externa

1. Insertar registro en la tabla `services` (plantilla de API) — sin código nuevo
2. La empresa configura sus credenciales vía el endpoint de `company_integrations`
3. El HTTP Adapter genérico usa la plantilla para construir el request

### 7.4 Nueva llamada HTTP a API externa

```ruby
# ✅ Siempre dentro de un PORO, nunca en controllers ni models, y siempre
# ejecutado desde un job: la API externa puede tardar o estar caída.
# Ejemplo real: app/poros/catalog/outbound_sync.rb
module Catalog
  class OutboundSync < ApplicationPoro
    def call
      Integrations::HttpAdapter.new(
        company_integration: mapping.company_integration,
        # payload: claves internas; el request_mapper del Service las traduce
        payload: { external_id: mapping.external_product_id, available_quantity: total_stock },
        # uri_params: interpola los :placeholders de la URI de la plantilla
        uri_params: { external_id: mapping.external_product_id }
      ).call
    end
  end
end
```

#### Las excepciones: la cotización y el despacho

La regla anterior tiene dos casos documentados que no la cumplen, y conviene que
se lean acá y no se descubran leyendo el código. Los dos son del mismo tramo del
producto —el usuario eligiendo cómo despachar— y los dos devuelven en la
respuesta un dato que no sirve más tarde.

`POST /api/v1/orders/:order_id/quotes` (TESIS-46) llama a los couriers **dentro
del request**, no desde un job. El motivo es el producto: el usuario está
esperando la lista de tarifas para elegir una. Devolverla por un job obligaría a
sondear o a abrir un canal de tiempo real para un dato que se consume en el acto
y que caduca enseguida.

`POST /api/v1/shipments/:id/dispatch` (TESIS-47) hace lo propio con el operador
que el usuario eligió: le pide la etiqueta y devuelve el número de seguimiento y
el PDF en la misma respuesta. Acá el motivo es además de consistencia: la
etiqueta ya existe del lado del courier apenas contesta, y diferir la escritura a
un job abre una ventana en la que el envío figura sin despachar aunque el
paquete ya tenga su número. Lo que acota el riesgo es distinto que en la
cotización —es un solo operador, no varios en paralelo— y está en el propio caso
de uso: la llamada corre **fuera** de la transacción, el estado se revalida bajo
`lock!` antes de escribir, y un fallo del courier deja el envío exactamente como
estaba.

> **Deuda anotada.** Este es el segundo caso sincrónico, que es justamente la
> condición que la sección de abajo ponía para revisar la excepción. Se mantiene
> porque los dos casos comparten el mismo argumento de producto y ninguno es una
> sincronización de fondo; si aparece un tercero, o si el despacho empieza a
> tardar, el camino es encolar y notificar. El costo conocido de sostenerlo: si
> la respuesta del courier se pierde después de que él generó la etiqueta, el
> envío queda `pending` y un reintento genera una segunda etiqueta.

Lo que acota el riesgo de sostener un hilo de Puma:

- **Timeout propio y más corto.** El adaptador acepta los timeouts por parámetro;
  la cotización usa 4 s de apertura y de lectura, contra los 10 s del uso en
  background. El techo de la request es ese, no la suma de los couriers.
- **Concurrencia real.** Los operadores se consultan en paralelo, así que el
  tiempo total es el del más lento y no la suma. Medido con tres couriers de
  0,4 s: 0,46 s.
- **Aislamiento por operador.** El fallo de un courier se rescata dentro de su
  propio hilo y sale de la lista de opciones; nunca voltea la cotización.

**Cuándo sí hay que volver a un job:** si la cantidad de couriers integrados por
empresa deja de ser un puñado, o si aparece una llamada saliente sincrónica
fuera de este tramo del producto. Ahí el patrón correcto es encolar y notificar,
y estas excepciones dejan de estar justificadas.

Toda otra llamada saliente sigue la regla: PORO, ejecutado desde un job.

---

## 8. Background jobs y colas (Solid Queue)

El broker es **Solid Queue sobre PostgreSQL** (ver [ADR-006](../adr/ADR-006-background-jobs.md)): no hay Redis ni RabbitMQ en el stack. Los jobs viven en una base separada (`queue`), configurada en `config/database.yml` y activa en desarrollo y producción; en test se usa el adaptador `:test`, que encola en memoria sin ejecutar.

### 8.1 Colas por prioridad

Definidas en `config/queue.yml` y expuestas en `ApplicationJob::QUEUES`:

| Cola       | Uso                                                        | Threads |
| ---------- | ---------------------------------------------------------- | ------- |
| `realtime` | Eventos entrantes que se esperan reflejados cuanto antes   | 5       |
| `default`  | Trabajo de negocio no interactivo                          | 3       |
| `low`      | Sincronizaciones salientes, reintentos, tareas programadas | 2       |

Cada job declara la suya con `queue_as :realtime`.

> **El pool de conexiones debe cubrir la suma de threads de los workers.** Con un pool menor, `bin/jobs` se niega a arrancar con el mensaje `Solid Queue is configured to use N threads but the database connection pool is M`. De ahí el default de `pool: 15` en `database.yml`.

### 8.2 Reintentos

`ApplicationJob` reintenta con espera creciente (`wait: :polynomially_longer`, 5 intentos) **solo** los fallos de APIs externas (`Integrations::AdapterExecutionError`), que son transitorios. Cualquier otra excepción sube y el job queda fallido — no se reintenta un bug. La cola de reintentos persistente y el barrido de eventos atascados corresponden a TESIS-39 (DLQ).

`discard_on ActiveJob::DeserializationError`: si el registro asociado ya no existe, el job perdió sentido.

### 8.3 Correr los workers

```bash
bin/jobs                      # Supervisor con todas las colas (Linux/macOS, producción)
bin/jobs --queues=realtime    # Sólo una cola
```

⚠️ **En Windows `bin/jobs` no arranca**: el supervisor de Solid Queue registra `SIGQUIT`, señal que no existe en la plataforma. Para probar un worker localmente en Windows:

```ruby
# bundle exec rails runner "..."
worker = SolidQueue::Worker.new(queues: 'realtime', threads: 1, polling_interval: 0.2)
Thread.new { worker.start }
sleep 5
worker.stop
```

Alternativas: WSL, Docker, o dejar la verificación de workers al CI/deploy (Linux).

### 8.4 Tareas programadas

`config/recurring.yml` declara los cronjobs (formato de recurring tasks de Solid Queue):

| Tarea                        | Job                                 | Frecuencia       |
| ---------------------------- | ----------------------------------- | ---------------- |
| Motor de reintentos de la DLQ | `Webhooks::ScanDueFailedEventsJob` | cada minuto      |
| Limpieza de JWT revocados    | `Auth::PurgeExpiredTokensJob`       | diaria, 4 am     |
| Pull tracking de couriers    | `Shipments::ScanPullTrackingJob`    | cada 30 minutos  |
| Limpieza de jobs terminados  | comando de Solid Queue              | cada hora (sólo producción) |

Los cronjobs que abarcan a todas las empresas corren sin tenant, leen con `unscoped` y encolan un job por unidad de trabajo con su `company_id`; el job hijo activa el tenant con `with_tenant`.

### 8.5 La base de datos de la cola

Solid Queue guarda sus jobs en una base aparte (`queue`), declarada en `config/database.yml` para desarrollo y producción. Conviene tener claro cómo se crea y actualiza, porque **no se maneja con las migraciones del proyecto**:

- El esquema de la cola vive en **`db/queue_schema.rb`**, que provee la propia gema. No hay migraciones nuestras para esas tablas: `db/queue_migrate/` está declarado en `database.yml` (viene del scaffold de Rails) pero no existe ni hace falta.
- `bin/rails db:migrate` corre **sólo las migraciones de negocio** (`db/migrate/`). No toca la base de la cola.
- `bin/rails db:prepare` crea ambas bases y carga el esquema de la cola. Es el comando a usar en un entorno nuevo.
- Si `db:prepare` falla al crear la base (pasa en algunos PostgreSQL locales, donde la conexión de mantenimiento no está disponible), se crea a mano y se carga el esquema:

```bash
bin/rails runner "ActiveRecord::Base.connection.execute('CREATE DATABASE proyecto_api_development_queue')"
bin/rails db:schema:load:queue
```

Rails expone tareas por base con el sufijo `:queue` (`db:create:queue`, `db:drop:queue`, `db:migrate:queue`, etc.) para operar sobre ella sin afectar la principal.

En **test** no hay base de cola: el adaptador `:test` encola en memoria, así que el CI funciona con una sola base y un único `DATABASE_URL`.

---

## 9. Control de concurrencia

Las escrituras de stock tienen que quedar serializadas por producto a través de todos los procesos que puedan tocarlas: workers de Puma, workers de Solid Queue y, eventualmente, varias instancias desplegadas. La decisión completa y las alternativas descartadas están en [ADR-009](../adr/ADR-009-bloqueos-distribuidos.md); esta sección es la guía práctica de uso.

### 9.1 Cuándo usar cada tipo de bloqueo

| Mecanismo                                                      | Cuándo usarlo                                                                                                                        |
| -------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------ |
| Advisory lock a nivel transacción (`Catalog::WithStockLock`) | La operación abarca varias filas de `stocks`, o puede crear una fila que todavía no existe                                            |
| `SELECT ... FOR UPDATE` (`lock!`)                              | Alcanza con serializar una única fila que ya existe                                                                                  |
| Restricción `CHECK` en la base                                 | Invariante que tiene que valer siempre, incluso ante escrituras que no pasen por los modelos (`update_all`, `upsert_all`, SQL crudo)  |
| `limits_concurrency` de Solid Queue                            | Limitar cuántos jobs del mismo tipo corren a la vez — no reemplaza al advisory lock (ver 9.3)                                         |

### 9.2 Uso del PORO

```ruby
Catalog::WithStockLock.new(product_id: product.id).call do
  # sección crítica: escrituras de stock
end
```

### 9.3 `wait: true` vs `wait: false`

Por default el PORO espera el lock hasta que vence `lock_timeout` (`wait: true`, usa `pg_advisory_xact_lock`). Es el modo correcto para **jobs de background**: pueden permitirse esperar un momento y, si aun así fallan, confiar en el reintento de Active Job.

```ruby
Catalog::WithStockLock.new(product_id: product.id, wait: false).call { ... }
```

Con `wait: false` (`pg_try_advisory_xact_lock`) el PORO no espera: si el lock está tomado, falla al instante. Es el modo correcto para **requests HTTP interactivos** — no conviene dejar un thread de Puma colgado esperando un lock que puede tardar.

En ambos modos, si no se puede garantizar exclusividad (venció el `lock_timeout`, o el lock estaba tomado en modo `wait: false`) se levanta `Catalog::LockTimeoutError`, que `ApplicationController` mapea a **409 Conflict**.

### 9.4 `Current.company_id` es obligatorio

La tabla `stocks` no tiene columna `company_id` propia (llega por `product`), así que la clave del lock se arma con el `company_id` activo en `Current`. Si viniera en `nil`, el lock dejaría de aislar empresas. El PORO levanta `ArgumentError` en ese caso, igual que `ApplicationJob#with_tenant` (ver sección 5.4).

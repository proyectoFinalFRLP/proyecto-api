# ADR-010: Ingesta de órdenes provenientes de webhooks

**Fecha:** 2026-08-19  
**Estado:** Aceptado

---

## Contexto

El gateway de webhooks ([TESIS-36](ADR-008-dead-letter-queue.md)) persiste el evento crudo en `webhook_logs` y devuelve `202` sin interpretarlo: la plataforma externa no espera detrás de nuestra lógica de negocio. Eso deja los eventos en `pending` y a nadie procesándolos.

Falta el otro lado del gateway: convertir esa fila cruda en una venta del OMS —`Order` + `OrderItem`— y descontar el stock vendido, con tres condiciones que no son negociables:

- **Cada canal manda un JSON distinto.** El OMS no puede tener una clase por proveedor: la traducción tiene que salir de la plantilla del `Service`, igual que las llamadas salientes ([ADR-004](ADR-004-architecture.md)).
- **El id de producto que manda el canal no es el nuestro.** Hay que resolverlo contra `product_mappings` (Identity Mapping), y un ítem sin mapear no puede terminar en una venta a medias.
- **Crear la orden y descontar el stock es una sola operación.** Una orden sin descuento sobrevende; un descuento sin orden regala mercadería.

## Decisión

Un pipeline asíncrono en tres piezas: el gateway encola, un job aporta el contexto de tenant y el manejo del fallo, y un PORO hace el trabajo dentro de una transacción.

```
POST /api/webhooks/integrations/:id
  → WebhookLog (pending)                        # gateway, TESIS-36
  → Orders::ProcessWebhookEventJob (realtime)   # fuera del request HTTP
      → Orders::ProcessWebhookOrder
          → Orders::TranslateWebhookPayload     # plantilla del Service
          → ProductMapping                      # Identity Mapping
          → BEGIN
              Order + OrderItems
              Catalog::DeductStock (por ítem)   # advisory lock, ADR-009
            COMMIT
          → WebhookLog: processed | failed + error_message
      → (si falló) FailedEvent inbound          # DLQ, ADR-008
```

| Pieza                                   | Rol                                                                 |
| --------------------------------------- | ------------------------------------------------------------------- |
| `Orders::ProcessWebhookEventJob`         | Activa el tenant, delega y deriva el fallo a la DLQ                 |
| `Orders::ProcessWebhookOrder`            | Caso de uso completo: traducir, resolver, escribir, marcar el log   |
| `Orders::TranslateWebhookPayload`        | Payload externo → claves internas de la venta y de sus ítems        |
| `Integrations::ParseExternalCollection`  | Resuelve las entradas de colección (`[]`) del `response_mapper`     |
| `Catalog::DeductStock`                   | Descuenta unidades de un depósito bajo el lock de stock             |
| `Webhooks::Replayers::OrderIngestion`    | Replayer de la DLQ: vuelve a correr la ingesta del mismo log        |

### Traducción dinámica: el marcador `[]`

El `response_mapper` de un `Service` traduce rutas externas a claves internas (`"buyer.nickname" => "customer_name"`). Una venta, además, trae una **lista** de ítems, y el mapper plano de [TESIS-31](ADR-004-architecture.md) no sabía expresarla.

Se extiende la convención con un marcador de colección en la ruta externa:

```jsonc
{
  "id":                        "external_order_id",
  "buyer.nickname":            "customer_name",
  "order_items[].item.id":     "external_product_id",   // por cada elemento…
  "order_items[].quantity":    "quantity",              // …de order_items
  "order_items[].unit_price":  "unit_price"
}
```

Lo que va antes del `[]` ubica la lista dentro del payload; lo que va después es la ruta dentro de cada elemento. Se eligió esto y no una columna nueva en `services` (`items_mapper`) porque no agrega esquema, se edita desde el mismo formulario del backoffice y deja la plantilla legible como una sola descripción del payload. `ParseExternalResponse` ignora las entradas con marcador y `ParseExternalCollection` procesa sólo esas: las dos formas conviven en un mapper sin pisarse.

Una plantilla declara **una** colección (los ítems de la venta). Si declarara más de una raíz, se usa la primera; mezclar listas distintas en una sola no tendría sentido para una orden.

Las claves internas reconocidas están en `Orders::TranslateWebhookPayload::ORDER_KEYS` / `ITEM_KEYS`; el resto de lo que traiga la plantilla se ignora, porque el mismo `response_mapper` puede servir a otros flujos (por ejemplo el `tracking_number` de un courier).

### Transaccionalidad

`Order`, sus `OrderItem` y el descuento de stock ocurren en **una única transacción**. Cualquier fallo —ítem sin mapear, stock insuficiente, validación— la rollea entera: no queda una orden parcial ni stock descontado de una venta que no existe.

Dos detalles que hacen que eso realmente se cumpla:

- **Los mapeos se resuelven antes de abrir la transacción.** Un ítem sin mapear corta el procesamiento sin haber escrito nada, en lugar de hacerlo a mitad de la orden.
- **Los ítems se procesan ordenados por `product_id`.** Cada descuento toma el advisory lock del producto ([ADR-009](ADR-009-bloqueos-distribuidos.md)) y lo sostiene hasta el commit de la transacción externa. Sin un orden estable, dos ventas que comparten productos podrían tomar los locks en orden inverso y trabarse mutuamente.

El registro del resultado en el `WebhookLog` va **fuera** de la transacción de negocio: si fuera adentro, el propio rollback se llevaría puesto el registro del error.

### Depósito del que se descuenta

`Catalog::DeductStock` toma el **primer depósito, en orden estable por `warehouse_id`, que pueda cubrir la cantidad completa**. No parte una venta entre varios depósitos: si ninguno alcanza por sí solo, falla aunque el stock consolidado sea suficiente.

Es la regla explícita del MVP de la card. El reparto multi-depósito —y el "depósito principal" configurable por integración— necesita una decisión de negocio (¿cuál es la prioridad: menor costo de envío, cercanía al comprador, vaciar el depósito más viejo?) que hoy no está tomada, y el modelo no tiene dónde guardarla: `warehouses` no tiene ni prioridad ni marca de principal.

### Estados y manejo del fallo

El `WebhookLog` guarda el resultado del **último** intento:

```
pending ──(éxito)──> processed
   │                     ^
   └───(fallo)──> failed ─┘   (un reintento exitoso lo deja en processed)
```

Un fallo, además, se registra como `FailedEvent` con `direction: 'inbound'` y `event_type: 'webhooks.order_ingestion'`. Es lo que la columna `direction` de [ADR-008](ADR-008-dead-letter-queue.md) venía esperando: el motor de reintentos ya sabía reintentar con backoff, dar por muerto lo que agota intentos y exponerlo en `/api/v1/failed-events`; sólo faltaba registrar el replayer. El `FailedEvent` guarda únicamente el `webhook_log_id`, no una copia del payload: la fuente de verdad del evento crudo sigue siendo `webhook_logs`.

Esto cubre el caso operativo típico: llega una venta de un producto que nadie mapeó, el evento reintenta y muere en `dead`, el operador crea el `ProductMapping` que faltaba y dispara el reintento manual desde la API — la venta entra sin tocar la base a mano.

La excepción **no se propaga** desde el job: si subiera, Active Job reintentaría por su cuenta el mismo trabajo que la DLQ ya tiene agendado, con otro backoff y sin registro consultable.

### Idempotencia

Las plataformas reenvían webhooks y Solid Queue garantiza *at-least-once*: el mismo evento puede llegar a procesarse más de una vez, y descontar el stock dos veces por una sola venta es el peor error posible acá. Tres barreras, en orden:

1. Un log ya `processed` no se vuelve a procesar.
2. Si ya existe una `Order` con ese `external_order_id`, se marca el log como procesado y no se crea nada.
3. Si dos workers corren a la vez, el índice único `(company_id, external_order_id)` deja pasar a uno solo; el que pierde la carrera captura el `RecordNotUnique` y termina como duplicado.

### Ruteo en el gateway

El gateway encola la ingesta **sólo para integraciones de servicios `ecommerce`**. Un webhook de courier (`type: 'courier'`) se persiste y queda en `pending` para la épica de envíos (TESIS-24), en lugar de irse a la DLQ como un evento que nadie sabe traducir.

### Multi-tenancy

El job recibe `company_id` y lo activa con `with_tenant` ([ADR-003](ADR-003-multitenancy.md)), así que todas las lecturas y escrituras pasan por el `default_scope` de `CompanyScoped`. Los `ProductMapping` se buscan por `company_integration_id` —la integración que recibió el webhook—, lo que además impide resolver un id externo de otro canal de la misma empresa.

## Alternativas consideradas

### Procesar el webhook dentro del request HTTP

- ✅ Sin infraestructura de colas, el resultado es inmediato
- ❌ La plataforma externa espera detrás de una transacción con locks de stock; muchos proveedores cortan por timeout y reenvían, multiplicando el trabajo
- ❌ Un pico de ventas satura los threads de Puma y degrada toda la API

### Un traductor por proveedor (clase por canal)

- ✅ Máxima flexibilidad para payloads raros
- ❌ Cada canal nuevo es código nuevo, deploy incluido: exactamente lo que [ADR-004](ADR-004-architecture.md) descartó para las llamadas salientes

### Columna nueva `items_mapper` en `services`

- ✅ Separa explícitamente la lista del resto del mapeo
- ❌ Migración + otro campo que mantener en el backoffice, para expresar lo mismo que una convención de ruta
- ❌ Deja de haber una única descripción del payload de respuesta

### Estado `processing` y claim atómico en `webhook_logs`

- ✅ Sería el mismo mecanismo de la DLQ contra ejecuciones concurrentes
- ❌ Pide migración (nuevo estado + `claimed_at` + `CHECK`) y un barrido de claims vencidos
- ❌ Para este caso alcanza con el índice único de la orden: lo que hay que evitar no es que el job corra dos veces, sino que se registre dos veces la misma venta

## Consecuencias

- ✅ Una venta de un canal externo entra sola al OMS, con su stock descontado, sin tocar el request de la plataforma
- ✅ Sumar un canal es cargar una plantilla desde el backoffice, sin código nuevo
- ✅ Ningún evento se pierde: el `WebhookLog` guarda el error y la DLQ lo reintenta y lo deja reprocesable desde la API
- ✅ El descuento por venta reutiliza el lock de stock, así que compite correctamente con el ABM y con el sync saliente
- ✅ El descuento dispara solo el sync saliente de stock (callback de `Stock`, TESIS-35): una venta en un canal actualiza la publicación en todos los demás, sin código extra acá
- ⚠️ Una venta falla si ningún depósito **por sí solo** cubre la cantidad, aunque el total alcance: el reparto multi-depósito queda pendiente
- ⚠️ `orders` no tiene columna `total`: el total de la venta externa no se persiste, se deriva de los ítems (`quantity * unit_price`). Si el canal aplica descuentos o impuestos a nivel de orden, esa diferencia hoy no se guarda
- ⚠️ Un webhook cuyo `perform_later` falle (broker caído) queda en `pending` para siempre: no hay barrido de logs pendientes, sólo de la DLQ
- ⚠️ Si el mismo log se procesa dos veces en paralelo, cada corrida registra su propio `FailedEvent`: el reintento es idempotente, pero la DLQ puede mostrar entradas duplicadas del mismo evento
- ⚠️ Un canal que reciba webhooks de venta **y** reciba pushes de stock necesita una plantilla por operación (hoy 'Mercado Libre' y 'Mercado Libre - Stock'), porque el `ProductMapping` publica el producto en la integración, no en la operación

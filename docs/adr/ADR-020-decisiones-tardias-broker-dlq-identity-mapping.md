# ADR-020: Decisiones tardías: broker, Dead Letter Queue e Identity Mapping

**Fecha:** 2026-10-10  
**Estado:** Aceptado

---

## Contexto

Tres piezas sostienen el flujo central del OMS (una venta que entra por webhook, descuenta stock y vuelve a publicarse en los canales), y ninguna quedó como la planteó su ADR original:

- **El broker** se eligió en [ADR-006](ADR-006-background-jobs.md) (abril), antes de que existiera un solo job. Las colas por prioridad, la base aparte, el despliegue de los workers y la relación entre el gateway y la cola se resolvieron después, card por card.
- **La Dead Letter Queue** se diseñó en [ADR-008](ADR-008-dead-letter-queue.md) (julio) como un motor genérico para «todo evento de integración». Al cierre la usan dos flujos, no todos.
- **El Identity Mapping** (`product_mappings`) nunca tuvo ADR propio. Nació en TESIS-32/34, la ingesta lo volvió crítico ([ADR-010](ADR-010-ingesta-de-ordenes-de-webhooks.md)) y cambió dos veces más: con la conexión real a Shopify ([ADR-018](ADR-018-conexion-con-proveedores-reales.md)) y con la idempotencia por canal (TESIS-154).

Las decisiones que se tomaron sobre la marcha quedaron repartidas entre seis ADRs y los comentarios del código. Este ADR las junta, registra el estado real al cierre del proyecto (incluido lo que quedó afuera) y corrige dos afirmaciones de ADRs anteriores que ya no son ciertas. No reemplaza a esos ADRs: los completa.

El recorrido completo de un webhook, paso a paso, está en [`docs/guides/flujo-de-un-webhook.md`](../guides/flujo-de-un-webhook.md).

## Decisión

### 1. Broker: PostgreSQL hace de broker y el gateway hace de bandeja de entrada

**No hay un broker de mensajes aparte** (RabbitMQ, Kafka, Redis). Solid Queue guarda los jobs en PostgreSQL, en una base propia (`queue`) del mismo servidor, en desarrollo y en producción. En test se usa el adaptador `:test` y no hay base de cola, así que el CI corre con una sola base. Lo que el proyecto llama «cola de mensajes» en el alcance es eso: tablas de Solid Queue, colas con nombre y workers que las consumen.

**Tres colas por latencia, no por dominio** (TESIS-37): `realtime` (5 threads) para los eventos entrantes, `default` (3) para el trabajo de negocio y `low` (2) para el tráfico saliente, los reintentos y los cronjobs. Una caída de un canal que llena `low` de reintentos no demora la ingesta de ventas en `realtime`. El pool de conexiones (15) cubre la suma de threads, o `bin/jobs` no arranca.

**Los workers corren dentro de Puma en el despliegue** (`SOLID_QUEUE_IN_PUMA`, `config/deploy.yml`): un solo contenedor sirve la API, ejecuta los jobs y dispara los cronjobs. Alcanza para un servidor de demo. Separarlos (`bin/jobs` en su propio proceso) no pide cambios de código, sólo de despliegue.

**El evento crudo vive en `webhook_logs`, no en la cola.** El gateway persiste el evento en la base principal y recién después encola un job que lleva **sólo ids** (`webhook_log_id`, `company_id`), nunca el payload. La fuente de verdad del evento es la tabla, y la cola es sólo el transporte. Motivos:

- La cola se purga: en producción, un cronjob horario borra los jobs terminados (los de más de un día, el default de Solid Queue). La auditoría y el reproceso necesitan que el evento sobreviva al job.
- Un reintento tiene que ver el mismo evento que vio el primer intento, no una copia que pudo quedar vieja. Por eso un `FailedEvent` de entrada también guarda sólo el `webhook_log_id` (ADR-010).
- Un payload ilegible se guarda igual (`{ "raw": ... }`): nada se pierde por venir roto.

**La entrega es *at-least-once* y la idempotencia es del consumidor.** Ni Solid Queue ni los proveedores garantizan una única entrega: Shopify reintenta lo que no recibió un 2xx y un job puede correr dos veces. No se deduplica en el broker ni por el id de entrega del proveedor (`X-Shopify-Webhook-Id`). Se deduplica donde está el daño: un log `processed` no se reprocesa, y el índice único `(company_integration_id, external_order_id)` impide registrar dos veces la misma venta del mismo canal (ADR-010, TESIS-154).

**Corrección a ADR-006.** ADR-006 da como consecuencia que «las jobs son transaccionales con el mismo commit que las dispara». Con la cola en una base aparte eso no es cierto: el insert del `WebhookLog` y el encolado van a bases distintas y no son atómicos. Lo que sí está garantizado es el **orden**: el log se commitea antes de encolar, y los jobs que nacen de una escritura de negocio se encolan en un `after_commit` (el sync de stock en `Stock`). Ningún job encuentra el registro sin commitear. Lo que queda abierto es el hueco del medio: si el log se guarda y el encolado falla, el evento queda `pending` sin nadie que lo procese (ya anotado en ADR-010).

### 2. Dead Letter Queue: sólo para lo que no se recupera solo

ADR-008 planteó la DLQ para cualquier llamada a un proveedor. Al cierre, cada flujo tiene el mecanismo que corresponde a **qué se pierde si el evento se pierde**:

| Flujo | Si falla | Por qué así |
| --- | --- | --- |
| Ingesta de ventas (webhook) | `FailedEvent` `inbound`, `webhooks.order_ingestion` | Una venta perdida no vuelve: el canal no la reenvía para siempre |
| Ingesta de tracking (push de courier) | `FailedEvent` `inbound`, `webhooks.tracking_ingestion` | Mismo motivo: el movimiento del envío no se repite |
| Sync saliente de stock | `retry_on` de Active Job: 5 intentos con espera creciente | Se publica una cantidad absoluta: el próximo cambio de stock del producto vuelve a publicar el total vigente |
| Pull tracking de couriers | Se loguea y sigue | El próximo ciclo (30 minutos) es el reintento ([ADR-014](ADR-014-pull-tracking-de-couriers.md)) |
| Cotización, despacho, vínculo de producto | Error en la respuesta | Son sincrónicos: el usuario está esperando y decide ([architecture.md §7.4](../guidelines/architecture.md)) |

La regla que sale de la tabla: **la DLQ es para los eventos entrantes**, donde perder el evento es perder un dato de negocio que nadie va a volver a mandar. Lo saliente se recupera solo, porque el OMS es la fuente de verdad y vuelve a publicar.

Las decisiones que acompañan a la regla:

- **El job no propaga la excepción.** El fallo se registra en la DLQ y el job termina bien. Si subiera, el `retry_on` de Active Job reintentaría por su cuenta lo que la DLQ ya tiene agendado, con otro backoff y sin registro consultable.
- **Un producto sin vincular es el caso operativo típico, y la DLQ lo resuelve sin tocar la base.** La venta falla entera, el evento reintenta y termina `dead`, el operador crea el vínculo que faltaba y dispara `POST /api/v1/failed-events/:id/retry`. La venta entra con su stock descontado.
- **Claim con vencimiento en vez de lock.** Un `UPDATE` atómico reclama el evento, y pasado `CLAIM_TIMEOUT` (5 minutos) un claim huérfano vuelve a estar disponible (ADR-008). No se sostiene una transacción abierta durante la llamada al proveedor.

**Corrección a ADR-008.** ADR-008 dice que sumar el sync de stock a la DLQ «es registrar un replayer nuevo». La pieza existe y tiene specs (`Webhooks::ExecuteIntegrationRequest` y el replayer `integrations.http_request`), pero **ningún flujo de producción la usa**: `Catalog::OutboundSync` llama al `HttpAdapter` directo y sus fallos van al `retry_on`. Si un canal está caído más de lo que duran los cinco intentos (unos minutos), ese push se pierde y la publicación queda desactualizada hasta el próximo movimiento de stock del producto. El job agotado queda en las tablas de Solid Queue, no en `/api/v1/failed-events`. Queda como trabajo futuro: envolver `push_to` con `ExecuteIntegrationRequest`.

### 3. Identity Mapping: el vínculo es del canal, no de la empresa

`product_mappings` traduce el id que manda un canal al producto interno. Una fila vincula **un producto con una integración** (`company_integration_id`), no con una empresa ni con un proveedor:

```
product_mappings
  product_id              → el producto del OMS
  company_integration_id  → la cuenta de la empresa en ese canal
  external_product_id     → el id con el que el canal lo nombra (en Shopify, la variante)
  external_price          → el precio publicado en ese canal (respaldo del precio de la venta)
  external_refs (jsonb)   → otros ids que el canal necesita (en Shopify, inventory_item_id)

  único (company_integration_id, external_product_id)   un id externo → un producto, por canal
  único (product_id, company_integration_id)            un producto → una publicación, por canal
```

Las decisiones:

- **Se resuelve siempre por la integración que recibió el evento.** El mismo id externo puede existir en dos canales y apuntar a productos distintos. Buscar por empresa mezclaría canales. Es el mismo criterio con el que TESIS-154 pasó la idempotencia de órdenes de empresa a canal.
- **La tabla no tiene `company_id`.** Sigue el criterio de las otras tablas hijas (`stocks`, `order_items`, `shipment_events`): el tenant se hereda del padre. Acá hay dos padres, así que una validación exige que el producto y la integración sean de la misma empresa, y toda lectura entra por uno de los dos, que sí están aislados (el producto en la API, la integración en la ingesta). Una columna más sería un dato que puede contradecir a las FKs.
- **Un ítem sin vínculo corta la venta entera.** Los vínculos se resuelven antes de abrir la transacción, así que un ítem sin vincular no deja ni orden a medias ni stock descontado. No se adivina el producto en la ingesta (por SKU o por nombre): un acierto equivocado descuenta stock de otro producto, y eso es peor que una venta que espera en la DLQ.
- **El vínculo se valida contra el canal al crearlo.** Si la plantilla sabe buscar (`product_lookup`, `product_search`), el canal confirma que la publicación existe antes de guardar el vínculo. Es el tercer caso sincrónico de §7.4 (ADR-018). Un id mal cargado se rechaza al vincular y no recién en la primera venta.
- **1 producto = 1 SKU** en el MVP: si el SKU del canal no coincide, el vínculo se crea con un aviso (`warnings`) en vez de rechazarse.
- **El vínculo es de la cuenta, no de la operación.** Mercado Libre necesitaba dos integraciones (órdenes y stock), y el vínculo quedaba en una sola de las dos. Con las plantillas de operación de ADR-018 la cuenta se conecta una vez, y la venta y el stock usan el mismo vínculo. Shopify ya funciona así. Las plantillas de Mercado Libre de los seeds siguen con el esquema anterior, porque esa integración quedó en pausa.

## Alternativas consideradas

### Un broker dedicado (RabbitMQ o Kafka)

- ✅ Es el componente «de libro» para una cola de mensajes, con routing, acknowledgements y consumidores múltiples
- ❌ Suma un servicio más que operar y monitorear, para un volumen que PostgreSQL cubre de sobra
- ❌ El evento igual tendría que persistirse en la base para auditoría y reproceso: el broker sería un segundo lugar donde vive el mismo dato

### El payload en los argumentos del job

- ✅ El job no necesita leer la base para empezar
- ❌ El evento quedaría en una tabla que se purga, y el reintento de la DLQ no tendría de dónde sacarlo
- ❌ Duplica el payload: en el log de auditoría y en la cola

### La cola en la misma base que los datos

- ✅ El insert del log y el encolado serían atómicos, y desaparecería el hueco de los logs `pending` huérfanos
- ❌ Se aparta del esquema de Rails 8 (base `queue` propia), y el desarrollo ya estaba montado sobre él
- ➖ No se descartó por diseño: el hueco que deja es chico, está anotado, y un barrido de logs `pending` viejos lo cerraría con menos cambio

### La DLQ para todo lo saliente

- ✅ Un solo lugar para ver todo lo que falló
- ❌ Los pushes de stock fallidos de una caída larga llenarían la DLQ con eventos que el siguiente cambio de stock vuelve innecesarios
- ➖ Sigue siendo el paso natural para que un push perdido sea visible: queda como trabajo futuro (ver la corrección a ADR-008)

### Resolver el producto por SKU en la ingesta

- ✅ Una venta de un producto sin vincular entraría igual
- ❌ El SKU del canal lo carga la empresa a mano y puede no coincidir. Un acierto equivocado descuenta stock real de otro producto, sin nada que lo marque

### `company_id` en `product_mappings` con `CompanyScoped`

- ✅ La tabla quedaría aislada por el `default_scope`, sin depender de por dónde entra la lectura
- ❌ Es un dato derivable de dos FKs, que podría contradecirlas, y rompería el criterio de las demás tablas hijas
- ❌ No cambia ninguna consulta: todas filtran por integración o por producto

## Consecuencias

- ✅ Una venta entra, descuenta stock y vuelve a publicarse en los canales sin más infraestructura que PostgreSQL
- ✅ El evento crudo sobrevive a la cola: se audita, se reintenta y se reprocesa desde la misma fila
- ✅ Una venta con un producto sin vincular no se pierde ni entra a medias: espera en la DLQ hasta que alguien crea el vínculo
- ✅ Un canal caído no demora la ingesta de ventas (colas separadas por latencia)
- ⚠️ El insert del log y el encolado no son atómicos: un encolado fallido deja el evento `pending` sin procesar, y no hay barrido que lo detecte
- ⚠️ Un push de stock que agota sus reintentos no queda visible por API, y la publicación sigue desactualizada hasta el próximo movimiento de stock del producto
- ⚠️ Con los workers dentro de Puma, una ráfaga de jobs compite por CPU con los requests HTTP
- ⚠️ Como las demás tablas hijas, `product_mappings` no tiene scope automático: su aislamiento depende de que toda lectura entre por el producto o por la integración. A diferencia de ellas, tiene dos padres, y la validación de misma empresa es lo que impide cruzarlos
- ⚠️ La DLQ no tiene política de limpieza: los eventos `succeeded` y `discarded` se acumulan (ya anotado en ADR-008)

## Referencias

- [ADR-006](ADR-006-background-jobs.md): Solid Queue y las colas por prioridad
- [ADR-008](ADR-008-dead-letter-queue.md): el motor de reintentos y su ciclo de vida
- [ADR-009](ADR-009-bloqueos-distribuidos.md): el lock de stock que toma la ingesta
- [ADR-010](ADR-010-ingesta-de-ordenes-de-webhooks.md): la ingesta de ventas
- [ADR-018](ADR-018-conexion-con-proveedores-reales.md) y [ADR-019](ADR-019-ventas-entrantes-de-shopify.md): Shopify, las plantillas de operación y la firma
- [`docs/guides/flujo-de-un-webhook.md`](../guides/flujo-de-un-webhook.md): el recorrido de punta a punta

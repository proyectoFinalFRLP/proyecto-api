# ADR-014: Pull tracking de couriers sin webhooks

**Fecha:** 2026-09-21  
**Estado:** Aceptado

---

## Contexto

[ADR-011](ADR-011-push-tracking-de-couriers.md) resolvió el seguimiento de los envíos para los couriers que **avisan**: el proveedor empuja cada movimiento a `POST /api/webhooks/couriers/:company_integration_id` y el sistema lo traduce, lo registra en `shipment_events` y avanza `shipments.status`. Ese ADR dejó anotado el polling como "complemento futuro para couriers que no ofrezcan push".

Ese futuro es TESIS-49. No todos los operadores logísticos tienen webhooks salientes: con uno así, un envío despachado (TESIS-47) queda para siempre en `ready_to_ship`, porque nadie le avisa nada al sistema. La bitácora que ve el vendedor y el estado que después consume el listado de órdenes dependerían de que alguien fuera a mirar la web del courier.

Había tres preguntas que el código existente no contestaba:

1. **Cómo se le pregunta a un courier por un envío.** La plantilla con la que se despacha (`Service`) apunta al endpoint de despacho: su `uri` y su `http_method` son los de crear la etiqueta, no los de consultar su estado.
2. **Cómo se sabe qué couriers hay que consultar.** Consultar a uno que ya empuja el tracking gasta cuota sin ganar nada.
3. **Cómo se procesa lo que contesta.** El push ya tenía reglas de idempotencia, orden y bloqueo, pero atadas al `WebhookLog` que las disparaba.

## Decisión

Un cronjob de Solid Queue barre cada 30 minutos los envíos en curso de los couriers sin webhooks y encola una consulta por envío —o por lote, si el courier lo admite—; cada consulta usa la plantilla de seguimiento del courier y entrega lo que contesta al mismo núcleo que usa el push.

```
config/recurring.yml  (every 30 minutes, dev y producción)
  │
  ▼
Shipments::ScanPullTrackingJob                         (cola low, sin tenant)
  - CompanyIntegration.unscoped activas cuyo Service tiene tracking_service
  - Shipment.unscoped.in_flight de cada una            (ready_to_ship | in_transit, con tracking)
  - PollTrackingJob.set(wait: escalonado)              (1 por envío, o 1 por lote de 50)
  │
  ▼
Shipments::PollTrackingJob                             (cola low, 1 a la vez por integración)
  - with_tenant(company_id)
  │
  ▼
Shipments::PollTrackingStatus
  - HttpAdapter(integración del envío, service: tracking_service).fetch   # JSON crudo
  - Shipments::TranslateTrackingPayload                # external_status crudo + internal_status
  - Shipments::RegisterTrackingEvent                   # el mismo núcleo que el push
      BEGIN
        shipment.lock!
        duplicado / desordenado → nada
        ShipmentEvent.create! + shipments.status si avanza
      COMMIT
  - Fallo HTTP / respuesta inutilizable → Rails.logger y sigue con el resto
```

| Pieza                                   | Rol                                                                                              |
| --------------------------------------- | ------------------------------------------------------------------------------------------------ |
| `services.tracking_service_id`          | FK opcional a otra plantilla: "a este courier se le pregunta con ésta". Su presencia lo pone en el barrido |
| `Service#answers_tracking?`             | La plantilla sabe contestar: mapea `external_status` y dice cómo preguntar (`:tracking_number` en la URI, o una colección en la respuesta) |
| `Service#tracks_in_batch?`              | La respuesta lista envíos (`envios[].numero` → `tracking_number`): consulta masiva                 |
| `Shipment.in_flight`                    | El universo a consultar: con etiqueta y sin entregar                                               |
| `Shipments::ScanPullTrackingJob`        | Cronjob: barre todos los tenants y reparte el trabajo en jobs escalonados                          |
| `Shipments::PollTrackingJob`            | Activa el tenant y delega; `limits_concurrency` de 1 por integración                               |
| `Shipments::PollTrackingStatus`         | Caso de uso: consulta, traduce, empareja y registra, aislando cada fallo                           |
| `Shipments::RegisterTrackingEvent`      | Núcleo idempotente y transaccional, extraído de `ProcessTrackingUpdate` y compartido con el push   |
| `Integrations::HttpAdapter#fetch`       | La respuesta JSON sin pasar por los mappers                                                        |

### Una plantilla de seguimiento, vinculada a la de despacho

Consultar el estado de un envío es otro endpoint del proveedor —otra `uri`, casi siempre `GET`—, y el proyecto ya modela un endpoint por `Service`: 'Andreani - Cotización' es una plantilla distinta de 'Andreani' (TESIS-46). La consulta es entonces una plantilla más, 'Correo Argentino - Seguimiento', y el courier la declara con una FK: `services.tracking_service_id`.

El vínculo va **entre plantillas** y no entre integraciones porque "cómo se le pregunta a este proveedor por un envío" es igual para todas las empresas que lo usan. La consulta sale con las credenciales de la integración que despachó el envío (`HttpAdapter` acepta `service:` para hablarle al proveedor con otra de sus plantillas): es la misma cuenta del mismo proveedor, y pedirle a cada empresa que cargue una segunda integración con las mismas credenciales sólo agregaría una forma de configurarlo mal.

Que la FK esté cargada es además lo que decide si al courier se lo consulta. Un courier con push (ADR-011) no la carga y no entra en el barrido; uno sin push la carga y entra. Un courier que tuviera las dos cosas podría cargarla igual: la idempotencia del núcleo hace que un movimiento que llega por las dos vías se registre una sola vez.

### Qué plantilla sabe contestar lo declara la plantilla

Mismo principio data-driven que `Service#quotes_shipping?` y `Service#dispatches_shipment?`: la plantilla dice qué sabe contestar, sin una columna por capacidad.

- **Consulta individual:** la `uri` interpola `:tracking_number` (`.../tracking/:tracking_number`). Un request por envío.
- **Consulta masiva:** el `response_mapper` lee el número de seguimiento de una colección (`envios[].numero` → `tracking_number`). Un request para todos: los números viajan a la vez como `:tracking_numbers` en la URI (separados por coma, para un `GET`) y como `tracking_numbers` en el payload (para un `POST` con `request_mapper`); la plantilla toma el que mapea. Cada elemento de la respuesta se empareja con su envío por número, y los que no son de ninguno se ignoran, igual que un push de un paquete ajeno.

En los dos casos la plantilla tiene que mapear `external_status`. La validación del modelo rechaza vincular una plantilla que no cumpla esto —la de cotización, por ejemplo— o a la plantilla consigo misma: el barrido llamaría todos los ciclos a un endpoint que no contesta estados.

Como una plantilla de seguimiento masiva mapea `tracking_number`, `dispatches_shipment?` la habría tomado por una de despacho. Se excluye explícitamente: saber contestar por un envío no es saber despachar uno.

### El mismo núcleo que el push

Las reglas de la card para registrar un movimiento —distinto estado o timestamp más nuevo, transacción, bloqueo— son exactamente las de ADR-011: descartar el duplicado exacto, descartar lo desordenado, `shipment.lock!` antes de los chequeos, índice único como red de fondo, y el estado no mapeado registrado como informativo sin mover `shipments.status`. En vez de copiarlas, se extrajeron de `ProcessTrackingUpdate` a `Shipments::RegisterTrackingEvent`, que ahora usan los dos caminos. `ProcessTrackingUpdate` conserva sólo lo propio de un webhook: el `WebhookLog`, su estado y la DLQ.

Un matiz de la card queda cubierto por la barrera de duplicado exacto: "un nuevo movimiento dentro del mismo estado" (el paquete sigue `EN TRANSITO` pero pasó por otra planta) tiene otro `occurred_at`, así que no es un duplicado y se registra. Si el courier no fecha sus movimientos, el núcleo cae a comparar contra el último estado registrado —con un `occurred_at` sintético cada ciclo, comparar por timestamp duplicaría el mismo estado cada 30 minutos—.

### El estado externo crudo, también en el pull

La traducción pasa por `TranslateTrackingPayload`, igual que el push, para conservar `external_status` tal cual lo dijo el courier además del `internal_status` traducido. Por eso el caso de uso no usa `HttpAdapter#call`, que aplica el `response_value_mapper` a todo lo que extrae y perdería el dato crudo, sino `#fetch`, que devuelve el JSON sin tocar. Para la consulta masiva, `TranslateTrackingPayload` acepta el mapper de cada elemento (`ParseExternalCollection#element_mapper`), con las rutas relativas al elemento.

### Fallos: log y siguiente ciclo, sin DLQ ni reintentos

La card pide que la falla de un courier no interrumpa el cronjob. Hay tres niveles de aislamiento:

1. **Entre couriers y entre envíos:** cada consulta es su propio job. Que uno falle no toca a los demás.
2. **Dentro de una consulta:** un fallo HTTP (timeout, 5xx, respuesta no JSON) se rescata en `PollTrackingStatus`, se loguea como `warn` y la consulta sigue con los envíos que queden. Un movimiento que no se pudo guardar se loguea como `error` —ahí sí puede haber un bug— y no voltea al resto del lote.
3. **Respuestas inutilizables:** sin `external_status` (plantilla que no lo ubica) o hablando de otro número de seguimiento, se loguean y no se escriben.

Nada de esto va a la DLQ de ADR-008 ni aprovecha el `retry_on AdapterExecutionError` de `ApplicationJob`, a diferencia del push. En el push, el evento es único: si se pierde, se perdió, y por eso se guarda para reintentarlo. En el pull, el próximo ciclo vuelve a preguntar lo mismo; un reintento antes sólo acercaría al courier a su límite de requests, y una fila en la DLQ por cada consulta fallida de un courier caído sería ruido.

### Frecuencia y control de ráfagas

- **Cada 30 minutos**, el extremo más frecuente de lo que sugiere la card. Es una sola frecuencia para todos los couriers: ninguna plantilla declara hoy su límite de requests, y modelarlo antes de tener un proveedor real que lo exija sería adivinar.
- **Escalonamiento:** los jobs de un mismo courier se encolan separados por 2 segundos, salvo que la ronda no entre en 20 minutos —menos que el intervalo del cron—; en ese caso la separación se achica para que la ronda se **encole** antes de la siguiente. Eso no garantiza que **termine** antes: los jobs de una integración corren de a uno (`limits_concurrency to: 1`), así que con volumen la ronda dura lo que tarden sus requests en serie, y pasado cierto punto los jobs esperan el semáforo y no el `wait`. Con el volumen actual (lotes de 50 envíos en la consulta masiva) no se llega.
- **`limits_concurrency to: 1` por integración:** aunque una ronda se atrase, a un mismo courier nunca le llega más de una consulta a la vez.
- **Lotes de 50** en la consulta masiva, para no mandar un request con cientos de números.

### Multi-tenancy

El barrido es, como `Webhooks::ScanDueFailedEventsJob`, el único punto sin tenant: lee integraciones y envíos con `unscoped` y encola cada consulta con el `company_id` de su integración. El job activa ese tenant con `with_tenant` antes de tocar nada, y el caso de uso busca los envíos a través de la integración (`integration.shipments.in_flight.where(id:)`), así que un id de otra empresa no encuentra nada. Los envíos se revalidan al ejecutar y no al encolar: entre el barrido y el job, uno pudo entregarse.

## Alternativas consideradas

### Una columna `tracking_uri` en la plantilla de despacho

- ✅ Una sola plantilla por courier, sin FK
- ❌ La consulta también necesita su propio `http_method` y sus propios mappers: la respuesta del despacho y la de la consulta no tienen la misma forma. Terminaría siendo una plantilla entera metida en columnas de otra
- ❌ El adaptador genérico tendría que saber elegir entre dos URIs, cuando hoy sólo entiende "la plantilla"

### Una integración aparte por empresa para la plantilla de seguimiento

- ✅ Sin FK entre plantillas: cada empresa conecta la plantilla de seguimiento como cualquier otra
- ❌ Nada une esa integración con la que despachó el envío; habría que emparejarlas por nombre o por otra convención frágil
- ❌ Duplica las credenciales del mismo proveedor, y la segunda copia puede quedar desactualizada respecto de la primera

### Reusar `ProcessTrackingUpdate` sintetizando un `WebhookLog` por respuesta

- ✅ Cero código nuevo de registro, y la DLQ gratis
- ❌ Un `WebhookLog` dice "el proveedor nos mandó esto"; en el pull nadie mandó nada. Ensuciaría la auditoría de webhooks con miles de filas por día
- ❌ Arrastraría la DLQ, que es justamente lo que el pull no quiere (ver Fallos)

### Un job por integración que recorre sus envíos secuencialmente

- ✅ Menos jobs en la cola
- ❌ Un courier con muchos envíos individuales tendría un job de larga duración que sostiene un thread de la cola `low`, compartida con los reintentos de la DLQ
- ❌ El escalonamiento dependería de `sleep` dentro del job en vez de la planificación de Solid Queue

### Reintentar la consulta fallida con el `retry_on` de `ApplicationJob`

- ✅ Recupera antes un fallo transitorio
- ❌ El próximo ciclo ya es un reintento; los de Active Job se sumarían a él y multiplicarían los requests justo cuando el courier está mal

## Consecuencias

- ✅ Un courier sin webhooks se integra cargando dos plantillas y una FK, sin código nuevo: la bitácora y el estado de sus envíos se mantienen solos
- ✅ Push y pull comparten una sola implementación de las reglas de idempotencia, orden y bloqueo: un arreglo en una vale para las dos
- ✅ Un envío entregado deja de consultarse, y un courier caído no voltea la ronda ni la llena de reintentos
- ⚠️ Latencia de hasta un ciclo (30 minutos) más el escalonamiento: el pull nunca va a ser tiempo real
- ⚠️ Con mucho volumen en un courier de consulta individual, dos rondas pueden solaparse: la segunda consulta envíos que la primera todavía no terminó. No duplica movimientos —el núcleo descarta el duplicado exacto—, pero gasta requests; si pasa, la salida es la consulta masiva o una ventana por integración
- ⚠️ Una sola frecuencia para todos los couriers. Si aparece uno con un límite de requests más estricto, la plantilla va a tener que declararlo y el barrido respetarlo
- ⚠️ Un courier que contesta sin fechar sus movimientos no distingue "sigue en el mismo estado" de "pasó por otra planta con el mismo estado": el segundo se descarta como duplicado. Es el mismo costo que ya asumió ADR-011 para el push sin fecha
- ⚠️ Los fallos sólo quedan en el log de la aplicación; no hay una tabla consultable de "couriers que no contestan". Si hace falta visibilidad desde el panel, es una card aparte

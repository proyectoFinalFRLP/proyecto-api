# ADR-011: Push tracking de couriers

**Fecha:** 2026-08-24  
**Estado:** Aceptado

---

## Contexto

El gateway de webhooks (TESIS-36) persiste todo evento entrante en un `WebhookLog` y devuelve `202 Accepted` sin interpretarlo: `Api::Webhooks::EventIngestion` (el concern que comparten los endpoints de `integrations` y `couriers`) sólo guarda el crudo y libera la conexión; qué worker procesa cada evento —si es que alguno lo hace— queda como un hook que cada controller resuelve por su cuenta. Hasta esta card, `CouriersController` no existía: un push de courier no tenía a dónde llegar, y el estado de un envío sólo se movía si alguien lo editaba a mano.

TESIS-45 ya modeló `Shipment` y `ShipmentEvent` —incluida la distinción entre `external_status` (crudo) e `internal_status` (normalizado, restringido a `Shipment::STATUSES`)— pero nada los alimentaba: la bitácora de un envío se cargaba manualmente, como en los seeds. Sin un mecanismo de push tracking, el estado logístico que ve el vendedor depende de que alguien vaya a consultar al courier, lo cual no escala y no es en tiempo real.

Esta card cierra ese hueco: recibe en tiempo real las actualizaciones que empujan los couriers, las traduce con la plantilla del `Service` (el mismo mecanismo de `integrations`, TESIS-20) y actualiza `shipments`/`shipment_events` de forma transaccional e idempotente.

## Decisión

Se agrega un endpoint público dedicado a couriers que persiste el evento crudo y dispara, de forma asíncrona, un pipeline que traduce, registra y actualiza el envío:

```
POST /api/webhooks/couriers/:company_integration_id      (público, sin JWT)
  │
  ▼
Api::Webhooks::CouriersController (concern EventIngestion)
  - WebhookLog.create!(status: 'pending')             # auditoría del evento crudo
  - Shipments::ProcessTrackingEventJob.perform_later    # sólo si el Service es courier
  - head :accepted                                      # 202, cuerpo vacío, no espera nada
  │
  ▼  (cola realtime)
Shipments::ProcessTrackingEventJob
  - with_tenant(company_id)
  │
  ▼
Shipments::ProcessTrackingUpdate
  - Shipments::TranslateTrackingPayload                 # traduce con la plantilla del Service
  - Shipment.find_by(tracking_number:, company_integration_id:)
  - BEGIN
      shipment.lock!                                    # SELECT ... FOR UPDATE
      ShipmentEvent.create!(...)
      shipment.update!(status: internal_status)         # sólo si el estado avanza
    COMMIT
  - WebhookLog: processed | failed + error_message
  │
  ▼ (si falló de verdad)
FailedEvent inbound 'webhooks.tracking_ingestion' → DLQ (ADR-008)
```

| Pieza                                    | Rol                                                                                   |
| ----------------------------------------- | -------------------------------------------------------------------------------------- |
| `Api::Webhooks::CouriersController`       | Endpoint público: persiste el evento y encola sólo si el `Service` es de tipo courier  |
| `Api::Webhooks::EventIngestion`           | Concern con la mecánica común de ingesta, compartida con el endpoint de `integrations` |
| `Shipments::ProcessTrackingEventJob`      | Job en la cola `realtime`: activa el tenant y delega en el caso de uso, sin propagar excepciones |
| `Shipments::ProcessTrackingUpdate`        | Caso de uso transaccional: traduce, ubica el envío, registra el evento y actualiza el estado |
| `Shipments::TranslateTrackingPayload`     | Traduce el payload crudo con la plantilla del `Service`, conservando `external_status` crudo e `internal_status` traducido |
| `Webhooks::Replayers::TrackingIngestion`  | Reprocesa desde la DLQ releyendo el `WebhookLog` original                              |
| `Webhooks::ReplayRegistry`                | Registra `'webhooks.tracking_ingestion'` como el `event_type` que resuelve este replayer |

### Endpoint propio y no ruteo dentro del gateway existente

La card fija la ruta `POST /api/webhooks/couriers/:company_integration_id`, separada del endpoint genérico de integraciones (`POST /api/webhooks/integrations/:company_integration_id`, TESIS-36). Los dos comparten exactamente la misma mecánica de ingesta —persistir el `WebhookLog` crudo y liberar la conexión—, así que esa parte común se extrajo al concern `Api::Webhooks::EventIngestion`, incluido por ambos controllers; lo único que cada uno decide es a qué worker encolar después de persistir (`enqueue_processing`, el hook que expone el concern). Una ruta propia por tipo de proveedor documenta mejor el contrato con cada integración que un único endpoint con un `case` interno sobre `service.type`, y ese `case` habría crecido con cada tipo de evento entrante nuevo en vez de quedar en la firma de la ruta.

### Por qué se conserva el estado crudo

`external_status` es el texto que mandó el courier tal cual; `internal_status` es lo que el OMS entendió después de aplicar el `response_value_mapper` de la plantilla. Guardar los dos hace auditable la traducción: si la plantilla queda mal configurada o el courier cambia el texto de un estado, `external_status` permite reconstruir qué pasó realmente sin haber perdido la bitácora, y corregir el mapper no exige reinventar el historial — sólo reprocesar. Por eso `TranslateTrackingPayload` lee cada campo con `Integrations::ParseExternalResponse.dig_path` en vez de reusar `ParseExternalResponse#call` completo: ese último ya aplica el `response_value_mapper` a todo lo que extrae, y el dato crudo se perdería en el camino antes de llegar a la bitácora.

### Estado externo no mapeado

Un courier puede empezar a mandar un estado que la plantilla todavía no contempla —un estado nuevo de su lado, o un mapper desactualizado—. El evento se registra igual: el `ShipmentEvent` se crea con `internal_status` igual al último estado conocido del envío (la columna es `NOT NULL`, y no tiene sentido inventar uno), pero `shipments.status` no se toca. Es información, no una traducción fallida: el movimiento del paquete queda auditado en la bitácora aunque el OMS todavía no sepa interpretarlo, y nunca se descarta un evento real del courier por un hueco en la configuración de la plantilla.

### Transaccionalidad y bloqueo

`ShipmentEvent` y la actualización de `shipments.status` ocurren en una única transacción, con `shipment.lock!` (`SELECT ... FOR UPDATE`) tomado antes de los chequeos de duplicado y orden. Es el caso "alcanza con serializar una única fila que ya existe" de la sección 9.1 de [`architecture.md`](../guidelines/architecture.md), no el de "puede crear una fila que todavía no existe" que exige el advisory lock de [ADR-009](ADR-009-bloqueos-distribuidos.md): el `Shipment` siempre existe de antes —lo crea la confirmación del despacho, TESIS-47—, el push de tracking sólo lo actualiza. El lock por fila alcanza y es más barato que tomar un advisory lock por cada evento.

### Idempotencia y orden

La entrega de webhooks es *at-least-once*: el mismo evento puede llegar dos veces, y dos llegadas del mismo evento pueden procesarse casi en simultáneo en dos workers. Tres barreras, de la más a la menos frecuente:

1. **Duplicado exacto.** Ya existe un `ShipmentEvent` del mismo envío con igual `external_status` **y** igual `occurred_at` → se descarta y se devuelve éxito. El chequeo corre dentro del lock del shipment a propósito: afuera del lock, dos entregas simultáneas del mismo evento pasarían las dos. Cuando el payload no trae `occurred_at` (ver Consecuencias), `occurred_at` se sintetiza distinto en cada entrega y esta comparación exacta nunca coincidiría entre reintentos; para ese caso el chequeo cae a comparar sólo por `external_status` contra el último evento registrado del envío.
2. **Evento desordenado.** `occurred_at` estrictamente anterior al del último evento registrado del envío → se descarta: llegó tarde y ya hay un estado más nuevo en la bitácora.
3. **Red del motor.** Índice único `(shipment_id, external_status, occurred_at)` (migración `20260824120000`): si dos transacciones arrancan antes de que cualquiera tome el lock, ambas podrían pasar el chequeo en Ruby; el índice es la garantía de fondo. `ActiveRecord::RecordNotUnique` se captura y se interpreta como "ya registrado", no como un error.

### Degradación elegante

Un `tracking_number` que no existe en la base —el courier avisa de un paquete que no es nuestro, o el evento llegó antes que la asignación del despacho— se omite sin excepción: el `WebhookLog` queda `processed` y no se genera `FailedEvent`. El courier no tiene que enterarse de nada raro y, sobre todo, no debe reintentar indefinidamente algo que nunca se va a resolver solo.

Contraste con lo que **sí** es un error real: un payload sin `tracking_number` o sin `external_status` no es un tracking ajeno, es una plantilla del `Service` mal configurada —no ubica esos datos en el payload—. `ProcessTrackingUpdate` lo levanta como `InvalidPayloadError`, el job lo captura y lo deriva a la DLQ ([ADR-008](ADR-008-dead-letter-queue.md)): ahí sí hace falta que alguien se entere y corrija la plantilla, y el reintento automático tiene sentido porque el problema persiste hasta que alguien la arregla, no porque el próximo intento vaya a tener más suerte por las suyas.

### Multi-tenancy

El tenant sale de la integración (`CompanyIntegration#company_id`), nunca de un JWT que no existe en este endpoint público: `EventIngestion` lo persiste explícitamente en el `WebhookLog` y el job lo activa con `with_tenant(company_id)` antes de tocar cualquier modelo con `CompanyScoped`. El envío se busca por `tracking_number` **y** `company_integration_id` juntos, no sólo por `tracking_number`: dos couriers integrados a la misma empresa podrían coincidir en el mismo número de seguimiento, y atar la búsqueda a la integración de origen evita cruzar el evento con el envío equivocado.

## Alternativas consideradas

### Procesar dentro del request HTTP

- ✅ Sin cola, sin latencia de un job en el medio
- ❌ El endpoint queda a merced de la latencia de nuestras propias queries dentro del request del courier: un lock esperando o una query lenta hacen esperar al proveedor, y varios couriers tienen su propio timeout corto para el push
- ❌ Rompe la garantía "el proveedor nunca espera" que ya vale para el resto de los webhooks (TESIS-36): mezclar dos criterios para el mismo tipo de endpoint es una inconsistencia sin beneficio real

### Rutear los couriers por el endpoint genérico `/api/webhooks/integrations/:id`

- ✅ Una sola ruta, un solo controller
- ❌ El controller tendría que resolver `service.courier?` para decidir a qué job encolar, mezclando la mecánica común —que ya vive en el concern— con una decisión de negocio propia de cada dominio
- ❌ El contrato de la card pide explícitamente una ruta dedicada; `EventIngestion` ya resuelve la duplicación de código sin necesitar una única ruta

### Polling periódico al courier (pull tracking)

- ✅ No depende de que el proveedor implemente bien un webhook saliente
- ❌ Latencia mínima de un ciclo de polling en vez de tiempo real
- ❌ Multiplica llamadas salientes —una por envío activo en cada ciclo— contra la API del courier, con su propio costo y límites de rate
- Push y pull no son excluyentes: `feature-structure.md` ya lista "Push/Pull tracking" como alcance de `shipments`. El pull queda como complemento futuro para couriers que no ofrezcan push, no como sustituto de éste

### Estado `unknown` en `Shipment::STATUSES` para lo no mapeado

- ✅ Explícito: distingue "no sabemos" de cualquier estado real
- ❌ Contamina `Shipment::STATUSES` —hoy sólo estados de negocio reales— con un valor que no describe al envío sino una falla de configuración de la plantilla
- ❌ Un envío que "retrocediera" a `unknown` sería confuso para quien lea la bitácora; conservar el último estado conocido es más fiel a la realidad: el paquete no dejó de estar donde estaba, sólo llegó un evento que la plantilla no supo traducir

## Consecuencias

- ✅ El estado logístico se refleja en tiempo real sin intervención manual: TESIS-45 deja de depender de que alguien actualice la bitácora a mano
- ✅ `external_status` e `internal_status` quedan auditables por separado: una plantilla mal mapeada se corrige sin perder historial
- ✅ Ningún evento se pierde: los fallos reales van a la DLQ y los eventos de paquetes ajenos se descartan sin generar reintentos infinitos
- ✅ `EventIngestion` evita duplicar la mecánica de ingesta entre `integrations` y `couriers`, y sumar un tercer tipo de webhook entrante es repetir la misma receta, no tocar el gateway
- ⚠️ El endpoint es público y hoy no valida la firma del courier: cualquiera que conozca (o adivine) un `company_integration_id` puede escribir eventos de tracking falsos. Queda para una card de seguridad dedicada (verificación de firma/HMAC por proveedor)
- ⚠️ Sin `occurred_at` en el payload, `ProcessTrackingUpdate` cae a `Time.current`: si el evento llega tarde —cola atrasada, reintento del courier— la bitácora puede quedar con el timestamp del procesamiento en vez del real, desordenando el historial. Como ese timestamp sintético también es la clave de la barrera 1, el chequeo de duplicado deja de comparar por `occurred_at` exacto para este caso y compara sólo por `external_status` contra el último evento del envío: no distingue un reintento de un cambio de estado real que llegara sin fecha y coincidiera con el estado anterior, pero para una bitácora de auditoría el default seguro es no duplicar
- ⚠️ La unicidad `(shipment_id, external_status, occurred_at)` descarta como duplicado un evento legítimo que repita exactamente el mismo estado y timestamp; se acepta el costo porque, en la práctica, el propio courier tampoco suele distinguir esos dos casos entre sí

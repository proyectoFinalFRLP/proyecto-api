# ADR-012: Creación de envíos

**Fecha:** 2026-09-08  
**Estado:** Aceptado

---

## Contexto

La épica logística (TESIS-24) estaba completa salvo por su punto de entrada. Se podía cotizar un envío contra los couriers de la empresa (TESIS-46), confirmar su despacho (TESIS-47) y seguirlo por el push de tracking del courier (TESIS-48, [ADR-011](ADR-011-push-tracking-de-couriers.md)). Lo único que no se podía era **tener** el envío: nada en `app/` creaba un `Shipment`, y los únicos que existían en la base los sembraba `db/seeds.rb`.

Eso no era sólo un hueco de funcionalidad. TESIS-47 valida que el envío esté en `pending` y presupone la fila; y `Shipments::ProcessTrackingUpdate` ubica el envío por `tracking_number` + `company_integration_id`, así que contra una base real nunca habría encontrado nada y todo evento de courier habría quedado registrado como "paquete ajeno".

El modelado de TESIS-45 ya contemplaba este paso y no hubo que tocarlo: `shipments.status` tiene `default: 'pending'`, `company_integration_id` es nullable ("se completa al confirmar el despacho"), hay índice único sobre `order_id` y `order_belongs_to_company` cubre el cruce de tenants. Faltaba el disparador, no el dominio.

## Decisión

El envío se crea de forma **explícita**, con un endpoint propio colgado de la orden:

```
POST /api/v1/orders/:order_id/shipment
  │
  ▼
Api::V1::ShipmentsController#create
  - Order.find(:order_id)          # CompanyScoped: una orden ajena es 404
  - authorize order, :ship?        # OrderPolicy — el permiso es sobre la orden
  │
  ▼
Shipments::CreateShipment
  - rechaza las órdenes en un estado que no admite despacho -> 422
  - Shipment.create!(status: 'pending')   # sin courier, sin tracking, sin costo
  - traduce el choque contra la restricción 1 a 1 -> 409
  │
  ▼
ShipmentSerializer  -> 201 con el id que consumen TESIS-46 y TESIS-47
```

| Pieza                                 | Rol                                                                       |
| ------------------------------------- | ------------------------------------------------------------------------- |
| `Api::V1::ShipmentsController#create`  | Resuelve la orden dentro del tenant, autoriza y delega                    |
| `Shipments::CreateShipment`            | Caso de uso: regla de estado, alta en `pending` y semántica del duplicado |
| `Shipments::UnshippableOrderError`     | El estado de la orden no admite despacho (422)                            |
| `Shipments::DuplicateShipmentError`    | La orden ya tiene su envío (409)                                          |
| `OrderPolicy#ship?`                    | Autorización: la orden tiene que ser del tenant del usuario               |

### Explícito y no automático al pagar

La alternativa era crear el `Shipment` en la misma transacción que escribe la orden, en cuanto ésta quedara `paid`. Se eligió el alta explícita por dos motivos concretos:

- El wizard de orden manual (TESIS-59) ya modela la elección logística como un **paso del usuario**, no como un efecto secundario del pago.
- TESIS-47 recibe un `shipment_id` en la URL. Con el alta explícita ese id sale de esta respuesta; con el alta automática habría que ir a buscarlo.

El costo asumido es que una orden pagada puede quedarse sin envío por olvido. Se acepta porque el listado de envíos (TESIS-113) y el detalle de la orden hacen visible el hueco, y porque el error inverso —envíos fantasma para retiros en sucursal o productos digitales— ensucia datos que después hay que limpiar a mano.

### Autorizar la orden y no el envío

`authorize order, :ship?` en vez de `authorize Shipment`. Cuando corre el chequeo el envío todavía no existe, y el permiso que hay que verificar es sobre la orden: que sea del tenant del usuario. Es el mismo criterio que ya usa la cotización (`authorize order, :quote?`, TESIS-46), que es la otra acción anidada bajo `orders`. `ShipmentPolicy` sigue siendo de sólo lectura y sus acciones de escritura siguen en `false`.

### Qué estados de orden admiten despacho

`Shipments::CreateShipment::NON_SHIPPABLE_STATUSES` es una lista de **exclusión** (`cancelled`), y no la inclusión de `paid` que pedía el alcance de la card.

El motivo es que hoy nada en la aplicación mueve una orden a `paid`: `Orders::CreateOrder` la crea `pending` (TESIS-42) y `Orders::ProcessWebhookOrder` sólo llega a `paid` si el canal externo lo manda en el payload (TESIS-43). No existe endpoint de transición de estados. Exigir `paid` habría dejado el endpoint inalcanzable justo para el alta manual que este mismo circuito necesita habilitar, y el único envío creable sería el de una orden sembrada.

Cuando exista la transición de estados, endurecer la regla es cambiar esa constante.

### El duplicado se detecta escribiendo, no consultando

Una orden tiene a lo sumo un envío. La comprobación **no** es un `exists?` previo: entre esa consulta y el `INSERT` hay una ventana en la que otro request puede insertar el envío, y las dos llamadas terminarían devolviendo 201. La verdad la dice el intento de escritura, que falla por dos caminos:

1. `validates :order_id, uniqueness: true` (TESIS-45) atrapa el caso normal antes de tocar la base: `RecordInvalid` con el error `:taken`.
2. El índice único sobre `order_id` atrapa la carrera real, cuando dos transacciones pasan la validación antes de que cualquiera confirme: `RecordNotUnique`.

Los dos son el mismo hecho de negocio, así que `CreateShipment` los traduce al mismo `DuplicateShipmentError` y el controller los devuelve como el mismo **409**. Cualquier otro `RecordInvalid` sigue de largo y sale como 422: no todo fallo de validación es un conflicto.

No hay transacción explícita porque hay una única escritura: un choque contra la restricción no deja nada a medias que revertir.

### Ruta singular anidada

`resource :shipment` (singular) dentro de `resources :orders`. La restricción 1 a 1 hace que no haya id que poner en la URL, y colgarla de la orden dice en la firma de la ruta lo que el modelo ya garantiza. La lista y el detalle siguen en `/api/v1/shipments` (TESIS-113): se leen por envío, y el filtro por orden es un query param más.

## Alternativas consideradas

### Crear el envío automáticamente al pasar la orden a `paid`

- ✅ Ninguna orden pagada se queda sin envío, y el listado de logística se llena solo
- ❌ Crea envíos para órdenes que nunca se van a despachar (retiro en sucursal, productos digitales)
- ❌ No encaja con el wizard de TESIS-59, que ya trata la elección logística como un paso explícito
- ❌ Hoy sería en la práctica "al crear la orden": no existe la transición a `paid`

### Ambos caminos: alta automática más endpoint explícito

- ✅ Cubre el olvido y la elección manual
- ❌ El automático haría que el explícito devolviera 409 casi siempre, dejándolo como un endpoint que casi nunca funciona
- ❌ Duplica la superficie de la card sin resolver ninguna pregunta que el explícito deje abierta

### Chequear `Shipment.exists?(order_id:)` antes de crear

- ✅ Mensaje de error más directo, sin depender de la traducción de excepciones
- ❌ Tiene carrera: dos requests simultáneos pasan el chequeo y uno de los dos se estrella igual contra el índice, así que el `rescue` hace falta de todos modos
- ❌ Suma una query al camino feliz para no ahorrar nada

### Autorizar con `ShipmentPolicy#create?`

- ✅ La policy del recurso que se crea es lo que uno esperaría de entrada
- ❌ El envío todavía no existe en ese momento: la policy recibiría la clase y no podría expresar la regla real, que es sobre la orden
- ❌ Se apartaría de `quote?`, la otra acción anidada bajo `orders`, sin ganar nada

## Consecuencias

- ✅ La épica logística encadena de punta a punta: crear envío → cotizar (TESIS-46) → despachar (TESIS-47) → recibir tracking (TESIS-48)
- ✅ TESIS-48 pasa a servir contra datos reales: hasta ahora sólo podía matchear un envío sembrado
- ✅ Se desbloquean TESIS-47 y TESIS-59
- ⚠️ Una orden pagada puede quedarse sin envío si nadie lo crea. Es visible en el listado de envíos y en el detalle de la orden, pero no hay hoy ninguna alerta que lo señale
- ⚠️ Mientras no exista la transición de estados de la orden, la regla de despacho es "todo menos `cancelled`": una orden `pending` sin pagar puede entrar al circuito logístico
- ⚠️ El envío nace sin `company_integration_id` ni `tracking_number`, así que entre el alta y el despacho hay una ventana en la que un push de tracking no puede encontrarlo. `ProcessTrackingUpdate` ya lo trata como paquete ajeno y lo descarta sin generar reintentos ([ADR-011](ADR-011-push-tracking-de-couriers.md))

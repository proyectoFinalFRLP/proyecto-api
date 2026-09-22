# ADR-013: Modificación de órdenes

**Fecha:** 2026-09-20  
**Estado:** Aceptado

---

## Contexto

Hasta TESIS-126 una orden era inmutable: `index`, `show` y `create`, y nada más. El operador que cargaba mal una cantidad o una dirección no tenía cómo corregirla, y la pantalla de modificación del front (TESIS-61, S09) asumía un `PUT /api/v1/orders/:id` que no existía.

Editar una orden no es editar texto. Sus líneas ya descontaron stock al crearse (`Orders::CreateOrder`, TESIS-42; `Orders::ProcessWebhookOrder`, TESIS-43), así que cambiar una cantidad es un movimiento de inventario. Y ahí apareció el hueco de fondo: **la línea no sabía de qué depósito había salido.** El alta manual recibe el `warehouse_id` en el request y el picking automático de `Catalog::DeductStock` lo elige, pero los dos lo descartaban después de descontar. Mientras nadie editaba, no importaba.

## Decisión

```
PUT /api/v1/orders/:id          If-Match: "<versión>"   (opcional)
  │
  ▼
Api::V1::OrdersController#update
  - Order.find(:id)                  # CompanyScoped: una orden ajena es 404
  - authorize order                  # OrderPolicy#update? — mismo criterio que show?
  │
  ▼
Orders::UpdateOrder                  # una sola transacción
  - valida el estado pedido          # sólo pending ↔ paid                     -> 422
  - order.lock!                      # FOR UPDATE: serializa ediciones de la misma orden
  - verifica If-Match                # Orders::OrderVersion                    -> 412
  - rechaza cancelada o despachada   # Orders::OrderNotEditableError           -> 409
  - actualiza datos del cliente y estado
  - si vienen líneas:
      Orders::ReplaceOrderLines      # diff contra lo que hay + movimientos de stock
      total_amount = items_total     # dentro de la misma transacción (TESIS-114)
  │
  ▼
200 con OrderSerializer + ETag nuevo
```

### La línea recuerda su depósito

`order_items.warehouse_id`, nullable, con FK `restrict` a `warehouses`. Los dos caminos de alta lo escriben: el manual con el depósito del request, el de webhooks con el `Stock` que devuelve el picking.

Se consideraron dos alternativas y se descartaron:

- **Pedir el depósito en el request de modificación.** El front no lo sabe —no existía en ningún lado— y terminaría eligiendo uno arbitrario. Devolver unidades a un depósito del que nunca salieron corrompe el inventario con una operación que parece correcta.
- **No tocar stock al editar.** El total y las líneas quedan bien y el inventario queda mal.

**Sin backfill.** Las líneas anteriores no dejaron rastro de a qué depósito le pegó su descuento, y cualquier valor que se les asignara sería inventado. Quedan en `NULL`: pueden seguir como están, pero una modificación que tenga que moverles unidades se rechaza con 422, en vez de adivinar.

Un depósito del que salieron ventas ya no se puede borrar (`has_many :order_items, dependent: :restrict_with_error`): la devolución de una línea quedaría sin destino.

### Las líneas viajan completas, no como operaciones

El request trae la orden **como tiene que quedar**. Una línea con `id` ya existe y sólo cambia su cantidad; una sin `id` es nueva y trae producto, cantidad, precio y depósito; una que existe y no vino, se borra. Sin `items` en el body, las líneas no se tocan.

Es lo que la pantalla tiene para mandar —su estado local— y evita un protocolo de altas, bajas y modificaciones por línea que el cliente tendría que llevar a mano.

### De la diferencia salen los movimientos de stock

| Caso | Movimiento |
| --- | --- |
| Línea nueva | `DeductStock` del depósito que trae |
| Cantidad que sube | `DeductStock` de la diferencia, del depósito de la línea |
| Cantidad que baja | `AdjustWarehouseStock` con la diferencia, al depósito de la línea |
| Línea que no vino | `AdjustWarehouseStock` con toda la cantidad, al depósito de la línea |

Los advisory locks se toman **en orden canónico** antes de mover nada, igual que en el alta ([ADR-009](ADR-009-bloqueos-distribuidos.md)), y sólo para los productos cuyo stock se mueve: una línea que queda igual no compite con nadie. `wait: false`, porque corre en un request HTTP.

Todo lo que puede hacer fallar el reemplazo —una línea ajena, un depósito de otra empresa, un producto inexistente, una línea sin depósito que tendría que moverse— se valida **antes** de tomar el primer lock.

### Lo que no se modifica

- **El precio de una línea existente**, aunque venga en el request. Es lo que se facturó ([TESIS-114](https://proyectofinalfrlp.atlassian.net/browse/TESIS-114)); para cambiarlo, se borra la línea y se agrega otra.
- **La cancelación.** El estado sólo va y viene entre `pending` y `paid`. Cancelar devuelve el stock de la orden entera y obliga a decidir qué pasa con su envío: son reglas propias, y merecen su card.
- **Una orden cancelada**, ni **una cuyo envío ya salió** (estado distinto de `pending`, o `pending` con número de seguimiento, mismo criterio que `Shipments::AlreadyDispatchedError`). Cambiar las líneas de algo que ya viaja no es una corrección. Las dos responden 409: no hay body que haga pasar el mismo request.

### Ediciones concurrentes: el mismo contrato que productos

`GET` y `PUT` devuelven la versión de la orden como `ETag`, y el `PUT` la acepta en `If-Match` con 412 si ya no es la vigente. Es el mecanismo del ABM de productos ([ADR-009](ADR-009-bloqueos-distribuidos.md), TESIS-101); la parte de HTTP pasó a un concern compartido (`Api::V1::OptimisticLocking`).

La huella (`Orders::OrderVersion`) cubre los datos del cliente, el estado **y** las líneas. Las líneas no son un extra: dos operadores cambiando cantidades distintas de la misma orden no tocan la fila `orders` hasta que se recalcula el total, y una versión sobre esa fila sola no los detectaría.

El chequeo va detrás del `lock!` y **antes** que las guardas de estado: si otro operador canceló la orden, la versión también cambió, y el 412 le dice al cliente que recargue y lo vea.

## Consecuencias

- ✅ La orden se puede corregir sin tocar la base a mano, y el inventario acompaña cada corrección contra el depósito correcto
- ✅ El depósito de cada línea queda registrado desde el alta: es un dato que el negocio ya tenía y se estaba tirando
- ✅ El front no lleva un protocolo de operaciones: manda lo que tiene en pantalla
- ⚠️ Las líneas anteriores a TESIS-126 quedan con `warehouse_id` en `NULL` y no se pueden achicar ni borrar; con el tiempo dejan de existir en órdenes editables, pero no hay forma de repararlas
- ⚠️ Como en productos, la protección contra ediciones concurrentes es **opt-in**: un cliente que no manda `If-Match` no está protegido
- ⚠️ La cancelación sigue sin camino: una orden sólo llega a `cancelled` por el canal externo o por el backoffice

# ADR-016: Cotización del alta manual y despacho de la opción elegida

**Fecha:** 2026-09-24  
**Estado:** Aceptado

---

## Contexto

El paso 3 del alta manual de órdenes (TESIS-59, diseño S07) sigue este recorrido: al entrar se cotiza contra todos los operadores, el operador elige una opción y **«Confirmar orden»** crea la orden y emite el despacho. Las piezas de la API existían por separado —cotizar (TESIS-46), crear el envío (TESIS-105, [ADR-012](ADR-012-creacion-de-envios.md)) y despacharlo (TESIS-47)—, pero juntas no alcanzaban para ese recorrido. Había tres huecos:

1. **La cotización necesitaba una orden** (`POST /orders/:id/quotes`). Para mostrar las tarifas antes de confirmar había que crear la orden, y eso descuenta el stock. Si el operador abandonaba el paso, quedaba una orden `pending` que nadie podía cancelar: `Orders::UpdateOrder` deja la cancelación afuera a propósito ([ADR-013](ADR-013-modificacion-de-ordenes.md)).
2. **Una cotización no se podía despachar.** Cotizar y despachar son dos endpoints del proveedor y, por convención, dos `Service` («Andreani - Cotización» y «Andreani»). Cada opción informaba la integración de la plantilla que **cotiza**, y `Shipments::ConfirmDispatch` exige una que **despache**. Nada en el modelo decía que eran del mismo courier.
3. **El costo elegido se perdía.** El despacho no escribía `shipments.shipping_cost`, así que el detalle de la orden mostraba el envío «a cotizar» para siempre.

## Decisión

```
Paso 3 del alta
  │
  ├─ POST /api/v1/quotes                     cotiza el borrador, sin crear nada
  │    { origin_warehouse_id, destination_zip_code, destination_address,
  │      items: [{ product_id, quantity }] }
  │    -> [{ company_integration_id, dispatch_integration_id,
  │          provider_name, shipping_cost, estimated_days }]
  │
  └─ «Confirmar orden»
       ├─ POST /api/v1/orders                 crea la orden y descuenta el stock
       ├─ POST /api/v1/orders/:id/shipment    abre el envío en `pending`
       └─ POST /api/v1/shipments/:id/dispatch
            { company_integration_id: <dispatch_integration_id>,
              origin_warehouse_id, shipping_cost }
```

| Pieza                                   | Rol                                                                                       |
| --------------------------------------- | ----------------------------------------------------------------------------------------- |
| `Api::V1::DraftQuotesController`        | `POST /api/v1/quotes`: arma el paquete del borrador dentro del tenant y delega            |
| `Shipments::QuoteShipment`              | Cotiza un paquete (origen, destino y líneas); `.for_order` lo arma desde una orden        |
| `Service#quote_service`                 | En la plantilla que despacha: la plantilla con la que se cotiza al mismo courier          |
| `Shipments::ConfirmDispatch`            | Guarda además el `shipping_cost` confirmado, si viene                                     |

### Se cotiza el paquete, no la orden

`QuoteShipment` recibe el origen, el destino y pares `[producto, cantidad]`. El peso sigue saliendo de `products.weight` del lado del backend: el cliente manda qué lleva el paquete, no cuánto pesa. La cotización de una orden (`POST /orders/:id/quotes`) arma ese mismo contexto con `QuoteShipment.for_order` y responde igual que antes.

**Alternativas descartadas:**

- **Un estado `draft` de la orden** que no descuente stock hasta confirmar. Resolvía el hueco 1, pero tocaba los estados, el listado, los KPIs del panel y el momento del descuento: un cambio de dominio para un problema de secuencia.
- **Que el front mande el peso total.** Duplica en el cliente un dato que ya es del backend, y deja que el cliente decida sobre qué se cotiza.

### El vínculo entre plantillas cuelga de la que despacha

`services.quote_service_id` sigue el patrón de `tracking_service_id` ([ADR-014](ADR-014-pull-tracking-de-couriers.md)). El `Service` del proveedor es el que despacha, y sus plantillas auxiliares (la de seguimiento, la de cotización) cuelgan de él. La validación también es la misma: sólo couriers, nunca la propia plantilla, y sólo una plantilla que cotice (`Service#quotes_shipping?`).

Además, **una plantilla de cotización es de un solo despachador**, y sólo la plantilla que despacha puede tener una. La cotización devuelve una opción por plantilla de cotización y la despacha con una integración; si dos plantillas de despacho («Andreani» y «Andreani Express») compartieran el cotizador, una desaparecería de las opciones sin aviso. `Service` lo valida con un mensaje para el panel, y un índice único sobre `quote_service_id` lo respalda en la base. Si algún día dos servicios del mismo proveedor necesitan el mismo endpoint de tarifas, se carga una plantilla de cotización por cada uno: son filas, no código.

Con el vínculo, cada opción informa `dispatch_integration_id` y se nombra por el courier («Andreani», no «Andreani - Cotización»).

**Una plantilla de cotización sin integración de despacho activa no se consulta.** Se filtra antes de abrir los hilos, no después de cotizar: una opción que el operador no puede confirmar no es una opción, y pedirle la tarifa sería hacerlo esperar por algo que no se va a mostrar.

### El costo que se guarda es el que se confirmó

El despacho acepta `shipping_cost` opcional y lo escribe en el envío. Se validó la alternativa de volver a cotizar al despachar y guardar lo que conteste el courier, y se descartó por dos motivos: es una segunda llamada externa dentro del request, y el precio podría no coincidir con el que el operador aceptó segundos antes.

El valor se valida antes de pedir la etiqueta (que el courier cobra), y contra la regla del modelo, no contra una copia: `ConfirmDispatch` prueba el costo con las validaciones de `Shipment` —no negativo y menor a 100.000.000, lo que entra en `decimal(10,2)`— antes de llamar al courier. Un costo que no es un número, negativo, fuera de rango, `NaN` o infinito responde 400 sin haber llamado a nadie. Validarlo sólo en el controller dejaba pasar los tres últimos: se emitía la etiqueta, el `update!` fallaba después y el envío seguía `pending`, así que un reintento pagaba una segunda etiqueta. Un despacho sin costo deja el que hubiera.

El costo lo manda el cliente y no se compara con lo que devolvió la cotización: el operador está autenticado dentro de su propio tenant, y el costo que se guarda es informativo —no se le cobra a nadie a partir de él—. Si algún día se factura con este dato, la comparación pasa a ser necesaria.

### Cotizar tiene un tope por usuario

`POST /quotes` es el primer endpoint autenticado que sale a los proveedores sin dejar rastro en la base: antes, cotizar exigía crear la orden, que funcionaba como freno. Sin tope, un cliente en loop —un `useEffect` mal puesto que cotiza en cada tecla— generaría tantas llamadas a los couriers como quisiera, con las credenciales de la empresa. Se aplica el `rate_limit` de Rails (el mismo mecanismo que el registro, TESIS-82): **20 cotizaciones por minuto por usuario**, con 429 y `Retry-After`. Se cuenta por usuario y no por IP porque todos los requests llegan autenticados, y los operarios de un depósito detrás de un mismo NAT no deberían compartir el cupo.

## Consecuencias

**A favor**

- El stock se descuenta una sola vez, cuando el operador confirma. Cotizar no crea nada.
- Una opción cotizada siempre se puede despachar: la que no tendría con qué, no aparece.
- El detalle de la orden muestra el costo que se eligió.

**En contra**

- **Confirmar son tres requests encadenados, y no es atómico.** El despacho llama a un courier externo y no puede ir en la misma transacción que el alta. Si falla, la orden queda creada con su envío `pending`, que es un estado válido y se puede volver a despachar. Lo resuelve el front, reintentando el despacho sobre la orden ya creada.
- **El precio puede cambiar entre la cotización y el despacho.** Se guarda el que se confirmó, no el que el courier cobre al emitir la etiqueta. Si un proveedor empieza a devolver el costo en la respuesta del despacho, esa es la fuente mejor, y este ADR se revisa.
- Un courier cargado sin su `quote_service` no se ofrece al cotizar. En el panel de administración, el vínculo se edita en la plantilla que despacha, junto a la de seguimiento.
- El contador del tope vive en la cache de la app (Solid Cache en producción). En test es `:null_store` y el tope nunca se alcanza, salvo en el spec que lo prueba.

## Referencias

- TESIS-131 — la card de este ADR
- TESIS-59 — el paso 3 del alta manual, que consume este flujo
- TESIS-46 / TESIS-47 / TESIS-105 — cotización, despacho y alta del envío
- [ADR-012](ADR-012-creacion-de-envios.md), [ADR-014](ADR-014-pull-tracking-de-couriers.md)

# ADR-023: Fecha comprometida del envío y envíos demorados como anomalías

**Fecha:** 2026-10-20  
**Estado:** Aceptado

---

## Contexto

La pantalla de Reportes (S14) tiene cuatro KPIs y una tabla de anomalías. Dos de los KPIs, «Cumplimiento de plazo» y «Anomalías activas», y la tabla entera llegaban siempre vacíos: `Reports::BuildOverview` los devolvía como `nil` fijo porque el modelo no tenía con qué calcularlos.

- **Cumplimiento de plazo** necesita una fecha contra la cual medir la entrega, y `shipments` no la guardaba. La cotización sí trae el plazo de cada opción (`estimated_days`, [ADR-016](ADR-016-cotizacion-del-alta-manual.md)), pero el despacho no lo recibía.
- **Anomalías** («anomalías regionales» en el diseño, con un código de incidente, un nodo y un tipo de desvío) no tenía ninguna entidad detrás.

El detalle de la orden tenía un hueco parecido: «Depósito de origen» salía siempre «—». El despacho recibe el depósito para cotizar y pedir la etiqueta, pero no lo guardaba.

## Decisión

**El despacho guarda en el envío de dónde sale y para cuándo se compromete la entrega**, y las anomalías son los envíos que no cumplieron esa fecha.

```
POST /api/v1/shipments/:id/dispatch
  { company_integration_id, origin_warehouse_id, shipping_cost, estimated_days }
      │
      └─ Shipments::ConfirmDispatch
           shipments.origin_warehouse_id   = origin_warehouse_id
           shipments.promised_delivery_on  = día del despacho + estimated_days
```

| Pieza                             | Rol                                                                                     |
| --------------------------------- | --------------------------------------------------------------------------------------- |
| `shipments.origin_warehouse_id`   | FK `restrict` a `warehouses`: un depósito que despachó no se borra (409)                |
| `shipments.promised_delivery_on`  | Día calendario en hora de Argentina (`Shipment::PROMISE_ZONE`)                          |
| `Shipment.delayed` / `#delayed?`  | En camino (`ready_to_ship` o `in_transit`) y con la fecha comprometida vencida          |
| `Reports::PromisedDeliveries`     | Las entregas de un rango que tenían fecha comprometida, con el día de la entrega        |
| `Reports::DelayedShipments`       | El KPI de anomalías activas y las filas de la tabla                                     |
| `GET /shipments?delayed=true`     | El listado de los demorados, a donde lleva «Ver bitácora» desde Reportes                |

### La fecha comprometida es un día, no una hora

El plazo que dan los couriers es en días («3 días hábiles», `PlazoEntrega` en OCA), y el seguimiento de OCA fecha los estados sin hora ([ADR-022](ADR-022-oca-epak-con-el-adaptador-generico.md)). Se guarda un `date` y se compara contra el día de la entrega cortado en hora de Argentina: una entrega a las 23 h del día prometido llegó a tiempo, aunque en UTC ya sea el día siguiente.

Los días se cuentan **corridos**, no hábiles. Contar hábiles pide un calendario de feriados que el sistema no tiene, y para el plazo que se mide alcanza con que la regla sea la misma para todos los envíos.

### Una anomalía es un envío demorado

| Estado          | Regla                                                                    |
| --------------- | ------------------------------------------------------------------------ |
| `investigating` | En camino, 1 o 2 días después de la fecha comprometida                   |
| `critical`      | En camino, `CRITICAL_DELAY_DAYS` (3) días o más después                  |
| `resolved`      | Entregado después de la fecha comprometida, dentro de la ventana elegida |

Las abiertas son de hoy y no dependen del período elegido. Las resueltas sí, porque son entregas.

**Alternativas descartadas:**

- **Una entidad `Anomaly`** cargada a mano o por reglas. Es un dominio nuevo (quién la abre, quién la cierra, qué la dispara) para un proyecto que ya tiene el dato que importa: si el paquete llegó cuando se prometió.
- **Sacar el KPI y la tabla de la pantalla.** Era lo más barato, pero dejaba Reportes sin la única métrica de servicio que el diseño pide.

### Lo que no cambia

- Un envío sin fecha comprometida no está demorado ni cuenta para el cumplimiento: los despachados antes de este cambio y los de un courier que cotiza sin plazo. Si en la ventana no hay ninguna entrega con plazo, el KPI es `nil` («sin entregas que medir») y no un 0 %.
- La curva de Reportes sigue siendo de **ventas** (órdenes creadas y facturación por día). La pantalla la llamaba «Curva de despacho»; el front la renombra.
- `kpis.orders` se deja de calcular: la pantalla nunca lo mostró.

## Consecuencias

- ✅ Reportes muestra los cuatro KPIs y la tabla con datos reales, y «Ver bitácora» lleva a los envíos demorados.
- ✅ El detalle de la orden muestra el depósito de origen y la entrega comprometida.
- ⚠️ La fecha comprometida depende de que el front mande `estimated_days` al despachar. Un despacho por API sin ese campo queda sin plazo, no con uno inventado.
- ⚠️ Los días son corridos: un envío despachado un viernes con «2 días» queda comprometido para el domingo.

# Respuesta al review — TESIS-45 (Shipments)

**Reviewer:** Tomás
**Autor:** grupo (Aubert, Cuenca, Natalichio, Martin)
**Fecha:** 23/08/2026

---

## 1. `shipping_cost` acepta negativos ✅ Resuelto

**Comentario del reviewer:** El único de los tres que arreglaría antes de mergear, porque es una línea.

**Acción:** Agregada validación en el modelo + 3 specs:

```ruby
# app/models/shipment.rb
validates :shipping_cost, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
```

**Commits:**
- `7c49959` fix: reject negative shipping_cost on Shipment

**Nota:** Seguimos el patrón de `order_item.unit_price` y `product_mappings.external_price` (misma restricción, `allow_nil: true`).

---

## 2. `internal_status` sin vocabulario ✅ Resuelto

**Comentario del reviewer:** Cuatro de cuatro status columns lo tienen; este es el que queda afuera. Si el vocabulario normalizado es el mismo del envío, lo natural es que reuse `Shipment::STATUSES`.

**Acción:** Agregada validación de inclusión reutilizando `Shipment::STATUSES` + 2 specs:

```ruby
# app/models/shipment_event.rb
validates :internal_status, presence: true, inclusion: { in: Shipment::STATUSES }
```

**Commits:**
- `ce5bcc9` fix: constrain internal_status on ShipmentEvent to Shipment::STATUSES

**Decisión de diseño:** Confirmamos que el vocabulario normalizado es el mismo del envío. El crudo del courier vive en `external_status`; `internal_status` es escrito por nuestro sistema al procesar el webhook. No necesitamos estados adicionales como `exception` o `returned` en esta etapa — si aparecen, se agregan a `Shipment::STATUSES` y cascadan a ambos modelos.

---

## 3. Índice compuesto `(shipment_id, occurred_at)` 📌 Aplazado

**Comentario del reviewer:** No corre apuro con el volumen de hoy y no bloquea nada — lo dejo anotado para cuando llegue la lectura, que es TESIS-47/49.

**Acción:** No se agrega índice ahora. Lo llevamos como task pendiente en TESIS-47/49 cuando se implemente la lectura cronológica de la bitácora.

**Justificación:** Con el volumen actual el índice compuesto no aporta ganancia medible. Lo agregaremos cuando tengamos el primer caso de uso de lectura ordenada (ej: dashboard de tracking, API de historial de envío).

---

## 4. Pregunta: ¿el envío es historia preservable o no? 💬 Respuesta

**Comentario del reviewer:** Quedan tres criterios distintos conviviendo: la integración no puede llevarse el envío, el producto no puede llevarse sus líneas de venta, pero la orden sí se lleva el envío y su bitácora.

**Respuesta:**

Tenés razón en que los tres comentarios juntos parecen contradictorios. La distinción que hacemos es:

| Entidad | DELETE de padre | Razón |
|---------|----------------|-------|
| `order_items → products` | **RESTRICT** | Las ventas son registros financieros independientes del catálogo. Un producto puede dejarse de vender, pero las facturas emitidas no pueden desaparecer. |
| `shipments → company_integration` | **NULLIFY** | La integración es el canal de origen, no el dueño del envío. Si se borra la integración (ej: se da de baja Andreani), el envío sigue existiendo y es consultable. |
| `shipments → order` | **CASCADE** | El envío es subordinado a la orden. Una orden se **cancela**, no se **borra** en producción — el CASCADE nunca dispara. Si algo borrara una orden (ej: limpieza de datos de prueba), el envío y su bitácora deben irse junto con ella porque no tienen sentido sin la orden. |

**En resumen:** el envío es historia preservable **mientras la orden exista**. No necesitamos conservar envíos huérfanos (sin orden), a diferencia de los `order_items` que deben sobrevivir a cambios del catálogo.

Si esto no refleja el comportamiento esperado, podemos cambiar `cascade: :destroy` por `restrict_with_error` en `order_id` — pero primero conviene definir si alguna vez se borran órdenes con envíos activos en producción.

---

## 5. Punto verificado y confirmado que está bien ✅

**Comentario del reviewer:** `validates :order_id, uniqueness: true` con `default_scope` de `CompanyScoped` no es problema porque el validador usa `klass.unscoped`.

**Confirmación:** Correcto, verificado en la fuente (`activerecord-8.1.3.1/lib/active_record/validations/uniqueness.rb`). El validador arranca de `unscoped`, coincide con el alcance del índice único (también global). No hay riesgo de `RecordNotUnique` (500).

---

## Resumen de cambios

| # | Review item | Estado | Commit |
|---|-------------|--------|--------|
| 1 | `shipping_cost` negativos | ✅ Resuelto | `7c49959` |
| 2 | `internal_status` sin vocabulario | ✅ Resuelto | `ce5bcc9` |
| 3 | Índice compuesto | 📌 TESIS-47/49 | — |
| 4 | CASCADE vs RESTRICT | 💬 Discutido | — |
| 5 | `uniqueness` + `default_scope` | ✅ Confirmado OK | — |

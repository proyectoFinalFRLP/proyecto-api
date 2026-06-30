# Guía para redactar Pull Requests

Este documento define cómo completar cada sección del template de PR. Está pensado para ser usado como contexto por una IA al redactar descripciones de pull requests.

El template vive en `.github/pull_request_template.md`.

---

## Principios generales

- **Escribir para el reviewer, no para el autor.** Quien revisa no tiene el contexto de lo que se estuvo trabajando. El PR debe ser autoexplicativo.
- **Explicar el por qué, no solo el qué.** El diff ya muestra qué cambió; el PR debe explicar la motivación y el razonamiento detrás de las decisiones.
- **Ser específico y concreto.** Evitar frases vagas como "se refactorizó el código" o "se mejoró la lógica". Decir exactamente qué PORO, controller, model o policy se afectó y cómo.
- **Idioma:** español para toda la descripción. (Los commits van en inglés, las descripciones de PR en español.)

---

## Sección por sección

### 🔗 Ticket de Jira

Solo reemplazar `TESIS-XXX` con el número de la card. Sin texto adicional.

---

### 📝 Descripción

Responder en 2–4 oraciones:

1. **Qué hace este PR** — el comportamiento o funcionalidad que introduce o corrige.
2. **Por qué es necesario** — el problema que resuelve o el valor que aporta.
3. **Contexto relevante** (si aplica) — decisiones de diseño no obvias, limitaciones conocidas, dependencias con otros PRs o con el frontend.

**No incluir:** lista de archivos modificados, explicación del código, ni información que ya está en el diff.

**Ejemplos:**

```
✅ Agrega el modelo Order con su ciclo de vida de estados y la API REST para crear
   órdenes manuales. El aislamiento multi-tenant se aplica automáticamente via
   Global Default Scope heredado de ApplicationRecord.

✅ Corrige la condición de carrera que ocurría al confirmar dos órdenes del mismo
   producto simultáneamente. La causa era la ausencia de un bloqueo a nivel DB;
   se agrega SELECT FOR UPDATE en el PORO ConfirmOrder.

❌ Se modificaron varios archivos para agregar el modelo de órdenes.
❌ Refactor del controller y actualización de dependencias.
```

---

### 🛠️ Cambios realizados

Lista de bullets. Cada item debe:

- **Mencionar el model, PORO, controller, policy, serializer o job afectado** — no solo la acción.
- **Describir el cambio en términos de comportamiento o estructura**, no de implementación interna.
- Usar verbos en pasado: "Agrega", "Extrae", "Corrige", "Renombra", "Reemplaza".

Agrupar primero los cambios principales y después los secundarios o colaterales.

**Ejemplos:**

```
✅
- Agrega modelo `Order` con validaciones y ciclo de vida de estados (pending → confirmed → shipped → delivered)
- Agrega `Orders::CreateOrder` PORO que valida stock antes de persistir la orden
- Agrega `Orders::ConfirmOrder` PORO que descuenta stock y dispara `StockUpdatedEvent` en transacción
- Agrega `OrderSerializer` (Blueprinter) con campos básicos y asociación `order_items`
- Agrega `OrderPolicy` con reglas de autorización tenant-aware (404 ante acceso cross-tenant)
- Registra rutas `GET /api/v1/orders` y `POST /api/v1/orders` en routes.rb

✅ (cambio pequeño)
- Corrige el scope de `policy_scope(Order)` en el index action para incluir órdenes canceladas

❌ Se hicieron cambios en Order, OrderSerializer, OrdersController y routes.rb
❌ Refactor y mejoras varias en el módulo de órdenes
```

Cuando el PR es un refactor sin cambio de comportamiento, aclararlo explícitamente:

```
✅
- Extrae la lógica de deducción de stock de `OrdersController` a `Catalog::DeductStock` PORO (sin cambio de comportamiento)
- Renombra `ProductService` a `Products::CreateProduct` para consistencia con la convención de POROs del proyecto
```

---

### 🧪 Cómo probar

Completar cuando el PR introduce comportamiento que no es evidente solo leyendo el diff, o cuando hay casos límite importantes.

**Estructura:** un caso por flujo o escenario. Cada caso incluye:

- **Precondición** (si aplica): datos necesarios, usuario requerido, estado de la DB.
- **Pasos**: request HTTP concreto (método, endpoint, payload).
- **Resultado esperado**: status HTTP, estructura del JSON de respuesta.

```
✅ Ejemplo bien escrito:

### Caso 1: crear orden manual exitosamente
_Precondición: usuario autenticado, producto con stock disponible en su empresa._
1. POST /api/v1/orders con payload:
   { "order_items": [{ "product_id": 1, "quantity": 2 }], "source": "manual" }
   Authorization: Bearer <jwt>
→ Responde 201 Created con el JSON de la orden
→ El stock del producto se reduce en 2 unidades

### Caso 2: intento de acceso cross-tenant
_Precondición: dos empresas creadas con sus respectivos usuarios y órdenes._
1. GET /api/v1/orders/:id con el ID de una orden de la empresa B, autenticado como usuario de la empresa A
→ Responde 404 Not Found (no 403, para no confirmar existencia del recurso)

### Caso 3: webhook duplicado
1. POST /api/v1/webhooks/orders con el mismo external_order_id dos veces
→ Primera llamada: responde 200 OK, crea la orden
→ Segunda llamada: responde 200 OK, NO crea duplicado (retorna la orden existente)
```

```
❌ Ejemplo pobre:
1. Probar que funciona
2. Ver que el JSON tiene los campos correctos
```

---

### 📸 Evidencia visual

Este es un backend API — normalmente no hay evidencia visual. Reemplazar la tabla por `N/A`.

Excepción: si el PR incluye cambios en el panel de Active Admin (administración interna), adjuntar screenshot.

---

### ⚠️ Impacto y consideraciones

Completar solo las secciones que apliquen. Si una sección no aplica, eliminarla.

**Breaking changes:** ¿Cambia algún contrato de la API que el frontend ya consume? Si sí, coordinar con el equipo web antes de mergear.

**Variables de entorno nuevas:** Listar con su nombre y valor de ejemplo.

**Cambio arquitectónico:** Si el PR introduce un nuevo patrón (nuevo tipo de PORO, nueva convención de serialización, etc.), mencionar si requiere actualizar un ADR en `docs/adr/`.

---

## Casos especiales

### Bug fix

La descripción debe explicar:

1. Cuál era el comportamiento incorrecto (síntoma)
2. Cuál era la causa raíz
3. Cómo se corrigió

```
✅ El stock no se descontaba al confirmar órdenes creadas desde webhooks de Mercado Libre.
   La causa era que `ProcessWebhookOrder` PORO creaba la orden con status `confirmed` directamente,
   sin pasar por `ConfirmOrder` que es quien dispara la deducción de stock.
   Se corrige delegando a `ConfirmOrder` desde dentro de `ProcessWebhookOrder`.
```

### Refactor

Aclarar explícitamente que no hay cambio de comportamiento observable. Explicar la motivación.

```
✅ Extrae la lógica de construcción del request HTTP hacia APIs externas del
   método `call` de cada PORO de integración al `HttpAdapter` genérico.
   Sin cambio de comportamiento; todos los tests existentes continúan en verde.
```

### PR que depende de otro PR o del frontend

Mencionarlo al inicio de la descripción:

```
✅ Depende de TESIS-33 (branch `TESIS-33-product-catalog-model`).
   Requiere que el modelo Product esté migrado y accesible para poder crear órdenes con ítems.
```

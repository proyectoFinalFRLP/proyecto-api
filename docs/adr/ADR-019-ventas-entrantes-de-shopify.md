# ADR-019: Ventas entrantes de Shopify: firma, mapeo y suscripción

**Fecha:** 2026-10-01  
**Estado:** Aceptado

---

## Contexto

ADR-018 conectó Shopify en un sentido: el OMS publica su stock en la tienda. El criterio de aceptación del proyecto (E4b V2 §2.6) pide que la plataforma funcione de punta a punta, y E4a lo detalla: las ventas del canal entran solas al OMS y descuentan stock (RF-19), sin duplicarse (RF-20). ADR-018 dejó las ventas entrantes para este ADR.

El motor de ingesta (TESIS-36, TESIS-43, ADR-010) ya existía y estaba probado con payloads inventados. Para recibir ventas reales faltaban cuatro cosas:

- **La firma.** El gateway público (`POST /api/webhooks/integrations/:id`) aceptaba cualquier body, y la integración se identifica por un id secuencial. Expuesto a internet, cualquiera podía inyectar ventas falsas que descuentan stock. ADR-011 ya había dejado la verificación de firma pendiente.
- **El mapeo.** La plantilla `Shopify` no traducía `orders/create` (`response_mapper` vacío).
- **La ciudad y la provincia.** La ingesta no las copiaba, y el courier las necesita para cotizar el envío.
- **La suscripción.** Nadie le decía a la tienda adónde avisar.

## Decisión

### La plantilla declara cómo firma su proveedor

`services.webhook_config` (jsonb, vacío por defecto):

```json
{ "signature": "hmac_sha256_base64",
  "signature_header": "X-Shopify-Hmac-SHA256",
  "secret_key": "client_secret" }
```

Se lee como «el header trae el HMAC-SHA256 del body, en base64, calculado con la credencial `client_secret` de la integración». Los algoritmos son `hmac_sha256_base64` y `hmac_sha256_hex`. Una plantilla sin `signature` no se verifica: así siguen Mercado Libre (que no firma) y los couriers de los seeds.

`Webhooks::VerifySignature` corre en el gateway **antes de persistir**, en los dos endpoints (integraciones y couriers):

- Calcula sobre el **body crudo** (`request.raw_post`), nunca sobre el JSON re-serializado: un espacio o una tilde escapada de otra forma cambian el HMAC.
- Compara con `ActiveSupport::SecurityUtils.secure_compare`.
- Una firma inválida o un header ausente responden **401** y no se persiste nada: guardar el evento dejaría a cualquiera llenando la auditoría. El log dice el motivo, sin el payload ni la firma.
- **Falla cerrado:** si la plantilla exige firma y la integración no tiene el secreto, el evento se rechaza. Nunca se saltea la verificación.

El secreto es **de la integración**, no de la plantilla, porque cada empresa conecta su propia app de Shopify (ADR-018) y Shopify firma con el client secret de la app que registró el webhook. Una venta firmada con la app de otra empresa no pasa.

Un `webhook_config` a medias (sin header o sin secreto, o con un algoritmo desconocido) no se puede guardar: el gateway rechazaría todos los eventos de la plantilla.

### El mapeo de `orders/create` vive en la plantilla madre

`orders/create` trae la orden completa, así que alcanza con el `response_mapper` de la madre `Shopify` (ADR-010: la ingesta aplica el mapper directo al payload):

| Ruta en `orders/create` | Clave interna |
|---|---|
| `id` | `external_order_id` |
| `financial_status` | `status` |
| `shipping_address.name` / `address1` / `zip` | `customer_name` / `customer_address` / `customer_zip_code` |
| `shipping_address.city` / `province` | `customer_city` / `customer_province` |
| `line_items[].variant_id` / `quantity` / `price` | `external_product_id` / `quantity` / `unit_price` |

`external_product_id` es el id numérico de la variante, que es lo que el vínculo guarda desde ADR-018: la venta se resuelve contra los vínculos existentes sin cambios. El `response_value_mapper` traduce los estados de pago que no se llaman igual (`authorized` y `partially_paid` → `pending`, `voided` → `cancelled`); cualquier otro entra como pendiente.

Una venta descuenta stock, y eso dispara el sync saliente (TESIS-35): el total del OMS vuelve a publicarse en Shopify, que también había descontado el suyo. El valor final en la tienda es el del OMS.

### Ciudad y provincia en la ingesta

`customer_city` y `customer_province` se suman a las claves que la ingesta reconoce. La provincia se valida contra `Order::PROVINCES` (TESIS-128), y cada canal la escribe a su manera (Shopify manda «Santiago Del Estero»). Se compara sin mayúsculas ni tildes. Si igual no matchea, la venta entra **sin provincia** en vez de fallar: es el mismo criterio que el estado desconocido, la venta es el dato que no se puede perder. Un alias de verdad («Capital Federal») lo traduce el `response_value_mapper` de la plantilla.

### La suscripción la registra el sistema

Dos plantillas hijas (ADR-018) más:

| Hija | Operación | Para qué |
|---|---|---|
| `Shopify - Buscar webhook` | `webhook_lookup` | Saber si la tienda ya avisa a esta dirección |
| `Shopify - Webhook` | `webhook_subscription` | Crear la suscripción a `ORDERS_CREATE` |

`Integrations::RegisterWebhook` busca primero y crea sólo si no existe: registrar dos veces no duplica nada. Las dos contestan `webhook_subscription_id`.

La dirección es la del gateway de la integración sobre la URL pública de la API: `PUBLIC_WEBHOOK_BASE_URL` (`config.x.public_webhook_base_url`). No sale del host del request, porque el registro corre desde el backoffice o la consola y lo que importa es cómo nos ve el proveedor. En producción es el dominio HTTPS del servidor. En desarrollo es un túnel (`ngrok http 3001`), y `config.hosts` lo acepta.

Se registra:

- al guardar **Configure connection** en el backoffice, si la prueba de conexión pasa;
- con la acción **Register webhook**, para cuando cambió la URL pública o el registro falló;
- con `bin/rails "integrations:shopify:webhook[norte]"` en desarrollo.

### Los reintentos no duplican la venta

Shopify reintenta una entrega que no recibió un 2xx (8 veces en 4 horas). La idempotencia de órdenes (TESIS-44, índice único `company_id + external_order_id`) ya lo cubre: el segundo evento se persiste y se marca `processed` sin crear otra orden ni descontar stock. No se agrega dedupe por `X-Shopify-Webhook-Id`.

## Alternativas consideradas

### Un token opaco en la URL en lugar del id secuencial

Evita que se enumeren las integraciones, pero no prueba el origen: la URL la ve cualquiera que lea un log. Para Shopify la firma alcanza. El token sigue siendo útil para los proveedores que no firman y queda como trabajo futuro.

### Suscribir el webhook en el `shopify.app.toml`

Es una sola dirección para todas las tiendas que instalan la app, y habría que rutear por `X-Shopify-Shop-Domain`. Va en contra de que cada integración tenga su gateway, y con una app por empresa no simplifica nada.

### Registrarlo a mano desde GraphiQL

Funciona para la demo, pero es un paso más que alguien tiene que acordarse de hacer, y la dirección cambia con cada túnel. Queda como plan B documentado.

### Fallar la venta con una provincia desconocida

La venta quedaría en la DLQ por un dato que no la invalida. Se prefiere registrarla y que la provincia falte.

## Consecuencias

- ✅ Una venta en la tienda entra sola al OMS con cliente, dirección, ciudad y provincia, descuenta stock y el stock nuevo vuelve a Shopify
- ✅ Un evento sin la firma de la app de la empresa no se persiste ni se procesa
- ✅ Todo sigue siendo plantilla: ni el mapeo, ni la firma, ni la suscripción tienen código de Shopify
- ✅ Registrar el webhook es idempotente
- ⚠️ Las plantillas que no firman (Mercado Libre, couriers) siguen aceptando cualquier evento en su gateway
- ⚠️ Sigue sin haber regla de unicidad sobre la tienda (ADR-018): si dos empresas conectaran la misma, cada venta entraría en las dos
- ⚠️ El gateway no mira `is_active`: una integración desactivada con la suscripción viva sigue recibiendo ventas
- ⚠️ Si la app no tiene acceso a los datos protegidos de cliente, Shopify manda la orden sin dirección de envío. La venta falla por `customer_name` y queda visible en la DLQ
- ⚠️ Cada URL pública nueva deja una suscripción más en la tienda. Las viejas fallan hasta que Shopify las da de baja

## Referencias

- [ADR-010](ADR-010-ingesta-de-ordenes-de-webhooks.md): la ingesta de ventas por webhook
- [ADR-011](ADR-011-push-tracking-de-couriers.md): dejó la verificación de firma pendiente
- [ADR-018](ADR-018-conexion-con-proveedores-reales.md): conexión, plantillas de operación y publicación del stock
- Shopify: [verificar webhooks](https://shopify.dev/docs/apps/build/webhooks/subscribe/https#step-2-validate-the-origin-of-your-webhook), [`webhookSubscriptionCreate`](https://shopify.dev/docs/api/admin-graphql/latest/mutations/webhookSubscriptionCreate), [`orders/create`](https://shopify.dev/docs/api/webhooks/latest?reference=toml#list-of-topics-orders/create)

# ADR-018: Conexión con proveedores reales

**Fecha:** 2026-09-26  
**Estado:** Aceptado

---

## Contexto

El criterio de aceptación del proyecto (E4b V2 §2.6) pide que al menos una plataforma de e-commerce y un courier funcionen de punta a punta en un entorno sandbox o real. El motor de integraciones data-driven (TESIS-28 a TESIS-31) estaba construido, pero sólo se había probado contra WebMock, y no podía hablar con un proveedor real:

- `HttpAdapter` sólo sabía mandar un `Bearer` fijo y JSON. Cualquier otra clave de `credentials` viajaba como header literal. No había OAuth, ni renovación de tokens, ni GraphQL.
- `CompanyIntegration` mezclaba en un solo campo cifrado los secretos y la configuración de la cuenta (el dominio de una tienda no es un secreto, y la plantilla necesita interpolarlo en la URI).
- Un proveedor real necesita varias llamadas con la misma cuenta (probar la conexión, buscar una publicación, publicar el stock). Hasta ahora eso obligaba a una integración por plantilla, con el token duplicado y los vínculos de productos repartidos (la consecuencia aceptada de ADR-010).
- El sync saliente (TESIS-35) publicaba el stock en **cualquier** plantilla con productos vinculados, aunque no supiera qué hacer con él.
- No había forma de conectar un proveedor sin Postman o el backoffice.

El primer proveedor es **Shopify**, contra una tienda de prueba (*dev store*) del Partner Program. El equipo decidió integrarse sólo contra entornos de prueba, nunca contra producción. Este ADR registra las decisiones que la conexión real obligó a tomar. Los webhooks entrantes seguros (firma, token opaco, dedupe) van en un ADR aparte, junto con la ingesta de ventas.

## Decisión

### Dos lugares por integración: `settings` y `credentials`

`company_integrations.settings` (jsonb, **sin cifrar**) guarda la configuración no secreta de la cuenta de la empresa: el dominio de la tienda, la ubicación de stock, el CUIT. `credentials` (cifrado, como hasta ahora) queda sólo para secretos y para el token que se obtiene con ellos.

La separación no es cosmética. La plantilla interpola los settings en su URI (`https://:shop_domain/admin/api/2026-07/graphql.json`) y en el `request_mapper` (`settings.location_id`), y el front los muestra y los precarga en el formulario. Los secretos nunca salen de la API: el listado sólo dice qué claves están cargadas (`credentials_set`).

### Cada empresa conecta su propia app del proveedor

El sistema es multi-tenant, y la forma de autenticarse lo condiciona. Shopify ofrece dos caminos:

- El grant **client credentials**, que sólo funciona si la app y la tienda pertenecen a la misma organización de Shopify.
- El **authorization code** de una app pública, que exige un flujo de instalación y la aprobación de Shopify para distribuirla.

Se eligió que **cada empresa cree su propia app** en el Dev Dashboard de su organización y cargue en OneStock el `client_id`, el `client_secret` y el dominio de su tienda. Así, client credentials funciona para cualquier cliente, y no sólo para tiendas de la organización del equipo. Desde el 1/1/2026 Shopify tampoco permite crear apps desde el admin de la tienda: el Dev Dashboard es el camino oficial para la integración propia de una tienda.

En consecuencia, **las credenciales de Shopify son del tenant** y viven cifradas en su integración. No hay credenciales de nivel app (Rails credentials) en uso: el mecanismo queda para un proveedor con una app única de OneStock (Mercado Libre, en pausa).

### La plantilla declara cómo se autentica

`services.auth_strategy` + `services.auth_config`. El adaptador delega en la estrategia (`Integrations::AuthHeaders`) en lugar de iterar `credentials`:

| Estrategia | Qué hace |
|---|---|
| `bearer` (default) | El comportamiento de siempre: `access_token` como `Authorization: Bearer`, el resto de las claves como headers literales |
| `oauth_client_credentials` | Pide el token con el `client_id`/`client_secret` de la integración (`Integrations::RequestClientCredentialsToken`), lo cachea hasta `expires_in` y lo manda en el header que declara `auth_config` (`X-Shopify-Access-Token`, sin prefijo) |

La autenticación sale siempre de la plantilla **conectada**, no de la que se ejecuta: una plantilla hija usa la cuenta y el token de su madre.

Sobre el token (`Integrations::EnsureAccessToken`):

- Se renueva **5 minutos antes** de vencer, para que un request no salga con un token que expira en el camino.
- La renovación corre con **la fila de la integración bloqueada** (`with_lock`), y adentro se vuelve a mirar: el que esperó el lock puede encontrarse con que otro worker ya lo renovó.
- Ante un **401** con un token que parecía vigente, el adaptador pide uno nuevo **una sola vez** y reintenta.
- Si cambia una credencial, el token cacheado se descarta: se obtuvo con la anterior.
- Ningún error incluye el body del proveedor ni los datos del pedido, que llevan el secreto. Del rechazo de Shopify se conserva sólo el código (`app_not_installed`).

Sólo se implementaron las dos estrategias que usa la demo. `oauth_refresh` (con refresh token de uso único) y `login` quedan para cuando un proveedor las pida.

### La plantilla declara qué datos pide

`services.credential_fields` y `services.setting_fields`: una lista de `{ key, label, required, format? }`. Es **la única fuente de verdad** del formulario de conexión del front y de la validación del alta (`Integrations::ApplyDeclaredFields`). Agregar un campo a la plantilla desde el backoffice lo hace aparecer en el formulario sin tocar código.

Reglas del alta (`PUT /api/v1/integrations/:service_id`):

- Un campo no declarado, uno requerido faltante o un valor que no cumple su `format` responden **422**.
- Un secreto que llega vacío **no se cambia**: el formulario nunca los precarga, así que «vacío» quiere decir «dejalo como está».
- Un setting que llega vacío **se borra**: ése sí se precarga, y vaciarlo es deliberado.
- Sin `is_active`, se conserva el que tenía: editar la configuración no reactiva una integración pausada.
- Las plantillas que no declaran campos conservan el contrato de siempre (`credentials` reemplaza entero lo que había).

El 422 respeta ADR-015: `error` siempre está, y `fields` viaja **junto** a él como dato para recuperarse, igual que `current_version` en el 409 del locking. Cada campo lleva un código, no un texto (`required`, `invalid_format`, `unknown`), y el front lo traduce:

```json
{ "error": "Invalid integration data",
  "fields": { "settings.shop_domain": ["invalid_format"], "credentials.client_secret": ["required"] } }
```

Desconectar (`DELETE /api/v1/integrations/:service_id`) desactiva la integración y **borra sus secretos**, pero conserva los settings y los productos vinculados, para reconectar la misma cuenta sin volver a mapear.

### Plantillas de operación

`services.parent_service_id` + `services.operation`. Una plantilla **hija** es otra llamada al mismo proveedor con la misma cuenta: no es conectable (no aparece en el listado, y conectarla directamente da 404) y se ejecuta con la integración de su madre (`HttpAdapter.new(company_integration:, service: hija)`, que ya existía para el tracking de ADR-014). `Service#template_for(operation)` la resuelve.

Las operaciones de Shopify son:

| Hija | Operación | Para qué |
|---|---|---|
| `Shopify - Conexión` | `connection_test` | «Probar conexión». Además completa los settings declarados que la empresa no cargó y el proveedor sabe (la ubicación de stock) |
| `Shopify - Variante` | `product_lookup` | Confirmar que un id de variante existe al vincularlo, y traer su `inventory_item_id` |
| `Shopify - Buscar por SKU` | `product_search` | Vincular un producto buscando la variante con su mismo SKU |

La madre es la que se conecta y la que publica el stock.

`tracking_service` (ADR-014) y `quote_service` (TESIS-131) son el mismo concepto con otra forma, una FK por rol. No se migran: el patrón de operación es para lo nuevo.

### Transporte: GraphQL y valores armados

- `request_format: graphql` manda `{ query: body_template, variables }`, donde las variables son el resultado del `request_mapper`. El documento viaja tal cual: los valores dinámicos van siempre como variables, nunca interpolados en el documento.
- Algunas APIs contestan un error con **HTTP 200**. El adaptador lo detecta en `fetch`, así lo ven todos los caminos (`Integrations::DetectResponseErrors`), de dos fuentes: un `errors` no vacío en la raíz de una respuesta GraphQL, y la ruta que declara `services.error_path` (`data.inventorySetQuantities.userErrors`).
- El valor de una entrada del `request_mapper` puede leer un setting (`settings.location_id`) o armar un texto con variables (`gid://shopify/ProductVariant/{{external_id}}`, porque GraphQL no concatena strings). No es un motor de plantillas: sólo reemplaza variables, y una plantilla a la que le falta alguna no se envía a medias.

### Publicar el stock sólo donde se sabe

El sync saliente publica en `Service#stock_template`: la propia plantilla si mapea `available_quantity`, o su hija `stock`. Si ninguna sabe, el canal no recibe nada. Así se cierra el caso de la plantilla de órdenes de Mercado Libre, que recibía un stock que no sabía procesar.

- **Referencias externas.** `product_mappings.external_refs` (jsonb) guarda los identificadores extra que necesita el canal. Shopify vende por variante (`external_product_id`, lo que trae la venta) pero publica el stock por inventory item. El sync las suma al payload.
- **Idempotencia.** Shopify exige una clave de idempotencia en `inventorySetQuantities` desde 2026-04. El sync genera una por intento: fijar una cantidad absoluta es idempotente por naturaleza, así que un reintento con otra clave no hace daño. La mutación usa `changeFromQuantity: null`, sin compare-and-set, porque el OMS es la fuente de verdad del stock.
- **Push inicial al vincular.** Vincular un producto publica su stock sólo en el canal recién vinculado, no en todos.

### Vincular consulta al canal dentro del request

`POST /api/v1/products/:product_id/mappings` le pregunta al canal si la publicación existe (`product_lookup`) o la busca por SKU (`product_search`) antes de crear el vínculo:

- Si la publicación no existe, responde **422**.
- Si hay dos variantes con el mismo SKU, responde **422**: no elige.
- Si el SKU es distinto, crea el vínculo pero **avisa** (`warnings`), porque 1 producto = 1 SKU es regla del MVP.
- Si el canal no contesta, responde **502**.

La consulta corre dentro del request, con el timeout de 4 s de la cotización. Es el tercer caso sincrónico que `docs/guidelines/architecture.md` §7.4 anticipaba. Se toma por el mismo argumento de producto (el usuario está esperando saber si el vínculo es válido) y porque es una sola lectura sin efectos en el proveedor. El push que sigue va a un job.

## Alternativas consideradas

### Todo en `credentials`

Era lo que había. Se descartó porque obliga a descifrar para mostrar un dominio, impide que la plantilla lo interpole sin tratarlo como secreto y mezcla lo que el front puede precargar con lo que no debe volver nunca.

### Una app única de OneStock con authorization code (modelo de app pública)

Es el modelo «de libro» de un SaaS: la empresa toca «Conectar con Shopify», autoriza y el sistema guarda un token por tienda. Se descartó **por ahora** por costo, no por diseño: exige el flujo de instalación (redirect, callback, validación del `state`) y la aprobación de Shopify para instalar la app en tiendas de otras organizaciones. Queda como trabajo futuro. El mecanismo de credenciales de nivel app es el que usaría.

### Una clase Ruby por proveedor

Rompe el principio de TESIS-31: la diferencia entre proveedores tiene que vivir en datos (plantilla, estrategia, campos), no en código. Con este diseño, Shopify no tiene una sola línea propia en `app/`.

### Una FK por rol para cada llamada auxiliar

Como `tracking_service` (`lookup_service_id`, `connection_test_service_id`...). Una migración y una validación por rol. Shopify solo ya necesitaba tres.

### Validar la publicación en un job al vincular

Respeta la regla de «llamadas externas en un job», pero el usuario se entera de un id equivocado recién cuando el sync falla, y para mostrarlo haría falta un estado nuevo en el vínculo. Para una sola lectura, el costo no se justifica.

## Consecuencias

- ✅ Shopify funciona contra una tienda de prueba real sin código específico: conexión, prueba, vínculo por id o por SKU y publicación del stock
- ✅ Cualquier empresa puede conectar su propia tienda: el diseño es multi-tenant de punta a punta, y nada del proveedor queda atado a la organización del equipo
- ✅ Las integraciones que ya existían (Mercado Libre, Tiendanube, Andreani, Correo) siguen igual: `bearer` es el default y las plantillas sin campos declarados conservan su alta
- ✅ El formulario de conexión del front se arma solo con lo que declara la plantilla
- ✅ Ningún secreto sale de la API, y un error del proveedor no lo filtra
- ⚠️ La empresa tiene que crear su app en el Dev Dashboard de Shopify: es más fricción que un botón «Conectar»
- ⚠️ Una sola cuenta por proveedor y por empresa (índice único `company_id + service_id`)
- ⚠️ Nada impide todavía conectar la misma tienda a dos empresas: cada venta entraría en las dos. Hace falta una regla de unicidad sobre el setting que identifica la cuenta, antes de habilitar las ventas entrantes
- ⚠️ El token se renueva con la fila bloqueada durante el pedido HTTP (hasta 10 s)
- ⚠️ La versión de la API de Shopify vive en la URI de la plantilla: hay que actualizarla desde el backoffice antes de que venza (unos 12 meses)

## Referencias

- [ADR-010](ADR-010-ingesta-de-ordenes-de-webhooks.md): la integración por plantilla que las plantillas de operación resuelven
- [ADR-014](ADR-014-pull-tracking-de-couriers.md): una plantilla que se ejecuta con la cuenta de otra
- [ADR-015](ADR-015-convencion-de-respuesta-de-la-api.md): la forma del error, que `fields` acompaña
- `docs/guidelines/architecture.md` §7.4: las llamadas sincrónicas a proveedores
- Shopify: [client credentials grant](https://shopify.dev/docs/apps/build/authentication-authorization/access-tokens/client-credentials-grant), [`inventorySetQuantities`](https://shopify.dev/docs/api/admin-graphql/latest/mutations/inventorySetQuantities)

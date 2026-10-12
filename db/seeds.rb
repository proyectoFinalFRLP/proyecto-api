# This file should ensure the existence of records required to run the application in every environment
# (production, development, test). The code here must be idempotent so it can be executed at any point
# in every environment. Load it with `bin/rails db:seed` (or `db:setup`).
#
# Convención del proyecto: cada vez que se agrega o modifica un modelo, se deben agregar seeds
# representativos para ese modelo. Ver docs/guidelines/seeds.md.
#
# Multi-tenancy: todos los datos viven bajo una Company (tenant). Ver docs/guidelines/multi-tenancy-rls.md.

# ---------------------------------------------------------------------------
# TESIS-25 — Core & Tenancy: Companies, Users, Warehouses
# ---------------------------------------------------------------------------

companies = [
  {
    name: 'Distribuidora Norte S.A.',
    tax_id: '30-11111111-1',
    slug: 'norte',
    is_active: true,
    # Norte tiene integraciones habilitadas y Sur no: es el flag que el frontend
    # usa para mostrar u ocultar la sección, y lo que se demuestra en la demo.
    features: { 'integrations' => true },
    # Norte **no** declara colores a propósito: es el tenant que se queda con la
    # paleta canónica del design system. Sin esto los dos tenants pisarían la
    # marca del producto y el camino de fallback —el que corre para toda empresa
    # que compra sin branding propio— no se vería nunca, ni en la demo ni en
    # desarrollo local, donde `norte` es el tenant por defecto.
    branding: {
      'display_name' => 'Distribuidora Norte',
      'logo_url' => nil,
      'tagline' => 'Logística del norte'
    },
    users: [
      { email: 'admin@norte.com', password: 'password123' },
      { email: 'operador@norte.com', password: 'password123' }
    ],
    warehouses: [
      # `capacity` es la capacidad declarada (TESIS-162): la barra de ocupación
      # del detalle de producto compara lo guardado contra este techo. El
      # satélite va sin declarar a propósito, para que se vea el caso en que la
      # pantalla no dibuja la barra porque nadie cargó el número.
      { name: 'Depósito Central', zip_code: '1900', address: 'Av. 7 N° 1234, La Plata',
        capacity: 6_000 },
      { name: 'Depósito Satélite Norte', zip_code: '1602', address: 'Calle 25 N° 456, Florida' }
    ]
  },
  {
    name: 'Comercial Sur S.R.L.',
    tax_id: '30-22222222-2',
    slug: 'sur',
    is_active: true,
    features: { 'integrations' => false },
    branding: {
      'display_name' => 'Comercial Sur',
      # Demo: Sur tiene que distinguirse de Norte a primera vista. Naranja
      # industrial (identidad de herramienta, acorde a su catálogo) contra el
      # celeste del DS que Norte hereda, y su portal en modo claro contra el
      # dark canónico de Norte. `theme_mode` es el default con el que arranca
      # el frontend; el toggle del usuario siempre gana sobre él.
      'primary_color' => '#F97316',
      'accent_color' => '#FB923C',
      'logo_url' => nil,
      'tagline' => 'Distribución para el sur',
      'theme_mode' => 'light'
    },
    users: [
      { email: 'admin@sur.com', password: 'password123' },
      { email: 'deposito@sur.com', password: 'password123' }
    ],
    warehouses: [
      { name: 'Depósito Sur', zip_code: '8000', address: 'Av. Colón N° 789, Bahía Blanca' }
    ]
  },
  {
    # Tenant inactivo: representa una empresa dada de baja (is_active: false).
    name: 'Importadora Vieja S.A. (inactiva)',
    tax_id: '30-33333333-3',
    slug: 'importadora',
    is_active: false,
    features: { 'integrations' => false },
    branding: {
      'display_name' => 'Importadora Vieja',
      'primary_color' => '#6D4C41',
      'accent_color' => '#A1887F',
      'logo_url' => nil,
      'tagline' => 'Empresa dada de baja'
    },
    users: [
      { email: 'admin@vieja.com', password: 'password123' }
    ],
    warehouses: [
      { name: 'Depósito en Liquidación', zip_code: '5000', address: 'Bv. San Juan N° 100, Córdoba' }
    ]
  }
]

companies.each do |attrs|
  company = Company.find_or_create_by!(tax_id: attrs[:tax_id]) do |c|
    c.name = attrs[:name]
    c.is_active = attrs[:is_active]
    c.slug = attrs[:slug]
    c.features = attrs[:features]
    c.branding = attrs[:branding]
  end

  # El bloque de find_or_create_by! sólo corre en el alta, así que una base que
  # ya tenía estas companies (cualquiera creada antes de TESIS-120) se quedaría
  # sin slug ni branding. Reasignar acá mantiene el seed idempotente y además
  # convergente: correrlo dos veces deja el mismo estado, y correrlo sobre una
  # base vieja la actualiza.
  company.update!(
    name: attrs[:name],
    is_active: attrs[:is_active],
    slug: attrs[:slug],
    features: attrs[:features],
    branding: attrs[:branding]
  )

  attrs[:users].each do |user_attrs|
    User.find_or_create_by!(email: user_attrs[:email]) do |u|
      u.password = user_attrs[:password]
      u.company = company
    end
  end

  attrs[:warehouses].each do |warehouse_attrs|
    warehouse = Warehouse.find_or_create_by!(name: warehouse_attrs[:name], company: company) do |w|
      w.zip_code = warehouse_attrs[:zip_code]
      w.address = warehouse_attrs[:address]
    end

    # Fuera del bloque de creación, por el mismo motivo que la categoría de los
    # productos: así las bases ya sembradas antes de que existiera la columna
    # también quedan con capacidad. El `if` no pisa una cargada a mano.
    if warehouse.capacity.nil? && warehouse_attrs[:capacity]
      warehouse.update!(capacity: warehouse_attrs[:capacity])
    end
  end
end

# ---------------------------------------------------------------------------
# TESIS-29 — Backoffice: administrador inicial del panel /admin
# ---------------------------------------------------------------------------

AdminUser.find_or_create_by!(email: 'admin@backoffice.com') do |admin|
  admin.password = 'admin123'
end

# ---------------------------------------------------------------------------
# TESIS-28 — Integraciones: Services (plantillas globales) + CompanyIntegrations
# ---------------------------------------------------------------------------

services = [
  {
    # Plantilla de órdenes entrantes: GET sin body, no transmite stock. El
    # sync saliente (TESIS-35) para los productos mapeados en este canal usa
    # la plantilla 'Mercado Libre - Stock' de abajo, no ésta.
    #
    # El response_mapper es el que usa la ingesta de webhooks (TESIS-43) para
    # traducir la venta: las entradas con el marcador `[]` describen la lista de
    # ítems ("por cada elemento de order_items, el id externo está en item.id").
    service_name: 'Mercado Libre',
    type: 'ecommerce',
    uri: 'https://api.mercadolibre.com/orders',
    http_method: 'GET',
    request_mapper: { 'destination.street' => 'customer_address' },
    response_mapper: {
      'id' => 'external_order_id',
      'status' => 'status',
      'buyer.nickname' => 'customer_name',
      'buyer.billing_info.doc_number' => 'customer_document',
      'shipping.receiver_address.address_line' => 'customer_address',
      'shipping.receiver_address.zip_code' => 'customer_zip_code',
      'order_items[].item.id' => 'external_product_id',
      'order_items[].quantity' => 'quantity',
      'order_items[].unit_price' => 'unit_price'
    },
    request_value_mapper: {},
    response_value_mapper: { 'pagado' => 'paid', 'paid' => 'paid' }
  },
  {
    # Plantilla de actualización de stock de Mercado Libre: es la que consume
    # el sync saliente (TESIS-35) para los productos mapeados en este canal.
    # PUT /items/:item_id es la forma real de la API de ML para stock.
    service_name: 'Mercado Libre - Stock',
    type: 'ecommerce',
    uri: 'https://api.mercadolibre.com/items/:external_id',
    http_method: 'PUT',
    request_mapper: { 'available_quantity' => 'available_quantity' },
    response_mapper: {},
    request_value_mapper: {},
    response_value_mapper: {}
  },
  {
    # Plantilla de actualización de stock: es la que consume el sync saliente
    # (TESIS-35). El id externo del ProductMapping se interpola en la URI y el
    # request_mapper traduce la clave interna available_quantity.
    service_name: 'Tiendanube',
    type: 'ecommerce',
    uri: 'https://api.tiendanube.com/v1/products/:external_id/variants',
    http_method: 'PUT',
    request_mapper: { 'stock' => 'available_quantity' },
    response_mapper: { 'id' => 'external_product_id' },
    request_value_mapper: {},
    response_value_mapper: {}
  },
  # Plantilla de COTIZACIÓN de Andreani (TESIS-46). Va aparte de la de despacho
  # porque son dos endpoints distintos del proveedor, igual que 'Mercado Libre'
  # y 'Mercado Libre - Stock'. El motor la reconoce porque su response_mapper
  # declara `shipping_cost` (ver Service#quotes_shipping?).
  {
    service_name: 'Andreani - Cotización',
    type: 'courier',
    uri: 'https://apis.andreani.com/v1/tarifas',
    http_method: 'POST',
    request_mapper: {
      'origen.postal.codigoPostal' => 'origin_zip_code',
      'destino.postal.codigoPostal' => 'destination_zip_code',
      'bultos.0.kilos' => 'total_weight'
    },
    response_mapper: {
      'tarifaConIva.total' => 'shipping_cost',
      'plazoEntrega' => 'estimated_days'
    },
    request_value_mapper: {},
    response_value_mapper: {}
  },
  {
    # Una misma plantilla describe dos payloads distintos del mismo proveedor: la
    # respuesta síncrona de POST /ordenes-de-envio (numeroDeEnvio del despacho) y
    # el push asíncrono de tracking que Andreani manda al webhook de couriers
    # (TESIS-48). Es la misma convención de ADR-010: el Service modela "cómo
    # habla este proveedor", no "para qué endpoint propio es cada dato" —
    # separar la plantilla en dos duplicaría URI y credenciales sin necesidad,
    # cuando lo único que cambia es qué ruta del payload se lee en cada caso.
    service_name: 'Andreani',
    type: 'courier',
    uri: 'https://apis.andreani.com/v2/ordenes-de-envio',
    http_method: 'POST',
    request_mapper: { 'destino.postal.codigoPostal' => 'customer_zip_code' },
    response_mapper: {
      'bulto.0.numeroDeEnvio' => 'tracking_number',
      # Ruta de la etiqueta en la respuesta del despacho (TESIS-47): el PDF que
      # se imprime y se pega al paquete. Es lo que hace que esta plantilla sirva
      # para despachar y no sólo para leer el push de tracking.
      'etiqueta.url' => 'shipping_label_url',
      # Rutas del push de tracking (TESIS-48): Shipments::TranslateTrackingPayload
      # las lee crudas (sin pasar por response_value_mapper) para conservar el
      # external_status tal cual lo mandó el courier.
      'evento.estado' => 'external_status',
      'evento.fecha' => 'occurred_at',
      'evento.sucursal' => 'description'
    },
    request_value_mapper: {},
    response_value_mapper: {
      'EnPreparacion' => 'ready_to_ship',
      'EnDistribucion' => 'in_transit',
      'EntregadoAlDestinatario' => 'delivered',
      'Entregado' => 'delivered'
    }
  },
  # Courier SIN webhooks de tracking (TESIS-49): su estado sólo se conoce
  # preguntándole. Despacha con esta plantilla, igual que Andreani, pero no
  # mapea rutas de push: no hay push que leer.
  {
    service_name: 'Correo Argentino',
    type: 'courier',
    uri: 'https://api.correoargentino.com.ar/micorreo/v1/shipping/import',
    http_method: 'POST',
    request_mapper: { 'recipient.address.postalCode' => 'destination_zip_code' },
    response_mapper: { 'trackingNumber' => 'tracking_number' },
    request_value_mapper: {},
    response_value_mapper: {}
  },
  # Plantilla de CONSULTA de tracking de Correo Argentino (TESIS-49). La URI
  # interpola el número de seguimiento: una consulta por envío (ver
  # Service#answers_tracking?). La vincula a 'Correo Argentino' el bloque de
  # tracking_service más abajo.
  {
    service_name: 'Correo Argentino - Seguimiento',
    type: 'courier',
    uri: 'https://api.correoargentino.com.ar/micorreo/v1/shipping/tracking/:tracking_number',
    http_method: 'GET',
    request_mapper: {},
    response_mapper: {
      'ultimoEvento.estado' => 'external_status',
      'ultimoEvento.fecha' => 'occurred_at',
      'ultimoEvento.planta' => 'description'
    },
    request_value_mapper: {},
    response_value_mapper: {
      'PREIMPOSICION' => 'ready_to_ship',
      'EN TRANSITO' => 'in_transit',
      'EN DISTRIBUCION' => 'in_transit',
      'ENTREGADO' => 'delivered'
    }
  },
  # Shopify (TESIS-138): la madre es la integración que la empresa conecta.
  # Cada empresa carga el client_id y el client_secret de SU propia app del
  # Dev Dashboard (opción B: la app y la tienda están en la organización de la
  # empresa, que es lo que exige el grant client_credentials) y el dominio de
  # su tienda. El token lo obtiene y renueva el sistema.
  #
  # La versión de la API vive en la URI: se actualiza desde el backoffice sin
  # deploy. Shopify mantiene cada versión unos 12 meses.
  #
  # La madre publica el stock (la usa el sync saliente, TESIS-35): fija la
  # cantidad `available` del inventory item en la ubicación de la cuenta. Es un
  # valor absoluto, así que `changeFromQuantity: null` (sin compare-and-set: el
  # OMS es la fuente de verdad). Desde 2026-04 Shopify exige la clave de
  # idempotencia, que el sync genera por intento.
  {
    service_name: 'Shopify',
    type: 'ecommerce',
    uri: 'https://:shop_domain/admin/api/2026-07/graphql.json',
    http_method: 'POST',
    request_format: 'graphql',
    body_template: <<~GRAPHQL.squish,
      mutation SetStock($inventoryItemId: ID!, $locationId: ID!, $quantity: Int!,
                        $idempotencyKey: String!) {
        inventorySetQuantities(input: {
          name: "available", reason: "correction",
          referenceDocumentUri: "logistics://onestock/stock-sync",
          quantities: [{ inventoryItemId: $inventoryItemId, locationId: $locationId,
                         quantity: $quantity, changeFromQuantity: null }]
        }) @idempotent(key: $idempotencyKey) {
          userErrors { code field message }
        }
      }
    GRAPHQL
    error_path: 'data.inventorySetQuantities.userErrors',
    auth_strategy: 'oauth_client_credentials',
    auth_config: {
      'token_url' => 'https://:shop_domain/admin/oauth/access_token',
      'token_header' => 'X-Shopify-Access-Token',
      'token_prefix' => ''
    },
    credential_fields: [
      { 'key' => 'client_id', 'label' => 'Client ID', 'required' => true },
      { 'key' => 'client_secret', 'label' => 'Client secret', 'required' => true }
    ],
    setting_fields: [
      { 'key' => 'shop_domain', 'label' => 'Dominio de la tienda', 'required' => true,
        'format' => '\A[a-z0-9][a-z0-9-]*\.myshopify\.com\z' },
      { 'key' => 'location_id', 'label' => 'Ubicación de stock', 'required' => false }
    ],
    request_mapper: {
      'inventoryItemId' => 'inventory_item_id',
      'locationId' => 'settings.location_id',
      'quantity' => 'available_quantity',
      'idempotencyKey' => 'idempotency_key'
    },
    # Las ventas llegan por el webhook `orders/create`, que trae la orden
    # completa: la ingesta (TESIS-43) la traduce con este mapper. El cliente y
    # la dirección salen de la dirección de envío, que Shopify sólo manda si la
    # app tiene acceso a los datos protegidos de cliente.
    response_mapper: {
      'id' => 'external_order_id',
      'financial_status' => 'status',
      'shipping_address.name' => 'customer_name',
      'shipping_address.address1' => 'customer_address',
      'shipping_address.zip' => 'customer_zip_code',
      'shipping_address.city' => 'customer_city',
      'shipping_address.province' => 'customer_province',
      'line_items[].variant_id' => 'external_product_id',
      'line_items[].quantity' => 'quantity',
      'line_items[].price' => 'unit_price'
      # `requires_shipping` NO se mapea, y por eso toda venta que entra por acá
      # queda como envío (ProcessWebhookOrder asume `true` cuando la plantilla
      # no lo declara). Shopify no manda un booleano único: lo más cercano es
      # la ausencia de `shipping_lines`, que el formato de la plantilla
      # —camino de origen a campo— no sabe expresar. Un canal que quiera
      # registrar retiros tiene que declararlo en su response_mapper; hasta
      # entonces el retiro es sólo para el alta manual.
    },
    request_value_mapper: {},
    # Estados de pago de Shopify que no se llaman igual en el OMS. `paid` y
    # `pending` coinciden, y cualquier otro entra como pendiente.
    response_value_mapper: { 'authorized' => 'pending', 'partially_paid' => 'pending',
                             'voided' => 'cancelled' },
    # Shopify firma cada webhook con el client secret de la app que lo
    # registró: como cada empresa conecta la suya, el secreto es el de su
    # integración.
    webhook_config: { 'signature' => 'hmac_sha256_base64',
                      'signature_header' => 'X-Shopify-Hmac-SHA256',
                      'secret_key' => 'client_secret' }
  },
  # «Probar conexión» de Shopify: plantilla hija, se ejecuta con la cuenta de la
  # madre. Trae el nombre de la tienda y la primera ubicación, que completa el
  # setting `location_id` si la empresa no lo cargó.
  {
    service_name: 'Shopify - Conexión',
    parent_service_name: 'Shopify',
    operation: 'connection_test',
    type: 'ecommerce',
    uri: 'https://:shop_domain/admin/api/2026-07/graphql.json',
    http_method: 'POST',
    request_format: 'graphql',
    body_template: '{ shop { name } locations(first: 5) { nodes { id name } } }',
    request_mapper: {},
    response_mapper: {
      'data.shop.name' => 'account_name',
      'data.locations.nodes.0.id' => 'location_id'
    },
    request_value_mapper: {},
    response_value_mapper: {}
  },
  # Vincular por id de variante: confirma que existe y trae su inventory item,
  # que es con lo que Shopify publica el stock. `node` en vez de una consulta
  # por variante: es la forma estable de pedir cualquier objeto por su GID.
  {
    service_name: 'Shopify - Variante',
    parent_service_name: 'Shopify',
    operation: 'product_lookup',
    type: 'ecommerce',
    uri: 'https://:shop_domain/admin/api/2026-07/graphql.json',
    http_method: 'POST',
    request_format: 'graphql',
    body_template: 'query Variant($id: ID!) { node(id: $id) { ... on ProductVariant { ' \
                   'legacyResourceId sku inventoryItem { id } product { title } } } }',
    request_mapper: { 'id' => 'gid://shopify/ProductVariant/{{external_id}}' },
    response_mapper: {
      'data.node.legacyResourceId' => 'external_product_id',
      'data.node.sku' => 'external_sku',
      'data.node.product.title' => 'external_title',
      'data.node.inventoryItem.id' => 'inventory_item_id'
    },
    request_value_mapper: {},
    response_value_mapper: {}
  },
  # Vincular por SKU: busca la variante con el SKU del producto. Pide dos
  # resultados para detectar un SKU repetido en la tienda (`ambiguous_match`).
  {
    service_name: 'Shopify - Buscar por SKU',
    parent_service_name: 'Shopify',
    operation: 'product_search',
    type: 'ecommerce',
    uri: 'https://:shop_domain/admin/api/2026-07/graphql.json',
    http_method: 'POST',
    request_format: 'graphql',
    body_template: 'query BySku($query: String!) { productVariants(first: 2, query: $query) { ' \
                   'nodes { legacyResourceId sku inventoryItem { id } product { title } } } }',
    request_mapper: { 'query' => 'sku:{{sku}}' },
    response_mapper: {
      'data.productVariants.nodes.0.legacyResourceId' => 'external_product_id',
      'data.productVariants.nodes.0.sku' => 'external_sku',
      'data.productVariants.nodes.0.product.title' => 'external_title',
      'data.productVariants.nodes.0.inventoryItem.id' => 'inventory_item_id',
      'data.productVariants.nodes.1.legacyResourceId' => 'ambiguous_match'
    },
    request_value_mapper: {},
    response_value_mapper: {}
  },
  # Registrar el webhook de ventas (Integrations::RegisterWebhook): primero se
  # busca si la tienda ya avisa a esta dirección, para no duplicar la
  # suscripción, y si no se crea. La dirección la arma el sistema.
  {
    service_name: 'Shopify - Buscar webhook',
    parent_service_name: 'Shopify',
    operation: 'webhook_lookup',
    type: 'ecommerce',
    uri: 'https://:shop_domain/admin/api/2026-07/graphql.json',
    http_method: 'POST',
    request_format: 'graphql',
    body_template: 'query Webhook($uri: String!) { webhookSubscriptions(first: 1, uri: $uri, ' \
                   'topics: [ORDERS_CREATE]) { nodes { id } } }',
    request_mapper: { 'uri' => 'webhook_url' },
    response_mapper: { 'data.webhookSubscriptions.nodes.0.id' => 'webhook_subscription_id' },
    request_value_mapper: {},
    response_value_mapper: {}
  },
  {
    service_name: 'Shopify - Webhook',
    parent_service_name: 'Shopify',
    operation: 'webhook_subscription',
    type: 'ecommerce',
    uri: 'https://:shop_domain/admin/api/2026-07/graphql.json',
    http_method: 'POST',
    request_format: 'graphql',
    body_template: 'mutation Subscribe($uri: String!) { webhookSubscriptionCreate(' \
                   'topic: ORDERS_CREATE, webhookSubscription: { uri: $uri, format: JSON }) { ' \
                   'webhookSubscription { id } userErrors { field message } } }',
    error_path: 'data.webhookSubscriptionCreate.userErrors',
    request_mapper: { 'uri' => 'webhook_url' },
    response_mapper: {
      'data.webhookSubscriptionCreate.webhookSubscription.id' => 'webhook_subscription_id'
    },
    request_value_mapper: {},
    response_value_mapper: {}
  }
]

services.each do |attrs|
  # El vínculo con la madre se resuelve después del loop: la madre recién existe
  # cuando terminó de crearse.
  attrs = attrs.except(:parent_service_name)
  service = Service.find_or_create_by!(service_name: attrs[:service_name]) do |s|
    s.assign_attributes(attrs)
  end

  # find_or_create_by! no toca un registro que ya existe: una base sembrada antes
  # de ampliar una plantilla (p.ej. el push de tracking de Andreani, TESIS-48)
  # se quedaría con los mappers viejos para siempre. Reaplicar sólo
  # Service::MAPPER_FIELDS mantiene la carga idempotente sin pisar el resto de
  # la plantilla (uri, http_method, type) por si se editó a mano desde el
  # backoffice, y sin tocar otras plantillas: cada vuelta sólo actualiza su
  # propio service_name.
  # La configuración de conexión (auth, transporte, campos declarados) se
  # reaplica con el mismo criterio: si no, una base sembrada antes de TESIS-138
  # se quedaba con plantillas que no saben autenticarse.
  service.update!(attrs.slice(*(Service::MAPPER_FIELDS + Service::CONNECTION_FIELDS).map(&:to_sym)))
end

# Las plantillas de siempre se autentican con un token fijo (`bearer`): se
# declara ese campo para que el formulario de conexión del front sepa pedirlo.
Service.connectable.where(auth_strategy: 'bearer', credential_fields: []).find_each do |service|
  service.update!(credential_fields: [{ 'key' => 'access_token', 'label' => 'Access token',
                                        'required' => true }])
end

# Plantillas de operación: cada hija apunta a su madre (TESIS-138).
services.select { |attrs| attrs[:parent_service_name] }.each do |attrs|
  parent = Service.find_by!(service_name: attrs[:parent_service_name])
  Service.find_by!(service_name: attrs[:service_name]).update!(parent_service: parent)
end

# Correo Argentino no empuja el tracking: se le pregunta con su plantilla de
# seguimiento (TESIS-49). El vínculo va aparte del loop de arriba porque
# referencia a otra plantilla, que recién existe cuando el loop terminó.
correo_service = Service.find_by(service_name: 'Correo Argentino')
correo_tracking = Service.find_by(service_name: 'Correo Argentino - Seguimiento')
correo_service&.update!(tracking_service: correo_tracking) if correo_tracking

# Andreani cotiza con una plantilla y despacha con otra (TESIS-131): el vínculo
# es lo que deja despachar la opción que el operador eligió al cotizar.
andreani_dispatch = Service.find_by(service_name: 'Andreani')
andreani_quote = Service.find_by(service_name: 'Andreani - Cotización')
andreani_dispatch&.update!(quote_service: andreani_quote) if andreani_quote

# Vincula la primera empresa activa con Mercado Libre (integración de ejemplo).
# La variable ml_integration la consume la orden de webhook de la sección TESIS-40
# más abajo (sin ella, `db:seed` cortaba con NameError: undefined ml_integration).
first_company = Company.find_by(tax_id: '30-11111111-1')
ml_service = Service.find_by(service_name: 'Mercado Libre')
ml_integration =
  if first_company && ml_service
    CompanyIntegration.find_or_create_by!(company: first_company, service: ml_service) do |ci|
      ci.credentials = { 'access_token' => 'DEMO-TOKEN-ML' }
    end
  end

# ---------------------------------------------------------------------------
# TESIS-32 — Catalog: Products, Stock, ProductMappings
# ---------------------------------------------------------------------------

# Cada fila de stock que se crea acá dispara el sync saliente (TESIS-35). Sobre
# datos de demo no hay nada que propagar —las URLs de los servicios son
# ficticias— y encolar exigiría tener creada la base de la cola, que no todos
# los entornos tienen al correr los seeds: se descartan los encolados.
ActiveJob::Base.queue_adapter = :test

norte_company = Company.find_by(tax_id: '30-11111111-1')
sur_company = Company.find_by(tax_id: '30-22222222-2')

if norte_company
  # Products de Distribuidora Norte
  celular = Product.find_or_create_by!(sku: 'NOR-001', company: norte_company) do |p|
    p.name = 'Celular Samsung Galaxy A14'
    p.description = 'Smartphone gama media con 128GB de almacenamiento'
    p.weight = 0.200
    p.dimensions = '16.5x7.8x0.9'
  end

  notebook = Product.find_or_create_by!(sku: 'NOR-002', company: norte_company) do |p|
    p.name = 'Notebook Lenovo ThinkPad'
    p.description = 'Notebook empresarial con 16GB RAM y 512GB SSD'
    p.weight = 1.500
    p.dimensions = '32x22x1.8'
  end

  mouse = Product.find_or_create_by!(sku: 'NOR-003', company: norte_company) do |p|
    p.name = 'Mouse Inalámbrico Logitech'
    p.description = 'Mouse ergonómico con sensor óptico'
    p.weight = 0.100
    p.dimensions = '10x6x3'
  end

  # Categorías (TESIS-102). Se asignan fuera del bloque de find_or_create_by!
  # porque ese bloque sólo corre al crear: así las bases ya sembradas antes de
  # que existiera la columna también quedan con categoría. El `if` mantiene la
  # idempotencia y no pisa una categoría cambiada a mano.
  { celular => 'Electronics', notebook => 'Electronics', mouse => 'Electronics' }
    .each { |product, category| product.update!(category: category) if product.category.nil? }

  # Empaque y norma técnica (TESIS-162). Mismo criterio que la categoría: fuera
  # del bloque de creación, y sólo si no están, para no pisar lo cargado a mano.
  { celular => ['Caja individual', 'IRAM 4220'],
    notebook => ['Caja con separadores x4', 'IEC 62368-1'],
    mouse => ['Blíster x12', 'IRAM 2063'] }.each do |product, (packaging, standard)|
    product.update!(packaging: packaging) if product.packaging.nil?
    product.update!(technical_standard: standard) if product.technical_standard.nil?
  end

  # Stock en depósitos de Norte
  central = Warehouse.find_by(company: norte_company, name: 'Depósito Central')
  satelite = Warehouse.find_by(company: norte_company, name: 'Depósito Satélite Norte')

  if central
    Stock.find_or_create_by!(product: celular, warehouse: central) { |s| s.quantity = 50 }
    Stock.find_or_create_by!(product: notebook, warehouse: central) { |s| s.quantity = 20 }
    Stock.find_or_create_by!(product: mouse, warehouse: central) { |s| s.quantity = 100 }
  end

  if satelite
    Stock.find_or_create_by!(product: celular, warehouse: satelite) { |s| s.quantity = 15 }
    Stock.find_or_create_by!(product: mouse, warehouse: satelite) { |s| s.quantity = 30 }
  end

  # Transferencia en vuelo (TESIS-103): unidades que ya salieron del Central y
  # todavía no llegaron al Satélite. No se usa DispatchTransfer porque el stock
  # sembrado arriba ya refleja el saldo posterior al despacho; acá sólo se
  # registra el movimiento para que el catálogo tenga un producto con
  # `in_transit_quantity > 0` y el tab "In Transit" muestre algo real.
  if central && satelite
    StockTransfer.find_or_create_by!(product: notebook, origin_warehouse: central,
                                     destination_warehouse: satelite,
                                     status: 'in_transit') do |t|
      t.company = norte_company
      t.quantity = 5
      t.dispatched_at = 2.days.ago
    end
  end

  # Identity Mapping: vincula productos de Norte con Mercado Libre, usando la
  # integración de la plantilla de stock (la de órdenes no transmite stock).
  ml_stock_service = Service.find_by(service_name: 'Mercado Libre - Stock')
  if ml_stock_service
    ml_stock_integration = CompanyIntegration.find_or_create_by!(
      company: norte_company, service: ml_stock_service
    ) do |ci|
      ci.credentials = { 'access_token' => 'DEMO-TOKEN-ML' }
    end

    # Una base que corrió estas seeds antes de este cambio tiene el mapping
    # viejo apuntando a la integración de órdenes (el síntoma del 🟡-1): se
    # descarta antes de crear el de la integración de stock, para no dejar el
    # producto publicado en dos canales de ML ni duplicar el mapping.
    ProductMapping.joins(:company_integration)
                 .where(company_integrations: { service: ml_service }, product: [celular, notebook])
                 .destroy_all

    ProductMapping.find_or_create_by!(
      product: celular, company_integration: ml_stock_integration
    ) do |pm|
      pm.external_product_id = 'MLA123456789'
      pm.external_price = 149_999.99
    end

    ProductMapping.find_or_create_by!(
      product: notebook, company_integration: ml_stock_integration
    ) do |pm|
      pm.external_product_id = 'MLA987654321'
      pm.external_price = 699_999.50
    end
  end

  # Segundo canal para los mismos productos: un cambio de stock del celular
  # dispara dos llamadas salientes (una por canal), que es el escenario que
  # ejercita el sync de TESIS-35.
  tn_service = Service.find_by(service_name: 'Tiendanube')
  if tn_service
    tn_integration = CompanyIntegration.find_or_create_by!(
      company: norte_company, service: tn_service
    ) do |ci|
      ci.credentials = { 'access_token' => 'DEMO-TOKEN-TN' }
    end

    ProductMapping.find_or_create_by!(
      product: celular, company_integration: tn_integration
    ) do |pm|
      pm.external_product_id = 'TN-55501'
      pm.external_price = 152_999.99
    end

    ProductMapping.find_or_create_by!(
      product: notebook, company_integration: tn_integration
    ) do |pm|
      pm.external_product_id = 'TN-55502'
      pm.external_price = 705_000.00
    end
  end
end

# Las conexiones de Mercado Libre y Tiendanube de Norte son de ejemplo: el token
# es inventado y nunca hablaron con el proveedor. Se conservan porque las órdenes,
# los vínculos y los eventos de ejemplo salen de ellas, pero inactivas: activas,
# la pantalla de integraciones las mostraba como conectadas y cada cambio de
# stock intentaba publicar en ellas y fallaba. Se recorre en vez de crearlas
# inactivas para corregir también una base que ya había corrido las seeds
# (find_or_create_by! no toca una fila que existe).
demo_channel_tokens = %w[DEMO-TOKEN-ML DEMO-TOKEN-TN]
CompanyIntegration.unscoped.where(is_active: true).find_each do |integration|
  credentials = integration.credentials
  next unless credentials.is_a?(Hash) && demo_channel_tokens.include?(credentials['access_token'])

  integration.update!(is_active: false)
end

if sur_company
  # Products de Comercial Sur
  taladro = Product.find_or_create_by!(sku: 'SUR-001', company: sur_company) do |p|
    p.name = 'Taladro Percutor Inalámbrico'
    p.description = 'Taladro a batería 20V con maletín'
    p.weight = 2.300
    p.dimensions = '25x20x8'
  end

  amoladora = Product.find_or_create_by!(sku: 'SUR-002', company: sur_company) do |p|
    p.name = 'Amoladora Angular 4 1/2"'
    p.description = 'Amoladora 800W con disco de corte'
    p.weight = 1.800
    p.dimensions = '30x12x10'
  end

  { taladro => 'Machinery', amoladora => 'Machinery' }
    .each { |product, category| product.update!(category: category) if product.category.nil? }

  # Stock en depósito de Sur
  deposito_sur = Warehouse.find_by(company: sur_company, name: 'Depósito Sur')
  if deposito_sur
    Stock.find_or_create_by!(product: taladro, warehouse: deposito_sur) { |s| s.quantity = 10 }
    Stock.find_or_create_by!(product: amoladora, warehouse: deposito_sur) { |s| s.quantity = 25 }
  end
end

# ---------------------------------------------------------------------------
# TESIS-36 — Webhooks: log crudo de eventos entrantes (auditoría)
# ---------------------------------------------------------------------------

# El payload imita una venta de Mercado Libre y es el que sabe traducir el
# response_mapper de la plantilla. Queda en 'pending': las seeds no encolan
# jobs (el adaptador de cola está en :test más arriba), así que el evento espera
# a que se lo procese a mano —lo que sirve para probar la ingesta de TESIS-43:
#
#   Orders::ProcessWebhookEventJob.perform_now(WebhookLog.unscoped.last.id, <company_id>)
#
# Los ítems del ejemplo no están mapeados contra esta integración a propósito
# (ver el ProductMapping.destroy_all de más arriba: publicar los productos en la
# integración de órdenes le mandaría el stock a la plantilla equivocada), así que
# ese procesamiento termina en 'failed' y en la DLQ. Para verlo terminar bien,
# crear antes el ProductMapping del ítem contra esta integración.
demo_integration = CompanyIntegration.unscoped.first
if demo_integration && WebhookLog.unscoped.none?
  WebhookLog.create!(
    company_id: demo_integration.company_id,
    company_integration: demo_integration,
    headers: { 'HTTP_USER_AGENT' => 'MercadoLibre-Webhook/1.0' },
    payload: {
      'id' => '2000003508419013',
      'status' => 'pagado',
      'buyer' => { 'nickname' => 'COMPRADOR_DEMO',
                   'billing_info' => { 'doc_number' => '20-40234567-8' } },
      'shipping' => { 'receiver_address' => { 'address_line' => 'Av. Rivadavia 1234, CABA',
                                              'zip_code' => '1406' } },
      'order_items' => [
        { 'item' => { 'id' => 'MLA123456789' }, 'quantity' => 1, 'unit_price' => 149_999.99 }
      ]
    },
    status: 'pending'
  )
end

# ---------------------------------------------------------------------------
# TESIS-40 — Orders & OrderItems (base de la épica TESIS-23)
# ---------------------------------------------------------------------------

# Venta manual (offline) de Distribuidora Norte: sin external_order_id (no
# proviene de ningún canal), status 'paid' y cliente con datos completos.
if norte_company
  # Clave de búsqueda alineada al índice único (company_id, external_order_id):
  # external_order_id: nil desambigua órdenes manuales de las de webhook.
  # Las manuales traen ciudad y provincia (TESIS-128); las de webhook, no: la
  # ingesta todavía no las mapea.
  manual_order = Order.find_or_create_by!(
    company: norte_company, external_order_id: nil, customer_name: 'Cliente Mayorista Norte'
  ) do |o|
    o.customer_document = '20-30123456-7'
    o.customer_address = 'Calle 7 N° 890, La Plata'
    o.customer_zip_code = '1900'
    o.customer_city = 'La Plata'
    o.customer_province = 'Buenos Aires'
    o.status = 'paid'
  end

  # Orden originada por webhook (ver TESIS-36): external_order_id presente,
  # vincula la integración de Mercado Libre y sigue 'pending'.
  webhook_order = Order.find_or_create_by!(
    company: norte_company, external_order_id: 'ML-2000003508419013'
  ) do |o|
    o.company_integration = ml_integration if ml_integration
    o.customer_name = 'Comprador Mercado Libre'
    o.customer_document = '20-40234567-8'
    o.customer_address = 'Av. Rivadavia 1234, CABA'
    o.customer_zip_code = '1406'
    o.status = 'pending'
  end

  # Ítems de la venta manual: celular y mouse con unit_price snapshot.
  OrderItem.find_or_create_by!(order: manual_order, product: celular) do |i|
    i.quantity = 2
    i.unit_price = 149_999.99
  end
  OrderItem.find_or_create_by!(order: manual_order, product: mouse) do |i|
    i.quantity = 5
    i.unit_price = 12_500.00
  end

  # Ítems de la orden de webhook: notebook (solo ejemplo, sin mapeo real).
  OrderItem.find_or_create_by!(order: webhook_order, product: notebook) do |i|
    i.quantity = 1
    i.unit_price = 699_999.50
  end
end

# Venta de Norte que el cliente retira en el local (TESIS-162): no entra al
# circuito logístico, así que el detalle no ofrece crearle un envío y la API
# rechaza el alta con 422. Es el caso que distingue «esta orden no lleva envío»
# de «a esta orden le falta el envío», que hasta ahora se veían igual.
if norte_company && celular
  retiro = Order.find_or_create_by!(
    company: norte_company, external_order_id: nil, customer_name: 'Retiro en Mostrador'
  ) do |o|
    o.customer_document = '27-35123456-4'
    o.status = 'paid'
    o.requires_shipping = false
  end

  central = Warehouse.find_by(company: norte_company, name: 'Depósito Central')

  OrderItem.find_or_create_by!(order: retiro, product: celular) do |i|
    i.quantity = 1
    i.unit_price = 285_000.00
    i.warehouse = central
    # El alta real descuenta el stock (`Catalog::DeductStock`); el seed escribe
    # la fila a mano, así que descuenta también. Sin esto la unidad quedaba
    # contada dos veces —en `stocks` y vendida— y el «En depósito» del celular
    # salía uno más alto que el estante.
    Stock.find_by(product: celular, warehouse: central)&.then do |stock|
      stock.update!(quantity: [stock.quantity - 1, 0].max)
    end
  end
end

if sur_company
  # Venta manual de Comercial Sur: cubre el caso borde de una orden sin
  # dirección de envío (retiro en sucursal) y con status 'cancelled'.
  sur_order = Order.find_or_create_by!(
    company: sur_company, external_order_id: nil, customer_name: 'Cliente Minorista Sur'
  ) do |o|
    o.customer_document = '23-40345678-9'
    o.status = 'cancelled'
  end

  OrderItem.find_or_create_by!(order: sur_order, product: taladro) do |i|
    i.quantity = 1
    i.unit_price = 89_999.00
  end
end

# ---------------------------------------------------------------------------
# TESIS-45 — Shipments & ShipmentEvents (base de la épica TESIS-24)
# ---------------------------------------------------------------------------

# Integración de courier Andreani para Distribuidora Norte: la consume el envío
# de la venta manual (se asigna al confirmar el despacho).
andreani_service = Service.find_by(service_name: 'Andreani')
if norte_company && andreani_service
  andreani_integration = CompanyIntegration.find_or_create_by!(
    company: norte_company, service: andreani_service
  ) do |ci|
    ci.credentials = { 'access_token' => 'DEMO-TOKEN-ANDREANI' }
    ci.is_active = true
  end

  # Integración de la plantilla de cotización: es la que consume el motor de
  # TESIS-46 para pedir tarifas antes de elegir operador.
  quote_service = Service.find_by(service_name: 'Andreani - Cotización')
  if quote_service
    CompanyIntegration.find_or_create_by!(company: norte_company, service: quote_service) do |ci|
      ci.credentials = { 'access_token' => 'DEMO-TOKEN-ANDREANI' }
      ci.is_active = true
    end
  end

  # Envío de la venta manual: despachado con Andreani, en tránsito, con bitácora.
  # La clave de búsqueda es la orden: la restricción 1 a 1 garantiza que nunca
  # haya dos envíos para la misma orden.
  if manual_order
    shipped = Shipment.find_or_create_by!(order: manual_order) do |s|
      s.company = norte_company
      s.company_integration = andreani_integration
      s.tracking_number = 'AND-100000001'
      s.shipping_label_url = 'https://apis.andreani.com/labels/AND-100000001.pdf'
      s.status = 'in_transit'
      s.shipping_cost = 12_500.00
    end

    # Bitácora cronológica del envío: el courier reporta el estado crudo
    # (external_status) y el sistema lo normaliza (internal_status).
    [
      { internal_status: 'ready_to_ship',
        external_status: 'En preparación',
        occurred_at: Time.zone.parse('2026-08-10 10:00:00') },
      { internal_status: 'in_transit',
        external_status: 'En distribución',
        occurred_at: Time.zone.parse('2026-08-11 08:30:00') }
    ].each do |event_attrs|
      ShipmentEvent.find_or_create_by!(shipment: shipped, **event_attrs)
    end
  end

  # Envío de la orden de webhook: inicializado (pending) sin courier todavía —
  # la integración se asigna recién al confirmar el despacho (TESIS-47).
  if webhook_order
    Shipment.find_or_create_by!(order: webhook_order) do |s|
      s.company = norte_company
      s.status = 'pending'
    end
  end
end

# Integración de Distribuidora Norte con Correo Argentino: la que despacha y,
# por su plantilla de seguimiento, la que recorre la consulta periódica de
# tracking (TESIS-49). La consulta usa estas mismas credenciales.
if norte_company && correo_service
  CompanyIntegration.find_or_create_by!(company: norte_company, service: correo_service) do |ci|
    ci.credentials = { 'access_token' => 'DEMO-TOKEN-CORREO' }
    ci.is_active = true
  end
end

# La orden cancelada de Comercial Sur queda SIN envío a propósito: una orden
# cancelada nunca se despacha. Cubre el caso borde de orden sin shipment.

# ---------------------------------------------------------------------------
# TESIS-48 — Webhooks: log crudo de push tracking de courier (auditoría)
# ---------------------------------------------------------------------------

# Equivalente al webhook de orden que sembró TESIS-36: un WebhookLog en
# 'pending' listo para disparar a mano en desarrollo el pipeline completo
# (Shipments::ProcessTrackingEventJob → ProcessTrackingUpdate) sin esperar un
# push real de Andreani. El payload sigue las rutas del response_mapper
# ampliado más arriba y apunta al tracking_number del envío ya despachado: al
# procesarlo, 'Entregado' traduce a delivered y el shipment pasa de
# in_transit a delivered.
#
# Guard scopeado a la integración de Andreani (no a WebhookLog.unscoped.none?
# a secas, como en TESIS-36): esa base ya tiene el webhook log de la orden de
# Mercado Libre para cuando se llega acá, así que un chequeo global nunca
# volvería a sembrar éste.
if andreani_integration && shipped &&
   WebhookLog.unscoped.where(company_integration: andreani_integration).none?
  WebhookLog.create!(
    company_id: norte_company.id,
    company_integration: andreani_integration,
    headers: { 'HTTP_USER_AGENT' => 'Andreani-Tracking-Webhook/1.0' },
    payload: {
      'bulto' => [{ 'numeroDeEnvio' => shipped.tracking_number }],
      'evento' => {
        'estado' => 'Entregado',
        'fecha' => '2026-08-24T09:15:00-03:00',
        'sucursal' => 'CABA - Palermo'
      }
    },
    status: 'pending'
  )
end

# ---------------------------------------------------------------------------
# Demo: datos adicionales para mostrar volumen en el backoffice
# ---------------------------------------------------------------------------

#
# Norte — productos adicionales (Cabling, Power)
#
if norte_company
  switch = Product.find_or_create_by!(sku: 'NOR-004', company: norte_company) do |p|
    p.name = 'Switch Gigabit 8 Puertos TP-Link'
    p.description = 'Switch no administrable con 8 puertos Gigabit'
    p.weight = 0.350
    p.dimensions = '15x10x3'
  end
  switch.update!(category: 'Cabling') if switch.category.nil?

  cable = Product.find_or_create_by!(sku: 'NOR-005', company: norte_company) do |p|
    p.name = 'Cable UTP Cat6 100m'
    p.description = 'Cable de red UTP Cat6 rollo de 100 metros'
    p.weight = 4.500
    p.dimensions = '30x30x12'
  end
  cable.update!(category: 'Cabling') if cable.category.nil?

  ups = Product.find_or_create_by!(sku: 'NOR-006', company: norte_company) do |p|
    p.name = 'UPS APC 1500VA'
    p.description = 'Estabilizador/UPS APC Back-UPS 1500VA'
    p.weight = 12.000
    p.dimensions = '35x20x25'
  end
  ups.update!(category: 'Power') if ups.category.nil?

  breaker = Product.find_or_create_by!(sku: 'NOR-007', company: norte_company) do |p|
    p.name = 'Disyuntor Diferencial 2P 25A'
    p.description = 'Disyuntor diferencial unipolar 25 amperios'
    p.weight = 0.200
    p.dimensions = '8x4x7'
  end
  breaker.update!(category: 'Power') if breaker.category.nil?

  # Stock de los productos nuevos
  if central
    Stock.find_or_create_by!(product: switch, warehouse: central) { |s| s.quantity = 40 }
    Stock.find_or_create_by!(product: cable, warehouse: central) { |s| s.quantity = 15 }
    Stock.find_or_create_by!(product: ups, warehouse: central) { |s| s.quantity = 8 }
    Stock.find_or_create_by!(product: breaker, warehouse: central) { |s| s.quantity = 60 }
  end

  if satelite
    Stock.find_or_create_by!(product: switch, warehouse: satelite) { |s| s.quantity = 12 }
    Stock.find_or_create_by!(product: cable, warehouse: satelite) { |s| s.quantity = 25 }
    Stock.find_or_create_by!(product: ups, warehouse: satelite) { |s| s.quantity = 3 }
  end

  #
  # Norte — órdenes adicionales
  #

  # Venta online 1: pagada, con envío entregado
  order_paid_1 = Order.find_or_create_by!(
    company: norte_company, external_order_id: 'ML-2000003508419099'
  ) do |o|
    o.company_integration = ml_integration
    o.customer_name = 'Juan Pérez'
    o.customer_document = '20-30567890-1'
    o.customer_address = 'Av. Corrientes 1234, CABA'
    o.customer_zip_code = '1043'
    o.status = 'paid'
  end
  OrderItem.find_or_create_by!(order: order_paid_1, product: celular) do |i|
    i.quantity = 1
    i.unit_price = 149_999.99
  end
  OrderItem.find_or_create_by!(order: order_paid_1, product: switch) do |i|
    i.quantity = 2
    i.unit_price = 18_500.00
  end

  # Venta online 2: pagada
  order_paid_2 = Order.find_or_create_by!(
    company: norte_company, external_order_id: 'TN-ORD-88210'
  ) do |o|
    o.company_integration = tn_integration
    o.customer_name = 'María García'
    o.customer_document = '27-32456789-5'
    o.customer_address = 'Calle 50 N° 800, Mar del Plata'
    o.customer_zip_code = '7600'
    o.status = 'paid'
  end
  OrderItem.find_or_create_by!(order: order_paid_2, product: notebook) do |i|
    i.quantity = 1
    i.unit_price = 699_999.50
  end

  # Venta manual 3: pagada, sin integración (venta en local)
  order_manual_2 = Order.find_or_create_by!(
    company: norte_company, external_order_id: nil, customer_name: 'Distribuidora Tres Febrero'
  ) do |o|
    o.customer_document = '30-56789012-3'
    o.customer_address = 'Ruta 8 km 65, Escobar'
    o.customer_zip_code = '1625'
    o.customer_city = 'Escobar'
    o.customer_province = 'Buenos Aires'
    o.status = 'paid'
  end
  OrderItem.find_or_create_by!(order: order_manual_2, product: ups) do |i|
    i.quantity = 3
    i.unit_price = 185_000.00
  end
  OrderItem.find_or_create_by!(order: order_manual_2, product: cable) do |i|
    i.quantity = 10
    i.unit_price = 12_000.00
  end

  # Venta online 3: pendiente
  order_pending_1 = Order.find_or_create_by!(
    company: norte_company, external_order_id: 'ML-2000003508419150'
  ) do |o|
    o.company_integration = ml_integration
    o.customer_name = 'Carlos López'
    o.customer_document = '23-34567890-9'
    o.customer_address = 'San Martín 456, Rosario'
    o.customer_zip_code = '2000'
    o.status = 'pending'
  end
  OrderItem.find_or_create_by!(order: order_pending_1, product: breaker) do |i|
    i.quantity = 4
    i.unit_price = 8_500.00
  end

  # Venta cancelada
  order_cancelled_1 = Order.find_or_create_by!(
    company: norte_company, external_order_id: 'TN-ORD-88299'
  ) do |o|
    o.company_integration = tn_integration
    o.customer_name = 'Ana Martínez'
    o.customer_document = '27-30987654-3'
    o.status = 'cancelled'
  end
  OrderItem.find_or_create_by!(order: order_cancelled_1, product: mouse) do |i|
    i.quantity = 10
    i.unit_price = 12_500.00
  end

  #
  # Norte — envíos adicionales
  #

  # Envío de order_paid_1: entregado con events completos
  if order_paid_1 && andreani_integration
    shipped_paid_1 = Shipment.find_or_create_by!(order: order_paid_1) do |s|
      s.company = norte_company
      s.company_integration = andreani_integration
      s.tracking_number = 'AND-100000002'
      s.shipping_label_url = 'https://apis.andreani.com/labels/AND-100000002.pdf'
      s.status = 'delivered'
      s.shipping_cost = 8_750.00
    end

    [
      { internal_status: 'ready_to_ship',
        external_status: 'En preparación',
        occurred_at: Time.zone.parse('2026-08-25 09:00:00') },
      { internal_status: 'in_transit',
        external_status: 'En distribución',
        occurred_at: Time.zone.parse('2026-08-26 14:00:00') },
      { internal_status: 'delivered',
        external_status: 'Entregado',
        occurred_at: Time.zone.parse('2026-08-27 11:30:00') }
    ].each do |event_attrs|
      ShipmentEvent.find_or_create_by!(shipment: shipped_paid_1, **event_attrs)
    end
  end

  # Envío de order_paid_2: en tránsito
  if order_paid_2 && andreani_integration
    shipped_paid_2 = Shipment.find_or_create_by!(order: order_paid_2) do |s|
      s.company = norte_company
      s.company_integration = andreani_integration
      s.tracking_number = 'AND-100000003'
      s.shipping_label_url = 'https://apis.andreani.com/labels/AND-100000003.pdf'
      s.status = 'in_transit'
      s.shipping_cost = 15_200.00
    end

    [
      { internal_status: 'ready_to_ship',
        external_status: 'En preparación',
        occurred_at: Time.zone.parse('2026-09-01 08:00:00') },
      { internal_status: 'in_transit',
        external_status: 'En distribución',
        occurred_at: Time.zone.parse('2026-09-02 10:00:00') }
    ].each do |event_attrs|
      ShipmentEvent.find_or_create_by!(shipment: shipped_paid_2, **event_attrs)
    end
  end

  # Envío de order_manual_2: listo para despachar (confirmado, sin tracking)
  if order_manual_2
    Shipment.find_or_create_by!(order: order_manual_2) do |s|
      s.company = norte_company
      s.status = 'ready_to_ship'
    end
  end

  # Envío de order_pending_1: pendiente (aún no despachado)
  if order_pending_1
    Shipment.find_or_create_by!(order: order_pending_1) do |s|
      s.company = norte_company
      s.status = 'pending'
    end
  end

  #
  # Norte — transferencias adicionales
  #
  if central && satelite
    StockTransfer.find_or_create_by!(product: switch, origin_warehouse: central,
                                     destination_warehouse: satelite,
                                     status: 'received') do |t|
      t.company = norte_company
      t.quantity = 10
      t.dispatched_at = 10.days.ago
      t.settled_at = 8.days.ago
    end

    StockTransfer.find_or_create_by!(product: ups, origin_warehouse: central,
                                     destination_warehouse: satelite,
                                     status: 'in_transit') do |t|
      t.company = norte_company
      t.quantity = 2
      t.dispatched_at = 1.day.ago
    end
  end
end

#
# Sur — productos y pedidos adicionales
#
if sur_company
  cable_sur = Product.find_or_create_by!(sku: 'SUR-003', company: sur_company) do |p|
    p.name = 'Cable Eléctrico 2.5mm x 100m'
    p.description = 'Cable unipolar 2.5mm2 rollo de 100 metros'
    p.weight = 3.200
    p.dimensions = '25x25x10'
  end
  cable_sur.update!(category: 'Cabling') if cable_sur.category.nil?

  destornillador = Product.find_or_create_by!(sku: 'SUR-004', company: sur_company) do |p|
    p.name = 'Set Destornilladores Industriales'
    p.description = 'Juego de 6 destornilladores aislados'
    p.weight = 0.800
    p.dimensions = '25x12x3'
  end
  destornillador.update!(category: 'Cabling') if destornillador.nil?

  # Stock de los productos nuevos
  if deposito_sur
    Stock.find_or_create_by!(product: cable_sur, warehouse: deposito_sur) { |s| s.quantity = 50 }
    Stock.find_or_create_by!(product: destornillador, warehouse: deposito_sur) { |s| s.quantity = 35 }
  end

  #
  # Sur — órdenes adicionales
  #

  # Venta pagada
  sur_paid = Order.find_or_create_by!(
    company: sur_company, external_order_id: nil, customer_name: 'Construcciones del Sur'
  ) do |o|
    o.customer_document = '30-67890123-4'
    o.customer_address = 'Belgrano 567, Bahía Blanca'
    o.customer_zip_code = '8000'
    o.customer_city = 'Bahía Blanca'
    o.customer_province = 'Buenos Aires'
    o.status = 'paid'
  end
  OrderItem.find_or_create_by!(order: sur_paid, product: taladro) do |i|
    i.quantity = 2
    i.unit_price = 89_999.00
  end
  OrderItem.find_or_create_by!(order: sur_paid, product: cable_sur) do |i|
    i.quantity = 5
    i.unit_price = 8_500.00
  end

  # Venta pendiente
  sur_pending = Order.find_or_create_by!(
    company: sur_company, external_order_id: nil, customer_name: 'Ferretería El Martillo'
  ) do |o|
    o.customer_document = '20-54321098-7'
    o.customer_address = 'Av. Mitre 234, Mar del Plata'
    o.customer_zip_code = '7600'
    o.customer_city = 'Mar del Plata'
    o.customer_province = 'Buenos Aires'
    o.status = 'pending'
  end
  OrderItem.find_or_create_by!(order: sur_pending, product: amoladora) do |i|
    i.quantity = 1
    i.unit_price = 65_000.00
  end
  OrderItem.find_or_create_by!(order: sur_pending, product: destornillador) do |i|
    i.quantity = 3
    i.unit_price = 15_000.00
  end
end

#
# Webhook logs adicionales (diferentes estados para el demo)
#
if ml_integration
  # Log procesado exitosamente
  if WebhookLog.unscoped.where(company_integration: ml_integration, status: 'processed').none?
    WebhookLog.create!(
      company_id: norte_company.id,
      company_integration: ml_integration,
      headers: { 'HTTP_USER_AGENT' => 'MercadoLibre-Webhook/1.0' },
      payload: {
        'id' => '2000003508419050',
        'status' => 'pagado',
        'buyer' => { 'nickname' => 'COMPRADOR_TEST_2',
                     'billing_info' => { 'doc_number' => '20-30567890-1' } },
        'shipping' => { 'receiver_address' => { 'address_line' => 'Corrientes 1234, CABA',
                                                'zip_code' => '1043' } },
        'order_items' => [
          { 'item' => { 'id' => 'MLA123456789' }, 'quantity' => 1, 'unit_price' => 149_999.99 }
        ]
      },
      status: 'processed'
    )
  end

  # Log fallido (payload inválido)
  if WebhookLog.unscoped.where(company_integration: ml_integration, status: 'failed').none?
    WebhookLog.create!(
      company_id: norte_company.id,
      company_integration: ml_integration,
      headers: { 'HTTP_USER_AGENT' => 'MercadoLibre-Webhook/1.0' },
      payload: {
        'id' => '2000003508419060',
        'status' => 'unknown_status'
      },
      error_message: 'Invalid status value: unknown_status',
      status: 'failed'
    )
  end
end

# Dos meses de ventas y dos eventos en la DLQ para la demo (ver el archivo).
load Rails.root.join('db/seeds/demo_activity.rb')

puts "Seeds cargados: #{Company.count} empresas, #{User.count} usuarios, " \
     "#{Warehouse.count} depósitos, #{Service.count} servicios, " \
     "#{CompanyIntegration.count} integraciones, #{AdminUser.count} admins, " \
     "#{Product.count} productos, #{Stock.count} stocks, " \
     "#{ProductMapping.count} mappings, " \
     "#{WebhookLog.unscoped.count} webhook logs, " \
     "#{Order.unscoped.count} órdenes, #{OrderItem.unscoped.count} ítems, " \
     "#{Shipment.unscoped.count} envíos, #{ShipmentEvent.unscoped.count} eventos de envío."

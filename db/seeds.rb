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
    branding: {
      'display_name' => 'Distribuidora Norte',
      'primary_color' => '#2E7D32',
      'accent_color' => '#66BB6A',
      'logo_url' => nil,
      'tagline' => 'Logística del norte'
    },
    users: [
      { email: 'admin@norte.com', password: 'password123' },
      { email: 'operador@norte.com', password: 'password123' }
    ],
    warehouses: [
      { name: 'Depósito Central', zip_code: '1900', address: 'Av. 7 N° 1234, La Plata' },
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
      'primary_color' => '#1565C0',
      'accent_color' => '#FFA726',
      'logo_url' => nil,
      'tagline' => 'Distribución para el sur'
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
    Warehouse.find_or_create_by!(name: warehouse_attrs[:name], company: company) do |w|
      w.zip_code = warehouse_attrs[:zip_code]
      w.address = warehouse_attrs[:address]
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
  }
]

services.each do |attrs|
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
  service.update!(attrs.slice(*Service::MAPPER_FIELDS.map(&:to_sym)))
end

# Vincula la primera empresa activa con Mercado Libre (integración de ejemplo).
# La variable ml_integration la consume la orden de webhook de la sección TESIS-40
# más abajo (sin ella, `db:seed` cortaba con NameError: undefined ml_integration).
first_company = Company.find_by(tax_id: '30-11111111-1')
ml_service = Service.find_by(service_name: 'Mercado Libre')
ml_integration =
  if first_company && ml_service
    CompanyIntegration.find_or_create_by!(company: first_company, service: ml_service) do |ci|
      ci.credentials = { 'access_token' => 'DEMO-TOKEN-ML' }
      ci.is_active = true
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
      ci.is_active = true
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
      ci.is_active = true
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
  manual_order = Order.find_or_create_by!(
    company: norte_company, external_order_id: nil, customer_name: 'Cliente Mayorista Norte'
  ) do |o|
    o.customer_document = '20-30123456-7'
    o.customer_address = 'Calle 7 N° 890, La Plata'
    o.customer_zip_code = '1900'
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

puts "Seeds cargados: #{Company.count} empresas, #{User.count} usuarios, " \
     "#{Warehouse.count} depósitos, #{Service.count} servicios, " \
     "#{CompanyIntegration.count} integraciones, #{AdminUser.count} admins, " \
     "#{Product.count} productos, #{Stock.count} stocks, " \
     "#{ProductMapping.count} mappings, " \
     "#{WebhookLog.unscoped.count} webhook logs, " \
     "#{Order.unscoped.count} órdenes, #{OrderItem.unscoped.count} ítems, " \
     "#{Shipment.unscoped.count} envíos, #{ShipmentEvent.unscoped.count} eventos de envío."

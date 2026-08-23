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
    is_active: true,
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
    is_active: true,
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
    is_active: false,
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
  end

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
    service_name: 'Mercado Libre',
    type: 'ecommerce',
    uri: 'https://api.mercadolibre.com/orders',
    http_method: 'GET',
    request_mapper: { 'destination.street' => 'customer_address' },
    response_mapper: { 'tracking.number' => 'tracking_number' },
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
  {
    service_name: 'Andreani',
    type: 'courier',
    uri: 'https://apis.andreani.com/v2/ordenes-de-envio',
    http_method: 'POST',
    request_mapper: { 'destino.postal.codigoPostal' => 'customer_zip_code' },
    response_mapper: { 'bulto.0.numeroDeEnvio' => 'tracking_number' },
    request_value_mapper: {},
    response_value_mapper: { 'EnDistribucion' => 'in_transit', 'Entregado' => 'delivered' }
  }
]

services.each do |attrs|
  Service.find_or_create_by!(service_name: attrs[:service_name]) do |s|
    s.assign_attributes(attrs)
  end
end

# Vincula la primera empresa activa con Mercado Libre (integración de ejemplo).
first_company = Company.find_by(tax_id: '30-11111111-1')
ml_service = Service.find_by(service_name: 'Mercado Libre')
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

demo_integration = CompanyIntegration.unscoped.first
if demo_integration && WebhookLog.unscoped.none?
  WebhookLog.create!(
    company_id: demo_integration.company_id,
    company_integration: demo_integration,
    headers: { 'HTTP_USER_AGENT' => 'MercadoLibre-Webhook/1.0' },
    payload: { 'topic' => 'orders_v2', 'resource' => '/orders/2000003508419013' },
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

puts "Seeds cargados: #{Company.count} empresas, #{User.count} usuarios, " \
     "#{Warehouse.count} depósitos, #{Service.count} servicios, " \
     "#{CompanyIntegration.count} integraciones, #{AdminUser.count} admins, " \
     "#{Product.count} productos, #{Stock.count} stocks, " \
     "#{ProductMapping.count} mappings, " \
     "#{WebhookLog.unscoped.count} webhook logs, " \
     "#{Order.unscoped.count} órdenes, #{OrderItem.unscoped.count} ítems."

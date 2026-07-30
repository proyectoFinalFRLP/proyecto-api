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

  # Identity Mapping: vincula productos de Norte con Mercado Libre
  ml_integration = CompanyIntegration.find_by(company: norte_company, service: ml_service)
  if ml_integration
    ProductMapping.find_or_create_by!(
      product: celular, company_integration: ml_integration
    ) do |pm|
      pm.external_product_id = 'MLA123456789'
      pm.external_price = 149_999.99
    end

    ProductMapping.find_or_create_by!(
      product: notebook, company_integration: ml_integration
    ) do |pm|
      pm.external_product_id = 'MLA987654321'
      pm.external_price = 699_999.50
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

  # Stock en depósito de Sur
  deposito_sur = Warehouse.find_by(company: sur_company, name: 'Depósito Sur')
  if deposito_sur
    Stock.find_or_create_by!(product: taladro, warehouse: deposito_sur) { |s| s.quantity = 10 }
    Stock.find_or_create_by!(product: amoladora, warehouse: deposito_sur) { |s| s.quantity = 25 }
  end
end

puts "Seeds cargados: #{Company.count} empresas, #{User.count} usuarios, " \
     "#{Warehouse.count} depósitos, #{Service.count} servicios, " \
     "#{CompanyIntegration.count} integraciones, #{AdminUser.count} admins, " \
     "#{Product.count} productos, #{Stock.count} stocks, " \
     "#{ProductMapping.count} mappings."

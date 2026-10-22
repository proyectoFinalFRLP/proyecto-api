# Datos para las pruebas de carga (TESIS-96). Se corre con
#
#   bin/rails runner load/fixtures.rb
#
# contra una base PROPIA de la prueba (ver load/README.md): crea productos con
# stock de sobra, una integración de Shopify con un secreto conocido para firmar
# webhooks y un volumen de órdenes históricas para que el listado pagine sobre
# algo parecido a una empresa real. Es idempotente: correrlo dos veces no
# duplica productos ni la integración (las órdenes históricas sí se suman).
#
# Deja los ids que necesitan los scripts de k6 en load/fixtures.json (o donde
# diga LOAD_FIXTURES_OUT). A un archivo y no a stdout: Rails en producción
# imprime avisos por stdout al bootear y ensuciarían el JSON.
#
# Escribe sobre la base sin pasar por la API —insert_all, credenciales—, así que
# se niega a correr contra una base cuyo nombre no diga `loadtest`.

database = ActiveRecord::Base.connection_db_config.database.to_s
unless database.include?('loadtest')
  abort "load/fixtures.rb sólo corre contra una base *loadtest* (esta es #{database.inspect})"
end

# El alta de stock encola el sync a los canales (Stock#enqueue_outbound_sync): acá
# no hay nada que propagar, igual que en db/seeds.rb.
ActiveJob::Base.queue_adapter = :test

SLUG = ENV.fetch('LOAD_SLUG', 'norte')
PRODUCTS = ENV.fetch('LOAD_PRODUCTS', '200').to_i
HISTORIC_ORDERS = ENV.fetch('LOAD_HISTORIC_ORDERS', '20000').to_i
UNITS = 1_000_000
WEBHOOK_SECRET = ENV.fetch('LOAD_WEBHOOK_SECRET', 'loadtest-shopify-secret')

company = Company.find_by!(slug: SLUG)
Current.company_id = company.id
warehouse = Warehouse.where(company: company).order(:id).first!

def load_product(company, warehouse, sku, name)
  product = Product.find_or_create_by!(sku: sku, company: company) do |p|
    p.name = name
    p.category = 'Electronics'
    p.weight = 0.5
    p.length_cm = 10
    p.width_cm = 10
    p.height_cm = 10
  end
  Stock.find_or_initialize_by(product: product, warehouse: warehouse)
       .update!(quantity: UNITS)
  product
end

products = (1..PRODUCTS).map do |i|
  load_product(company, warehouse, format('LOAD-%04d', i), "Producto de carga #{i}")
end
hot = load_product(company, warehouse, 'LOAD-HOT', 'Producto caliente (concurrencia)')

shopify = Service.find_by!(service_name: 'Shopify')
integration = CompanyIntegration.find_or_initialize_by(company: company, service: shopify)
integration.credentials = (integration.credentials || {}).merge(
  'client_id' => 'loadtest', 'client_secret' => WEBHOOK_SECRET
)
integration.is_active = true
integration.save!

# Cada producto de carga queda vinculado a una variante de Shopify: así el
# webhook de venta que manda load/webhooks.js se puede PROCESAR (el worker
# traduce `line_items[].variant_id` a un producto por este vínculo) y no sólo
# ingerir. El id de variante es 9_000_000 + el número del producto.
VARIANT_BASE = 9_000_000
variant_ids = products.each_with_index.map do |product, i|
  variant_id = (VARIANT_BASE + i + 1).to_s
  ProductMapping.find_or_create_by!(product: product, company_integration: integration) do |m|
    m.external_product_id = variant_id
  end
  variant_id
end

# insert_all a propósito: 20 000 órdenes por la API tardarían minutos y no son lo
# que se mide. Sin validaciones, pero con los CHECK de la base de respaldo.
if HISTORIC_ORDERS.positive?
  now = Time.current
  names = %w[Perez Gomez Rodriguez Fernandez Lopez Martinez Garcia Sanchez Romero Diaz]
  statuses = Order::STATUSES
  HISTORIC_ORDERS.times.each_slice(2_000) do |slice|
    rows = slice.map do |i|
      created = now - rand(90 * 24 * 3600)
      { company_id: company.id, customer_name: "#{names.sample} #{i}",
        customer_address: "Calle #{i} #{rand(1..5000)}", customer_zip_code: rand(1000..9999).to_s,
        customer_city: 'La Plata', customer_province: 'Buenos Aires',
        status: statuses.sample, total_amount: 100,
        created_at: created, updated_at: created }
    end
    ids = Order.insert_all!(rows, returning: :id).pluck('id') # rubocop:disable Rails/SkipsModelValidations
    items = ids.map do |order_id|
      { order_id: order_id, product_id: products.sample.id, warehouse_id: warehouse.id,
        quantity: 1, unit_price: 100, created_at: now, updated_at: now }
    end
    OrderItem.insert_all!(items) # rubocop:disable Rails/SkipsModelValidations
  end
end

fixtures = {
  slug: SLUG,
  email: company.users.order(:id).first!.email,
  warehouse_id: warehouse.id,
  product_ids: products.map(&:id),
  hot_product_id: hot.id,
  webhook_integration_id: integration.id,
  webhook_signature_header: shopify.webhook_config['signature_header'],
  webhook_secret: WEBHOOK_SECRET,
  webhook_variant_ids: variant_ids
}

out = ENV.fetch('LOAD_FIXTURES_OUT', Rails.root.join('load/fixtures.json').to_s)
File.write(out, JSON.pretty_generate(fixtures))
warn "Fixtures escritos en #{out}"

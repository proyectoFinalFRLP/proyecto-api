# frozen_string_literal: true

# Actividad histórica de Distribuidora Norte para la demo.
#
# Los seeds de arriba crean las órdenes en el momento de correrlos: todas caen
# el mismo día, y la pantalla de Reportes dibujaba un solo punto. Tampoco había
# nada en la cola de eventos fallidos. Esto agrega cuatro semanas de ventas
# manuales repartidas día por día —algunas despachadas y entregadas, una
# cancelada— y dos eventos en la DLQ, uno agotado y uno pendiente.
#
# Va en un archivo aparte y no dentro de `seeds.rb` para que tocarlo no choque
# con los cambios de las plantillas y las conexiones, que viven allá.
#
# Idempotente como el resto: cada venta se reconoce por el nombre del cliente,
# y cada evento por su error. Las fechas son relativas a cuando se corre, en
# hora de Argentina, para que la ventana de «últimos 30 días» siempre las vea.
#
# No mueve stock: son ventas pasadas, ya despachadas o canceladas, y el stock
# de la demo es el que cargan los seeds de arriba.
module DemoActivity
  ZONE = ActiveSupport::TimeZone['America/Argentina/Buenos_Aires']

  PRICES = {
    'NOR-001' => 149_999.99, 'NOR-002' => 699_999.50, 'NOR-003' => 24_999.00,
    'NOR-004' => 18_500.00, 'NOR-005' => 3_200.00, 'NOR-006' => 95_000.00,
    'NOR-007' => 12_800.00
  }.freeze

  # [días atrás, cliente, líneas [sku, cantidad], estado, envío]
  # envío: nil (sin envío), :in_transit o :delivered.
  SALES = [
    [27, 'Ferretería San Martín', [['NOR-005', 10], ['NOR-007', 4]], 'paid', :delivered],
    [25, 'Estudio Contable Ríos', [['NOR-001', 2]], 'paid', :delivered],
    [24, 'Colegio Nacional', [['NOR-002', 3]], 'paid', :delivered],
    [22, 'Panadería La Espiga', [['NOR-003', 4]], 'paid', :delivered],
    [20, 'Clínica del Parque', [['NOR-006', 2], ['NOR-004', 3]], 'paid', :delivered],
    [18, 'Hotel Bristol', [['NOR-001', 1], ['NOR-003', 6]], 'paid', :delivered],
    [17, 'Constructora Lomas', [['NOR-007', 12]], 'cancelled', nil],
    [15, 'Agencia Sur Viajes', [['NOR-002', 1]], 'paid', :delivered],
    [13, 'Municipalidad de Berisso', [['NOR-005', 30], ['NOR-004', 6]], 'paid', :delivered],
    [11, 'Óptica Visión', [['NOR-003', 3]], 'paid', :delivered],
    [9, 'Librería Fausto', [['NOR-001', 2], ['NOR-005', 5]], 'paid', :delivered],
    [8, 'Taller Mecánico Ruta 2', [['NOR-007', 6]], 'paid', :in_transit],
    [6, 'Consultorio Dr. Pérez', [['NOR-006', 1]], 'paid', :in_transit],
    [5, 'Gimnasio Olimpo', [['NOR-004', 8]], 'paid', :in_transit],
    [3, 'Distribuidora Este', [['NOR-002', 2], ['NOR-003', 2]], 'paid', :in_transit],
    [2, 'Kiosco El Sol', [['NOR-005', 4]], 'pending', nil],
    [1, 'Bar Notable', [['NOR-001', 1]], 'pending', nil]
  ].freeze

  module_function

  def run
    company = Company.find_by(slug: 'norte')
    return if company.nil?

    Current.set(company_id: company.id) do
      context = context_for(company)
      next if context.nil?

      SALES.each_with_index { |sale, index| seed_sale(context, index, sale) }
      seed_failed_events(company)
    end
  end

  # Lo que las ventas necesitan de los seeds de arriba. Sin alguna de esas
  # piezas (otra base, seeds a medias) no se siembra nada.
  COURIERS = ['Andreani', 'Correo Argentino'].freeze

  def context_for(company)
    warehouse = Warehouse.find_by(name: 'Depósito Central')
    products = Product.where(sku: PRICES.keys).index_by(&:sku)
    couriers = CompanyIntegration.joins(:service).where(services: { service_name: COURIERS }).to_a
    return if warehouse.nil? || products.size < PRICES.size || couriers.empty?

    { company: company, warehouse: warehouse, products: products, couriers: couriers }
  end

  def seed_sale(context, index, sale)
    days_ago, customer, lines, status, shipping = sale
    return if Order.exists?(customer_name: customer)

    at = ZONE.now.beginning_of_day - days_ago.days + (9 + (index % 9)).hours
    order = create_order(context, index, customer, status, at)
    lines.each do |sku, quantity|
      OrderItem.create!(order: order, product: context[:products].fetch(sku),
                        warehouse: context[:warehouse], quantity: quantity,
                        unit_price: PRICES.fetch(sku))
    end
    order.update_columns(total_amount: order.items_total) # rubocop:disable Rails/SkipsModelValidations
    seed_shipment(context, order, index, at, shipping) if shipping
  end

  def create_order(context, index, customer, status, at)
    Order.create!(company: context[:company], customer_name: customer, status: status,
                  customer_address: "Calle #{10 + index} N° #{100 + index}, La Plata",
                  customer_zip_code: '1900', customer_province: 'Buenos Aires',
                  created_at: at, updated_at: at)
  end

  # La bitácora es lo que fecha el despacho (Reportes cuenta las unidades por el
  # evento `ready_to_ship`), así que cada envío lleva su historia completa.
  def seed_shipment(context, order, index, at, shipping)
    shipment = Shipment.create!(
      company: context[:company], order: order, status: shipping.to_s,
      company_integration: context[:couriers][index % context[:couriers].size],
      tracking_number: format('DEMO-%06d', 100 + index), shipping_cost: 4_500 + (index * 350)
    )
    events = [['ready_to_ship', 'Etiqueta generada', 1.day], ['in_transit', 'En camino', 2.days]]
    events << ['delivered', 'Entregado', 4.days] if shipping == :delivered
    events.each do |internal, external, offset|
      ShipmentEvent.create!(shipment: shipment, internal_status: internal,
                            external_status: external, occurred_at: [at + offset, ZONE.now].min)
    end
  end

  # Uno agotado y uno pendiente, para que la cola de eventos fallidos tenga qué
  # mostrar. El agotado apunta al webhook inválido que cargan los seeds: si se
  # lo reintenta, vuelve a fallar por el mismo motivo, como pasaría de verdad.
  def seed_failed_events(company)
    invalid_log = WebhookLog.where(company_id: company.id, status: 'failed').first
    ml = CompanyIntegration.joins(:service).find_by(services: { service_name: 'Mercado Libre' })

    unless FailedEvent.exists?(last_error: 'the payload does not carry any order item')
      FailedEvent.create!(company: company, company_integration: ml, direction: 'inbound',
                          event_type: 'webhooks.order_ingestion', status: 'dead', attempts: 5,
                          payload: { 'webhook_log_id' => invalid_log&.id },
                          last_error: 'the payload does not carry any order item')
    end
    return if FailedEvent.exists?(last_response_status: 503)

    FailedEvent.create!(company: company, company_integration: ml, direction: 'outbound',
                        event_type: 'integrations.http_request', status: 'pending', attempts: 2,
                        next_retry_at: 4.minutes.from_now, last_response_status: 503,
                        last_error: 'Service Unavailable', payload: {})
  end
end

DemoActivity.run

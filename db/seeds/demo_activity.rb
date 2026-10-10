# frozen_string_literal: true

# Actividad histórica de Distribuidora Norte para la demo.
#
# Los seeds de arriba crean las órdenes en el momento de correrlos: todas caen
# el mismo día, y la pantalla de Reportes dibujaba un solo punto. Tampoco había
# nada en la cola de eventos fallidos. Esto agrega dos meses de ventas manuales
# repartidas día por día —algunas despachadas y entregadas, dos canceladas— y
# dos eventos en la DLQ, uno agotado y uno pendiente.
#
# Dos meses y no cuatro semanas porque Reportes compara la ventana elegida con
# la anterior del mismo largo (`Reports::BuildOverview#trended`). Con un solo
# mes, «últimos 30 días» no tenía contra qué comparar: Órdenes y Facturación
# salían sin tendencia, y Volumen despachado mostraba +2.425 % contra las 4
# unidades que los seeds de arriba despachan en fechas fijas de 2026. Esas 4
# siguen contando mientras la ventana anterior las alcance, pero contra el
# centenar del mes anterior mueven la tendencia unos pocos puntos.
#
# Lo mismo con «últimos 7 días», que es lo primero que abre Reportes: las
# órdenes de los seeds de arriba caen todas en esta semana, y la anterior tenía
# cuatro ventas y el despacho grande de la Municipalidad. Daba +200 % de
# órdenes, +175 % de facturación y −75 % de volumen despachado. Las ventas del
# final de la tabla emparejan las dos semanas.
#
# Va en un archivo aparte y no dentro de `seeds.rb` para que tocarlo no choque
# con los cambios de las plantillas y las conexiones, que viven allá.
#
# Idempotente como el resto: cada venta se reconoce por el nombre del cliente,
# y cada evento por su error. Las fechas son relativas a cuando se corre, en
# hora de Argentina, para que «últimos 30 días» y el período anterior siempre
# las vean.
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
    [1, 'Bar Notable', [['NOR-001', 1]], 'pending', nil],

    # El mes anterior: contra esto calcula Reportes la tendencia de «últimos 30
    # días». Va al final y no arriba, en orden, porque del índice salen el
    # número de seguimiento y el operador de cada envío: corriendo las de arriba,
    # una base ya sembrada recibiría números repetidos.
    #
    # Volumen parecido al de este mes (contando las del final de la tabla), a
    # propósito no igual: unas órdenes menos, algo menos facturado y más
    # unidades despachadas, para que las tres tarjetas muestren variaciones
    # creíbles, y alguna en rojo.
    #
    # Todas entregadas: un envío de hace dos meses no sigue en camino, y así
    # Volumen despachado y Entregas por operador también tienen con qué
    # comparar. La más nueva es de hace 31 días y no de 30, porque el despacho
    # va un día después de la venta (ver `seed_shipment`) y tiene que caer
    # dentro de la ventana anterior: Reportes fecha el despacho por ese evento.
    # La entrega de las últimas cae ya en este mes, como pasaría de verdad, y no
    # mueve ningún número: lo entregado se cuenta por el estado del envío.
    #
    # Sin hueco con las de arriba: si la serie se cortara unos días antes, la
    # curva semanal de «últimos 90 días» mostraría una semana en cero en el
    # medio de la actividad.
    [59, 'Inmobiliaria Diagonal', [['NOR-001', 2]], 'paid', :delivered],
    [57, 'Escuela Técnica N° 5', [['NOR-002', 2]], 'paid', :delivered],
    [56, 'Farmacia Central', [['NOR-005', 12], ['NOR-004', 2]], 'paid', :delivered],
    [54, 'Club Social Tolosa', [['NOR-003', 5]], 'paid', :delivered],
    [53, 'Cooperativa City Bell', [['NOR-007', 10], ['NOR-005', 6]], 'paid', :delivered],
    [51, 'Estudio Jurídico Moreno', [['NOR-001', 1], ['NOR-006', 1]], 'paid', :delivered],
    [50, 'Veterinaria Los Hornos', [['NOR-004', 4]], 'paid', :delivered],
    [48, 'Instituto Superior Belgrano', [['NOR-002', 1], ['NOR-003', 3]], 'paid', :delivered],
    [47, 'Restaurante La Cantina', [['NOR-006', 2]], 'cancelled', nil],
    [46, 'Centro Médico Gonnet', [['NOR-006', 2]], 'paid', :delivered],
    [44, 'Imprenta Rápida 7', [['NOR-005', 12]], 'paid', :delivered],
    [43, 'Lavadero Burbujas', [['NOR-007', 3]], 'paid', :delivered],
    [41, 'Escribanía Ledesma', [['NOR-001', 2], ['NOR-003', 2]], 'paid', :delivered],
    [40, 'Supermercado Don Pepe', [['NOR-004', 5], ['NOR-005', 8]], 'paid', :delivered],
    [38, 'Fundación Esperanza', [['NOR-002', 1]], 'paid', :delivered],
    [37, 'Autoservicio El Trébol', [['NOR-003', 2]], 'paid', :delivered],
    [36, 'Agencia de Seguros Plata', [['NOR-001', 1], ['NOR-007', 2]], 'paid', :delivered],
    [34, 'Laboratorio Bioquímico Sur', [['NOR-006', 1], ['NOR-005', 5]], 'paid', :delivered],
    [33, 'Cafetería Plaza Moreno', [['NOR-003', 4]], 'paid', :delivered],
    [32, 'Academia de Idiomas Babel', [['NOR-002', 1], ['NOR-004', 2]], 'paid', :delivered],
    [31, 'Carpintería Los Pinos', [['NOR-007', 5]], 'paid', :delivered],

    # La semana anterior a «últimos 7 días», por la misma razón y también al
    # final. Esta semana carga con las órdenes que los seeds de arriba crean al
    # correr (sin facturación ni despacho), así que la anterior necesita más
    # ventas que esta para quedar pareja: diez contra doce.
    #
    # El volumen despachado se empareja con la de hace 7 días: se vende en la
    # semana anterior y se despacha al día siguiente, ya en esta. Es lo que
    # equilibra el despacho de la Municipalidad de Berisso, que cae del otro lado.
    # Las demás llevan pocas unidades por venta, para no agrandarlo de nuevo.
    [13, 'Hostel Plaza Paso', [['NOR-003', 2]], 'paid', :delivered],
    [12, 'Estudio de Arquitectura Línea', [['NOR-002', 1]], 'paid', :delivered],
    [10, 'Peluquería Glam', [['NOR-004', 2]], 'paid', :delivered],
    [9, 'Escuela de Música Allegro', [['NOR-003', 2]], 'paid', :delivered],
    [8, 'Consultora Datos Abiertos', [['NOR-001', 2]], 'paid', :delivered],
    [7, 'Mayorista El Puerto', [['NOR-005', 30], ['NOR-007', 10], ['NOR-004', 4]], 'paid',
     :delivered],

    # Las de arriba también suman a «últimos 30 días»: sin estas, el mes
    # anterior quedaba corto y las tres tendencias subían a entre +34 % y +45 %.
    [58, 'Hotel del Bosque', [['NOR-003', 4], ['NOR-005', 16]], 'paid', :delivered],
    [52, 'Corralón Los Andes', [['NOR-007', 12], ['NOR-004', 6]], 'paid', :delivered],
    [45, 'Biblioteca Popular Alborada', [['NOR-002', 1]], 'paid', :delivered],
    [39, 'Panificadora Arco Iris', [['NOR-005', 10]], 'paid', :delivered],
    [35, 'Taller de Motos Ensenada', [['NOR-004', 5], ['NOR-006', 1]], 'paid', :delivered]
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

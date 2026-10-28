# frozen_string_literal: true

# `demo:purge_seeded_history[slug]` (lib/tasks/demo.rake).
#
# La historia que inventaba db/seeds/demo_activity.rb, reconocida con
# precisión: las ventas manuales con los clientes de esa tabla cuyo envío, si
# lo tienen, lleva un número `DEMO-` de seis dígitos, y los dos eventos de la
# DLQ que sembraba, atados a la integración de ejemplo de Mercado Libre. Nunca
# movieron stock, así que borrarlas no devuelve unidades.
module DemoHistoryPurge
  module_function

  CUSTOMERS = [
    'Ferretería San Martín', 'Estudio Contable Ríos', 'Colegio Nacional', 'Panadería La Espiga',
    'Clínica del Parque', 'Hotel Bristol', 'Constructora Lomas', 'Agencia Sur Viajes',
    'Municipalidad de Berisso', 'Óptica Visión', 'Librería Fausto', 'Taller Mecánico Ruta 2',
    'Consultorio Dr. Pérez', 'Gimnasio Olimpo', 'Distribuidora Este', 'Kiosco El Sol',
    'Bar Notable', 'Inmobiliaria Diagonal', 'Escuela Técnica N° 5', 'Farmacia Central',
    'Club Social Tolosa', 'Cooperativa City Bell', 'Estudio Jurídico Moreno',
    'Veterinaria Los Hornos', 'Instituto Superior Belgrano', 'Restaurante La Cantina',
    'Centro Médico Gonnet', 'Imprenta Rápida 7', 'Lavadero Burbujas', 'Escribanía Ledesma',
    'Supermercado Don Pepe', 'Fundación Esperanza', 'Autoservicio El Trébol',
    'Agencia de Seguros Plata', 'Laboratorio Bioquímico Sur', 'Cafetería Plaza Moreno',
    'Academia de Idiomas Babel', 'Carpintería Los Pinos', 'Hostel Plaza Paso',
    'Estudio de Arquitectura Línea', 'Peluquería Glam', 'Escuela de Música Allegro',
    'Consultora Datos Abiertos', 'Mayorista El Puerto', 'Hotel del Bosque',
    'Corralón Los Andes', 'Biblioteca Popular Alborada', 'Panificadora Arco Iris',
    'Taller de Motos Ensenada'
  ].freeze
  TRACKING = /\ADEMO-\d{6}\z/
  FAKE_CHANNEL_TOKEN = 'DEMO-TOKEN-ML'

  def purge(slug, dry_run:)
    company = OcaDevTasks.company(slug)
    Current.set(company_id: company.id) do
      orders = seeded_orders
      events = seeded_failed_events(company)
      report(orders, events, dry_run: dry_run)
      delete(orders, events) unless dry_run
    end
  end

  def seeded_orders
    Order.includes(:shipment)
         .where(customer_name: CUSTOMERS, external_order_id: nil, company_integration_id: nil)
         .select { |order| order.shipment.nil? || seeded_tracking?(order.shipment) }
  end

  def seeded_tracking?(shipment)
    shipment.tracking_number.to_s.match?(TRACKING)
  end

  def seeded_failed_events(company)
    channel = CompanyIntegration.unscoped.where(company_id: company.id).find do |integration|
      integration.credentials.is_a?(Hash) &&
        integration.credentials['access_token'] == FAKE_CHANNEL_TOKEN
    end
    return [] if channel.nil?

    events = FailedEvent.where(company_integration_id: channel.id)
    events.where(direction: 'inbound', event_type: 'webhooks.order_ingestion', status: 'dead',
                 attempts: 5, last_error: 'the payload does not carry any order item').to_a +
      events.where(direction: 'outbound', event_type: 'integrations.http_request',
                   last_response_status: 503, last_error: 'Service Unavailable').to_a
  end

  def report(orders, events, dry_run:)
    verb = dry_run ? 'Borraría' : 'Borrando'
    shipments = orders.filter_map(&:shipment)
    puts "#{verb} #{orders.size} órdenes, #{shipments.size} envíos y " \
         "#{events.size} eventos fallidos:"
    orders.each do |order|
      puts "  Orden ##{order.id} #{order.customer_name} #{order.shipment&.tracking_number}"
    end
    events.each { |event| puts "  Evento fallido ##{event.id} #{event.last_error}" }
  end

  # Hijos primero, aunque las claves foráneas borren en cascada: así lo que se
  # borra es exactamente lo que se listó, y en una transacción.
  def delete(orders, events)
    ActiveRecord::Base.transaction do
      shipment_ids = orders.filter_map { |order| order.shipment&.id }
      ShipmentEvent.where(shipment_id: shipment_ids).delete_all
      Shipment.where(id: shipment_ids).delete_all
      OrderItem.where(order_id: orders.map(&:id)).delete_all
      Order.where(id: orders.map(&:id)).delete_all
      FailedEvent.where(id: events.map(&:id)).delete_all
    end
    puts 'Listo.'
  end
end

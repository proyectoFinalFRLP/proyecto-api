# frozen_string_literal: true

# La smoke de OCA e-Pak (`integrations:oca:smoke[slug]`, lib/tasks/oca.rake):
# cotiza, despacha, baja la etiqueta y pregunta el estado de un envío inventado
# contra el entorno de PRUEBA de OCA, con la integración que dejó
# `integrations:oca:connect`. Usa los mismos casos de uso que la API.
module OcaSmoke
  module_function

  def smoke(slug)
    company = OcaDevTasks.company(slug)
    Current.set(company_id: company.id) do
      integration = OcaDevTasks.dispatch_integration(company)
      warehouse = company.warehouses.where.not(city: nil).first!
      order = fake_order(company, warehouse)

      shipment = dispatch(order, warehouse, integration, quote_for(order, warehouse, integration))
      label(shipment)
      track(shipment)
    end
  end

  def fake_order(company, warehouse)
    product = company.products.where.not(weight: 0).first!
    Order.create!(
      company: company, customer_name: "Cliente Ficticio #{Time.current.strftime('%H%M%S')}",
      customer_document: '20-00000000-0', customer_address: 'Calle 50 N° 742',
      customer_zip_code: 'B1900', customer_city: 'La Plata', customer_province: 'Buenos Aires',
      total_amount: 15_000,
      order_items: [OrderItem.new(product: product, warehouse: warehouse, quantity: 1,
                                  unit_price: 15_000)]
    ).tap { |order| puts "Orden ##{order.id} para #{order.customer_name}" }
  end

  def quote_for(order, warehouse, integration)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    quotes = Shipments::QuoteShipment.for_order(order: order, origin_warehouse: warehouse).call
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    options = quotes.map { |q| [q[:provider_name], q[:shipping_cost].to_f, q[:estimated_days]] }
    puts "Cotización (#{elapsed.round(2)}s): #{options}"

    quotes.find { |q| q[:dispatch_integration_id] == integration.id } ||
      abort('OCA no devolvió tarifa: ¿está conectada la cotización? integrations:oca:connect')
  end

  def dispatch(order, warehouse, integration, quote)
    shipment = Shipments::CreateShipment.new(order: order).call
    Shipments::ConfirmDispatch.new(
      shipment: shipment, company_integration: integration, origin_warehouse: warehouse,
      shipping_cost: quote[:shipping_cost]
    ).call.tap do |dispatched|
      puts "Despachado: envío ##{dispatched.id}, número #{dispatched.tracking_number}, " \
           "orden de retiro #{dispatched.external_reference}"
    end
  end

  def label(shipment)
    pdf = Shipments::FetchLabel.new(shipment: shipment).call.fetch(:pdf)
    path = Rails.root.join("tmp/oca-etiqueta-#{shipment.tracking_number}.pdf")
    File.binwrite(path, pdf)
    puts "Etiqueta: #{pdf.bytesize} bytes en #{path}"
  end

  def track(shipment)
    events = Shipments::PollTrackingStatus.new(company_integration: shipment.company_integration,
                                               shipment_ids: [shipment.id]).call
    shipment.reload
    puts "Seguimiento: #{events.map(&:external_status).presence || 'sin cambios'} " \
         "-> estado #{shipment.status}"
  end
end

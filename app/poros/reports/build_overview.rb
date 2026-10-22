# frozen_string_literal: true

module Reports
  # Agregados de la pantalla de Reportes (S14) sobre una ventana de tiempo.
  #
  # El cumplimiento de plazo y las anomalías salen de la fecha comprometida que
  # el despacho guarda en el envío (Reports::PromisedDeliveries y
  # Reports::DelayedShipments). Antes de guardarla viajaban como `nil` fijo.
  #
  # Todo pasa por los modelos con `CompanyScoped`, así que el reporte es del
  # tenant del request sin filtrar a mano.
  class BuildOverview < ApplicationPoro
    DISPATCH_STATUS = Shipments::ConfirmDispatch::DISPATCHED_STATUS

    def initialize(window:)
      super()
      @window = window
    end

    def call
      {
        period: @window.period,
        from: @window.from.iso8601,
        to: @window.to.iso8601,
        granularity: @window.granularity,
        kpis: kpis,
        curve: curve,
        carriers: carriers,
        anomalies: delayed_shipments.call
      }
    end

    private

    # La cantidad de órdenes no va: la pantalla nunca la mostró, y la curva ya
    # las cuenta día por día.
    def kpis
      {
        revenue: trended { |range| sales(range).sum(:total_amount).to_f },
        dispatched_units: trended { |range| dispatched_units(range) },
        on_time_delivery_rate: on_time_delivery_rate,
        active_anomalies: delayed_shipments.summary
      }
    end

    # El valor de la ventana y su variación porcentual contra la anterior. Sin
    # nada en la anterior, la variación es `nil`: un "+100 %" o un "0 %" ahí se
    # leería como un dato.
    def trended
      current = yield(@window.range)
      previous = yield(@window.previous_range)

      { value: current, trend: trend(current, previous) }
    end

    def trend(current, previous)
      return nil if previous.nil? || previous.zero?

      ((current - previous) * 100.0 / previous).round(1)
    end

    # Qué porcentaje de las entregas de la ventana llegó a tiempo. Sólo cuentan
    # las que tenían fecha comprometida: sin plazo no hay nada que cumplir. Sin
    # ninguna, el KPI entero es `nil` —«sin entregas que medir»—, y no un 0 %
    # que se leería como que todas llegaron tarde.
    #
    # La variación va en puntos y no relativa como en `trended`: de 50 % a 75 %
    # son 25 puntos, y un «+50 %» sobre un porcentaje se lee como otra cosa.
    def on_time_delivery_rate
      current = on_time_rate(deliveries)
      return nil if current.nil?

      previous = on_time_rate(PromisedDeliveries.call(range: @window.previous_range))
      { value: current, trend: previous && (current - previous).round(1) }
    end

    def on_time_rate(deliveries)
      return nil if deliveries.empty?

      (deliveries.count(&:on_time?) * 100.0 / deliveries.size).round(1)
    end

    # Las entregas con plazo de la ventana. Las leen el cumplimiento y las
    # anomalías resueltas: una sola consulta para las dos.
    def deliveries
      @deliveries ||= PromisedDeliveries.call(range: @window.range)
    end

    def delayed_shipments
      @delayed_shipments ||= DelayedShipments.new(window: @window, deliveries: deliveries)
    end

    # Las ventas que cuentan: las canceladas no facturaron.
    def sales(range)
      Order.where(created_at: range).where.not(status: Order::CANCELLED)
    end

    # `shipments` no guarda cuándo se despachó: lo dice el primer evento de la
    # bitácora, el `ready_to_ship` que escribe `ConfirmDispatch`.
    def dispatched_shipments(range)
      Shipment.where(id: ShipmentEvent.where(internal_status: DISPATCH_STATUS, occurred_at: range)
                                      .select(:shipment_id))
    end

    def dispatched_units(range)
      OrderItem.where(order_id: dispatched_shipments(range).select(:order_id)).sum(:quantity)
    end

    def curve
      totals = sales(@window.range).pluck(:created_at, :total_amount)
                                   .group_by { |created_at, _| @window.bucket_for(created_at) }

      @window.buckets.map do |date|
        rows = totals.fetch(date, [])
        { date: date.iso8601, orders: rows.size, revenue: rows.sum { |_, amount| amount.to_f } }
      end
    end

    # Volumen por operador: cuántos envíos se despacharon con cada integración de
    # courier en la ventana, y cuántos de esos ya se entregaron. No es el
    # cumplimiento de plazo del diseño: es lo que el modelo puede decir.
    def carriers
      shipments = dispatched_shipments(@window.range).where.not(company_integration_id: nil)
      dispatched = shipments.group(:company_integration_id).count
      delivered = shipments.where(status: 'delivered').group(:company_integration_id).count

      CompanyIntegration.includes(:service).where(id: dispatched.keys)
                        .map { |integration| carrier_row(integration, dispatched, delivered) }
                        .sort_by { |row| [-row[:dispatched], row[:name]] }
    end

    def carrier_row(integration, dispatched, delivered)
      { company_integration_id: integration.id, name: integration.service_name,
        dispatched: dispatched.fetch(integration.id, 0),
        delivered: delivered.fetch(integration.id, 0) }
    end
  end
end

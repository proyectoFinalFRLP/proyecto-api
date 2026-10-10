# frozen_string_literal: true

module Reports
  # Agregados de la pantalla de Reportes (S14) sobre una ventana de tiempo.
  #
  # Calcula sólo lo que el modelo permite calcular. El diseño tiene además el
  # cumplimiento de plazo y las anomalías regionales, que no tienen dominio
  # detrás (no hay fecha comprometida en `shipments`, ni una entidad de
  # anomalía): esos van como `nil` explícito y no como un número inventado.
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
        carriers: carriers
      }
    end

    private

    def kpis
      {
        orders: trended { |range| sales(range).count },
        revenue: trended { |range| sales(range).sum(:total_amount).to_f },
        dispatched_units: trended { |range| dispatched_units(range) },
        on_time_delivery_rate: nil,
        active_anomalies: nil
      }
    end

    # El valor de la ventana y su variación porcentual contra la anterior. Sin
    # nada en la anterior, la variación es `nil`: un "+100 %" o un "0 %" ahí se
    # leería como un dato.
    def trended
      current = yield(@window.range)
      previous = yield(@window.previous_range)
      trend = previous.zero? ? nil : ((current - previous) * 100.0 / previous).round(1)

      { value: current, trend: trend }
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

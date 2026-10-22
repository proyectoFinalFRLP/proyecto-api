# frozen_string_literal: true

module Reports
  # Los envíos entregados en un rango que tenían fecha comprometida, con el día
  # en que se entregaron. Es lo que miden el cumplimiento de plazo y las
  # anomalías resueltas de Reportes: las dos preguntas son sobre las mismas
  # entregas, y con una sola consulta cuentan lo mismo.
  #
  # La entrega la fecha el evento `delivered` de la bitácora, igual que el
  # despacho lo fecha el `ready_to_ship` (BuildOverview#dispatched_shipments):
  # `shipments` no guarda cuándo llegó. Si el courier reportó la entrega más de
  # una vez dentro del rango, cuenta la primera.
  #
  # El día se corta en hora de Argentina, la misma zona que la fecha
  # comprometida (Shipment::PROMISE_ZONE): una entrega a las 23 h del día
  # prometido llegó a tiempo, aunque en UTC ya sea el día siguiente.
  #
  # Arranca de Shipment, que es CompanyScoped: los eventos no tienen tenant
  # propio y se leen siempre a través de su envío.
  class PromisedDeliveries < ApplicationPoro
    DELIVERED_STATUS = 'delivered'

    Delivery = Data.define(:shipment_id, :promised_delivery_on, :delivered_on) do
      def on_time? = delivered_on <= promised_delivery_on

      def days_late = (delivered_on - promised_delivery_on).to_i
    end

    def initialize(range:)
      super()
      @range = range
    end

    def call
      first_delivery_by_shipment.map do |(shipment_id, promised), delivered_at|
        Delivery.new(shipment_id: shipment_id, promised_delivery_on: promised,
                     delivered_on: delivered_at.in_time_zone(Shipment::PROMISE_ZONE).to_date)
      end
    end

    private

    def first_delivery_by_shipment
      Shipment.where.not(promised_delivery_on: nil)
              .joins(:shipment_events)
              .where(shipment_events: { internal_status: DELIVERED_STATUS, occurred_at: @range })
              .group('shipments.id', 'shipments.promised_delivery_on')
              .minimum('shipment_events.occurred_at')
    end
  end
end

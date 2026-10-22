# frozen_string_literal: true

module Reports
  # Las anomalías de Reportes: los envíos que no llegaron en el plazo que se
  # comprometió al despacharlos.
  #
  # El diseño (S14) pedía «anomalías regionales» sin que existiera nada detrás.
  # Lo que el sistema sí sabe es la fecha comprometida de cada envío y si ya se
  # entregó, y un envío demorado es justo lo que un operador tiene que mirar.
  # No hace falta una entidad nueva: la anomalía se deriva del envío.
  #
  # - `investigating`: en camino, con la fecha comprometida vencida.
  # - `critical`: en camino y con CRITICAL_DELAY_DAYS días de demora o más.
  # - `resolved`: llegó, pero después de la fecha comprometida. Sólo las
  #   entregadas dentro de la ventana: las abiertas son de hoy, no del período.
  #
  # Las abiertas usan `Shipment.delayed`, el mismo scope del filtro
  # «demorados» del listado de envíos, a donde lleva «Ver bitácora».
  class DelayedShipments < ApplicationPoro
    CRITICAL_DELAY_DAYS = 3

    # Cuántas filas muestra la tabla. Las abiertas van primero, así que una
    # empresa con muchas demoras ve las que todavía puede resolver.
    LIMIT = 10

    PRELOAD = [:origin_warehouse, { order: :order_items, company_integration: :service }].freeze

    # `deliveries` son las PromisedDeliveries de la ventana, si quien llama ya
    # las tiene (BuildOverview las usa también para el cumplimiento).
    def initialize(window:, deliveries: nil)
      super()
      @window = window
      @today = window.to.to_date
      @deliveries = deliveries
    end

    # El KPI «Anomalías activas»: las demoras abiertas hoy, y si alguna ya es
    # crítica (la tarjeta pasa a alerta).
    def summary
      { count: Shipment.delayed(@today).count,
        critical: Shipment.delayed(@today - (CRITICAL_DELAY_DAYS - 1)).exists? }
    end

    def call
      open = Shipment.delayed(@today).preload(PRELOAD)
                     .order(:promised_delivery_on, :id).limit(LIMIT).to_a
      rows = open.map { |shipment| row(shipment, until_day: @today, resolved: false) }
      return rows if rows.size >= LIMIT

      rows + resolved_rows(LIMIT - rows.size)
    end

    private

    # Las entregas tardías de la ventana, las más recientes primero.
    def resolved_rows(limit)
      late = late_deliveries.first(limit)
      shipments = Shipment.preload(PRELOAD).where(id: late.map(&:shipment_id)).index_by(&:id)

      late.map do |delivery|
        row(shipments.fetch(delivery.shipment_id), until_day: delivery.delivered_on, resolved: true)
      end
    end

    def late_deliveries
      (@deliveries || PromisedDeliveries.call(range: @window.range))
        .reject(&:on_time?)
        .sort_by { |delivery| [-delivery.delivered_on.jd, delivery.shipment_id] }
    end

    # `until_day` es hasta cuándo corre la demora: hoy si sigue en camino, el
    # día de la entrega si ya llegó.
    def row(shipment, until_day:, resolved:)
      days_late = (until_day - shipment.promised_delivery_on).to_i
      DelayedShipmentSerializer.render_as_hash(shipment, days_late: days_late,
                                                         status: status_of(days_late, resolved))
    end

    def status_of(days_late, resolved)
      return 'resolved' if resolved

      days_late >= CRITICAL_DELAY_DAYS ? 'critical' : 'investigating'
    end
  end
end

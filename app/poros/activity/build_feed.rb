# frozen_string_literal: true

module Activity
  # Lo último que pasó en la empresa, en una sola lista ordenada por fecha: es lo
  # que muestra el panel de la campanita (TESIS-162) y el «feed de actividad
  # reciente» que RF-26 compromete para el panel de control.
  #
  # No hay tabla de notificaciones ni estado de leído por usuario a propósito:
  # eso es otro dominio —leídas por persona, vencimiento, preferencias— y nadie
  # lo pidió. Acá la actividad se **deriva** de lo que el sistema ya registra,
  # así que no puede desincronizarse de los hechos ni hay nada que mantener.
  #
  # Un endpoint y no tres: cada fuente es una consulta, pero la pantalla hace un
  # solo request y recibe la lista ya ordenada. Pedir tres y mezclarlas en el
  # cliente obligaría a que el front supiera cómo se ordena una actividad.
  class BuildFeed < ApplicationPoro
    DEFAULT_LIMIT = 20
    # Techo del `limit`: es un panel desplegable, no un listado paginado. Sin
    # tope, un `?limit=` grande haría tres consultas sin límite.
    MAX_LIMIT = 50

    # Las ventas que entraron, los envíos que salieron y lo que se cayó a la
    # cola de reintentos. Son las tres cosas sobre las que el operador actúa.
    TYPES = %w[order_created shipment_dispatched event_failed].freeze

    DISPATCH_STATUS = Shipments::ConfirmDispatch::DISPATCHED_STATUS

    def initialize(limit: nil)
      super()
      @limit = normalize_limit(limit)
    end

    # Se traen las últimas `limit` de cada fuente y recién después se mezclan:
    # cualquiera de las tres podría ser toda la lista, así que ninguna puede
    # traer menos.
    def call
      (recent_orders + recent_dispatches + recent_failures)
        .sort_by { |event| [-event[:occurred_at].to_f, event[:id]] }
        .first(@limit)
    end

    private

    # Un `limit` que no es un número vuelve al default y no a uno: `'muchas'.to_i`
    # es 0, y acotarlo devolvería una sola fila, que es una respuesta rara para
    # un parámetro que nadie escribió a propósito. Lo que sí es un número se
    # acota, con el mismo criterio que la paginación (TESIS-155).
    def normalize_limit(limit)
      value = limit.to_s.strip
      return DEFAULT_LIMIT unless value.match?(/\A\d+\z/)

      value.to_i.clamp(1, MAX_LIMIT)
    end

    # `Order` es CompanyScoped: el feed es del tenant del request sin filtrar a
    # mano, igual que el resto de la API.
    def recent_orders
      Order.order(created_at: :desc, id: :desc).limit(@limit).map do |order|
        {
          id: "order-#{order.id}", type: 'order_created', occurred_at: order.created_at,
          order_id: order.id, customer_name: order.customer_name,
          external_order_id: order.external_order_id,
          total_amount: order.total_amount&.to_f
        }
      end
    end

    # El despacho no deja una marca de tiempo propia en `shipments`: lo dice el
    # primer evento `ready_to_ship` de la bitácora, que es el que escribe
    # `ConfirmDispatch`. Mismo criterio que usan los reportes.
    #
    # `ShipmentEvent` no es CompanyScoped —no tiene company_id— así que el
    # aislamiento entra por el join con `Shipment`, que sí lo es.
    def recent_dispatches
      ShipmentEvent.where(internal_status: DISPATCH_STATUS)
                   .joins(:shipment).merge(Shipment.all)
                   .includes(shipment: { company_integration: :service })
                   .order(occurred_at: :desc, id: :desc).limit(@limit)
                   .map { |event| dispatch_entry(event, event.shipment) }
    end

    def dispatch_entry(event, shipment)
      {
        id: "dispatch-#{event.id}", type: 'shipment_dispatched', occurred_at: event.occurred_at,
        shipment_id: shipment.id, order_id: shipment.order_id,
        tracking_number: shipment.tracking_number,
        courier: shipment.company_integration&.service_name
      }
    end

    # Igual que las órdenes: `FailedEvent` es CompanyScoped.
    def recent_failures
      FailedEvent.includes(company_integration: :service)
                 .order(created_at: :desc, id: :desc).limit(@limit).map do |failure|
        {
          id: "failure-#{failure.id}", type: 'event_failed', occurred_at: failure.created_at,
          failed_event_id: failure.id, event_type: failure.event_type,
          status: failure.status, integration: failure.company_integration&.service_name
        }
      end
    end
  end
end

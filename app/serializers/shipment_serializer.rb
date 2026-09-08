# frozen_string_literal: true

# Detalle del envío: los mismos campos del listado más la etiqueta y la bitácora
# completa. La diferencia entre este serializer y ShipmentListSerializer es lo
# que justifica que existan los dos — una fila del listado no necesita traer
# todos los eventos del envío.
class ShipmentSerializer < ApplicationSerializer
  identifier :id

  fields :order_id, :status, :tracking_number, :shipping_label_url,
         :created_at, :updated_at

  # Mismo motivo que en ShipmentListSerializer: BigDecimal saldría como string.
  field :shipping_cost do |shipment|
    shipment.shipping_cost&.to_f
  end

  field :courier do |shipment|
    integration = shipment.company_integration
    next nil if integration.nil?

    { id: integration.id, service_id: integration.service_id,
      name: integration.service.service_name }
  end

  # Bitácora en orden cronológico. El orden se resuelve en memoria y no con un
  # `order` de SQL a propósito: el controller ya precargó los eventos, y pedir
  # el orden a la base sobre la asociación cargada dispararía una query más.
  # El desempate por id mantiene el orden estable entre dos eventos con el mismo
  # occurred_at (`sort_by` no garantiza estabilidad).
  association :shipment_events, name: :events, blueprint: ShipmentEventSerializer do |shipment|
    shipment.shipment_events.sort_by { |event| [event.occurred_at, event.id] }
  end
end

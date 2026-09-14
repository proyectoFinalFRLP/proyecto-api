# frozen_string_literal: true

class ShipmentListSerializer < ApplicationSerializer
  identifier :id

  fields :order_id, :status, :tracking_number, :created_at, :updated_at

  # shipping_cost es decimal en la DB y BigDecimal se serializa como string por
  # defecto; exponerlo como número evita que el front tenga que parsear. Nil se
  # conserva: un envío sin cotizar no cuesta 0.
  field :shipping_cost do |shipment|
    shipment.shipping_cost&.to_f
  end

  # Columna "Carrier" del listado (TESIS-52). El nombre sale de la plantilla del
  # Service, no de la integración, así que el controller precarga
  # `company_integration: :service` — sin eso es una query por fila.
  courier_field(:courier, &:company_integration)
end

# frozen_string_literal: true

class ShipmentListSerializer < ApplicationSerializer
  identifier :id

  fields :order_id, :status, :tracking_number, :created_at, :updated_at

  # El número con el que el canal conoce la orden del envío (TESIS-181). Sin él,
  # el listado de envíos mostraba la orden con su id interno y el de órdenes con
  # este número: la misma venta, dos números según la pantalla. `null` en las
  # ventas manuales, y ahí el front cae al id interno, igual que en órdenes.
  field :external_order_id do |shipment|
    shipment.order.external_order_id
  end

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

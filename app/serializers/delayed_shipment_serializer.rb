# frozen_string_literal: true

# Una fila de las anomalías de Reportes (Reports::DelayedShipments): el envío
# demorado con lo que la tabla necesita para nombrarlo —el número de la orden
# como lo muestra el resto de la pantalla, el courier y el depósito de origen—
# y cuánto se demoró.
#
# `days_late` y `status` no son del envío: dependen de hoy o del día de la
# entrega, así que los calcula el PORO y llegan como opciones.
class DelayedShipmentSerializer < ApplicationSerializer
  field :shipment_id, &:id

  fields :order_id, :promised_delivery_on

  # Mismo motivo que en ShipmentListSerializer (TESIS-180, TESIS-181).
  field :external_order_id do |shipment|
    shipment.order.external_order_id
  end

  field :external_order_number do |shipment|
    shipment.order.external_order_number
  end

  courier_field(:courier, &:company_integration)

  field :origin_warehouse do |shipment|
    warehouse = shipment.origin_warehouse
    warehouse && { id: warehouse.id, name: warehouse.name }
  end

  # Las unidades del paquete: lo que el cliente está esperando. En memoria
  # sobre la precarga del PORO, no con un `sum` que sería una query por fila.
  field :units do |shipment|
    shipment.order.order_items.sum(&:quantity)
  end

  field(:days_late) { |_shipment, options| options[:days_late] }
  field(:status) { |_shipment, options| options[:status] }
end

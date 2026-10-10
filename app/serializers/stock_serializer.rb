# frozen_string_literal: true

class StockSerializer < ApplicationSerializer
  identifier :id

  fields :quantity, :warehouse_id, :created_at, :updated_at

  # Calculado acá y no en el front: es la misma regla que el badge del producto
  # (`Product.stock_status_for`), aplicada a lo que guarda este depósito.
  field :stock_status

  # Vista `reference`: el depósito como referencia, sin `stored_units`. Ese
  # campo hace un SUM por depósito y en el detalle de un producto nadie lo lee;
  # con la vista por defecto, cada fila de stock agregaba una query.
  association :warehouse, blueprint: WarehouseSerializer, view: :reference
end

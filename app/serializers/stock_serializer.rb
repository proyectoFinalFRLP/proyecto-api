# frozen_string_literal: true

class StockSerializer < ApplicationSerializer
  identifier :id

  fields :quantity, :warehouse_id, :created_at, :updated_at

  # Calculado acá y no en el front: si este depósito guarda unidades o no
  # (`Stock#stock_status`). No hay «stock bajo» por depósito desde TESIS-182:
  # el mínimo del producto es para su total.
  field :stock_status

  # Vista `reference`: el depósito como referencia, sin `stored_units`. Ese
  # campo hace un SUM por depósito y en el detalle de un producto nadie lo lee;
  # con la vista por defecto, cada fila de stock agregaba una query.
  association :warehouse, blueprint: WarehouseSerializer, view: :reference
end

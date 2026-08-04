# frozen_string_literal: true

class StockSerializer < ApplicationSerializer
  identifier :id

  fields :quantity, :warehouse_id, :created_at, :updated_at

  association :warehouse, blueprint: WarehouseSerializer
end

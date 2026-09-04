# frozen_string_literal: true

class StockTransferSerializer < ApplicationSerializer
  identifier :id

  fields :quantity, :status, :dispatched_at, :settled_at, :created_at, :updated_at

  # Sólo la identidad del producto: quien lista transferencias ya tiene el
  # catálogo, y anidar el serializer completo traería total_stock —una agregación
  # por fila— para nada.
  field :product do |transfer|
    { id: transfer.product_id, sku: transfer.product.sku, name: transfer.product.name }
  end

  field :origin_warehouse do |transfer|
    { id: transfer.origin_warehouse_id, name: transfer.origin_warehouse.name }
  end

  field :destination_warehouse do |transfer|
    { id: transfer.destination_warehouse_id, name: transfer.destination_warehouse.name }
  end
end

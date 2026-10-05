# frozen_string_literal: true

class ProductSerializer < ApplicationSerializer
  identifier :id

  fields :sku, :name, :description, :category, :dimensions, :total_stock,
         :in_transit_quantity, :created_at, :updated_at

  # weight es decimal en la DB y BigDecimal se serializa como string por
  # defecto; exponerlo como número evita que el front tenga que parsear.
  field :weight do |product|
    product.weight.to_f
  end

  # La disponibilidad, con la misma regla que el listado: antes el detalle no la
  # traía y el front la recalculaba con otros umbrales.
  field :stock_status

  # Entrante por depósito (ver `Product#in_transit_by_warehouse`).
  field :in_transit_by_warehouse

  association :stocks, blueprint: StockSerializer
end

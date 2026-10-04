# frozen_string_literal: true

class ProductSerializer < ApplicationSerializer
  identifier :id

  fields :sku, :name, :description, :category, :packaging, :technical_standard,
         :dimensions, :total_stock, :in_transit_quantity, :created_at, :updated_at

  # Los tres números del stock que muestra el detalle (TESIS-162). Van los tres
  # desde el backend y ninguno se deriva en el cliente: `on_hand` no es
  # `total_stock` —lo vendido sin despachar sigue en el estante pero ya salió de
  # `stocks`— y restarlos mal del lado del front es el error que esta card viene
  # a cerrar.
  fields :committed_quantity, :on_hand_quantity, :available_to_promise

  # Lo comprometido por depósito, con la misma forma que `in_transit_by_warehouse`.
  field :committed_by_warehouse

  # weight es decimal en la DB y BigDecimal se serializa como string por
  # defecto; exponerlo como número evita que el front tenga que parsear.
  field :weight do |product|
    product.weight.to_f
  end

  association :stocks, blueprint: StockSerializer
end

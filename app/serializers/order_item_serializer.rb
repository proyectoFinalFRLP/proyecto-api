# frozen_string_literal: true

class OrderItemSerializer < ApplicationSerializer
  identifier :id

  fields :quantity, :product_id, :created_at, :updated_at

  # unit_price es decimal en la DB y BigDecimal se serializa como string por
  # defecto; exponerlo como número evita que el front tenga que parsear.
  field :unit_price do |item|
    item.unit_price.to_f
  end
end

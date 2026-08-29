# frozen_string_literal: true

class OrderItemSerializer < ApplicationSerializer
  identifier :id

  fields :quantity, :unit_price, :product_id, :created_at, :updated_at
end

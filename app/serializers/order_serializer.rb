# frozen_string_literal: true

class OrderSerializer < ApplicationSerializer
  identifier :id

  fields :customer_name, :customer_document, :customer_address, :customer_zip_code,
         :status, :created_at, :updated_at

  association :order_items, blueprint: OrderItemSerializer
end

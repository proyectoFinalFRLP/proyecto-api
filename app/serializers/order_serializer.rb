# frozen_string_literal: true

class OrderSerializer < ApplicationSerializer
  identifier :id

  fields :customer_name, :customer_document, :customer_address, :customer_zip_code,
         :external_order_id, :status, :created_at, :updated_at

  # Mismo criterio que unit_price: decimal en la DB, número en el JSON. Puede
  # ser nil en órdenes anteriores a TESIS-114 que no tienen líneas.
  field :total_amount do |order|
    order.total_amount&.to_f
  end

  association :order_items, blueprint: OrderItemSerializer
end

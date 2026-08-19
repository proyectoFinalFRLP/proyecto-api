# frozen_string_literal: true

class OrderItem < ApplicationRecord
  belongs_to :order
  belongs_to :product

  validates :quantity, numericality: { greater_than: 0 }
  validates :unit_price, numericality: { greater_than_or_equal_to: 0 }
  validate :product_belongs_to_same_company_as_order

  private

  # order_items no tiene company_id (tenant heredado de la orden): hay que
  # validar explícitamente que el producto pertenezca a la misma empresa que
  # la orden (lección TESIS-32 — FKs heredadas contra la misma empresa).
  def product_belongs_to_same_company_as_order
    return unless order && product
    return if order.company_id == product.company_id

    errors.add(:base, 'product must belong to the same company as the order')
  end
end

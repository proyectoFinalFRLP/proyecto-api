# frozen_string_literal: true

class Stock < ApplicationRecord
  belongs_to :product
  belongs_to :warehouse

  validates :quantity, numericality: { greater_than_or_equal_to: 0 }
  validates :warehouse_id, uniqueness: { scope: :product_id }
  validate :product_and_warehouse_must_belong_to_same_company

  private

  def product_and_warehouse_must_belong_to_same_company
    return unless product && warehouse

    return unless product.company_id != warehouse.company_id
    errors.add(:base, 'product and warehouse must belong to the same company')
  end
end

# frozen_string_literal: true

class ProductMapping < ApplicationRecord
  belongs_to :product
  belongs_to :company_integration

  validates :external_product_id, presence: true
  validates :company_integration_id, uniqueness: { scope: :product_id }
  validate :product_and_integration_must_belong_to_same_company

  private

  def product_and_integration_must_belong_to_same_company
    return unless product && company_integration

    return unless product.company_id != company_integration.company_id
    errors.add(:base, 'product and integration must belong to the same company')
  end
end

# frozen_string_literal: true

class ProductMapping < ApplicationRecord
  include CompanyScoped

  belongs_to :product
  belongs_to :company_integration

  validates :external_product_id, presence: true
  validates :company_integration_id, uniqueness: { scope: :product_id }
end

# frozen_string_literal: true

class ProductMapping < ApplicationRecord
  belongs_to :product
  belongs_to :company_integration

  validates :external_product_id, presence: true
  validates :company_integration_id, uniqueness: { scope: :product_id }
  # external_price es decimal(10,2): la DB tope en 99.999.999,99 y cualquier
  # valor mayor levanta ActiveRecord::RangeError, que Rails no mapea a ningún
  # status HTTP (o sea, 500). Con el rango explícito sale 422 y el límite queda
  # documentado. La misma línea tapa los otros dos agujeros del cast a
  # BigDecimal: 'abc' se guardaba como 0.0 en silencio y los negativos pasaban.
  validates :external_price, numericality: { greater_than_or_equal_to: 0, less_than: 100_000_000 },
                             allow_nil: true
  validate :product_and_integration_must_belong_to_same_company

  private

  def product_and_integration_must_belong_to_same_company
    return unless product && company_integration

    return unless product.company_id != company_integration.company_id
    errors.add(:base, 'product and integration must belong to the same company')
  end
end

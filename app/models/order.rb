# frozen_string_literal: true

class Order < ApplicationRecord
  include CompanyScoped

  STATUSES = %w[pending paid cancelled].freeze

  belongs_to :company
  belongs_to :company_integration, optional: true
  has_many :order_items, dependent: :destroy

  validates :customer_name, presence: true
  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :external_order_id, uniqueness: { scope: :company_id }, allow_nil: true
  validate :company_integration_belongs_to_company

  private

  # La integración debe pertenecer a la misma empresa que la orden: evita que
  # una orden quede vinculada a una integración de otro tenant.
  def company_integration_belongs_to_company
    return if company_integration.blank? || company_id.blank?
    return if company_integration.company_id == company_id

    errors.add(:company_integration, 'must belong to the same company')
  end
end

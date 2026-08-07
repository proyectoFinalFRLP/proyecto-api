# frozen_string_literal: true

class WebhookLog < ApplicationRecord
  include CompanyScoped

  STATUSES = %w[pending processed failed].freeze

  belongs_to :company
  belongs_to :company_integration

  validates :status, presence: true, inclusion: { in: STATUSES }
  validate :company_integration_belongs_to_company

  scope :pending, -> { where(status: 'pending') }

  private

  # El gateway deriva company_id y company_integration de la misma fuente, así
  # que hoy siempre son consistentes. Cuando los workers (TESIS-39/43) creen
  # logs programáticamente, esta validación evita que quede un log con el
  # tenant de una empresa y la integración de otra.
  def company_integration_belongs_to_company
    return if company_integration.blank? || company_id.blank?
    return if company_integration.company_id == company_id

    errors.add(:company_integration, 'must belong to the same company')
  end
end

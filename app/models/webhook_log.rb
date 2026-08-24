# frozen_string_literal: true

class WebhookLog < ApplicationRecord
  include CompanyScoped

  STATUSES = %w[pending processed failed].freeze
  # Mismo tope que FailedEvent: error_message sirve para diagnosticar, no para
  # guardar un stack trace entero.
  ERROR_LIMIT = 2_000

  belongs_to :company
  belongs_to :company_integration

  validates :status, presence: true, inclusion: { in: STATUSES }
  validate :company_integration_belongs_to_company

  scope :pending, -> { where(status: 'pending') }

  # Lo consultan los procesadores de eventos (Shipments::ProcessTrackingUpdate):
  # el proveedor reintenta la entrega y el worker puede correr más de una vez
  # para el mismo log, así que uno ya procesado no se vuelve a procesar.
  def processed? = status == 'processed'

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

# frozen_string_literal: true

class WebhookLog < ApplicationRecord
  include CompanyScoped

  STATUSES = { pending: 'pending', processed: 'processed', failed: 'failed' }.freeze
  # Mismo tope que FailedEvent: error_message sirve para diagnosticar, no para
  # guardar un stack trace entero.
  ERROR_LIMIT = 2_000

  belongs_to :company
  belongs_to :company_integration

  # Mismo criterio que FailedEvent: el enum da los predicados y los scopes
  # (`pending`, `processed?`) y `validate: true` hace que un status desconocido
  # invalide el registro en lugar de explotar en el asignador.
  enum :status, STATUSES, validate: true

  validate :company_integration_belongs_to_company

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

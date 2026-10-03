# frozen_string_literal: true

class CompanyIntegration < ApplicationRecord
  include CompanyScoped

  belongs_to :company
  belongs_to :service
  has_many :product_mappings, dependent: :destroy
  has_many :shipments, dependent: :nullify

  # El nombre del servicio se lee tanto que la cadena
  # `integration.service.service_name` estaba escrita en cinco lugares. `service`
  # es un belongs_to obligatorio, asi que la delegacion no necesita allow_nil.
  delegate :service_name, to: :service

  serialize :credentials, coder: JSON
  encrypts :credentials

  validates :service_id, uniqueness: { scope: :company_id }
  validate :service_is_connectable

  def display_name
    "#{company&.name} \u2194 #{service&.service_name}"
  end

  private

  # Una plantilla hija (ej. 'Shopify - Conexión') corre con la integración de su
  # madre. Conectarla sola dejaría una integración que ninguna parte del sistema
  # usa: el backoffice la ofrecería en el alta si no se validara acá.
  def service_is_connectable
    return if service.nil? || service.connectable?

    errors.add(:service, 'is an operation of another template and cannot be connected on its own')
  end
end

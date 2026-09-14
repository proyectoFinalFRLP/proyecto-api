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

  def display_name
    "#{company&.name} \u2194 #{service&.service_name}"
  end
end

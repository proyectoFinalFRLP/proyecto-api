# frozen_string_literal: true

class Service < ApplicationRecord
  # `type` es una columna de dominio (ecommerce | courier), NO el discriminador
  # de STI de Rails. Se desactiva STI para conservar el nombre definido en el DER.
  self.inheritance_column = nil

  TYPES = %w[ecommerce courier].freeze

  has_many :company_integrations, dependent: :restrict_with_error

  validates :service_name, presence: true, uniqueness: true
  validates :uri, presence: true
  validates :http_method, presence: true
  validates :type, presence: true, inclusion: { in: TYPES }
end

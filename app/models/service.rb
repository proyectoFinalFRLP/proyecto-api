# frozen_string_literal: true

class Service < ApplicationRecord
  self.inheritance_column = nil

  TYPES = %w[ecommerce courier].freeze
  MAPPER_FIELDS = %w[request_mapper response_mapper request_value_mapper
                     response_value_mapper].freeze

  has_many :company_integrations, dependent: :restrict_with_error

  validates :service_name, presence: true, uniqueness: true
  validates :uri, presence: true
  validates :http_method, presence: true
  validates :type, presence: true, inclusion: { in: TYPES }
  validate :mappers_are_valid_json

  # Los mappers aceptan String JSON (formularios del backoffice) además de Hash:
  # un String se parsea y, si es inválido o no es un objeto, el registro queda
  # inválido y conserva el valor anterior.
  MAPPER_FIELDS.each do |mapper|
    define_method(:"#{mapper}=") do |value|
      super(coerce_mapper(mapper, value))
    end
  end

  private

  def coerce_mapper(field, value)
    mapper_errors.delete(field)
    return value unless value.is_a?(String)
    return {} if value.blank?

    parse_mapper(field, value)
  end

  def parse_mapper(field, value)
    parsed = JSON.parse(value)
    return parsed if parsed.is_a?(Hash)

    mapper_errors[field] = 'debe ser un objeto JSON (diccionario clave-valor)'
    self[field]
  rescue JSON::ParserError
    mapper_errors[field] = 'no es un JSON válido'
    self[field]
  end

  def mapper_errors
    @mapper_errors ||= {}
  end

  def mappers_are_valid_json
    mapper_errors.each { |field, message| errors.add(field, message) }
  end
end

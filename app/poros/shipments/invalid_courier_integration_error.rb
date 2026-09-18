# frozen_string_literal: true

module Shipments
  # La integración elegida existe y es del tenant, pero no sirve para despachar:
  # no es un courier, está inactiva, o su plantilla no declara de dónde sacar el
  # número de seguimiento. Es un dato del request que el usuario puede corregir
  # eligiendo otro operador, así que el controller lo mapea a 422.
  class InvalidCourierIntegrationError < StandardError
    attr_reader :company_integration_id

    def initialize(company_integration:, reason:)
      @company_integration_id = company_integration.id
      super("integration #{company_integration.id} cannot dispatch a shipment: #{reason}")
    end
  end
end

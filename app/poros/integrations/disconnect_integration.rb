# frozen_string_literal: true

module Integrations
  # Desconectar: la integración deja de recibir y mandar tráfico y se borran
  # sus secretos (incluido el token). Se conservan los settings y los productos
  # vinculados, para poder reconectar la misma cuenta sin volver a mapear.
  class DisconnectIntegration < ApplicationPoro
    def initialize(company_integration:)
      super()
      @integration = company_integration
    end

    def call
      @integration.update!(is_active: false, credentials: {})
      @integration
    end
  end
end

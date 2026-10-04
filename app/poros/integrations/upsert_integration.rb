# frozen_string_literal: true

module Integrations
  class UpsertIntegration < ApplicationPoro
    # `credentials`, `settings` e `is_active` son opcionales: sin ellos, lo que ya
    # tenía la integración se conserva (editar la configuración no la reactiva,
    # y activarla no obliga a reenviar las credenciales). Una integración nueva
    # nace activa.
    def initialize(company:, service_id:, credentials: nil, is_active: nil, settings: nil)
      super()
      @company = company
      @service_id = service_id
      @credentials = credentials
      @is_active = is_active
      @settings = settings
    end

    # Una plantilla hija no es conectable: se ejecuta con la integración de su
    # madre, así que para el alta es como si no existiera (404).
    def call
      service = Service.connectable.find(@service_id)
      integration = @company.company_integrations.find_or_initialize_by(service: service)
      assign_connection(integration, service)
      integration.is_active = @is_active unless @is_active.nil?
      integration.save!
      integration
    end

    private

    # Una plantilla que declara sus campos valida y combina (ApplyDeclaredFields).
    # Las que no declaran nada conservan el contrato de siempre: `credentials`
    # reemplaza entero lo que había.
    def assign_connection(integration, service)
      if service.declares_fields?
        integration.credentials, integration.settings = ApplyDeclaredFields.new(
          service: service, integration: integration,
          credentials: @credentials, settings: @settings
        ).call
      else
        integration.credentials = @credentials unless @credentials.nil?
        integration.settings = @settings unless @settings.nil?
      end
    end
  end
end

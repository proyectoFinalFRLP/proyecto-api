# frozen_string_literal: true

module Integrations
  class UpsertIntegration < ApplicationPoro
    # `settings` es opcional: sin él, la configuración que ya tenía la
    # integración se conserva.
    def initialize(company:, service_id:, credentials:, is_active: true, settings: nil)
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
      integration.credentials = @credentials
      integration.settings = @settings unless @settings.nil?
      integration.is_active = @is_active
      integration.save!
      integration
    end
  end
end

# frozen_string_literal: true

module Integrations
  class UpsertIntegration < ApplicationPoro
    def initialize(company:, service_id:, credentials:, is_active: true)
      super()
      @company = company
      @service_id = service_id
      @credentials = credentials
      @is_active = is_active
    end

    def call
      service = Service.find(@service_id)
      integration = @company.company_integrations.find_or_initialize_by(service: service)
      integration.credentials = @credentials
      integration.is_active = @is_active
      integration.save!
      integration
    end
  end
end

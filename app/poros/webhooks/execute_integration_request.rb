# frozen_string_literal: true

module Webhooks
  # Envuelve una llamada saliente del HttpAdapter con la red de contención de la
  # DLQ: si la llamada falla, el evento queda persistido para reintento y el
  # flujo de negocio no se corta.
  #
  # Devuelve la respuesta parseada del adapter, o `nil` si el evento fue derivado
  # a la Dead Letter Queue.
  class ExecuteIntegrationRequest < ApplicationPoro
    def initialize(company_integration:, payload: {}, uri_params: {})
      super()
      @integration = company_integration
      @payload = payload
      @uri_params = uri_params
    end

    def call
      Integrations::HttpAdapter.new(
        company_integration: @integration, payload: @payload, uri_params: @uri_params
      ).call
    rescue Integrations::AdapterExecutionError => e
      register(e)
      nil
    end

    private

    def register(error)
      RegisterFailedEvent.new(
        event_type: ReplayRegistry::HTTP_REQUEST,
        payload: { 'payload' => @payload, 'uri_params' => @uri_params },
        company_integration: @integration,
        error: error
      ).call
    end
  end
end

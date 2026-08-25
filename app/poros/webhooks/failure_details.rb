# frozen_string_literal: true

module Webhooks
  # Traduce una excepción a las columnas de diagnóstico de un FailedEvent.
  # Compartido entre el registro inicial y cada reintento.
  module FailureDetails
    def failure_details(error)
      return { last_error: nil, last_response_status: nil, last_response_body: nil } if error.nil?

      {
        last_error: truncate_detail("#{error.class}: #{error.message}"),
        last_response_status: adapter_error?(error) ? error.response_status : nil,
        last_response_body: adapter_error?(error) ? truncate_detail(error.response_body) : nil
      }
    end

    private

    def adapter_error?(error) = error.is_a?(Integrations::AdapterExecutionError)

    def truncate_detail(text) = text&.to_s&.truncate(FailedEvent::ERROR_LIMIT)
  end
end

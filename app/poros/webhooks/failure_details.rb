# frozen_string_literal: true

module Webhooks
  # Traduce una excepción a las columnas de diagnóstico de un FailedEvent.
  # Compartido entre el registro inicial y cada reintento.
  #
  # `error_code` es el código de soporte del catálogo (ADR-024): lo que el
  # operador ve y le dicta a soporte. `last_error` conserva el texto técnico.
  module FailureDetails
    def failure_details(error)
      if error.nil?
        return { error_code: nil, last_error: nil, last_response_status: nil,
                 last_response_body: nil }
      end

      {
        error_code: ErrorCatalog.code_for(error),
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

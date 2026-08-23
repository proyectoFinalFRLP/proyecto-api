# frozen_string_literal: true

module Webhooks
  # Mapea el `event_type` de un FailedEvent con el PORO que sabe reprocesarlo.
  # El motor de reintentos no conoce ningún dominio: solo busca acá y ejecuta.
  # Para sumar un tipo de evento nuevo (ej. webhooks entrantes de TESIS-36) basta
  # con registrar su replayer; el motor no cambia.
  class ReplayRegistry
    class UnknownEventType < StandardError; end

    HTTP_REQUEST = 'integrations.http_request'

    REPLAYERS = {
      HTTP_REQUEST => 'Webhooks::Replayers::HttpRequest'
    }.freeze

    def self.fetch(event_type)
      REPLAYERS.fetch(event_type) do
        raise UnknownEventType, "no replayer registered for event_type '#{event_type}'"
      end.constantize
    end
  end
end

# frozen_string_literal: true

module Webhooks
  # Salida manual de la DLQ: el operador decide que el evento no debe reintentarse
  # más. Libera el claim para que un evento descartado mientras estaba en processing
  # no quede como candidato del barrido.
  class DiscardFailedEvent < ApplicationPoro
    def initialize(failed_event:)
      super()
      @event = failed_event
    end

    def call
      @event.update!(status: :discarded, next_retry_at: nil, claimed_at: nil)
      @event
    end
  end
end

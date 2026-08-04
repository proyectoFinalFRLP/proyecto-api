# frozen_string_literal: true

module Webhooks
  # Punto de entrada único de la Dead Letter Queue: persiste un evento que falló
  # y lo deja agendado para el primer reintento automático.
  class RegisterFailedEvent < ApplicationPoro
    include FailureDetails

    def initialize(event_type:, payload: {}, company_integration: nil, error: nil,
                   direction: :outbound)
      super()
      @event_type = event_type
      @payload = payload
      @company_integration = company_integration
      @error = error
      @direction = direction
    end

    def call
      FailedEvent.create!(
        event_type: @event_type,
        direction: @direction,
        payload: @payload,
        company_integration: @company_integration,
        status: :pending,
        attempts: 0,
        max_attempts: FailedEvent::DEFAULT_MAX_ATTEMPTS,
        next_retry_at: FailedEvent.next_retry_at(0),
        **failure_details(@error)
      )
    end
  end
end

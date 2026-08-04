# frozen_string_literal: true

module Webhooks
  # Ejecuta un intento de reproceso sobre un FailedEvent ya reclamado por el job.
  # Nunca propaga la excepción: el resultado del intento se persiste en el propio
  # evento para no disparar además el retry de Active Job.
  class RetryFailedEvent < ApplicationPoro
    include FailureDetails

    def initialize(failed_event:)
      super()
      @event = failed_event
    end

    def call
      ReplayRegistry.fetch(@event.event_type).new(failed_event: @event).call
      mark_succeeded
    rescue StandardError => e
      mark_failed(e)
    end

    private

    def mark_succeeded
      @event.update!(status: :succeeded, attempts: @event.attempts + 1,
                     next_retry_at: nil, last_error: nil)
      @event
    end

    def mark_failed(error)
      @event.attempts += 1
      exhausted = @event.attempts_exhausted?

      @event.update!(
        status: exhausted ? :dead : :pending,
        next_retry_at: exhausted ? nil : FailedEvent.next_retry_at(@event.attempts),
        **failure_details(error)
      )
      @event
    end
  end
end

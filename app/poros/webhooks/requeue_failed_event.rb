# frozen_string_literal: true

module Webhooks
  # Reintento manual desde la API: devuelve el evento a la cola con el contador
  # de intentos en cero y lo encola de inmediato, sin esperar al cronjob.
  class RequeueFailedEvent < ApplicationPoro
    class NotRequeueable < StandardError; end

    REQUEUEABLE_STATUSES = %w[pending dead discarded].freeze

    def initialize(failed_event:)
      super()
      @event = failed_event
    end

    def call
      unless REQUEUEABLE_STATUSES.include?(@event.status)
        raise NotRequeueable, "a #{@event.status} event cannot be requeued"
      end

      @event.update!(status: :pending, attempts: 0, next_retry_at: Time.current)
      RetryFailedEventJob.perform_later(@event.id, @event.company_id)
      @event
    end
  end
end

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
      raise NotRequeueable, "a #{@event.status} event cannot be requeued" unless requeueable?

      @event.update!(status: :pending, attempts: 0, next_retry_at: Time.current,
                     claimed_at: nil)
      RetryFailedEventJob.perform_later(@event.id, @event.company_id)
      @event
    end

    private

    # Un evento en processing no se toca mientras el worker que lo reclamó siga
    # vivo. Si el claim venció, ese worker murió y el reintento manual es una de
    # las dos formas de rescatarlo (la otra es el barrido del cronjob).
    def requeueable? = REQUEUEABLE_STATUSES.include?(@event.status) || @event.stalled?
  end
end

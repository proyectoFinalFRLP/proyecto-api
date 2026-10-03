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

    # Un éxito se registra aunque el evento se haya descartado mientras corría:
    # la venta o el envío ya se procesaron, y `succeeded` es tan terminal como
    # `discarded` —no vuelve a la cola—, pero además dice la verdad.
    def mark_succeeded
      @event.with_lock do
        @event.update!(status: :succeeded, attempts: @event.attempts + 1,
                       next_retry_at: nil, last_error: nil, claimed_at: nil)
      end
      @event
    end

    # El intento falló, pero el evento pudo cambiar de manos mientras corría: un
    # operador lo descartó (o lo reencoló) desde la API. Esa decisión gana. Antes
    # se escribía encima sin releer, el evento volvía a `pending` con un
    # `next_retry_at` y el barrido lo seguía reintentando aunque lo hubieran
    # descartado (hallazgo de la auditoría de TESIS-89).
    #
    # `with_lock` relee la fila con FOR UPDATE: la decisión del operador y este
    # resultado no se pueden cruzar a mitad de camino.
    def mark_failed(error)
      @event.with_lock do
        next unless @event.processing?

        @event.attempts += 1
        exhausted = @event.attempts_exhausted?
        @event.update!(
          status: exhausted ? :dead : :pending,
          next_retry_at: exhausted ? nil : FailedEvent.next_retry_at(@event.attempts),
          claimed_at: nil,
          **failure_details(error)
        )
      end
      @event
    end
  end
end

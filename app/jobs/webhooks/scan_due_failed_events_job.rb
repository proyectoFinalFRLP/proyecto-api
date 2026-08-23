# frozen_string_literal: true

module Webhooks
  # Cronjob del motor de reintentos (config/recurring.yml). Es el único job que
  # corre fuera de todo contexto de tenant: barre la DLQ de todas las empresas
  # con `unscoped` y encola un job por evento a reintentar, pasándole su company_id.
  #
  # Barre dos cosas: los pendientes con el reintento vencido y los eventos que
  # quedaron en processing con el claim vencido, que son los que perdió un worker
  # al morir entre el claim y la persistencia del resultado.
  class ScanDueFailedEventsJob < ApplicationJob
    queue_as :low

    BATCH_SIZE = 500

    def perform
      retryable_events.each { |id, company_id| RetryFailedEventJob.perform_later(id, company_id) }
    end

    private

    # El `order` no es cosmético: sin él, con más vencidos que BATCH_SIZE Postgres
    # puede devolver el mismo subconjunto tick tras tick y dejar al resto sin atender.
    def retryable_events
      FailedEvent.unscoped.retryable.order(:next_retry_at).limit(BATCH_SIZE)
                 .pluck(:id, :company_id)
    end
  end
end

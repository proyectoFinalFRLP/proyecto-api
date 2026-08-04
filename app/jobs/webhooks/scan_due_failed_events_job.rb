# frozen_string_literal: true

module Webhooks
  # Cronjob del motor de reintentos (config/recurring.yml). Es el único job que
  # corre fuera de todo contexto de tenant: barre la DLQ de todas las empresas
  # con `unscoped` y encola un job por evento vencido, pasándole su company_id.
  class ScanDueFailedEventsJob < ApplicationJob
    queue_as :low

    BATCH_SIZE = 500

    def perform
      FailedEvent.unscoped.due.limit(BATCH_SIZE).pluck(:id, :company_id).each do |id, company_id|
        RetryFailedEventJob.perform_later(id, company_id)
      end
    end
  end
end

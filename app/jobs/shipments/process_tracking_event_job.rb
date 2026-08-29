# frozen_string_literal: true

module Shipments
  # Procesa una actualización de tracking empujada por un courier. Es un evento
  # entrante que el vendedor espera ver reflejado cuanto antes: por eso corre en
  # la cola realtime en vez de compartir la low con los reintentos de la DLQ.
  class ProcessTrackingEventJob < ApplicationJob
    queue_as :realtime

    def perform(webhook_log_id, company_id)
      with_tenant(company_id) do
        log = WebhookLog.find_by(id: webhook_log_id)
        next if log.nil? # el log puede haberse borrado entre el encolado y la ejecución

        ingest(log)
      end
    end

    private

    # Si la excepción subiera acá, Active Job reintentaría por su cuenta el mismo
    # trabajo que RegisterFailedEvent ya deja agendado en la DLQ, con otro backoff
    # y sin quedar en una tabla consultable. Por eso el fallo se atrapa en el job
    # y nunca se propaga: la DLQ es el único mecanismo de reintento de este evento.
    def ingest(log)
      Shipments::ProcessTrackingUpdate.new(webhook_log: log).call
    rescue StandardError => e
      register_failure(log, e)
    end

    # Sólo se guarda el webhook_log_id: el payload crudo del courier ya vive en
    # webhook_logs como fuente de verdad (auditoría), así que la DLQ no lo
    # duplica y el replayer vuelve a levantarlo por esa referencia al reintentar.
    def register_failure(log, error)
      Webhooks::RegisterFailedEvent.new(
        event_type: Webhooks::ReplayRegistry::TRACKING_INGESTION,
        direction: :inbound,
        payload: { 'webhook_log_id' => log.id },
        company_integration: log.company_integration,
        error: error
      ).call
    end
  end
end

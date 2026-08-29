# frozen_string_literal: true

module Orders
  # Procesa un webhook de venta ya persistido por el gateway. Va a la cola
  # `realtime`: es un evento entrante que el vendedor espera ver reflejado cuanto
  # antes (el stock que se descuenta acá es el que se publica a los canales).
  #
  # El job no decide nada de negocio: reclama el tenant, delega en el PORO y, si
  # el intento falla, deriva el evento a la Dead Letter Queue (ADR-008) para que
  # el motor de reintentos lo vuelva a intentar solo.
  class ProcessWebhookEventJob < ApplicationJob
    queue_as :realtime

    def perform(webhook_log_id, company_id)
      with_tenant(company_id) do
        # El log puede haberse borrado entre el encolado y la ejecución (baja de
        # la integración, purga de auditoría): es un final esperado, no un fallo.
        log = WebhookLog.find_by(id: webhook_log_id)
        next if log.nil?

        ingest(log)
      end
    end

    private

    # La excepción no se propaga: el reintento lo maneja la DLQ, que persiste el
    # backoff y deja el evento visible por API. Dejarla subir sumaría encima el
    # retry de Active Job, que no distingue un fallo transitorio de un producto
    # sin mapear.
    def ingest(log)
      ProcessWebhookOrder.new(webhook_log: log).call
    rescue StandardError => e
      register_for_retry(log, e)
    end

    def register_for_retry(log, error)
      Webhooks::RegisterFailedEvent.new(
        event_type: Webhooks::ReplayRegistry::ORDER_INGESTION,
        direction: :inbound,
        payload: { 'webhook_log_id' => log.id },
        company_integration: log.company_integration,
        error: error
      ).call
    end
  end
end

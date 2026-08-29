# frozen_string_literal: true

module Webhooks
  module Replayers
    # Reprocesa un evento de tracking entrante que había fallado, releyendo el
    # WebhookLog original a partir del webhook_log_id persistido en el FailedEvent
    # (webhook_logs sigue siendo la fuente de verdad del payload crudo).
    class TrackingIngestion < ApplicationPoro
      class MissingWebhookLog < StandardError; end

      def initialize(failed_event:)
        super()
        @event = failed_event
      end

      # Idempotente: si mientras el evento esperaba turno en la DLQ alguien ya
      # lo procesó -o el log quedó `processed`-, Shipments::ProcessTrackingUpdate
      # corta sin duplicar nada (regla de idempotencia de ShipmentEvent) y el
      # intento cuenta como éxito igual.
      def call
        log = WebhookLog.find_by(id: @event.payload['webhook_log_id'])
        raise MissingWebhookLog, 'the webhook log no longer exists' if log.nil?

        Shipments::ProcessTrackingUpdate.new(webhook_log: log).call
      end
    end
  end
end

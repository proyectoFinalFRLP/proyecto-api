# frozen_string_literal: true

module Webhooks
  module Replayers
    # Reprocesa la ingesta de una venta entrante que había fallado: vuelve a
    # correr el PORO sobre el mismo WebhookLog, que sigue siendo la fuente de
    # verdad del evento crudo (por eso el FailedEvent guarda sólo su id).
    #
    # Es idempotente: si mientras tanto la orden se creó —o el log quedó
    # `processed`— el PORO corta sin duplicar nada y el intento cuenta como éxito.
    class OrderIngestion < ApplicationPoro
      class MissingWebhookLog < StandardError; end

      def initialize(failed_event:)
        super()
        @event = failed_event
      end

      def call
        log = WebhookLog.find_by(id: @event.payload['webhook_log_id'])
        raise MissingWebhookLog, 'the webhook log no longer exists' if log.nil?

        Orders::ProcessWebhookOrder.new(webhook_log: log).call
      end
    end
  end
end

# frozen_string_literal: true

module Api
  module Webhooks
    # Punto de entrada público para las plataformas externas: persiste el evento
    # crudo y libera la conexión. Sin autenticación JWT (los proveedores no
    # tienen sesión en el OMS) y sin lógica de negocio: el procesamiento real
    # queda a cargo de los workers asíncronos. La mecánica común de ingesta vive
    # en el concern EventIngestion, compartido con CouriersController.
    class IntegrationsController < ApplicationController
      include EventIngestion

      private

      # El procesamiento real corre en un worker (TESIS-43): el gateway sólo
      # persiste y encola. Sólo los canales de e-commerce generan ventas; los
      # webhooks de couriers quedan a cargo de CouriersController (TESIS-48).
      def enqueue_processing(log, integration)
        return unless integration.service.ecommerce?

        Orders::ProcessWebhookEventJob.perform_later(log.id, log.company_id)
      end
    end
  end
end

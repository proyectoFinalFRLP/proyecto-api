# frozen_string_literal: true

module Api
  module Webhooks
    # Recibe el push de tracking de los operadores logísticos. El evento se
    # persiste siempre (auditoría, vía el concern EventIngestion) pero sólo se
    # encola para procesar si la integración es de un Service de tipo courier:
    # un webhook de e-commerce que llegara por acá no tiene traducción de
    # tracking que aplicarle. Nunca rechaza al proveedor: siempre 202.
    class CouriersController < ApplicationController
      include EventIngestion

      private

      def enqueue_processing(log, integration)
        return unless integration.service.courier?

        Shipments::ProcessTrackingEventJob.perform_later(log.id, log.company_id)
      end
    end
  end
end

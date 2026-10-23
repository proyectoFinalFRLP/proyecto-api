# frozen_string_literal: true

module Api
  module V1
    # Tope de `GET /api/v1/shipments/:id/label` (TESIS-188).
    #
    # La etiqueta sale a pedir el PDF al courier cada vez, con las credenciales
    # de la empresa (TESIS-186): un cliente en loop —una pestaña que recarga
    # sola— le pega al courier tantas veces como quiera. Mismo criterio que la
    # cotización del alta (DraftQuotesController): por usuario, y con margen
    # para imprimir una tanda de etiquetas seguidas.
    module LabelRateLimit
      extend ActiveSupport::Concern

      LABELS_PER_WINDOW = 30
      LABEL_WINDOW = 1.minute

      included do
        rate_limit to: LABELS_PER_WINDOW, within: LABEL_WINDOW, only: :label,
                   by: -> { current_user.id }, with: :render_too_many_labels
      end

      private

      def render_too_many_labels
        response.set_header('Retry-After', LABEL_WINDOW.to_i.to_s)
        render json: { error: 'Too many label requests, try again later' },
               status: :too_many_requests
      end
    end
  end
end

# frozen_string_literal: true

module Api
  module V1
    # Lo último que pasó en la empresa, para el panel de la campanita
    # (TESIS-162). Colección: viaja en `data` sin `meta`, porque no pagina —es
    # un desplegable con un techo, no un listado (ADR-015).
    class ActivityController < ApplicationController
      def index
        authorize :activity, :index?
        # El feed no sale de un scope: son tres consultas a tres modelos, y los
        # tres ya filtran por tenant —`Order` y `FailedEvent` con CompanyScoped,
        # los eventos de envío por el join con `Shipment`—. No hay un
        # `policy_scope` que aplicar sin inventar un modelo que no existe.
        skip_policy_scope

        render json: { data: Activity::BuildFeed.new(limit: scalar_param(:limit)).call }
      end
    end
  end
end

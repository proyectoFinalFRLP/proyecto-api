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
    end
  end
end

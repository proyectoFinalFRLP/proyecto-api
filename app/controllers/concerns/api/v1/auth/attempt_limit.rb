# frozen_string_literal: true

module Api
  module V1
    module Auth
      # Límite de intentos para los endpoints públicos de auth: login y registro.
      #
      # Sin esto se podían probar contraseñas sin freno: después de 30 incorrectas
      # seguidas, la correcta entraba igual. Se limita por IP con el rate_limit de
      # Rails y no con el :lockable de Devise, que bloquea la cuenta: con él,
      # cualquiera podría dejar afuera a otro usuario tipeando mal su password a
      # propósito.
      #
      # El contador vive en la cache de la app, que en producción es Solid Cache y
      # la comparten todos los procesos. En test la cache es :null_store y el
      # límite nunca se alcanza, así los specs que loguean muchas veces no chocan
      # con él; el spec del límite le da una cache de verdad a propósito.
      module AttemptLimit
        extend ActiveSupport::Concern

        MAX_ATTEMPTS = 10
        WINDOW = 3.minutes

        included do
          rate_limit to: MAX_ATTEMPTS, within: WINDOW, only: :create,
                     with: :render_too_many_attempts
        end

        private

        def render_too_many_attempts
          response.set_header('Retry-After', WINDOW.to_i.to_s)
          render json: { error: 'Too many attempts, try again later' }, status: :too_many_requests
        end
      end
    end
  end
end

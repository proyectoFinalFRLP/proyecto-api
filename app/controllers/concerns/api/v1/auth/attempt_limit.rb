# frozen_string_literal: true

module Api
  module V1
    module Auth
      # Límite de intentos para los endpoints públicos de auth: login y registro.
      # El contador y sus reglas son los de FailedAttemptLimit, que comparte con
      # el login del backoffice; acá queda lo propio de la API.
      #
      # Cada endpoint cuenta distinto:
      # - Login: sólo los intentos fallidos (before_action
      #   :refuse_exhausted_attempts + count_failed_attempt en la rama del 401).
      #   El que entra no está adivinando nada, y contar los exitosos dejaba
      #   afuera al undécimo operario de un depósito detrás de un mismo NAT
      #   aunque pusiera bien su password.
      # - Registro: todos, con el rate_limit de Rails. Cada pedido crea una
      #   solicitud, y no hay un «pedido exitoso» que se repita en el uso normal.
      module AttemptLimit
        extend ActiveSupport::Concern
        include FailedAttemptLimit

        private

        def respond_too_many_attempts
          render json: { error: 'Too many attempts, try again later' }, status: :too_many_requests
        end
      end
    end
  end
end

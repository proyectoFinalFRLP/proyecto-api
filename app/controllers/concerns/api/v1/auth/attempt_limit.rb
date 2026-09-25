# frozen_string_literal: true

module Api
  module V1
    module Auth
      # Límite de intentos para los endpoints públicos de auth: login y registro.
      #
      # Sin esto se podían probar contraseñas sin freno: después de 30 incorrectas
      # seguidas, la correcta entraba igual. Se limita por IP y no con el
      # :lockable de Devise, que bloquea la cuenta: con él, cualquiera podría
      # dejar afuera a otro usuario tipeando mal su password a propósito.
      #
      # Cada endpoint cuenta distinto:
      # - Login: sólo los intentos fallidos (before_action
      #   :refuse_exhausted_attempts + count_failed_attempt en la rama del 401).
      #   El que entra no está adivinando nada, y contar los exitosos dejaba
      #   afuera al undécimo operario de un depósito detrás de un mismo NAT
      #   aunque pusiera bien su password.
      # - Registro: todos, con el rate_limit de Rails. Cada pedido crea una
      #   solicitud, y no hay un «pedido exitoso» que se repita en el uso normal.
      #
      # El contador vive en la cache de la app, que en producción es Solid Cache y
      # la comparten todos los procesos. En test la cache es :null_store y el
      # límite nunca se alcanza, así los specs que loguean muchas veces no chocan
      # con él; el spec del límite le da una cache de verdad a propósito.
      module AttemptLimit
        extend ActiveSupport::Concern

        MAX_ATTEMPTS = 10
        WINDOW = 3.minutes

        private

        # Una vez agotados se rechaza sin mirar la password, también la correcta:
        # si se la evaluara, el que prueba contraseñas seguiría probando y la
        # correcta le daría el token igual.
        def refuse_exhausted_attempts
          render_too_many_attempts if failed_attempts >= MAX_ATTEMPTS
        end

        # La ventana es fija: el increment de la cache conserva el vencimiento
        # que tomó la entrada con el primer fallo.
        def count_failed_attempt
          attempt_store.increment(failed_attempts_key, 1, expires_in: WINDOW)
        end

        # `raw: true` porque el valor lo escribió increment, que en algunos stores
        # guarda el entero sin serializar.
        def failed_attempts
          attempt_store.read(failed_attempts_key, raw: true).to_i
        end

        def failed_attempts_key
          "auth-failed-attempts:#{request.remote_ip}"
        end

        def attempt_store
          self.class.cache_store
        end

        def render_too_many_attempts
          response.set_header('Retry-After', WINDOW.to_i.to_s)
          render json: { error: 'Too many attempts, try again later' }, status: :too_many_requests
        end
      end
    end
  end
end

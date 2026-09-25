# frozen_string_literal: true

module Admin
  class SessionsController < Devise::SessionsController
    # Límite de intentos del login del backoffice (TESIS-129). Sin él, después
    # de 30 passwords incorrectas seguidas la correcta entraba igual. Mismo
    # criterio que TESIS-82 para el login de la API: por IP y no con :lockable,
    # que dejaría que cualquiera bloquee la cuenta del admin tipeando mal a
    # propósito, y contando sólo los intentos fallidos.
    #
    # El contador vive en la cache de la app (Solid Cache en producción). En
    # test es :null_store y el límite nunca se alcanza; el spec del límite le
    # da una cache de verdad.
    MAX_FAILED_ATTEMPTS = 10
    ATTEMPT_WINDOW = 3.minutes

    layout 'admin_auth'

    before_action :refuse_exhausted_attempts, only: :create

    # Devise no devuelve el fallo: warden.authenticate! lo tira con
    # `throw :warden` y lo atrapa el middleware de Warden, que responde con el
    # failure app. Se atrapa acá sólo para contarlo, y se vuelve a tirar tal
    # cual para que la respuesta siga siendo la de Devise.
    def create
      failure = catch(:warden) do
        super
        nil
      end
      return unless failure

      count_failed_attempt
      throw :warden, failure
    end

    private

    def after_sign_in_path_for(_resource)
      '/admin'
    end

    def after_sign_out_path_for(_scope)
      new_admin_user_session_path
    end

    # Agotados los intentos se rechaza sin mirar la password, también la
    # correcta: si se la evaluara, el que prueba contraseñas seguiría probando.
    def refuse_exhausted_attempts
      return if failed_attempts < MAX_FAILED_ATTEMPTS

      response.set_header('Retry-After', ATTEMPT_WINDOW.to_i.to_s)
      self.resource = resource_class.new
      set_flash_message(:alert, :too_many_attempts, now: true)
      render :new, status: :too_many_requests
    end

    # La ventana es fija: el increment conserva el vencimiento que tomó la
    # entrada con el primer fallo.
    def count_failed_attempt
      attempt_store.increment(failed_attempts_key, 1, expires_in: ATTEMPT_WINDOW)
    end

    # `raw: true` porque el valor lo escribió increment, que en algunos stores
    # guarda el entero sin serializar.
    def failed_attempts
      attempt_store.read(failed_attempts_key, raw: true).to_i
    end

    def failed_attempts_key
      "admin-failed-logins:#{request.remote_ip}"
    end

    def attempt_store
      self.class.cache_store
    end
  end
end

# frozen_string_literal: true

module Admin
  class SessionsController < Devise::SessionsController
    # Límite de intentos del login del backoffice (TESIS-129): sin él, después
    # de 30 passwords incorrectas seguidas la correcta entraba igual. Es el
    # mismo contador que el del login de la API, con su propia cuenta.
    include FailedAttemptLimit

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

    # Rota el token antes de cerrar la sesión: ver AdminUser#authenticatable_salt.
    def destroy
      current_admin_user&.expire_sessions!
      super
    end

    private

    def after_sign_in_path_for(_resource)
      '/admin'
    end

    def after_sign_out_path_for(_scope)
      new_admin_user_session_path
    end

    # El 429 del backoffice es el formulario de login con el aviso, no JSON.
    def respond_too_many_attempts
      self.resource = resource_class.new
      set_flash_message(:alert, :too_many_attempts, now: true)
      render :new, status: :too_many_requests
    end
  end
end

# frozen_string_literal: true

Devise.setup do |config|
  # :html habilita el login navegacional del backoffice (scope admin_user);
  # la API JWT (scope user) sigue respondiendo 401 en JSON, sin redirects.
  config.navigational_formats = [:html]

  # Los controllers de Devise (login del backoffice) necesitan una base HTML
  # completa, no el ApplicationController API-only con JWT.
  config.parent_controller = 'ActionController::Base'

  # El lambda difiere la resolución de la constante hasta el request, para no
  # forzar el autoload durante el boot.
  config.warden do |manager|
    manager.failure_app = ->(env) { ApiAwareFailureApp.call(env) }
  end

  config.jwt do |jwt|
    jwt.secret = ENV.fetch('DEVISE_JWT_SECRET_KEY') { Rails.application.secret_key_base }
    jwt.expiration_time = 1.day.to_i
  end
end

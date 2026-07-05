# frozen_string_literal: true

# Configuración de devise-jwt. Se aísla del initializer principal de Devise
# para mantener la config de JWT acotada y legible.
Devise.setup do |config|
  # API-only: sin formatos de navegación (evita flash/redirects de Devise).
  config.navigational_formats = []

  config.jwt do |jwt|
    jwt.secret = ENV.fetch('DEVISE_JWT_SECRET_KEY') { Rails.application.secret_key_base }
    jwt.dispatch_requests = [['POST', %r{^/api/v1/auth/login$}]]
    jwt.expiration_time = 1.day.to_i
  end
end

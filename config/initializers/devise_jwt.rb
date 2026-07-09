# frozen_string_literal: true

Devise.setup do |config|
  config.navigational_formats = []

  config.jwt do |jwt|
    jwt.secret = ENV.fetch('DEVISE_JWT_SECRET_KEY') { Rails.application.secret_key_base }
    jwt.expiration_time = 1.day.to_i
  end
end

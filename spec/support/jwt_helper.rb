# frozen_string_literal: true

module JwtHelper
  def decode_jwt(token)
    secret = ENV.fetch('DEVISE_JWT_SECRET_KEY') { Rails.application.secret_key_base }
    JWT.decode(token, secret, true, { algorithm: 'HS256' }).first
  end
end

RSpec.configure do |config|
  config.include JwtHelper, type: :request
end

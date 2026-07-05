# frozen_string_literal: true

module Auth
  # Valida credenciales y devuelve un JWT firmado, o nil si son inválidas.
  class AuthenticateUser < ApplicationPoro
    def initialize(email:, password:)
      super()
      @email = email
      @password = password
    end

    def call
      user = User.find_by(email: @email)
      return nil unless user&.valid_password?(@password)

      Warden::JWTAuth::UserEncoder.new.call(user, :user, nil).first
    end
  end
end

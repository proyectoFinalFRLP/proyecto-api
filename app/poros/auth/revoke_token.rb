# frozen_string_literal: true

module Auth
  # Revoca el token con el que llega el request. El encoder vive en
  # AuthenticateUser; este es su par simétrico.
  #
  # Se decodifica el token en lugar de leer `current_user.jti` porque el jti no
  # está en el modelo: identifica al token, no al usuario, y un mismo usuario
  # puede tener varios tokens vivos (dos navegadores, dos dispositivos). Revocar
  # por usuario los cerraría todos.
  class RevokeToken < ApplicationPoro
    def initialize(user:, authorization_header:)
      super()
      @user = user
      @header = authorization_header
    end

    # Devuelve true si el token quedó revocado. Un token ilegible no es un error
    # del cliente: ya no autentica a nadie, y el efecto buscado —que deje de
    # servir— está cumplido.
    def call
      return false if token.blank?

      payload = Warden::JWTAuth::TokenDecoder.new.call(token)
      JwtDenylist.revoke_jwt(payload, @user)
      true
    rescue JWT::DecodeError
      false
    end

    private

    def token
      @token ||= @header.to_s.split.last
    end
  end
end

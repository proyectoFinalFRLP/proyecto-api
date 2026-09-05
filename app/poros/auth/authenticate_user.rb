# frozen_string_literal: true

module Auth
  class AuthenticateUser < ApplicationPoro
    def initialize(email:, password:, company:)
      super()
      @email = email
      @password = password
      @company = company
    end

    # Devuelve nil ante cualquier fallo — tenant no resuelto, email inexistente
    # en ese tenant, usuario de otro tenant o password incorrecta. El caller no
    # puede distinguir los casos, que es justamente el punto: el 401 tiene que
    # ser idéntico para todos.
    def call
      return nil if @company.nil?

      user = find_user
      return nil unless user&.valid_password?(@password)

      Warden::JWTAuth::UserEncoder.new.call(user, :user, nil).first
    end

    private

    # `unscoped` explícito: User incluye CompanyScoped, y si el request de login
    # llegara con un JWT viejo en el header, el default scope filtraría por el
    # tenant de ese token y no por el que se está intentando. El scope acá es el
    # de la company resuelta por slug, y sólo ese.
    def find_user
      User.unscoped.find_by(company_id: @company.id, email: @email)
    end
  end
end

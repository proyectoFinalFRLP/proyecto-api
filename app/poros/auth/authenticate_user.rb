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
    # en ese tenant, usuario de otro tenant, password incorrecta o cuenta que
    # todavía no aprobaron. El caller no puede distinguir los casos, que es
    # justamente el punto: el 401 tiene que ser idéntico para todos.
    def call
      user = find_user
      return nil unless password_matches?(user) && user.approved?

      Warden::JWTAuth::UserEncoder.new.call(user, :user, nil).first
    end

    # Digest descartable contra el que se compara cuando no hay cuenta. Se arma
    # con el mismo Devise::Encryptor (y por lo tanto el mismo costo) que las
    # passwords reales.
    def self.dummy_digest
      @dummy_digest ||= Devise::Encryptor.digest(User, SecureRandom.hex(32))
    end

    private

    # Se corre bcrypt aunque no haya cuenta que comparar. Si no, el 401 de un
    # email inexistente (o de un tenant no resuelto) volvía mucho antes que el
    # de una password incorrecta, y el tiempo de respuesta decía qué emails
    # existen aunque el cuerpo fuera idéntico.
    def password_matches?(user)
      return user.valid_password?(@password) if user

      Devise::Encryptor.compare(User, self.class.dummy_digest, @password)
      false
    end

    # `unscoped` explícito: User incluye CompanyScoped, y si el request de login
    # llegara con un JWT viejo en el header, el default scope filtraría por el
    # tenant de ese token y no por el que se está intentando. El scope acá es el
    # de la company resuelta por slug, y sólo ese.
    def find_user
      return nil if @company.nil?

      User.unscoped.find_by(company_id: @company.id, email: normalized_email)
    end

    # Devise guarda el email en minúsculas y sin espacios alrededor
    # (case_insensitive_keys y strip_whitespace_keys), pero esa normalización
    # sólo corre al guardar y en sus propios finders, y este find_by es nuestro.
    # Sin esto, quien se registró como «Ana@Norte.com» no podía entrar tipeando
    # el email igual que al registrarse.
    def normalized_email
      @email.to_s.strip.downcase
    end
  end
end

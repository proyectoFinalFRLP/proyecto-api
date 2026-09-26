# frozen_string_literal: true

module Auth
  class RegisterUser < ApplicationPoro
    def initialize(params:, company:)
      super()
      @params = params
      @company = company
    end

    # Registrarse es pedir acceso (S02: «Solicitá acceso al espacio de operación
    # de tu organización»): la cuenta nace sin aprobar y no puede loguearse
    # hasta que la aprueben desde el backoffice. Antes el alta daba acceso
    # inmediato, y como el slug es público (es el subdominio), cualquiera podía
    # entrar a leer los datos de cualquier empresa.
    #
    # Devuelve la cuenta creada, o nil si el email ya tenía una. El controller
    # responde lo mismo en los dos casos: el email es único en toda la base, y
    # si la respuesta cambiara, el registro diría qué emails existen en esta
    # empresa o en cualquier otra.
    #
    # La company es la que resolvió el slug, nunca la del body (TESIS-120). El
    # `Current.set` no es decorativo: CompanyScoped pisa `company_id` con
    # `Current.company_id` en el create, y un register con un JWT de otro tenant
    # en el header crearía la cuenta en ese otro tenant.
    def call
      Current.set(company_id: @company.id) do
        user = User.new(@params.merge(company: @company, approved: false))
        next if email_taken?(user)

        user.save!
        user
      end
    rescue ActiveRecord::RecordNotUnique
      # Dos registros simultáneos del mismo email nuevo pasan los dos la
      # validación y el segundo choca contra el índice único. Para el que llama
      # es lo mismo que un email que ya tenía cuenta.
      nil
    end

    private

    # Valida lo que escribió el que llama y dice si el email ya tenía cuenta.
    # Los errores de formato (email mal escrito, password corta) se levantan
    # siempre, y ANTES de mirar si el email existe: al revés, una password
    # inválida respondería distinto según el email estuviera tomado o no, y la
    # diferencia volvería a delatarlo.
    def email_taken?(user)
      user.validate
      taken = user.errors.of_kind?(:email, :taken)
      user.errors.delete(:email, :taken)
      raise ActiveRecord::RecordInvalid, user if user.errors.any?

      taken
    end
  end
end

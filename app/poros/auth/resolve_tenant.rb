# frozen_string_literal: true

module Auth
  # Resuelve el tenant de un request que todavía no tiene contexto de sesión
  # (config pública, login, register).
  #
  # Regla dura de la ADR-003: el slug **nunca** es fuente de aislamiento de
  # datos. Si el request trae un usuario autenticado, gana el JWT y el slug se
  # ignora por completo; el slug sólo decide cuando no hay sesión.
  class ResolveTenant < ApplicationPoro
    def initialize(slug: nil, user: nil)
      super()
      @slug = slug
      @user = user
    end

    def call
      return company_from_user if @user

      Company.find_active_by_slug(@slug)
    end

    private

    def company_from_user
      Company.active.find_by(id: @user.company_id)
    end
  end
end

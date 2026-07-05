# frozen_string_literal: true

module Auth
  # Registra un usuario nuevo bajo una company existente.
  # La validación de pertenencia (company existente) la garantiza belongs_to.
  class RegisterUser < ApplicationPoro
    def initialize(params:)
      super()
      @params = params
    end

    def call
      User.create!(@params)
    end
  end
end

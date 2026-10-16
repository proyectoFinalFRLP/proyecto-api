# frozen_string_literal: true

module Addresses
  # Los cuatro dígitos del código postal argentino (TESIS-185).
  #
  # El sistema acepta el código como lo escriban: el viejo de cuatro dígitos
  # ('1414') o el CPA de ocho caracteres ('C1414ABC'), que suma la letra de la
  # provincia adelante y tres letras de la manzana atrás. Hay couriers —OCA
  # entre ellos— que sólo entienden los cuatro dígitos, y el CPA los contiene.
  #
  #   ShortPostalCode.call('C1414ABC')  # => '1414'
  #   ShortPostalCode.call('b1842zab')  # => '1842'
  #   ShortPostalCode.call('1414')      # => '1414'
  #   ShortPostalCode.call('14')        # => nil
  #
  # Lo que no tiene ninguna de esas formas devuelve nil en vez de recortarse a
  # ciegas: mandar cuatro dígitos cualquiera cotiza contra otra localidad.
  class ShortPostalCode < ApplicationPoro
    # Letra de provincia opcional, cuatro dígitos y las tres letras opcionales.
    # Los espacios se sacan antes, porque el CPA a veces se escribe partido.
    PATTERN = /\A[A-Z]?(?<digits>\d{4})(?:[A-Z]{3})?\z/

    def initialize(postal_code)
      super()
      @postal_code = postal_code
    end

    def call
      PATTERN.match(@postal_code.to_s.upcase.gsub(/\s+/, ''))&.[](:digits)
    end
  end
end

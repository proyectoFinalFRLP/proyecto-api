# frozen_string_literal: true

module Catalog
  # El cliente mando `If-Match` con una version que ya no es la vigente: alguien
  # toco el producto entre que lo leyo y lo guardo.
  #
  # Lleva la version actual para que el controller la devuelva en la respuesta:
  # el cliente puede recargar y reintentar sin pedir el detalle de nuevo.
  class StaleProductError < StandardError
    attr_reader :current_version

    def initialize(current_version:)
      @current_version = current_version
      super('the product changed since it was loaded')
    end
  end
end

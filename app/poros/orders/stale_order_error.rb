# frozen_string_literal: true

module Orders
  # El cliente mandó `If-Match` con una versión que ya no es la vigente: alguien
  # tocó la orden entre que la leyó y la guardó (TESIS-126).
  #
  # Lleva la versión actual para que el controller la devuelva en la respuesta,
  # igual que Catalog::StaleProductError: el cliente puede recargar y reintentar
  # sin pedir el detalle de nuevo.
  class StaleOrderError < StandardError
    attr_reader :current_version

    def initialize(current_version:)
      @current_version = current_version
      super('the order changed since it was loaded')
    end
  end
end

# frozen_string_literal: true

module Shipments
  # El costo confirmado es un número, pero no uno que el envío pueda guardar:
  # negativo, fuera del rango de la columna, NaN o infinito. Se detecta antes de
  # pedir la etiqueta, así que el courier no se llegó a llamar. Es un dato del
  # request, y el controller lo mapea a 400.
  class InvalidShippingCostError < StandardError
    def initialize(reasons)
      super("shipping_cost #{reasons.to_sentence}")
    end
  end
end

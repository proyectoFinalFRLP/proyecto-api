# frozen_string_literal: true

module Shipments
  # La orden la retira el cliente en el local, así que no entra al circuito
  # logístico: no hay envío que abrir ni etiqueta que emitir (TESIS-162).
  #
  # Es un error de datos y no transitorio, igual que `UnshippableOrderError`:
  # reintentar no cambia nada mientras la orden siga siendo un retiro. El
  # controller lo mapea a 422.
  #
  # Va aparte y no como otro estado de `UnshippableOrderError` porque el motivo
  # es distinto y la pantalla hace cosas distintas con cada uno: una orden
  # cancelada es un callejón sin salida, un retiro es una venta sana que
  # simplemente no se despacha.
  class PickupOrderError < StandardError
    attr_reader :order_id

    def initialize(order:)
      @order_id = order.id
      super('an order picked up at the store has no shipment')
    end
  end
end

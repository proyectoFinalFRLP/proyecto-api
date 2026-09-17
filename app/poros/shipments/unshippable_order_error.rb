# frozen_string_literal: true

module Shipments
  # La orden existe y es del tenant, pero su estado no admite entrar al circuito
  # logístico. Es un error de datos, no transitorio: reintentar no cambia nada
  # hasta que la orden cambie de estado. El controller lo mapea a 422.
  class UnshippableOrderError < StandardError
    attr_reader :order_id, :status

    def initialize(order:)
      @order_id = order.id
      @status = order.status
      super("an order in status '#{order.status}' cannot be shipped")
    end
  end
end

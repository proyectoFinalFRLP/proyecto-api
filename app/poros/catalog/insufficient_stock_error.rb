# frozen_string_literal: true

module Catalog
  # No hay unidades suficientes en el depósito para el movimiento pedido.
  # El controller lo mapea a 422: es un dato del request, no un fallo del sistema.
  class InsufficientStockError < StandardError
    attr_reader :product_id, :warehouse_id, :available, :requested

    def initialize(product_id:, warehouse_id:, available:, requested:)
      @product_id = product_id
      @warehouse_id = warehouse_id
      @available = available
      @requested = requested
      super("warehouse #{warehouse_id} holds #{available} units of product " \
            "#{product_id}, cannot move #{requested}")
    end
  end
end

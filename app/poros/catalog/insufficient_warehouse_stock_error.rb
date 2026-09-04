# frozen_string_literal: true

module Catalog
  # No hay unidades suficientes en el depósito para el movimiento pedido.
  # El controller lo mapea a 422: es un dato del request, no un fallo del sistema.
  #
  # Hermano de InsufficientStockError y no el mismo error: aquel responde "el
  # producto no alcanza en ningún lado" (lo levanta DeductStock al ingerir una
  # orden) y éste "no alcanza en ESTE depósito", que es la pregunta de una
  # transferencia entre nodos. Comparten la causa pero no los datos: uno nombra
  # el producto, el otro el depósito, lo disponible y lo pedido.
  class InsufficientWarehouseStockError < StandardError
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

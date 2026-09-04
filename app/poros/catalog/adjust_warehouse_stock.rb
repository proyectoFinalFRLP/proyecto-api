# frozen_string_literal: true

module Catalog
  # Suma o resta unidades de un producto en un depósito concreto.
  #
  # Es el único lugar que escribe `stocks.quantity` para las transferencias, y
  # las tres transiciones (despachar, recibir, cancelar) pasan por acá — por eso
  # existe como pieza aparte y no repetida en cada una.
  #
  # NO toma el advisory lock: lo toma quien la invoca, porque una transferencia
  # necesita que la lectura del saldo y la escritura estén dentro del MISMO lock
  # que la creación de la fila de transferencia. Tomarlo acá lo cerraría antes de
  # tiempo y dejaría la ventana que el lock existe para cerrar (ADR-009).
  class AdjustWarehouseStock < ApplicationPoro
    def initialize(product:, warehouse:, delta:)
      super()
      @product = product
      @warehouse = warehouse
      @delta = delta.to_i
    end

    def call
      stock = Stock.find_or_initialize_by(product_id: @product.id, warehouse_id: @warehouse.id)
      resulting = stock.quantity.to_i + @delta
      ensure_available!(stock, resulting)

      stock.quantity = resulting
      stock.save!
      stock
    end

    private

    # El CHECK `stocks_quantity_non_negative` es la última línea de defensa, pero
    # llegaría como CheckViolation genérica. Cortar acá deja un error que nombra
    # el depósito, lo disponible y lo pedido.
    def ensure_available!(stock, resulting)
      return unless resulting.negative?

      raise InsufficientWarehouseStockError.new(
        product_id: @product.id, warehouse_id: @warehouse.id,
        available: stock.quantity.to_i, requested: @delta.abs
      )
    end
  end
end

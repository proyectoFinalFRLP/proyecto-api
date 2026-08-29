# frozen_string_literal: true

module Catalog
  # Descuenta unidades de un producto de uno de sus depósitos.
  #
  # Regla del MVP (TESIS-43): se descuenta del primer depósito que pueda cubrir
  # la cantidad completa, tomados en orden estable por warehouse_id. No se parte
  # una venta entre varios depósitos: si ninguno alcanza solo, la operación falla
  # aunque el stock consolidado sea suficiente (ver ADR-010).
  #
  # La lectura del stock va adentro del advisory lock (ADR-009): es un
  # read-modify-write, y leer afuera dejaría la ventana para que otro proceso
  # descuente sobre el mismo saldo.
  class DeductStock < ApplicationPoro
    def initialize(product:, quantity:)
      super()
      @product = product
      @quantity = quantity.to_i
    end

    def call
      raise ArgumentError, 'quantity must be positive' unless @quantity.positive?

      WithStockLock.new(product_id: @product.id).call do
        stock = fulfilling_stock
        raise InsufficientStockError.new(product: @product, quantity: @quantity) if stock.nil?

        stock.update!(quantity: stock.quantity - @quantity)
        stock
      end
    end

    private

    # El orden por warehouse_id es arbitrario pero estable: dos ventas del mismo
    # producto vacían los depósitos en la misma secuencia, sin depender del orden
    # físico de las filas.
    def fulfilling_stock
      Stock.where(product_id: @product.id, quantity: @quantity..).order(:warehouse_id).first
    end
  end
end

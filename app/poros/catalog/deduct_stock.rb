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
    # warehouse_id: cuando se provee, descuenta del depósito específico
    # (ventas offline TESIS-42, donde el operador elige de dónde saca).
    # Cuando se omite, picking automático por orden de warehouse_id
    # (webhooks TESIS-43).
    def initialize(product:, quantity:, warehouse_id: nil)
      super()
      @product = product
      @quantity = quantity.to_i
      @warehouse_id = warehouse_id
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

    # Con warehouse_id: busca esa fila específica. Sin warehouse_id: picking
    # automático por orden de warehouse_id (comportamiento heredado TESIS-43).
    def fulfilling_stock
      scope = Stock.where(product_id: @product.id, quantity: @quantity..)
      scope = scope.where(warehouse_id: @warehouse_id) if @warehouse_id
      scope.order(:warehouse_id).first
    end
  end
end

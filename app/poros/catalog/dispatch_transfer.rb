# frozen_string_literal: true

module Catalog
  # Despacha unidades de un depósito a otro: descuenta del origen y deja la
  # transferencia en vuelo.
  #
  # Crear la transferencia y mover el stock es una sola operación atómica, bajo
  # el advisory lock del producto (ADR-009): la lectura del saldo del origen y su
  # escritura tienen que estar dentro del mismo lock, o dos despachos
  # simultáneos del mismo producto podrían descontar sobre el mismo saldo.
  class DispatchTransfer < ApplicationPoro
    def initialize(company:, product:, origin_warehouse:, destination_warehouse:, quantity:)
      super()
      @company = company
      @product = product
      @origin = origin_warehouse
      @destination = destination_warehouse
      @quantity = quantity
    end

    def call
      WithStockLock.new(product_id: @product.id, wait: false).call do
        transfer = build_transfer
        # Se valida antes de tocar stock: un origen igual al destino o una
        # cantidad inválida no deben dejar unidades descontadas.
        transfer.save!
        AdjustWarehouseStock.new(product: @product, warehouse: @origin,
                                 delta: -transfer.quantity).call
        transfer
      end
    end

    private

    def build_transfer
      StockTransfer.new(company: @company, product: @product, origin_warehouse: @origin,
                        destination_warehouse: @destination, quantity: @quantity,
                        status: :in_transit, dispatched_at: Time.current)
    end
  end
end

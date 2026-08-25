# frozen_string_literal: true

module Catalog
  # Cierra una transferencia en vuelo: la recibe en el destino o la cancela
  # devolviendo las unidades al origen.
  #
  # Las dos transiciones comparten todo salvo a qué depósito vuelven las
  # unidades y con qué estado queda la fila, así que viven en una sola pieza en
  # lugar de dos casi idénticas.
  class SettleTransfer < ApplicationPoro
    class NotInFlightError < StandardError; end

    OUTCOMES = {
      received: :destination_warehouse,
      cancelled: :origin_warehouse
    }.freeze

    def initialize(transfer:, outcome:)
      super()
      @transfer = transfer
      @outcome = outcome.to_sym
    end

    def call
      warehouse_method = OUTCOMES.fetch(@outcome) do
        raise ArgumentError, "unknown outcome '#{@outcome}'"
      end

      WithStockLock.new(product_id: @transfer.product_id, wait: false).call do
        # Se revisa adentro del lock: dos requests simultáneos sobre la misma
        # transferencia podrían pasar los dos el chequeo si estuviera afuera, y
        # las unidades entrarían al destino dos veces.
        ensure_in_flight!
        settle(@transfer.public_send(warehouse_method))
      end
    end

    private

    def ensure_in_flight!
      return if @transfer.reload.in_transit?

      raise NotInFlightError,
            "transfer #{@transfer.id} is already #{@transfer.status}"
    end

    def settle(warehouse)
      AdjustWarehouseStock.new(product: @transfer.product, warehouse: warehouse,
                               delta: @transfer.quantity).call
      @transfer.update!(status: @outcome, settled_at: Time.current)
      @transfer
    end
  end
end

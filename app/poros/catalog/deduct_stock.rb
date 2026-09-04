# frozen_string_literal: true

module Catalog
  # Descuenta unidades de un producto de uno de sus depósitos.
  #
  # Modo automático (sin warehouse_id, TESIS-43): picking del primer depósito
  # que pueda cubrir la cantidad completa, tomados en orden estable por
  # warehouse_id. No se parte una venta entre varios depósitos: si ninguno
  # alcanza solo, la operación falla aunque el stock consolidado sea suficiente
  # (ver ADR-010).
  #
  # Modo explícito (con warehouse_id, TESIS-42): descuenta del depósito
  # específico indicado por el operador en ventas offline.
  #
  # La lectura del stock va adentro del advisory lock (ADR-009): es un
  # read-modify-write, y leer afuera dejaría la ventana para que otro proceso
  # descuente sobre el mismo saldo.
  class DeductStock < ApplicationPoro
    # warehouse_id: cuando se provee, descuenta del depósito específico
    # (ventas offline TESIS-42, donde el operador elige de dónde saca).
    # Cuando se omite, picking automático por orden de warehouse_id
    # (webhooks TESIS-43).
    #
    # wait: pasa directo a WithStockLock. En requests HTTP (TESIS-42)
    # conviene wait: false para fallar rápido con 409; en jobs de
    # background (TESIS-43) el default true permite esperar y reintentar.
    #
    # already_locked: true cuando el caller YA tomó el advisory lock del
    # producto en la misma transacción (Orders::CreateOrder los adquiere
    # todos en orden canónico antes de descontar). Tomarlo de nuevo sería
    # reentrante pero es una llamada al pedo por ítem. El default false
    # conserva el comportamiento del camino de webhooks (TESIS-43), donde
    # DeductStock es el único que toma el lock.
    def initialize(product:, quantity:, warehouse_id: nil, wait: true, already_locked: false)
      super()
      @product = product
      @quantity = quantity.to_i
      @warehouse_id = warehouse_id
      @wait = wait
      @already_locked = already_locked
    end

    def call
      raise ArgumentError, 'quantity must be positive' unless @quantity.positive?

      if @already_locked
        deduct!
      else
        WithStockLock.new(product_id: @product.id, wait: @wait).call { deduct! }
      end
    end

    private

    def deduct!
      stock = fulfilling_stock
      raise InsufficientStockError.new(product: @product, quantity: @quantity) if stock.nil?

      stock.update!(quantity: stock.quantity - @quantity)
      stock
    end

    # Con warehouse_id: busca esa fila específica. Sin warehouse_id: picking
    # automático por orden de warehouse_id (comportamiento heredado TESIS-43).
    def fulfilling_stock
      scope = Stock.where(product_id: @product.id, quantity: @quantity..)
      scope = scope.where(warehouse_id: @warehouse_id) if @warehouse_id
      scope.order(:warehouse_id).first
    end
  end
end

# frozen_string_literal: true

module Catalog
  # Se levanta cuando WithStockLock no puede garantizar exclusividad sobre el
  # stock de un producto: venció el lock_timeout esperando el lock (modo wait), o
  # pg_try_advisory_xact_lock encontró el lock ocupado y no quiso esperar (modo
  # try). En ambos casos es un estado transitorio, no un error de datos: el
  # mensaje por defecto está pensado para devolverse tal cual en un 409.
  class LockTimeoutError < StandardError
    DEFAULT_MESSAGE = 'another operation is updating this product stock, please retry'

    attr_reader :product_id, :lock_key

    def initialize(message = DEFAULT_MESSAGE, product_id: nil, lock_key: nil)
      super(message)
      @product_id = product_id
      @lock_key = lock_key
    end
  end
end

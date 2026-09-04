# frozen_string_literal: true

require 'digest'

module Catalog
  # Huella del estado del producto tal como lo vio el cliente: los campos que el
  # ABM edita, mas el stock de cada deposito.
  #
  # Es la version que viaja como ETag y vuelve en `If-Match`. Cubre el agregado
  # completo y no solo la fila `products` a proposito: el modal edita nombre,
  # medidas y cantidades a la vez, y una version que solo mirara `products` no
  # detectaria que alguien movio el stock mientras el modal estaba abierto.
  #
  # Y no solo protege de otro operador: el caso mas peligroso es una venta. Si un
  # webhook descuenta 5 unidades entre que el modal abre y guarda, guardar la
  # cantidad ABSOLUTA que el usuario vio borraria ese descuento sin dejar rastro.
  # Por eso la huella incluye el stock venga de donde venga el cambio.
  class ProductVersion < ApplicationPoro
    SEPARATOR = '|'

    def initialize(product:)
      super()
      @product = product
    end

    def call
      Digest::SHA256.hexdigest(fingerprint)
    end

    private

    def fingerprint
      (edited_fields + stock_pairs).join(SEPARATOR)
    end

    def edited_fields
      [@product.name.to_s, @product.description.to_s,
       @product.weight.to_s, @product.dimensions.to_s]
    end

    # Los depositos se ordenan antes de digerir: `product.stocks` no garantiza
    # orden, y sin esto la misma fila daria huellas distintas entre requests.
    def stock_pairs
      @product.stocks.sort_by(&:warehouse_id).map { |s| "#{s.warehouse_id}:#{s.quantity}" }
    end
  end
end

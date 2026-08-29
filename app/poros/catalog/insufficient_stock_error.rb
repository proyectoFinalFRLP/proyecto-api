# frozen_string_literal: true

module Catalog
  # Se levanta cuando ningún depósito puede cubrir la cantidad pedida de un
  # producto. Es un error de datos, no transitorio: reintentarlo no cambia nada
  # hasta que entre stock nuevo.
  class InsufficientStockError < StandardError
    attr_reader :product_id, :quantity

    def initialize(product:, quantity:)
      @product_id = product.id
      @quantity = quantity
      super("insufficient stock for product '#{product.sku}': #{quantity} units required")
    end
  end
end

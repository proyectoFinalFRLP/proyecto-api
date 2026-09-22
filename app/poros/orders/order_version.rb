# frozen_string_literal: true

require 'digest'

module Orders
  # Huella de la orden tal como la vio el cliente (TESIS-126): lo que la
  # modificación edita —los datos del cliente, el estado y las líneas—.
  #
  # Es la versión que viaja como ETag y vuelve en `If-Match`, con el mismo
  # mecanismo que el ABM de productos (Catalog::ProductVersion, TESIS-101).
  # Cubre las líneas y no sólo la fila `orders` a propósito: la pantalla edita
  # las dos cosas a la vez, y dos operadores que cambian cantidades distintas de
  # la misma orden no tocan `orders` hasta que se recalcula el total.
  class OrderVersion < ApplicationPoro
    SEPARATOR = '|'
    HEADER_FIELDS = %i[customer_name customer_document customer_address
                       customer_zip_code status].freeze

    def initialize(order:)
      super()
      @order = order
    end

    def call
      Digest::SHA256.hexdigest((header + lines).join(SEPARATOR))
    end

    private

    def header
      HEADER_FIELDS.map { |field| @order.public_send(field).to_s }
    end

    # Ordenadas por id antes de digerir: la asociación no garantiza orden, y sin
    # esto la misma orden daría huellas distintas entre requests.
    def lines
      @order.order_items.sort_by(&:id).map do |line|
        [line.id, line.product_id, line.warehouse_id, line.quantity, line.unit_price.to_s].join(':')
      end
    end
  end
end

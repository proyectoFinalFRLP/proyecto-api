# frozen_string_literal: true

module Shipments
  # La orden ya tiene un envío. La restricción 1 a 1 de TESIS-45 es definitiva,
  # así que no es un estado transitorio ni un dato corregible del request: el
  # mensaje está pensado para devolverse tal cual en un 409.
  class DuplicateShipmentError < StandardError
    DEFAULT_MESSAGE = 'this order already has a shipment'

    attr_reader :order_id

    def initialize(order_id: nil)
      @order_id = order_id
      super(DEFAULT_MESSAGE)
    end
  end
end

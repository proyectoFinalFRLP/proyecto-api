# frozen_string_literal: true

module Shipments
  # El envío ya salió del estado inicial: o tiene su etiqueta y su número de
  # seguimiento, o el courier ya lo movió. Despacharlo de nuevo generaría una
  # segunda etiqueta para el mismo paquete, así que no es un dato corregible del
  # request: el controller lo mapea a 409.
  class AlreadyDispatchedError < StandardError
    attr_reader :shipment_id, :status

    def initialize(shipment:)
      @shipment_id = shipment.id
      @status = shipment.status
      super("a shipment in status '#{shipment.status}' cannot be dispatched again")
    end
  end
end

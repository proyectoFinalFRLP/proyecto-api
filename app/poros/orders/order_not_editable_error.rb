# frozen_string_literal: true

module Orders
  # La orden está en un estado que no admite modificación (TESIS-126): o fue
  # cancelada, o su envío ya salió. No es un dato corregible del request —no hay
  # body que haga pasar el mismo PUT—, así que el controller lo mapea a 409.
  class OrderNotEditableError < StandardError
    attr_reader :order_id

    def initialize(order:)
      @order_id = order.id
      super(reason(order))
    end

    private

    # Un envío `pending` con número de seguimiento ya fue despachado: el número
    # lo asigna el courier al confirmar (TESIS-47). Mismo criterio que
    # Shipments::AlreadyDispatchedError, y el mensaje nombra lo que bloquea.
    def reason(order)
      return 'a cancelled order cannot be modified' if order.status == 'cancelled'

      shipment = order.shipment
      if shipment.status == 'pending'
        return 'the order cannot be modified: its shipment already has the tracking number ' \
               "'#{shipment.tracking_number}'"
      end

      "the order cannot be modified: its shipment is already '#{shipment.status}'"
    end
  end
end

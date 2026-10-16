# frozen_string_literal: true

module Shipments
  # El envío no tiene etiqueta que mostrar: todavía no se despachó, o su
  # courier no sabe emitirla (ni una plantilla `label` ni una URL guardada al
  # despachar). El controller lo mapea a 404, igual que un recurso que no está.
  class LabelUnavailableError < StandardError
    DEFAULT_MESSAGE = 'the shipment has no label'

    def initialize(message = DEFAULT_MESSAGE)
      super
    end
  end
end

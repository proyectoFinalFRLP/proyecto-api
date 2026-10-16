# frozen_string_literal: true

module Shipments
  # El courier contestó al pedido de la etiqueta, pero no con un PDF: un texto
  # de error en el lugar del documento (OCA contesta «No se encontraron
  # etiquetas...» con HTTP 200), o nada. No es algo que el usuario pueda
  # corregir desde el request: el controller lo mapea a 502.
  class LabelResponseError < StandardError
    MAX_DETAIL_LENGTH = 200

    def initialize(service_name:, detail: nil)
      message = "#{service_name} did not return a PDF label"
      message += ": #{detail.to_s.squish.truncate(MAX_DETAIL_LENGTH)}" if detail.present?
      super(message)
    end
  end
end

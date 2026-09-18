# frozen_string_literal: true

module Shipments
  # El courier contestó, pero sin lo único que hace útil al despacho: el número
  # de seguimiento. Puede ser un cambio en su API o una plantilla mal mapeada; en
  # cualquier caso no hay nada que el usuario pueda corregir desde el request, y
  # el envío queda como estaba. El controller lo mapea a 502.
  class DispatchResponseError < StandardError
    DEFAULT_MESSAGE = 'the courier did not return a tracking number'

    def initialize(message = DEFAULT_MESSAGE)
      super
    end
  end
end

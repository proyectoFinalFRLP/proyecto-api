# frozen_string_literal: true

module Integrations
  # El pedido no salió porque la plantilla exige (`required`) un dato que no
  # estaba. Es un rechazo, como el de un courier que no cubre el destino.
  # `missing_value` es la clave interna que faltó (`package_height_cm`), para que
  # quien llamó la traduzca a algo que el operador pueda corregir (TESIS-188).
  class MissingValueError < AdapterExecutionError
    attr_reader :missing_value

    def initialize(message, missing_value:, payload: nil)
      super(message, payload: payload, rejected: true)
      @missing_value = missing_value
    end
  end
end

# frozen_string_literal: true

module Integrations
  # Los datos de una conexión no cumplen lo que declara la plantilla. `fields`
  # dice qué campo falló y por qué, con un código que el front traduce
  # (`required`, `invalid_format`, `unknown`): viaja junto a `error` en el 422,
  # como `current_version` en el 409 del locking (ADR-015).
  class InvalidIntegrationError < StandardError
    MESSAGE = 'Invalid integration data'

    attr_reader :fields

    def initialize(fields)
      super(MESSAGE)
      @fields = fields
    end
  end
end

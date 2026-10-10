# frozen_string_literal: true

module Integrations
  # Los datos de una conexión no cumplen lo que declara la plantilla. `fields`
  # dice qué campo falló y por qué (`required`, `invalid_format`, `unknown`),
  # con la clave `credentials.<campo>` o `settings.<campo>`: el backoffice lo
  # muestra con el nombre de cada campo (Avo::Actions::ConfigureConnection).
  class InvalidIntegrationError < StandardError
    MESSAGE = 'Invalid integration data'

    attr_reader :fields

    def initialize(fields)
      super(MESSAGE)
      @fields = fields
    end
  end
end

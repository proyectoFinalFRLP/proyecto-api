# frozen_string_literal: true

module Integrations
  # Algunas APIs contestan un error con HTTP 200 y lo explican en el body. El
  # adaptador sólo miraba el status, así que ese fallo pasaba como un éxito.
  #
  # Dos fuentes, las dos declaradas por la plantilla y ninguna por proveedor:
  # - GraphQL (`request_format: graphql`): un `errors` no vacío en la raíz.
  # - `error_path`: la ruta donde el proveedor lista los errores de negocio
  #   (en Shopify, `data.inventorySetQuantities.userErrors`). Puede declarar
  #   varias separadas por coma: OCA contesta un alta rechazada en `Error` y un
  #   bulto rechazado en `DetalleRechazos` (TESIS-186).
  #
  # El error sale marcado como rechazo (`rejected`): el proveedor contestó y
  # dijo que no. Para el usuario es distinto de un proveedor caído (ver
  # ShipmentsController#render_courier_failure).
  class DetectResponseErrors < ApplicationPoro
    MAX_MESSAGE_LENGTH = 300

    def initialize(service:, body:, payload: nil)
      super()
      @service = service
      @body = body
      @payload = payload
    end

    def call
      errors = graphql_errors + declared_errors
      return if errors.empty?

      raise AdapterExecutionError.new(
        "#{@service.service_name} returned errors: #{summary(errors)}",
        payload: @payload, response_body: @body.to_json, rejected: true
      )
    end

    private

    def graphql_errors
      return [] unless @service.graphql? && @body.is_a?(Hash)

      Array.wrap(@body['errors'])
    end

    def declared_errors
      @service.error_path.to_s.split(',').map(&:strip).compact_blank.flat_map do |path|
        Array.wrap(ParseExternalResponse.dig_path(@body, path)).compact_blank
      end
    end

    def summary(errors)
      errors.map { |error| describe(error) }.join('; ').truncate(MAX_MESSAGE_LENGTH)
    end

    # Un error de una sola columna (la fila `<Error><Descripcion>` de un
    # DataSet) se lee por su valor, no como JSON.
    def describe(error)
      return error.to_s unless error.is_a?(Hash)
      return error['message'] if error['message']

      error.size == 1 ? error.values.first.to_s : error.to_json
    end
  end
end

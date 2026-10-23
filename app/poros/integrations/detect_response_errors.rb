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
        Array.wrap(ParseExternalResponse.dig_path(@body, path)).select { meaningful?(it) }
      end
    end

    # Una fila de error con todas sus columnas vacías no es un error: un XML
    # trae `<Error><Descripcion/></Error>` como `{ "Descripcion" => nil }`, un
    # Hash que no está vacío pero no dice nada. Con `compact_blank` contaba como
    # rechazo y el despacho salía 422 con un motivo en blanco (TESIS-188).
    def meaningful?(error)
      case error
      when Hash then error.values.any? { meaningful?(it) }
      when Array then error.any? { meaningful?(it) }
      else error.present?
      end
    end

    def summary(errors)
      errors.map { |error| describe(error) }.join('; ').truncate(MAX_MESSAGE_LENGTH)
    end

    # Un error de una sola columna (la fila `<Error><Descripcion>` de un
    # DataSet) se lee por su valor, no como JSON. Las columnas vacías no
    # cuentan: una fila con el código en blanco y la descripción se lee por la
    # descripción.
    def describe(error)
      return error.to_s unless error.is_a?(Hash)
      return error['message'] if error['message']

      filled = error.select { |_column, value| meaningful?(value) }
      filled.size == 1 ? filled.values.first.to_s : filled.to_json
    end
  end
end

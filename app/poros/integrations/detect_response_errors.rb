# frozen_string_literal: true

module Integrations
  # Algunas APIs contestan un error con HTTP 200 y lo explican en el body. El
  # adaptador sólo miraba el status, así que ese fallo pasaba como un éxito.
  #
  # Dos fuentes, las dos declaradas por la plantilla y ninguna por proveedor:
  # - GraphQL (`request_format: graphql`): un `errors` no vacío en la raíz.
  # - `error_path`: la ruta donde el proveedor lista los errores de negocio
  #   (en Shopify, `data.inventorySetQuantities.userErrors`).
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
        payload: @payload, response_body: @body.to_json
      )
    end

    private

    def graphql_errors
      return [] unless @service.graphql? && @body.is_a?(Hash)

      Array.wrap(@body['errors'])
    end

    def declared_errors
      return [] if @service.error_path.blank?

      Array.wrap(ParseExternalResponse.dig_path(@body, @service.error_path))
    end

    def summary(errors)
      errors.map { |error| error.is_a?(Hash) ? error['message'] || error.to_json : error.to_s }
            .join('; ').truncate(MAX_MESSAGE_LENGTH)
    end
  end
end

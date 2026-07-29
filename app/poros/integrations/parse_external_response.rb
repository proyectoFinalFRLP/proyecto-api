# frozen_string_literal: true

module Integrations
  # Aplana la respuesta JSON externa al formato interno usando la plantilla del
  # Service: response_mapper {"ruta.externa.anidada" => "clave_interna"} (las
  # rutas soportan índices de array, ej. "bulto.0.numeroDeEnvio") y
  # response_value_mapper {"valor_externo" => "valor_interno"}.
  class ParseExternalResponse < ApplicationPoro
    def initialize(service:, response_body:)
      super()
      @service = service
      @response_body = response_body
    end

    def call
      @service.response_mapper.each_with_object({}) do |(external_path, internal_key), result|
        value = dig_path(@response_body, external_path)
        next if value.nil?

        result[internal_key] = translate(value)
      end
    end

    private

    def translate(value)
      @service.response_value_mapper.fetch(value.to_s, value)
    end

    def dig_path(node, path)
      path.split('.').reduce(node) do |current, key|
        case current
        when Array then current[key.to_i]
        when Hash then current[key]
        end
      end
    end
  end
end

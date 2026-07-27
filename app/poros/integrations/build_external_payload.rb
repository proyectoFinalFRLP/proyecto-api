# frozen_string_literal: true

module Integrations
  # Construye el JSON externo a partir del payload interno usando la plantilla
  # del Service: request_mapper {"ruta.externa.anidada" => "clave_interna"} y
  # request_value_mapper {"valor_interno" => "valor_externo"}. Solo se envían
  # los campos mapeados (whitelist).
  class BuildExternalPayload < ApplicationPoro
    def initialize(service:, payload:)
      super()
      @service = service
      @payload = payload.transform_keys(&:to_s)
    end

    def call
      @service.request_mapper.each_with_object({}) do |(external_path, internal_key), result|
        next unless @payload.key?(internal_key)

        set_nested(result, external_path, translate(@payload[internal_key]))
      end
    end

    private

    def translate(value)
      @service.request_value_mapper.fetch(value.to_s, value)
    end

    def set_nested(hash, path, value)
      keys = path.split('.')
      last_key = keys.pop
      keys.reduce(hash) { |node, key| node[key] ||= {} }[last_key] = value
    end
  end
end

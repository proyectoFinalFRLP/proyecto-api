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

    # Simétrico con ParseExternalResponse.dig_path: un segmento numérico crea un
    # Array ({'items.0.sku' => ...} produce {"items" => [{"sku" => ...}]}).
    def set_nested(root, path, value)
      keys = path.split('.')
      last_key = keys.pop
      node = keys.each_with_index.reduce(root) do |current, (key, index)|
        child_key = keys[index + 1] || last_key
        descend(current, key, array_index?(child_key) ? [] : {})
      end
      write(node, last_key, value)
    end

    def descend(node, key, empty_child)
      existing = read(node, key)
      return existing if existing.is_a?(Hash) || existing.is_a?(Array)

      write(node, key, empty_child)
      empty_child
    end

    def read(node, key)
      node.is_a?(Array) ? node[key.to_i] : node[key]
    end

    def write(node, key, value)
      if node.is_a?(Array)
        node[key.to_i] = value
      else
        node[key] = value
      end
    end

    def array_index?(key)
      key.match?(/\A\d+\z/)
    end
  end
end

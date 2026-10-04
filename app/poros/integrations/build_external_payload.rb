# frozen_string_literal: true

module Integrations
  # Construye el JSON externo a partir del payload interno usando la plantilla
  # del Service: request_mapper {"ruta.externa.anidada" => "clave_interna"} y
  # request_value_mapper {"valor_interno" => "valor_externo"}. Solo se envían
  # los campos mapeados (whitelist).
  #
  # El valor de una entrada del request_mapper puede ser, además de una clave
  # del payload:
  # - `settings.<clave>`: un dato de la cuenta de la empresa (en Shopify, la
  #   ubicación donde se publica el stock). El prefijo evita que una clave del
  #   payload y una de los settings choquen.
  # - Un texto con `{{clave}}`: se arma con valores del payload o de los
  #   settings (Shopify identifica una variante como
  #   `gid://shopify/ProductVariant/{{external_id}}`, y GraphQL no concatena
  #   strings). No es un motor de plantillas: sólo reemplaza variables.
  #
  # Una entrada cuyo dato no está (o una plantilla a la que le falta alguna
  # variable) no se envía, igual que una clave ausente del payload.
  class BuildExternalPayload < ApplicationPoro
    SETTINGS_PREFIX = 'settings.'
    TEMPLATE_VARIABLE = /\{\{\s*([\w.]+)\s*\}\}/

    def initialize(service:, payload:, settings: {})
      super()
      @service = service
      @payload = payload.transform_keys(&:to_s)
      @settings = (settings || {}).transform_keys(&:to_s)
    end

    def call
      @service.request_mapper.each_with_object({}) do |(external_path, source), result|
        found, value = resolve(source.to_s)
        next unless found

        set_nested(result, external_path, translate(value))
      end
    end

    private

    # [encontrado, valor]: un valor puede ser legítimamente nil o false.
    def resolve(source)
      return render_template(source) if source.match?(TEMPLATE_VARIABLE)

      lookup(source)
    end

    def lookup(source)
      if source.start_with?(SETTINGS_PREFIX)
        key = source.delete_prefix(SETTINGS_PREFIX)
        [@settings.key?(key), @settings[key]]
      else
        [@payload.key?(source), @payload[source]]
      end
    end

    def render_template(source)
      variables = source.scan(TEMPLATE_VARIABLE).flatten
      values = variables.index_with { |variable| lookup(variable) }
      return [false, nil] unless values.values.all? { |found, value| found && !value.nil? }

      [true, source.gsub(TEMPLATE_VARIABLE) { values[Regexp.last_match(1)].last.to_s }]
    end

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

# frozen_string_literal: true

module Integrations
  # Aplana la respuesta JSON externa al formato interno usando la plantilla del
  # Service: response_mapper {"ruta.externa.anidada" => "clave_interna"} (las
  # rutas soportan índices de array, ej. "bulto.0.numeroDeEnvio") y
  # response_value_mapper {"valor_externo" => "valor_interno"}.
  class ParseExternalResponse < ApplicationPoro
    # Una entrada del mapper con este marcador no describe un valor suelto sino
    # una colección ("order_items[].item.id"): la resuelve
    # ParseExternalCollection, acá se ignora.
    COLLECTION_MARKER = '[]'

    # `mapper` permite traducir con un mapper derivado —el de cada elemento de
    # una colección— en lugar del response_mapper completo de la plantilla. El
    # response_value_mapper sigue saliendo del Service en ambos casos.
    def initialize(service:, response_body:, mapper: nil)
      super()
      @service = service
      @response_body = response_body
      @mapper = mapper || service.response_mapper
    end

    # Índices que también valen sobre un Hash suelto: la primera y la última
    # fila de una lista de una sola fila. Un XML no distingue «una fila» de
    # «una lista con una fila» (ver ParseXmlResponse), y la plantilla no
    # tendría cómo saber cuál le toca.
    SINGLE_ROW_INDEXES = %w[0 -1].freeze

    # Navega una ruta con notación de puntos, con soporte de índices de array
    # ("bulto.0.numeroDeEnvio", "-1" es el último). Es método de clase porque
    # ParseExternalCollection ubica su lista con las mismas reglas.
    def self.dig_path(node, path)
      path.split('.').reduce(node) do |current, key|
        case current
        when Array then current[key.to_i]
        when Hash then dig_hash(current, key)
        end
      end
    end

    def self.dig_hash(hash, key)
      return hash[key] if hash.key?(key) || SINGLE_ROW_INDEXES.exclude?(key)

      hash
    end

    def call
      @mapper.each_with_object({}) do |(external_path, internal_key), result|
        next if external_path.include?(COLLECTION_MARKER)

        value = self.class.dig_path(@response_body, external_path)
        next if value.nil?

        result[internal_key] = translate(value)
      end
    end

    private

    def translate(value)
      found, translated = TranslateResponseValue.new(mapper: @service.response_value_mapper,
                                                     value: value).call
      found ? translated : value
    end
  end
end

# frozen_string_literal: true

module Integrations
  # Busca un valor externo en el `response_value_mapper` de una plantilla
  # (TESIS-186, ADR-022).
  #
  # Primero por la clave exacta, que es lo de siempre. Si no está:
  #
  # 1. La misma clave sin distinguir mayúsculas, tildes ni espacios repetidos:
  #    `En Tránsito` y `EN TRANSITO` son el mismo estado.
  # 2. Las claves que terminan en `*` son prefijos: `Visita*` reconoce
  #    `Visita - Sin Novedad` y `Visita - Domicilio Cerrado`. Si varias
  #    coinciden, gana la más larga (`Estado de Visita ONLINE (Entregado)*`
  #    antes que `Estado de Visita ONLINE*`).
  #
  # Es lo que necesita un courier que informa el estado con un texto libre que
  # arranca igual y sigue con un detalle (OCA: `En proceso de Retiro - Suc: ...`),
  # sin una entrada en el mapper por cada sucursal.
  #
  # Devuelve `[encontrado, valor]`.
  class TranslateResponseValue < ApplicationPoro
    PREFIX_MARK = '*'

    # `scrub` primero: un courier que contesta en Latin-1 deja bytes que no son
    # UTF-8 válido, y `unicode_normalize` levanta con ellos. Ese valor no tiene
    # que voltear la consulta de seguimiento: a lo sumo no se reconoce.
    def self.normalize(text)
      text.to_s.scrub.unicode_normalize(:nfkd).gsub(/\p{Mn}/, '').downcase.squish
    end

    def initialize(mapper:, value:)
      super()
      @mapper = mapper || {}
      @value = value.to_s
    end

    def call
      return [true, @mapper[@value]] if @mapper.key?(@value)

      key = normalized_match || prefix_match
      key ? [true, @mapper[key]] : [false, nil]
    end

    private

    def normalized
      @normalized ||= self.class.normalize(@value)
    end

    def normalized_match
      @mapper.keys.find { |key| self.class.normalize(key) == normalized }
    end

    def prefix_match
      @mapper.keys
             .select { |key| key.end_with?(PREFIX_MARK) }
             .map { |key| [key, self.class.normalize(key.delete_suffix(PREFIX_MARK))] }
             .select { |_key, prefix| prefix.present? && normalized.start_with?(prefix) }
             .max_by { |_key, prefix| prefix.length }
             &.first
    end
  end
end

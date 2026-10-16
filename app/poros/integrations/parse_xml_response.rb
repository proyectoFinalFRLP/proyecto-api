# frozen_string_literal: true

module Integrations
  # Convierte una respuesta XML en el mismo Hash que daría un JSON, para que los
  # mappers, `error_path` y `dig_path` funcionen sin saber de dónde vino
  # (TESIS-186, ADR-022).
  #
  # Las reglas son pocas y genéricas, pensadas para los servicios .NET (ASMX)
  # que contestan DataSets, como OCA e-Pak:
  #
  # - Los namespaces se descartan: `diffgr:diffgram` es `diffgram`.
  # - El esquema del DataSet (`xs:schema`) se descarta: describe, no informa.
  # - `diffgram` y su hijo (`NewDataSet`, `Resultado`, `Errores`...) son
  #   envoltorios: sus filas quedan directamente bajo la raíz. Así un DataSet
  #   se lee `Table.0.Total` y no `diffgram.NewDataSet.Table.0.Total`.
  # - Un elemento con hijos es un Hash; los hermanos con el mismo nombre, un
  #   Array (una sola fila queda como Hash: `dig_path` acepta el índice 0
  #   sobre un Hash, así que `Table.0.Total` sirve para una fila o para varias).
  # - Un elemento sin hijos es su texto sin los espacios del borde (los
  #   campos de ancho fijo de SQL Server llegan rellenos), o nil si está vacío.
  #   Si ese texto es a su vez un documento XML, se convierte con las mismas
  #   reglas.
  # - La raíz no aparece como clave salvo que sea un texto suelto: un
  #   `<string>JVBER...</string>` (un PDF en base64) da `{ "string" => "JVBER..." }`.
  # - Los atributos se ignoran: en un DataSet son metadatos de la fila
  #   (`diffgr:id`, `msdata:rowOrder`).
  class ParseXmlResponse < ApplicationPoro
    class MalformedXmlError < StandardError; end

    SKIPPED = %w[schema].freeze
    WRAPPER = 'diffgram'

    def initialize(body)
      super()
      @body = body.to_s
    end

    def call
      root = parse(@body).root
      raise MalformedXmlError, 'the document has no root element' if root.nil?

      value = convert(root)
      value.is_a?(Hash) ? value : { root.name => value }
    end

    private

    def parse(text)
      Nokogiri::XML(text, &:strict).tap(&:remove_namespaces!)
    rescue Nokogiri::XML::SyntaxError => e
      raise MalformedXmlError, e.message
    end

    def convert(element)
      children = data_children(element)
      return structure(children) if children.any?

      # Sólo envoltorios vacíos (un DataSet sin filas): es una estructura sin
      # datos, no un texto.
      element.element_children.any? ? {} : text_value(element)
    end

    def structure(children)
      children.group_by(&:name).transform_values do |siblings|
        values = siblings.map { |child| convert(child) }
        values.size == 1 ? values.first : values
      end
    end

    # Los hijos que llevan datos, con los envoltorios del DataSet abiertos.
    def data_children(element)
      element.element_children.flat_map do |child|
        next [] if SKIPPED.include?(child.name)
        next child.element_children.flat_map(&:element_children) if child.name == WRAPPER

        [child]
      end
    end

    def text_value(element)
      text = element.text.strip
      return nil if text.empty?
      return text unless text.start_with?('<')

      nested(text)
    end

    # Un texto que parece XML pero no lo es se conserva como texto.
    def nested(text)
      self.class.new(text).call
    rescue MalformedXmlError
      text
    end
  end
end

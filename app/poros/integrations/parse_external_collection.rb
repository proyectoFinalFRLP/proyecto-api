# frozen_string_literal: true

module Integrations
  # Extrae la lista de ítems de un payload externo. Las entradas del
  # response_mapper que llevan el marcador `[]` describen una colección:
  #
  #   "order_items[].item.id"  => "external_product_id"
  #   "order_items[].quantity" => "quantity"
  #
  # se lee como "por cada elemento de order_items, el id externo está en item.id
  # y la cantidad en quantity". Lo que va antes del marcador ubica la lista
  # dentro del payload; lo que va después es la ruta dentro de cada elemento.
  #
  # Existe como PORO aparte de ParseExternalResponse porque son dos formas
  # distintas: aquel devuelve un hash plano de la venta, este una fila por ítem.
  class ParseExternalCollection < ApplicationPoro
    MARKER = ParseExternalResponse::COLLECTION_MARKER

    def initialize(service:, payload:)
      super()
      @service = service
      @payload = payload
    end

    def call
      return [] if collection.blank?

      elements.filter_map { |element| translate(element).presence }
    end

    private

    # Entradas de colección agrupadas por su raíz. Una plantilla declara una
    # sola colección (los ítems de la venta); si hubiera más de una raíz se toma
    # la primera declarada en lugar de mezclar listas distintas en una sola.
    def collection
      @collection ||= @service.response_mapper
                              .select { |path, _| path.include?(MARKER) }
                              .group_by { |path, _| path.split(MARKER, 2).first.chomp('.') }
                              .first
    end

    def root = collection.first

    # El mapper de cada elemento: las mismas claves internas, pero con la ruta
    # relativa al elemento. El límite del split es lo que deja la ruta vacía de
    # una entrada sin ruta interna ("tags[]"), que dig_path resuelve como el
    # elemento entero; sin él, Ruby descarta el pedazo vacío del final.
    def element_mapper
      @element_mapper ||= collection.last.to_h do |path, internal_key|
        [path.split(MARKER, 2).last.delete_prefix('.'), internal_key]
      end
    end

    # Array.wrap y no un cast directo: si la plataforma manda un solo ítem como
    # objeto en vez de lista, se procesa igual en lugar de perderse.
    def elements
      Array.wrap(ParseExternalResponse.dig_path(@payload, root))
    end

    def translate(element)
      ParseExternalResponse.new(
        service: @service, response_body: element, mapper: element_mapper
      ).call
    end
  end
end

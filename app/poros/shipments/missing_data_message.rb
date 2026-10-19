# frozen_string_literal: true

module Shipments
  # El motivo, para el operador, de un despacho que no salió porque la plantilla
  # del courier exige un dato que el envío no tiene (`required`, TESIS-186).
  #
  # El adaptador sólo conoce la clave interna que faltó (`package_height_cm`);
  # quien despacha conoce la orden. Acá se traduce la clave a lo que hay que
  # cargar y, si es un dato de producto, se nombra el producto al que le falta:
  # «Para despachar con OCA falta el alto de “Celular Samsung Galaxy A14”».
  # Sin eso el operador veía la clave en inglés y no sabía qué corregir
  # (TESIS-188).
  class MissingDataMessage < ApplicationPoro
    # El bulto es uno solo y consolidado (ConsolidatedPackage): si a un producto
    # le falta cualquier medida, faltan todos sus lados y el volumen, así que la
    # clave que llega no dice cuál. Se mira producto por producto.
    PACKAGE_KEYS = %w[package_length_cm package_width_cm package_height_cm package_volume_cm3
                      package_volume_m3].freeze
    MEASURE_LABELS = { length_cm: 'el largo', width_cm: 'el ancho', height_cm: 'el alto' }.freeze

    PLACES = { 'origin' => 'del depósito de origen', 'destination' => 'del destino' }.freeze
    ADDRESS_DATA = {
      'postal_code' => 'el código postal', 'zip_code' => 'el código postal',
      'street' => 'la calle', 'street_number' => 'la altura de la calle',
      'city' => 'la localidad', 'province' => 'la provincia', 'address' => 'la dirección'
    }.freeze

    OTHER_DATA = { 'declared_value' => 'el total de la orden' }.freeze

    # `payload` es el contexto que recibió la plantilla (CourierPayload): dice si
    # un dato derivado falta o está cargado pero no se pudo leer.
    def initialize(courier:, key:, products:, payload: {})
      super()
      @courier = courier
      @key = key.to_s
      @products = products
      @payload = payload
    end

    def call
      return invalid_postal_code if loaded_zip_code.present?

      "Para despachar con #{@courier} #{plural? ? 'faltan' : 'falta'} #{what}."
    end

    private

    def what
      weight || measures || address_data || OTHER_DATA[@key] || "un dato del envío (#{@key})"
    end

    def weight
      return unless @key == 'package_weight_kg'

      names = @products.reject { it.weight.to_d.positive? }.map { quoted(it) }.uniq
      names.empty? ? 'el peso de los productos' : "el peso de #{sentence(names)}"
    end

    def measures
      return unless measures_key?
      return 'las medidas de los productos' if missing_measures.empty?

      phrases = missing_measures.map do |product, labels|
        "#{sentence(labels)} de #{quoted(product)}"
      end
      sentence(phrases)
    end

    # Más de una medida, de un producto o de varios, o el genérico «las medidas».
    def plural?
      return false unless measures_key?

      missing_measures.size != 1 || missing_measures.values.first.size > 1
    end

    def measures_key? = PACKAGE_KEYS.include?(@key)

    # Producto => las medidas que le faltan, sólo los que tienen alguna en falta.
    def missing_measures
      @missing_measures ||= @products.uniq.index_with { measures_missing_in(it) }
                                     .reject { |_, list| list.empty? }
    end

    def measures_missing_in(product)
      MEASURE_LABELS.filter_map { |measure, label| label if product[measure].nil? }
    end

    def quoted(product) = "“#{product.name}”"

    def sentence(words) = words.to_sentence(two_words_connector: ' y ', last_word_connector: ' y ')

    def address_data
      place, field = address_key
      label = ADDRESS_DATA[field]
      "#{label} #{PLACES[place]}" if label && PLACES[place]
    end

    def address_key = @key.split('_', 2)

    # `_postal_code` son los 4 dígitos que salen de `_zip_code`
    # (Addresses::ShortPostalCode): si falta pero el código está cargado, es que
    # no tiene una forma válida, y decir «falta» mandaría a cargar lo que ya está.
    def loaded_zip_code
      place, field = address_key
      @payload["#{place}_zip_code"] if field == 'postal_code' && PLACES.key?(place)
    end

    def invalid_postal_code
      place, = address_key
      "Para despachar con #{@courier}, el código postal #{PLACES[place]} " \
        "(«#{loaded_zip_code}») no es válido."
    end
  end
end

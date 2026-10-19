# frozen_string_literal: true

module Shipments
  # El motivo, para el operador, de un despacho que no salió porque la plantilla
  # del courier exige un dato que el envío no tiene (`required`, TESIS-186).
  #
  # El adaptador sólo conoce la clave interna que faltó (`package_height_cm`);
  # quien despacha conoce la orden. Acá se traduce la clave a lo que hay que
  # cargar y, si es un dato de producto, se nombra el producto al que le falta:
  # «Para despachar con OCA e-Pak falta el alto de “Celular Samsung Galaxy A14”».
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

    def initialize(courier:, key:, products:)
      super()
      @courier = courier
      @key = key.to_s
      @products = products
    end

    def call
      text = what
      "Para despachar con #{@courier} #{@plural ? 'faltan' : 'falta'} #{text}."
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
      return unless PACKAGE_KEYS.include?(@key)

      missing = @products.uniq.index_with { missing_measures(it) }.reject { |_, list| list.empty? }
      @plural = missing.empty? || missing.size > 1 || missing.values.first.size > 1
      return 'las medidas de los productos' if missing.empty?

      sentence(missing.map { |product, labels| "#{sentence(labels)} de #{quoted(product)}" })
    end

    def missing_measures(product)
      MEASURE_LABELS.filter_map { |measure, label| label if product[measure].nil? }
    end

    def quoted(product) = "“#{product.name}”"

    def sentence(words) = words.to_sentence(two_words_connector: ' y ', last_word_connector: ' y ')

    def address_data
      place, field = @key.split('_', 2)
      label = ADDRESS_DATA[field]
      "#{label} #{PLACES[place]}" if label && PLACES[place]
    end
  end
end

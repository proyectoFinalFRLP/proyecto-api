# frozen_string_literal: true

module Shipments
  # El bulto único con el que se cotiza y se despacha una orden (TESIS-185).
  #
  # Los couriers cotizan por bulto —peso y medidas, o volumen— y el sistema no
  # sabe cómo se arma la caja: eso lo decide quien empaca. La regla es simple a
  # propósito, y es una estimación:
  #
  # 1. El volumen es la suma de largo × ancho × alto × cantidad de cada línea.
  # 2. La caja es un cubo con ese volumen: cada lado es la raíz cúbica,
  #    redondeada hacia arriba a 0,01 cm, para que el cubo nunca quede más
  #    chico que lo que lleva.
  #
  # Un producto sin las tres medidas cargadas suma cero: no se le inventa un
  # tamaño. Si nada tiene medidas, el volumen y el lado son nil —no cero—, y la
  # plantilla que los necesite se entera por el courier en vez de cotizar una
  # caja vacía.
  #
  # El volumen que se informa es el de lo que va adentro, no el del cubo: es el
  # dato real, y el cubo sólo existe porque hay couriers que piden tres lados.
  class ConsolidatedPackage < ApplicationPoro
    CM3_PER_M3 = 1_000_000

    def initialize(lines)
      super()
      @lines = lines
    end

    def call
      volume = total_volume
      return { side_cm: nil, volume_cm3: nil, volume_m3: nil } unless volume.positive?

      { side_cm: side_for(volume),
        volume_cm3: volume.round(2).to_f,
        volume_m3: (volume / CM3_PER_M3).round(6).to_f }
    end

    private

    def total_volume
      @lines.sum(BigDecimal(0)) do |product, quantity|
        measures = Product::MEASURES.map { |measure| product.public_send(measure) }
        next 0 if measures.any?(&:nil?)

        measures.reduce(:*) * quantity
      end
    end

    # El redondeo a 6 decimales antes de subir saca el ruido de la raíz en
    # punto flotante: la de 1000 tiene que dar 10,00 y no 10,01.
    def side_for(volume)
      (Math.cbrt(volume.to_f).round(6) * 100).ceil / 100.0
    end
  end
end

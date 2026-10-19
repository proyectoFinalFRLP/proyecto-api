# frozen_string_literal: true

module Shipments
  # El vocabulario interno que las plantillas de courier mapean (TESIS-185): de
  # dónde sale el paquete, a dónde va y qué es. Lo arman la cotización y el
  # despacho, y vive en un solo lugar para que una plantilla que cotiza con una
  # clave pueda despachar con la misma.
  #
  # Claves, todas en string:
  #
  # - `origin_*` y `destination_*`, una de cada por punta del viaje:
  #   - `_zip_code`: el código postal tal como está cargado.
  #   - `_postal_code`: sus 4 dígitos (Addresses::ShortPostalCode).
  #   - `_address`: la dirección en una línea, como está cargada.
  #   - `_street` y `_street_number`: calle y altura (Addresses::SplitStreet).
  #     La altura es nil si no se encontró una clara.
  #   - `_city` y `_province`: localidad y provincia (de `Order::PROVINCES`).
  # - `total_weight`: kilos, peso × cantidad de cada línea. Un producto sin
  #   peso suma cero (es como la mapean Andreani y Correo).
  # - `package_weight_kg`: lo mismo, pero nil si algún producto no tiene el
  #   peso cargado. Es la que usa una plantilla que no puede mandar un peso
  #   inventado (OCA, con `required`).
  # - `total_items`: unidades.
  # - `package_length_cm`, `package_width_cm`, `package_height_cm`: los lados
  #   del bulto consolidado, y `package_volume_cm3` / `package_volume_m3`: el
  #   volumen de lo que lleva (ver ConsolidatedPackage).
  # - `declared_value`: el valor declarado, que es el total de la orden.
  #
  # Las claves que ya existían no cambian de nombre ni de contenido: las
  # plantillas sembradas de Andreani y Correo las mapean. Las nuevas se suman.
  #
  # Una clave sin dato va igual, en nil: `BuildExternalPayload` no la manda a
  # medias en un texto con `{{variables}}`, y la plantilla que la necesite se
  # entera por el error del courier en vez de cotizar con un valor inventado.
  class CourierPayload < ApplicationPoro
    # `origin` es el depósito; `destination` lleva `:zip_code`, `:address`,
    # `:city` y `:province` (cualquiera puede faltar); `lines` son pares
    # `[producto, cantidad]`. `declared_value` es opcional: un alta que todavía
    # no se confirmó no tiene total.
    def initialize(origin:, destination:, lines:, declared_value: nil)
      super()
      @origin = origin
      @destination = destination
      @lines = lines
      @declared_value = declared_value
    end

    def call
      {
        **legacy_keys,
        **address_keys('origin', origin_address),
        **address_keys('destination', @destination),
        **package_keys,
        'declared_value' => @declared_value&.to_f
      }
    end

    private

    # Las del contrato original (TESIS-46/47), tal cual estaban.
    def legacy_keys
      { 'origin_zip_code' => @origin.zip_code,
        'origin_address' => @origin.address,
        'destination_zip_code' => @destination[:zip_code],
        'destination_address' => @destination[:address],
        'total_weight' => total_weight,
        'total_items' => @lines.sum { |_product, quantity| quantity } }
    end

    def origin_address
      { zip_code: @origin.zip_code, address: @origin.address,
        city: @origin.city, province: @origin.province }
    end

    def address_keys(prefix, place)
      street = Addresses::SplitStreet.call(place[:address])
      { "#{prefix}_street" => street[:street],
        "#{prefix}_street_number" => street[:number],
        "#{prefix}_postal_code" => Addresses::ShortPostalCode.call(place[:zip_code]),
        "#{prefix}_city" => place[:city],
        "#{prefix}_province" => place[:province] }
    end

    # Peso del paquete: la suma de peso × cantidad de cada línea. `products.weight`
    # es decimal y arranca en 0, así que un producto sin peso cargado no rompe la
    # cotización — suma cero.
    def total_weight
      @lines.sum { |product, quantity| product.weight * quantity }
    end

    # nil, y no la suma de los demás, si a un producto le falta el peso: el
    # bulto pesaría menos de lo que pesa.
    def package_weight
      total_weight if @lines.any? && @lines.all? { |product, _quantity| product.weight.positive? }
    end

    def package_keys
      box = ConsolidatedPackage.call(@lines)
      { 'package_weight_kg' => package_weight,
        'package_length_cm' => box[:side_cm],
        'package_width_cm' => box[:side_cm],
        'package_height_cm' => box[:side_cm],
        'package_volume_cm3' => box[:volume_cm3],
        'package_volume_m3' => box[:volume_m3] }
    end
  end
end

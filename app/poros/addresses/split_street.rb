# frozen_string_literal: true

module Addresses
  # Separa una dirección escrita en una sola línea en calle, altura y unidad
  # (TESIS-185). El sistema guarda la dirección como texto libre —así la carga
  # el operador y así la mandan los canales—, pero hay couriers que la piden
  # desglosada: OCA, por ejemplo, tiene un campo para la calle y otro para el
  # número.
  #
  #   SplitStreet.call('Av. Corrientes 1234')         # => calle 'Av. Corrientes', número '1234'
  #   SplitStreet.call('Calle 7 N° 1234, La Plata')   # => calle 'Calle 7', número '1234'
  #   SplitStreet.call('Belgrano 567 piso 4 dto B')   # => número '567', unidad 'piso 4 dto B'
  #   SplitStreet.call('Ruta 8 km 65')                # => sin número: la calle es todo
  #
  # Es una heurística y no un parser de direcciones: cuando no encuentra una
  # altura clara devuelve el texto entero como calle y el número en nil, en vez
  # de inventar uno. Un número equivocado manda el paquete a otra puerta; una
  # calle sin número la corrige el courier o el operador.
  #
  # Después de la primera coma suele venir la localidad ('…, La Plata'), que
  # el courier recibe aparte, así que de ahí sólo se toma una unidad
  # ('Rivadavia 1234, 3° A').
  class SplitStreet < ApplicationPoro
    # Lo que empieza una unidad dentro del edificio: piso, departamento,
    # oficina… o un '4°' suelto. La palabra tiene que terminar ahí: 'Pblo' o
    # 'Localidad' no son unidades.
    UNIT = /(?:(?:piso|p\.|dto\.?|dpto\.?|depto\.?|departamento|of\.?|oficina|pb|local|lote|
                torre|unidad|uf)(?![[:alpha:]])|\d+\s*[°º])/ix
    STARTS_WITH_UNIT = /\A#{UNIT}/

    # «Sin número», en las formas en que se escribe.
    WITHOUT_NUMBER = %r{\A(?<street>.+?)\s+(?:s\s*/\s*n[°º]?|sin\s+n(?:[uú]mero|ro\.?|[°º]))
                        (?<unit>\s.*)?\z}ix

    # Una altura anunciada: 'N° 1234', 'Nro. 1234', 'número 1234', '# 1234'. La
    # marca es lo que permite que la calle tenga números propios ('Calle 7').
    MARKED = /\A(?<street>.+?)\s+(?:n[°º]|nro\.?|n[uú]m(?:ero|\.)?|\#)\s*(?<number>\d+)
              (?<unit>\s.*)?\z/ix

    # Sin marca, la altura es el número que cierra la dirección o que precede a
    # la unidad. La calle es perezosa, así que en 'Calle 7 1234' se queda con
    # 'Calle 7': el 7 no puede ser la altura porque lo que sigue no es unidad.
    TRAILING = /\A(?<street>.+?)\s+(?<number>\d+)(?:\s+(?<unit>#{UNIT}.*))?\z/i

    # Una ruta se numera por kilómetro, no por altura.
    KILOMETER = /\bkm\.?\s*\d/i

    # Calles que se nombran con un número: 'Calle 7', 'Av. 60', 'Diagonal 73'.
    # Si lo único que queda antes del número es esto, el número es el nombre de
    # la calle y no la altura.
    NUMBERED_STREET = /\A(?:calle|av\.?|avda\.?|avenida|diag\.?|diagonal|ruta|bv\.?|boulevard|
                         bulevar|pasaje|pje\.?)\z/ix

    EMPTY = { street: nil, number: nil, unit: nil }.freeze

    def initialize(address)
      super()
      @address = address
    end

    def call
      segment, *rest = @address.to_s.split(',').map(&:squish)
      return EMPTY if segment.blank?

      result = split(segment) || { street: segment, number: nil, unit: nil }
      result[:unit] ||= rest.find { |part| part.match?(STARTS_WITH_UNIT) }
      result
    end

    private

    def split(segment)
      return nil if segment.match?(KILOMETER)

      if (match = WITHOUT_NUMBER.match(segment))
        return build(match[:street], nil, match[:unit])
      end

      match = MARKED.match(segment) || TRAILING.match(segment)
      return nil if match.nil? || match[:street].match?(NUMBERED_STREET)

      build(match[:street], match[:number], match[:unit])
    end

    def build(street, number, unit)
      { street: street.strip, number: number, unit: unit.to_s.strip.presence }
    end
  end
end

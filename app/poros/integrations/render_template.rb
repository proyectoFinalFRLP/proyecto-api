# frozen_string_literal: true

module Integrations
  # Reemplaza las `{{variables}}` de un texto de plantilla (TESIS-186, ADR-022).
  #
  # Es lo mínimo para armar un valor que el proveedor espera con un formato
  # fijo —el XML de un alta de OCA, un id `gid://...` de Shopify— sin escribir
  # código por proveedor. No hay condicionales ni bucles: si una plantilla los
  # necesita, ese proveedor pide otra cosa que una plantilla.
  #
  # Sintaxis: `{{ nombre | filtro:argumento | filtro }}`.
  #
  # - `nombre` lo resuelve quien llama (`resolver`, que devuelve
  #   `[encontrado, valor]`). Si no lo encuentra, `today` es la fecha de hoy y
  #   `now` el momento actual.
  # - Filtros, en el orden en que se escriben:
  #   - `default:X`: X si el valor falta o está vacío.
  #   - `truncate:N`: los primeros N caracteres (los proveedores con largos
  #     máximos rechazan el registro entero si uno se pasa).
  #   - `date:FORMATO`: una fecha con `strftime` (`{{today|date:%Y%m%d}}`).
  #   - `ascii`: sin tildes ni eñes (`Muñoz` es `Munoz`). OCA guarda un
  #     nombre con tildes con espacios en su lugar.
  #   - `raw`: no escapar este valor (ver `escape`).
  #   - `required`: el valor tiene que estar. Si falta, no se arma nada: sale
  #     `MissingValueError`, y el pedido no viaja. Es para el dato que el
  #     proveedor necesita y que no se puede inventar con un `default` (el peso
  #     y las medidas del paquete, por ejemplo).
  #
  # Los números se escriben con punto y sin notación científica (`2.5`, no
  # `0.25e1`), y un decimal entero sin decimales (`15000`, no `15000.0`).
  #
  # `strict`: una variable sin valor (después de los filtros) hace que el
  # resultado sea `[false, nil]`, para que quien llama no mande un texto a
  # medias. Si no es estricta, la variable sin valor queda vacía: en un XML con
  # atributos opcionales (el piso, el departamento) eso es lo correcto.
  #
  # `escape: :xml` escapa cada valor (no el texto de la plantilla) para que un
  # `&` o unas comillas en un nombre no rompan el documento.
  class RenderTemplate < ApplicationPoro
    VARIABLE = /\{\{\s*([\w.]+)\s*((?:\|[^|}]*)*)\}\}/
    FILTER = /\A\s*(\w+)\s*(?::(.*))?\z/m
    FILTERS = %w[default truncate date ascii raw required].freeze

    class Error < StandardError; end
    class UnknownFilterError < Error; end

    # El dato que pedía `required` y que no estaba. `variable` es su nombre.
    class MissingValueError < Error
      attr_reader :variable

      def initialize(variable)
        @variable = variable
        super("missing required template value: #{variable}")
      end
    end

    def self.template?(text) = text.to_s.match?(VARIABLE)

    # Los filtros que el texto usa y que no existen. Es lo que valida `Service`
    # al guardar: un tipeo en Avo no puede esperar al primer despacho para
    # aparecer.
    def self.unknown_filters(text)
      text.to_s.scan(VARIABLE).flat_map do |_name, chain|
        chain.split('|').drop(1).filter_map do |filter|
          name = filter.match(FILTER)&.captures&.first
          filter.strip unless FILTERS.include?(name)
        end
      end.uniq
    end

    # `[campo, mensaje]` por cada campo de la plantilla que usa un filtro que no
    # existe: el `request_mapper` y el `body_template`.
    def self.filter_problems(service)
      mapper = service.request_mapper
      { request_mapper: mapper.is_a?(Hash) ? mapper.values : [],
        body_template: [service.body_template] }.filter_map do |field, texts|
        unknown = texts.flat_map { unknown_filters(it) }.uniq
        [field, "usa filtros que no existen: #{unknown.join(', ')}"] if unknown.any?
      end
    end

    # El texto de un valor suelto (número, fecha, string) como viaja al
    # proveedor. Es público porque el form encoding usa la misma regla.
    def self.format_scalar(value)
      case value
      when BigDecimal, Float then format_decimal(value)
      when Date, Time, ActiveSupport::TimeWithZone then value.iso8601
      else value.to_s
      end
    end

    def self.format_decimal(value)
      decimal = BigDecimal(value.to_s)
      return decimal.to_i.to_s if decimal.frac.zero?

      decimal.to_s('F')
    end

    def initialize(template:, resolver:, strict: true, escape: nil)
      super()
      @template = template.to_s
      @resolver = resolver
      @strict = strict
      @escape = escape
    end

    # [renderizado, texto]: false si es estricta y faltó una variable.
    def call
      missing = false
      rendered = @template.gsub(VARIABLE) do
        value, raw = render_variable(Regexp.last_match(1), Regexp.last_match(2))
        missing ||= value.nil?
        escaped(value.nil? ? '' : self.class.format_scalar(value), raw)
      end
      @strict && missing ? [false, nil] : [true, rendered]
    end

    private

    def render_variable(name, filter_chain)
      value = lookup(name)
      raw = false
      filters(filter_chain).each do |filter, argument|
        raw = true if filter == 'raw'
        raise MissingValueError, name if filter == 'required' && value.to_s.strip.empty?

        value = apply(filter, argument, value)
      end
      [value, raw]
    end

    def lookup(name)
      found, value = @resolver.call(name)
      return value if found
      return Date.current if name == 'today'

      Time.current if name == 'now'
    end

    def filters(chain)
      chain.split('|').drop(1).map do |filter|
        name, argument = filter.match(FILTER)&.captures
        raise UnknownFilterError, "unknown template filter: #{filter.strip}" unless
          FILTERS.include?(name)

        [name, argument]
      end
    end

    def apply(filter, argument, value)
      return default(value, argument) if filter == 'default'
      return nil if value.nil?

      case filter
      when 'truncate' then self.class.format_scalar(value)[0, argument.to_i]
      when 'date' then format_date(value, argument)
      when 'ascii' then ascii(self.class.format_scalar(value))
      else value
      end
    end

    def default(value, fallback)
      value.nil? || value.to_s.empty? ? fallback.to_s : value
    end

    def ascii(text)
      text.unicode_normalize(:nfkd).gsub(/\p{Mn}/, '').gsub(/[^[:ascii:]]/, '')
    end

    def format_date(value, format)
      time = value.respond_to?(:strftime) ? value : Time.zone.parse(value.to_s)
      time&.strftime(format.to_s)
    rescue ArgumentError
      nil
    end

    def escaped(text, raw)
      return text if raw || @escape != :xml

      text.encode(xml: :attr).delete_prefix('"').delete_suffix('"')
    end
  end
end

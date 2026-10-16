# frozen_string_literal: true

module Integrations
  # Construye el JSON externo a partir del payload interno usando la plantilla
  # del Service: request_mapper {"ruta.externa.anidada" => "clave_interna"} y
  # request_value_mapper {"valor_interno" => "valor_externo"}. Solo se envían
  # los campos mapeados (whitelist).
  #
  # El valor de una entrada del request_mapper puede ser, además de una clave
  # del payload:
  # - `settings.<clave>`: un dato de la cuenta de la empresa (en Shopify, la
  #   ubicación donde se publica el stock). El prefijo evita que una clave del
  #   payload y una de los settings choquen.
  # - `credentials.<clave>`: un secreto de la cuenta, para los proveedores que
  #   lo reciben como parámetro y no como header (OCA e-Pak pide `usr` y `psw`
  #   en cada alta, TESIS-186). Nunca se loguea ni se guarda: el payload que
  #   viaja en los errores y en la DLQ es el interno, no éste.
  # - `literal:<texto>`: un valor fijo (`literal:false`, `literal:` para un
  #   parámetro que el proveedor exige aunque vaya vacío).
  # - Un texto con `{{clave}}`: se arma con valores del payload, los settings
  #   o las credenciales (Shopify identifica una variante como
  #   `gid://shopify/ProductVariant/{{external_id}}`, y GraphQL no concatena
  #   strings). Acepta filtros (`{{declared_value|default:0}}`), ver
  #   Integrations::RenderTemplate.
  # - `{{template:body}}`: el `body_template` de la plantilla, armado con las
  #   mismas variables y con cada valor escapado para XML. Es como OCA recibe
  #   el XML del alta: dentro de un parámetro del form (`xml_Datos`).
  #
  # Una entrada cuyo dato no está (o una plantilla a la que le falta alguna
  # variable) no se envía, igual que una clave ausente del payload. En el
  # body_template, en cambio, una variable sin valor queda vacía: un XML con
  # atributos opcionales se arma igual.
  #
  # Con `request_format: form` las claves no se anidan: `a.b` es el nombre del
  # parámetro, tal cual.
  class BuildExternalPayload < ApplicationPoro
    SETTINGS_PREFIX = 'settings.'
    CREDENTIALS_PREFIX = 'credentials.'
    LITERAL_PREFIX = 'literal:'
    BODY_TEMPLATE = '{{template:body}}'

    def initialize(service:, payload:, settings: {}, credentials: {})
      super()
      @service = service
      @payload = payload.transform_keys(&:to_s)
      @settings = (settings || {}).transform_keys(&:to_s)
      @credentials = (credentials || {}).transform_keys(&:to_s)
    end

    def call
      @service.request_mapper.each_with_object({}) do |(external_path, source), result|
        found, value = resolve(source.to_s)
        next unless found

        if @service.form?
          result[external_path] = translate(value)
        else
          set_nested(result, external_path, translate(value))
        end
      end
    end

    private

    # [encontrado, valor]: un valor puede ser legítimamente nil o false.
    def resolve(source)
      return render_body if source == BODY_TEMPLATE
      return [true, source.delete_prefix(LITERAL_PREFIX)] if source.start_with?(LITERAL_PREFIX)
      return render(source, strict: true) if RenderTemplate.template?(source)

      lookup(source)
    end

    def lookup(source)
      if source.start_with?(SETTINGS_PREFIX)
        fetch(@settings, source.delete_prefix(SETTINGS_PREFIX))
      elsif source.start_with?(CREDENTIALS_PREFIX)
        fetch(@credentials, source.delete_prefix(CREDENTIALS_PREFIX))
      else
        fetch(@payload, source)
      end
    end

    def fetch(hash, key) = [hash.key?(key), hash[key]]

    def render_body
      render(@service.body_template, strict: false, escape: :xml)
    end

    def render(template, strict:, escape: nil)
      RenderTemplate.new(template: template, resolver: method(:lookup),
                         strict: strict, escape: escape).call
    end

    def translate(value)
      @service.request_value_mapper.fetch(value.to_s, value)
    end

    # Simétrico con ParseExternalResponse.dig_path: un segmento numérico crea un
    # Array ({'items.0.sku' => ...} produce {"items" => [{"sku" => ...}]}).
    def set_nested(root, path, value)
      keys = path.split('.')
      last_key = keys.pop
      node = keys.each_with_index.reduce(root) do |current, (key, index)|
        child_key = keys[index + 1] || last_key
        descend(current, key, array_index?(child_key) ? [] : {})
      end
      write(node, last_key, value)
    end

    def descend(node, key, empty_child)
      existing = read(node, key)
      return existing if existing.is_a?(Hash) || existing.is_a?(Array)

      write(node, key, empty_child)
      empty_child
    end

    def read(node, key)
      node.is_a?(Array) ? node[key.to_i] : node[key]
    end

    def write(node, key, value)
      if node.is_a?(Array)
        node[key.to_i] = value
      else
        node[key] = value
      end
    end

    def array_index?(key)
      key.match?(/\A\d+\z/)
    end
  end
end

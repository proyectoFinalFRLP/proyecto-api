# frozen_string_literal: true

module Catalog
  # Lo que una integración necesita para publicar el stock, deducido de su
  # plantilla de stock (Service#stock_template) y no escrito por proveedor
  # (TESIS-177).
  #
  # El `request_mapper` de esa plantilla dice de dónde sale cada dato del
  # pedido. Lo que no pone el sync saliente tiene que estar en otro lado:
  #
  # - `settings.<clave>`: un dato de la cuenta de la empresa. En Shopify,
  #   `settings.location_id`, la ubicación donde se fija la cantidad. Sin él,
  #   el pedido salía con `locationId: null` y Shopify lo rechazaba con un error
  #   de GraphQL que no decía qué faltaba.
  # - una clave suelta que no es del sync (`inventory_item_id`): un
  #   identificador del vínculo, que tiene que estar en `external_refs`.
  #
  # Un `{{settings.x}}` o `{{clave}}` dentro de un valor armado cuenta igual,
  # salvo que tenga `default`: ése tiene con qué reemplazarse.
  class StockPublishRequirements < ApplicationPoro
    # Lo que el sync saliente pone en cada pedido (ver OutboundSync#stock_payload).
    SYNC_KEYS = ['external_id', Service::STOCK_KEY, 'idempotency_key'].freeze
    SETTINGS_PREFIX = Integrations::BuildExternalPayload::SETTINGS_PREFIX
    # Lo que no es un dato de la cuenta ni del vínculo.
    IGNORED_PREFIXES = [Integrations::BuildExternalPayload::CREDENTIALS_PREFIX,
                        Integrations::BuildExternalPayload::LITERAL_PREFIX].freeze
    BUILTIN_VARIABLES = %w[today now].freeze

    # `service` es la plantilla conectada (la madre), no la de stock.
    def initialize(service)
      super()
      @service = service
    end

    def stock_template
      return @stock_template if defined?(@stock_template)

      @stock_template = @service.stock_template
    end

    def publishes_stock? = stock_template.present?

    # Los settings que el pedido de stock lee.
    def setting_keys
      sources.filter_map { |source| source.delete_prefix(SETTINGS_PREFIX) if setting?(source) }.uniq
    end

    # Las referencias del vínculo que el pedido de stock lee.
    def ref_keys
      sources.reject { |source| setting?(source) || SYNC_KEYS.include?(source) }.uniq
    end

    # [{ 'key' =>, 'label' => }] de los settings que faltan, con el nombre con el
    # que la plantilla los declara (el que ve el administrador en el formulario).
    def missing_settings(settings)
      settings ||= {}
      setting_keys.select { |key| settings[key].to_s.strip.empty? }
                  .map { |key| { 'key' => key, 'label' => label_for(key) } }
    end

    def missing_refs(refs)
      refs ||= {}
      ref_keys.select { |key| refs[key].to_s.strip.empty? }
    end

    # Por qué esta integración no puede publicar, o nil si puede.
    def setting_problem(settings)
      missing = missing_settings(settings)
      return if missing.empty?

      "#{@service.service_name} cannot publish stock: the integration has no " \
        "#{missing.map { |field| "#{field['label']} (#{field['key']})" }.join(', ')} configured. " \
        'Run «Test connection» or load it with «Configure connection»'
    end

    def refs_problem(refs)
      missing = missing_refs(refs)
      return if missing.empty?

      "#{@service.service_name} cannot publish stock for this product: the link has no " \
        "#{missing.join(', ')}. Link it again from «Canales de venta»"
    end

    private

    def setting?(source) = source.start_with?(SETTINGS_PREFIX)

    # Cada origen del request_mapper reducido a la clave que lee. Un valor
    # armado aporta cada una de sus variables obligatorias.
    def sources
      return [] unless publishes_stock?

      @sources ||= stock_template.request_mapper.values.flat_map { |source| keys_in(source.to_s) }
    end

    def keys_in(source)
      return [] if ignored?(source)
      return [source] unless Integrations::RenderTemplate.template?(source)

      source.scan(Integrations::RenderTemplate::VARIABLE).filter_map do |name, filters|
        name unless filters.include?('default') || builtin?(name)
      end
    end

    # Las credenciales, los valores fijos y el body de la plantilla no son datos
    # de la cuenta ni del vínculo.
    def ignored?(source)
      source == Integrations::BuildExternalPayload::BODY_TEMPLATE ||
        IGNORED_PREFIXES.any? { |prefix| source.start_with?(prefix) }
    end

    # `today`, `now` y las credenciales no son datos de la cuenta ni del vínculo.
    def builtin?(name)
      BUILTIN_VARIABLES.include?(name) || name.start_with?(IGNORED_PREFIXES.first)
    end

    def label_for(key)
      field = @service.setting_fields.find { |spec| spec['key'] == key }
      field&.dig('label').presence || key
    end
  end
end

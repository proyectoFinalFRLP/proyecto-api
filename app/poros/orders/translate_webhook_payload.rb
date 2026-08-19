# frozen_string_literal: true

module Orders
  # Traduce el payload crudo de un webhook de venta a las claves internas del OMS
  # usando la plantilla del Service (response_mapper / response_value_mapper), sin
  # una línea de código por proveedor.
  #
  # Devuelve { order: {...atributos de la venta...}, items: [{...}, ...] }. Las
  # claves internas que la plantilla no mapea simplemente no vienen: quién es
  # obligatorio y quién no lo decide ProcessWebhookOrder, no la traducción.
  class TranslateWebhookPayload < ApplicationPoro
    # Claves internas reconocidas. Todo lo demás que traiga la plantilla se
    # ignora: el mapper de un Service puede mapear campos que sirven para otros
    # flujos (ej. tracking_number en la respuesta de un courier).
    ORDER_KEYS = %w[external_order_id customer_name customer_document
                    customer_address customer_zip_code status].freeze
    ITEM_KEYS = %w[external_product_id quantity unit_price].freeze

    def initialize(service:, payload:)
      super()
      @service = service
      @payload = payload
    end

    def call
      { order: order_attributes, items: items }
    end

    private

    def order_attributes
      Integrations::ParseExternalResponse
        .new(service: @service, response_body: @payload).call
        .slice(*ORDER_KEYS).symbolize_keys
    end

    def items
      Integrations::ParseExternalCollection
        .new(service: @service, payload: @payload).call
        .map { |item| item.slice(*ITEM_KEYS).symbolize_keys }
    end
  end
end

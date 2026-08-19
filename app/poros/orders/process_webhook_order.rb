# frozen_string_literal: true

module Orders
  # Convierte un WebhookLog crudo en una venta interna: traduce el payload con la
  # plantilla del Service, resuelve cada ítem contra su ProductMapping (Identity
  # Mapping) y descuenta stock.
  #
  # Todo lo que escribe va dentro de una única transacción: si un ítem no está
  # mapeado, si falta stock o si falla cualquier validación, no queda una orden a
  # medias ni stock descontado de más. El resultado —bueno o malo— se persiste en
  # el propio WebhookLog (`processed` / `failed` + error_message).
  #
  # La excepción se re-levanta después de marcar el log: quien invoca decide qué
  # hacer con el fallo (el job lo deriva a la DLQ, el replay de la DLQ lo cuenta
  # como intento fallido). Ver ADR-010.
  class ProcessWebhookOrder < ApplicationPoro
    class InvalidPayloadError < StandardError; end
    class UnmappedProductError < StandardError; end

    MISSING_ORDER_ID = 'the payload does not carry an external order id'
    MISSING_ITEMS = 'the payload does not carry any order item'

    def initialize(webhook_log:)
      super()
      @log = webhook_log
    end

    def call
      # Un log ya procesado no se vuelve a procesar: el proveedor puede
      # reintentar la entrega y el job puede ejecutarse más de una vez.
      return if @log.processed?

      order = ingest
      mark_processed
      order
    rescue StandardError => e
      mark_failed(e)
      raise
    end

    private

    def ingest
      validate_payload!
      duplicate = Order.find_by(external_order_id: external_order_id)
      return duplicate if duplicate

      items = resolve_items
      ActiveRecord::Base.transaction { create_order(items) }
    rescue ActiveRecord::RecordNotUnique
      # Dos workers con el mismo evento: el índice único (company_id,
      # external_order_id) deja pasar a uno solo. El que perdió la carrera no
      # tiene nada que hacer, la venta ya está registrada.
      Order.find_by(external_order_id: external_order_id)
    end

    def create_order(items)
      order = Order.create!(order_attributes)
      items.each { |item, mapping| register_item(order, item, mapping) }
      order
    end

    # El descuento va junto a la creación del ítem y no en un segundo recorrido:
    # así el rollback de cualquier ítem se lleva puesto todo lo anterior.
    def register_item(order, item, mapping)
      quantity = quantity_of(item)
      OrderItem.create!(order: order, product: mapping.product, quantity: quantity,
                        unit_price: unit_price_of(item, mapping))
      Catalog::DeductStock.new(product: mapping.product, quantity: quantity).call
    end

    # Resuelve el producto interno de cada ítem antes de escribir nada: un ítem
    # sin mapear corta el procesamiento acá, no a mitad de la orden.
    #
    # El orden por product_id no es cosmético: dos ventas que comparten productos
    # toman los advisory locks de stock en la misma secuencia y no pueden
    # trabarse entre sí (ADR-009).
    def resolve_items
      translated[:items].map { |item| [item, mapping_for(item)] }
                        .sort_by { |_item, mapping| mapping.product_id }
    end

    def mapping_for(item)
      external_id = item[:external_product_id].to_s
      mappings.fetch(external_id) do
        raise UnmappedProductError,
              "external product '#{external_id}' is not mapped to any internal product"
      end
    end

    # Identity Mapping acotado a la integración que recibió el webhook: el mismo
    # id externo puede existir en dos canales distintos y apuntar a productos
    # distintos. ProductMapping no lleva company_id (lo hereda de la
    # integración), así que filtrar por company_integration_id ya aísla el tenant.
    def mappings
      @mappings ||= ProductMapping
                    .where(company_integration_id: @log.company_integration_id,
                           external_product_id: external_product_ids)
                    .includes(:product)
                    .index_by(&:external_product_id)
    end

    def external_product_ids
      translated[:items].map { |item| item[:external_product_id].to_s }
    end

    def order_attributes
      translated[:order]
        .slice(:external_order_id, :customer_name, :customer_document,
               :customer_address, :customer_zip_code)
        .merge(company_id: @log.company_id, company_integration: @log.company_integration,
               status: status)
    end

    # El status externo llega ya traducido por el response_value_mapper de la
    # plantilla ('pagado' => 'paid'). Si no viene, o si el canal usa un estado
    # que el OMS no conoce, la venta entra como pendiente en lugar de fallar: el
    # estado es informativo, la venta es el dato que no se puede perder.
    def status
      value = translated[:order][:status].to_s
      Order::STATUSES.include?(value) ? value : 'pending'
    end

    # Una cantidad ausente o inválida no se asume 1: se corta y el evento queda
    # visible, que es preferible a registrar una venta por una cantidad inventada.
    def quantity_of(item)
      quantity = item[:quantity].to_i
      return quantity if quantity.positive?

      raise InvalidPayloadError,
            "item '#{item[:external_product_id]}' has no valid quantity"
    end

    # El precio de la venta externa es el que manda. Si la plantilla no lo mapea
    # se cae al precio publicado en el canal y, si tampoco está, a cero: la
    # columna es NOT NULL y el ítem no puede quedar sin precio.
    def unit_price_of(item, mapping)
      item[:unit_price] || mapping.external_price || 0
    end

    def validate_payload!
      raise InvalidPayloadError, MISSING_ORDER_ID if external_order_id.blank?
      raise InvalidPayloadError, MISSING_ITEMS if translated[:items].empty?
    end

    def external_order_id = translated[:order][:external_order_id].presence

    def translated
      @translated ||= TranslateWebhookPayload
                      .new(service: @log.company_integration.service, payload: @log.payload).call
    end

    def mark_processed
      @log.update!(status: :processed, error_message: nil)
    end

    # El update va fuera de la transacción de negocio, que ya rolleó: adentro, el
    # propio rollback se llevaría puesto el registro del error.
    def mark_failed(error)
      detail = "#{error.class}: #{error.message}".truncate(WebhookLog::ERROR_LIMIT)
      @log.update!(status: :failed, error_message: detail)
    end
  end
end

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
    UNREADABLE_ITEMS = 'the template could not read %<count>d of the order items in the payload'
    ORDERS_UNIQUE_INDEX = 'index_orders_on_company_id_and_external_order_id'

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
    rescue ActiveRecord::RecordNotUnique => e
      # Sólo la violación del índice de órdenes significa "otro worker ya registró
      # esta venta". El rescate cubre toda la transacción, y cualquier otro
      # índice único que aparezca ahí dentro —hoy no hay, mañana puede haberlo en
      # order_items o en stocks— es un fallo real: tratarlo como duplicado
      # devolvería una orden que no fue la causa del error, o nil, y entonces el
      # log quedaría en `processed` sin ninguna orden creada.
      raise unless e.message.include?(ORDERS_UNIQUE_INDEX)

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

    # El precio de la venta externa es el que manda; si la plantilla no lo mapea
    # se cae al precio publicado en el canal, que sigue siendo un precio real de
    # la venta.
    #
    # Si no hay ninguno de los dos se corta, mismo criterio que la cantidad: un
    # ítem en cero es indistinguible de una bonificación legítima, así que el
    # error quedaría enterrado para siempre en un registro financiero (los
    # mismos que este repo protege con `restrict_with_error` para que no se
    # evaporen). Preferimos que la venta no entre y quede visible en la DLQ,
    # reprocesable apenas se arregle el mapper, antes que registrarla gratis con
    # el descuento de stock hecho.
    def unit_price_of(item, mapping)
      price = item[:unit_price].presence || mapping.external_price
      return price if price

      raise InvalidPayloadError,
            "item '#{item[:external_product_id]}' has no usable unit price"
    end

    # Un ítem que la plantilla no sabe leer no se descarta en silencio: la orden
    # entraría con menos renglones de los que vendió el canal, el stock se
    # descontaría de menos —sobreventa— y el log quedaría en `processed` sin
    # rastro de lo que faltó. Es el mismo criterio que la lista vacía: un
    # elemento intraducible es menos información, no más. El caso real es que la
    # plataforma cambie la forma de sus ítems, y así falla fuerte una vez en vez
    # de degradar las ventas de a una.
    def validate_payload!
      raise InvalidPayloadError, MISSING_ORDER_ID if external_order_id.blank?

      lost = translated[:unreadable_items]
      raise InvalidPayloadError, format(UNREADABLE_ITEMS, count: lost) if lost.positive?
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

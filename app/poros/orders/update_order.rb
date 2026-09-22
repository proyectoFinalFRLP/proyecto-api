# frozen_string_literal: true

module Orders
  # Modifica una orden existente: los datos del cliente, el estado y, si vienen,
  # sus líneas (TESIS-126). Es el servicio que consume PUT /api/v1/orders/:id.
  #
  # Todo en una única transacción, como el alta: si falla una sola línea —stock
  # insuficiente, un producto ajeno, una línea sin depósito—, la orden, sus
  # líneas y el stock quedan exactamente como estaban.
  class UpdateOrder < ApplicationPoro
    # La cancelación no pasa por acá: devolver el stock de la orden entera y
    # decidir qué pasa con su envío son reglas propias, que no entran en una
    # edición. Por eso el estado sólo va y viene entre estos dos.
    EDITABLE_STATUSES = %w[pending paid].freeze

    # `items: nil` es "no toques las líneas", y no lo mismo que `[]`, que pediría
    # una orden vacía y se rechaza.
    def initialize(order:, params:, items: nil, expected_version: nil)
      super()
      @order = order
      @params = params
      @items = items
      @expected_version = expected_version
    end

    def call
      validate_status!

      ActiveRecord::Base.transaction do
        # FOR UPDATE sobre la orden: dos modificaciones concurrentes de la misma
        # orden se serializan acá, y la segunda evalúa las guardas sobre lo que
        # dejó la primera y no sobre lo que leyó antes.
        @order.lock!
        verify_version!
        ensure_editable!

        @order.update!(@params)
        replace_lines! unless @items.nil?
        @order
      end
    end

    private

    # Locking optimista, con el mismo criterio que Products::UpdateProduct: el
    # chequeo va DENTRO de la transacción y detrás del `lock!`, no antes. Con la
    # fila tomada, el segundo de dos requests que leyeron la misma versión espera,
    # relee lo que dejó el primero y su versión ya no coincide.
    #
    # Sin `expected_version` no hay precondición que verificar: es la semántica de
    # `If-Match` en HTTP, y deja pasar a un cliente que no lo mande.
    #
    # Va antes que las guardas a propósito: si otro operador canceló la orden, la
    # versión también cambió, y el 412 le dice al cliente que recargue y lo vea.
    def verify_version!
      return if @expected_version.blank?

      @order.order_items.reload
      current = OrderVersion.new(order: @order).call
      return if current == @expected_version

      raise StaleOrderError.new(current_version: current)
    end

    def validate_status!
      status = @params[:status]
      return if status.nil? || EDITABLE_STATUSES.include?(status)

      raise ActiveRecord::RecordNotSaved,
            "status can only change to #{EDITABLE_STATUSES.join(' or ')}"
    end

    # Una orden cancelada no se edita, y una cuyo envío ya salió tampoco: cambiar
    # las líneas de algo que ya viaja no es una corrección, es otra operación.
    # El envío `pending` sin número de seguimiento todavía no salió, y ése sí
    # admite cambios.
    def ensure_editable!
      return unless @order.status == 'cancelled' || dispatched?

      raise OrderNotEditableError.new(order: @order)
    end

    def dispatched?
      shipment = @order.shipment
      shipment.present? && (shipment.status != 'pending' || shipment.tracking_number.present?)
    end

    # El total se recalcula sólo si cambiaron las líneas, y dentro de la misma
    # transacción (TESIS-114). Con `items` ausente no se toca: una orden vieja sin
    # líneas conserva su NULL en vez de pasar a un 0 que nadie facturó.
    def replace_lines!
      ReplaceOrderLines.new(order: @order, items: @items).call
      @order.update!(total_amount: @order.items_total)
    end
  end
end

# frozen_string_literal: true

module Orders
  # Cancela una orden y devuelve sus unidades a los depósitos de los que salieron.
  #
  # Es la pieza que `UpdateOrder` deja afuera a propósito: devolver el stock de
  # la orden entera y decidir qué pasa con su envío son reglas propias. Sin
  # esto, una orden cancelada desde el backoffice dejaba el inventario
  # subestimado para siempre, y los canales publicando menos de lo que hay.
  #
  # Todo en una transacción: si una línea no se puede devolver, ni el stock ni el
  # estado cambian.
  #
  # El envío, si existe y no salió, queda como está: `CreateShipment` y
  # `ConfirmDispatch` ya se niegan a abrir o despachar el de una orden cancelada
  # (TESIS-136), así que no hay forma de que siga viaje. Uno que ya salió frena la
  # cancelación: el paquete está en manos del courier y eso es una devolución,
  # que está fuera del MVP (E4b, exclusión 5).
  #
  # Un retiro en el local (TESIS-162) se cancela como cualquier otra: no tiene
  # envío, así que `dispatched?` no lo frena, y sus unidades vuelven a `stocks`
  # igual que las de una orden con envío. Lo que esta clase no puede distinguir
  # es un retiro que el cliente ya se llevó de uno que todavía no pasó a
  # buscar: `Order` no tiene un estado «retirada», porque TESIS-162 decidió que
  # registrar la venta de mostrador y entregarla son el mismo momento. Hasta que
  # el modelo lo distinga, cancelar un retiro se lee como «la venta no ocurrió»;
  # deshacer una que sí ocurrió es una devolución, igual que con un envío que ya
  # salió.
  class CancelOrder < ApplicationPoro
    def initialize(order:, expected_version: nil)
      super()
      @order = order
      @expected_version = expected_version
    end

    def call
      ActiveRecord::Base.transaction do
        # FOR UPDATE: una cancelación y una edición concurrentes de la misma
        # orden se serializan acá, y la segunda ve lo que dejó la primera.
        @order.lock!
        verify_version!
        ensure_cancellable!
        give_back_stock!
        @order.update!(status: Order::CANCELLED)
        @order
      end
    end

    private

    # Misma semántica que `UpdateOrder#verify_version!`: dentro de la
    # transacción y detrás del `lock!`, y sin `If-Match` no hay precondición.
    def verify_version!
      return if @expected_version.blank?

      @order.order_items.reload
      current = OrderVersion.new(order: @order).call
      return if current == @expected_version

      raise StaleOrderError.new(current_version: current)
    end

    # Ya cancelada, o con el envío en camino: el mismo error y el mismo 409 que la
    # edición, que nombra lo que bloquea.
    def ensure_cancellable!
      return unless @order.status == Order::CANCELLED || dispatched?

      raise OrderNotEditableError.new(order: @order)
    end

    def dispatched?
      shipment = @order.shipment
      shipment.present? && (shipment.status != 'pending' || shipment.tracking_number.present?)
    end

    # Locks en orden canónico (ADR-009) y `wait: false`, porque esto corre en un
    # request HTTP: si otra operación tiene el stock de un producto, 409 ya.
    def give_back_stock!
      ensure_every_line_knows_its_warehouse!
      lines.map(&:product_id).uniq.sort.each do |product_id|
        Catalog::WithStockLock.new(product_id: product_id, wait: false).call { nil }
      end
      lines.each do |line|
        Catalog::AdjustWarehouseStock.new(product: line.product, warehouse: line.warehouse,
                                          delta: line.quantity).call
      end
    end

    # Las líneas anteriores a TESIS-126 no registran de qué depósito salieron:
    # devolverlas a uno cualquiera dejaría el inventario mal sin que nada lo
    # delate. Mismo criterio que `ReplaceOrderLines`.
    def ensure_every_line_knows_its_warehouse!
      blind = lines.find { |line| line.warehouse_id.nil? }
      return unless blind

      raise ActiveRecord::RecordNotSaved,
            "line #{blind.id} does not record the warehouse it was taken from: " \
            'its units cannot be given back'
    end

    def lines
      @lines ||= @order.order_items.includes(:product, :warehouse).to_a
    end
  end
end

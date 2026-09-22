# frozen_string_literal: true

module Orders
  # Reemplaza las líneas de una orden por la lista del request y deja el stock
  # consistente con el resultado (TESIS-126).
  #
  # El request trae la orden como tiene que quedar, no las operaciones. Una línea
  # con `id` ya existe y sólo puede cambiar su cantidad; una sin `id` es nueva y
  # trae producto, cantidad, precio y depósito; y la que existe y no vino, se
  # borra. De esa comparación salen los movimientos de stock:
  #
  #   · línea nueva       → se descuenta del depósito que trae
  #   · cantidad que sube → se descuenta la diferencia del depósito de la línea
  #   · cantidad que baja → se devuelve la diferencia al depósito de la línea
  #   · línea que no vino → se devuelve todo al depósito de la línea
  #
  # El precio de una línea existente no se toca aunque venga en el request: es lo
  # que se facturó (TESIS-114). Para cambiarlo, se borra la línea y se agrega otra.
  #
  # No abre su propia transacción: corre dentro de la de UpdateOrder, que es la
  # que garantiza que la orden quede entera o no cambie.
  class ReplaceOrderLines < ApplicationPoro
    NEW_LINE_KEYS = %i[product_id quantity unit_price warehouse_id].freeze

    def initialize(order:, items:)
      super()
      @order = order
      @items = items
    end

    def call
      validate_items!
      products = resolve_new_products!
      acquire_locks_in_canonical_order!(products)

      removed_lines.each { |line| remove!(line) }
      resizes_smallest_delta_first.each do |item|
        resize!(existing_lines.fetch(item[:id]), item[:quantity])
      end
      new_items.each { |item| add!(item, products.fetch(item[:product_id])) }

      @order.order_items.reset
    end

    private

    # --------------------------------------------------------------- validación

    # Todo lo que puede hacer fallar el reemplazo se revisa antes de tomar un
    # lock o de mover una unidad: un request inválido no llega a tocar stock.
    def validate_items!
      raise ActiveRecord::RecordNotSaved, 'an order needs at least one line' if @items.blank?

      @items = @items.each_with_index.map { |item, i| normalize(item, i) }
      validate_kept_lines!
      validate_lines_without_warehouse!
      validate_new_warehouses!
    end

    # Cantidad entera y positiva, y en las líneas nuevas los cuatro datos del
    # alta. `id` y `quantity` quedan como Integer para comparar sin sorpresas
    # entre el "3" de un form y el 3 de un JSON.
    def normalize(item, index)
      quantity = positive_integer(item[:quantity])
      unless quantity
        raise ActiveRecord::RecordNotSaved, "item[#{index}]: quantity must be a positive integer"
      end

      return normalize_kept(item, index, quantity) if item[:id].present?

      missing = NEW_LINE_KEYS.find { |key| item[key].blank? }
      raise ActiveRecord::RecordNotSaved, "item[#{index}]: #{missing} is required" if missing

      # Un `"id": null` explícito es una línea nueva, y no puede quedar con la
      # clave: `kept_items` separa por la presencia de `:id`.
      item.except(:id).merge(quantity: quantity)
    end

    def normalize_kept(item, index, quantity)
      id = positive_integer(item[:id])
      raise ActiveRecord::RecordNotSaved, "item[#{index}]: id must be a positive integer" unless id

      item.merge(id: id, quantity: quantity)
    end

    # `Integer(2.5)` trunca a 2 en vez de rechazar, así que no alcanza: se
    # aceptan sólo enteros de verdad o strings de dígitos.
    def positive_integer(value)
      integer = value if value.is_a?(Integer)
      integer ||= value.to_i if value.is_a?(String) && value.match?(/\A\d+\z/)
      integer if integer&.positive?
    end

    def validate_kept_lines!
      ids = kept_items.pluck(:id)
      duplicated = ids.uniq.size != ids.size
      raise ActiveRecord::RecordNotSaved, 'the same line was sent twice' if duplicated

      foreign = ids.find { |id| !existing_lines.key?(id) }
      raise ActiveRecord::RecordNotSaved, "line #{foreign} does not belong to this order" if foreign
    end

    # Las líneas anteriores a TESIS-126 no saben de qué depósito salieron. Mientras
    # no se muevan no molestan; si hay que devolverles o sacarles unidades, no hay
    # a dónde, y adivinar un depósito dejaría el inventario mal sin que nada lo
    # delate.
    def validate_lines_without_warehouse!
      blind = lines_moving_stock.find { |line| line.warehouse_id.nil? }
      return unless blind

      raise ActiveRecord::RecordNotSaved,
            "line #{blind.id} does not record the warehouse it was taken from: " \
            'its quantity cannot change and it cannot be removed'
    end

    # Warehouse es CompanyScoped, pero fuera de un request Current puede estar
    # en nil y el scope no aplica: el company_id va explícito, como en el alta.
    def validate_new_warehouses!
      ids = new_items.pluck(:warehouse_id).uniq
      return if Warehouse.where(id: ids, company_id: @order.company_id).count == ids.size

      raise ActiveRecord::RecordNotSaved, 'One or more warehouses do not belong to this company'
    end

    # Mismo criterio que Orders::CreateOrder: el producto se resuelve antes de
    # tomar locks, porque la clave del advisory lock no lleva el tenant y un id
    # ajeno no puede llegar a tomar el lock de ese producto.
    def resolve_new_products!
      new_items.to_h { |item| [item[:product_id], find_product!(item[:product_id])] }
    end

    def find_product!(product_id)
      Product.find(product_id)
    rescue ActiveRecord::RecordNotFound
      raise ActiveRecord::RecordNotSaved, "product_id #{product_id} does not exist"
    end

    # ------------------------------------------------------------------- stock

    # Sólo se bloquean los productos cuyo stock se mueve: una línea que queda
    # igual no compite con nadie. Orden canónico por la misma razón que en el
    # alta (ADR-009), y wait: false porque esto corre en un request HTTP.
    def acquire_locks_in_canonical_order!(products)
      ids = (lines_moving_stock.map(&:product_id) + products.values.map(&:id)).uniq
      ids.sort.each do |product_id|
        Catalog::WithStockLock.new(product_id: product_id, wait: false).call { nil }
      end
    end

    def remove!(line)
      give_back!(line, line.quantity)
      line.destroy!
    end

    def resize!(line, quantity)
      delta = quantity - line.quantity
      return if delta.zero?

      delta.positive? ? take!(line.product, delta, line.warehouse_id) : give_back!(line, -delta)
      line.update!(quantity: quantity)
    end

    def add!(item, product)
      take!(product, item[:quantity], item[:warehouse_id])
      OrderItem.create!(order: @order, product: product, warehouse_id: item[:warehouse_id],
                        quantity: item[:quantity], unit_price: item[:unit_price])
    end

    def take!(product, quantity, warehouse_id)
      Catalog::DeductStock.new(product: product, quantity: quantity, warehouse_id: warehouse_id,
                               wait: false, already_locked: true).call
    end

    def give_back!(line, quantity)
      Catalog::AdjustWarehouseStock.new(product: line.product, warehouse: line.warehouse,
                                        delta: quantity).call
    end

    # ------------------------------------------------------------ clasificación

    def existing_lines
      @existing_lines ||= @order.order_items.includes(:product, :warehouse).index_by(&:id)
    end

    def kept_items = @items.select { |item| item.key?(:id) }

    def new_items = @items.reject { |item| item.key?(:id) }

    def removed_lines
      kept = kept_items.pluck(:id)
      existing_lines.values.reject { |line| kept.include?(line.id) }
    end

    def resized_lines
      kept_items.filter_map do |item|
        line = existing_lines[item[:id]]
        line if line && line.quantity != item[:quantity]
      end
    end

    def lines_moving_stock = removed_lines + resized_lines

    # Las que bajan primero, por la misma razón que las bajas de líneas van
    # antes que las altas: devolver antes de descontar. Si una línea sube y otra
    # baja sobre el mismo producto y depósito, aplicarlas en el orden del request
    # haría que el mismo pedido —con el mismo neto— pase o falle por stock según
    # en qué orden vinieron las filas.
    def resizes_smallest_delta_first
      kept_items.sort_by { |item| item[:quantity] - existing_lines.fetch(item[:id]).quantity }
    end
  end
end

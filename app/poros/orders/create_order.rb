# frozen_string_literal: true

module Orders
  # Crea una orden de venta offline con sus ítems y descuenta stock, todo dentro
  # de una única transacción de base de datos. Si cualquier paso falla (producto
  # no encontrado, stock insuficiente, depósito ajeno), el ROLLBACK deja la DB
  # exactamente como estaba.
  #
  # Es el servicio que consume POST /api/v1/orders (TESIS-42). El alta manual
  # de ventas offline es el único caso de uso por ahora; las ventas por webhook
  # usan ProcessWebhookOrder (TESIS-43) que tiene su propia lógica de
  # resolución de identidades.
  class CreateOrder < ApplicationPoro
    REQUIRED_ITEM_KEYS = %i[product_id quantity unit_price warehouse_id].freeze

    def initialize(params:, items:, company:)
      super()
      @params = params
      @items = items
      @company = company
    end

    def call
      validate_items!

      ActiveRecord::Base.transaction do
        order = Order.create!(order_attributes)
        # Los productos se resuelven y validan ANTES de tomar locks: la clave
        # del advisory lock no lleva el tenant (WithStockLock#lock_key), así
        # que un product_id inexistente o de otra empresa no puede tomar el
        # lock de ese producto y bloquear sus escrituras legítimas con 409
        # mientras esta transacción vive.
        products = resolve_products!
        acquire_locks_in_canonical_order!(products)
        @items.each { |item| create_item!(order, item, products) }
        order
      end
    end

    private

    def order_attributes
      @params.merge(company: @company, status: 'pending')
    end

    def create_item!(order, item, products)
      product = products.fetch(item[:product_id])
      validate_warehouse!(item[:warehouse_id])

      OrderItem.create!(
        order: order,
        product: product,
        quantity: item[:quantity],
        unit_price: item[:unit_price]
      )

      Catalog::DeductStock.new(
        product: product,
        quantity: item[:quantity],
        warehouse_id: item[:warehouse_id],
        wait: false
      ).call
    end

    # Resuelve y valida TODOS los productos del request antes de tomar un solo
    # lock. find_product! traduce RecordNotFound a RecordNotSaved (422): un
    # product_id inexistente o de otro tenant falla acá, no después de adquirir
    # los locks. Devuelve un hash product_id → Product para reusar en
    # create_item! sin volver a consultar.
    def resolve_products!
      @items.to_h { |item| [item[:product_id], find_product!(item[:product_id])] }
    end

    def find_product!(product_id)
      # CompanyScoped ya pone el default_scope WHERE company_id = ?
      Product.find(product_id)
    rescue ActiveRecord::RecordNotFound
      # El product_id es un dato del body, no de la ruta: es un 422, no un
      # 404 (el 404 queda para show/index, TESIS-112). Se traduce a
      # RecordNotSaved con mensaje propio para no filtrar el esquema y el
      # scope multi-tenant que trae el mensaje crudo de ActiveRecord.
      raise ActiveRecord::RecordNotSaved,
            "product_id #{product_id} does not exist"
    end

    def validate_warehouse!(warehouse_id)
      # Warehouse.where ya filtra por company_id via CompanyScoped default_scope,
      # pero si Current.company_id es nil (fuera de request), el scope no aplica.
      # La validación explícita cubre ambos casos.
      return if Warehouse.exists?(id: warehouse_id, company_id: @company.id)

      raise ActiveRecord::RecordNotSaved,
            'One or more warehouses do not belong to this company'
    end

    def validate_items!
      raise ActiveRecord::RecordNotSaved, 'items must be present' if @items.blank?

      @items.each_with_index do |item, i|
        REQUIRED_ITEM_KEYS.each do |key|
          next if item[key].present?

          raise ActiveRecord::RecordNotSaved,
                "item[#{i}]: #{key} is required"
        end
      end
    end

    # Adquiere los advisory locks en orden canónico (product_id ascendente)
    # antes de crear los items. Con wait: false (este camino) el lock nunca
    # bloquea — falla con 409 si ya está tomado — así que el deadlock ya es
    # imposible por construcción. El orden canónico igual conviene: sin él,
    # dos órdenes concurrentes con los mismos productos en distinto orden
    # pueden tomar un lock cada una y fallar las dos; con él, una gana y la
    # otra falla limpio.
    #
    # products llega resuelto por resolve_products!, así que acá nunca cae un
    # product_id que no pertenezca a la empresa: la clave del lock es global
    # (sin tenant) y queda reservada para productos del propio tenant.
    def acquire_locks_in_canonical_order!(products)
      products.keys.sort_by(&:to_i).each do |product_id|
        Catalog::WithStockLock.new(product_id: product_id, wait: false).call { nil }
      end
    end
  end
end

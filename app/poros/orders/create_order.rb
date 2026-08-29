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
        @items.each { |item| create_item!(order, item) }
        order
      end
    end

    private

    def order_attributes
      @params.merge(company: @company, status: 'pending')
    end

    def create_item!(order, item)
      product = find_product!(item[:product_id])
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
        warehouse_id: item[:warehouse_id]
      ).call
    end

    def find_product!(product_id)
      # CompanyScoped ya pone el default_scope WHERE company_id = ?
      Product.find(product_id)
    end

    def validate_warehouse!(warehouse_id)
      # Warehouse.where ya filtra por company_id via CompanyScoped default_scope,
      # pero si Current.company_id es nil (fuera de request), el scope no aplica.
      # La validación explícita cubre ambos casos.
      owned = Warehouse.where(id: warehouse_id, company_id: @company.id).exists?
      return if owned

      raise ActiveRecord::RecordNotSaved,
            'One or more warehouses do not belong to this company'
    end

    def validate_items!
      raise ActiveRecord::RecordNotSaved, 'items must be present' if @items.blank?

      @items.each_with_index do |item, i|
        %i[product_id quantity unit_price warehouse_id].each do |key|
          next if item[key].present?

          raise ActiveRecord::RecordNotSaved,
                "item[#{i}]: #{key} is required"
        end
      end
    end
  end
end

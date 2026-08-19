# frozen_string_literal: true

module Products
  class CreateProduct < ApplicationPoro
    include Concerns::WarehouseValidation

    def initialize(params:, stocks:, company:)
      super()
      @params = params
      @stocks_params = stocks
      @company = company
    end

    def call
      Product.transaction do
        product = Product.create!(@params.merge(company: @company))

        write_stocks!(product) if @stocks_params.present?

        product
      end
    end

    private

    # Acá todavía no puede haber contención: el producto nace en esta misma
    # transacción y nadie más conoce su id. El lock se toma igual para que no
    # quede ningún camino que escriba stocks sin serializar — si mañana este
    # PORO acepta un producto existente, la protección ya está puesta — y
    # porque un lock no contendido no cuesta nada.
    #
    # wait: false porque esto corre en el ciclo de un request HTTP: conviene
    # devolver 409 enseguida (ApplicationController mapea el
    # Catalog::LockTimeoutError) antes que colgar un thread de Puma esperando.
    def write_stocks!(product)
      validate_warehouses_belong_to_company!

      Catalog::WithStockLock.new(product_id: product.id, wait: false).call do
        create_stocks_for_product!(product)
      end
    end

    def create_stocks_for_product!(product)
      @stocks_params.each do |stock_attrs|
        product.stocks.create!(
          warehouse_id: stock_attrs[:warehouse_id],
          quantity: stock_attrs[:quantity] || 0
        )
      end
    end
  end
end

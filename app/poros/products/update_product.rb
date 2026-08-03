# frozen_string_literal: true

module Products
  class UpdateProduct < ApplicationPoro
    include Concerns::WarehouseValidation

    def initialize(product:, params:, stocks:)
      super()
      @product = product
      @params = params
      @stocks_params = stocks
    end

    def call
      Product.transaction do
        @product.update!(@params)

        if @stocks_params.present?
          validate_warehouses_belong_to_company!
          upsert_stocks_for_product!
        end

        @product
      end
    end

    private

    def upsert_stocks_for_product!
      @stocks_params.each do |stock_attrs|
        stock = @product.stocks.find_or_initialize_by(
          warehouse_id: stock_attrs[:warehouse_id]
        )
        stock.quantity = stock_attrs[:quantity] || 0
        stock.save!
      end
    end
  end
end

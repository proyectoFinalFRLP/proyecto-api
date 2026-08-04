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

        if @stocks_params.present?
          validate_warehouses_belong_to_company!
          create_stocks_for_product!(product)
        end

        product
      end
    end

    private

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

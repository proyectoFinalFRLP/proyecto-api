# frozen_string_literal: true

module Products
  class CreateProduct < ApplicationPoro
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

    def validate_warehouses_belong_to_company!
      # rubocop:disable Rails/Pluck
      warehouse_ids = @stocks_params.map { |s| s[:warehouse_id] }.uniq
      # rubocop:enable Rails/Pluck
      owned = Warehouse.where(id: warehouse_ids, company: @company).pluck(:id)
      return if owned.sort == warehouse_ids.sort

      missing = warehouse_ids - owned
      raise ActiveRecord::RecordNotSaved,
            "Warehouse(s) #{missing.join(', ')} do not belong to this company"
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

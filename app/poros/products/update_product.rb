# frozen_string_literal: true

module Products
  class UpdateProduct < ApplicationPoro
    def initialize(product:, params:, stocks:, company:)
      super()
      @product = product
      @params = params
      @stocks_params = stocks
      @company = company
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

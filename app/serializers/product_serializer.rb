# frozen_string_literal: true

class ProductSerializer < ApplicationSerializer
  identifier :id

  fields :sku, :name, :description, :weight, :dimensions, :total_stock,
         :created_at, :updated_at

  association :stocks, blueprint: StockSerializer
end

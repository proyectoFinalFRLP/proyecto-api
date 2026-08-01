# frozen_string_literal: true

class ProductListSerializer < ApplicationSerializer
  identifier :id

  fields :sku, :name, :description, :weight, :dimensions, :total_stock,
         :created_at, :updated_at
end

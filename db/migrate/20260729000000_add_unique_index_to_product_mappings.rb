# frozen_string_literal: true

class AddUniqueIndexToProductMappings < ActiveRecord::Migration[8.1]
  def change
    add_index :product_mappings, %i[product_id company_integration_id], unique: true,
              name: 'index_product_mappings_on_product_and_integration'
  end
end

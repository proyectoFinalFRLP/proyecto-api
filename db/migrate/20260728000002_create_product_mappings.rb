# frozen_string_literal: true

class CreateProductMappings < ActiveRecord::Migration[8.1]
  def change
    create_table :product_mappings do |t|
      t.references :product, null: false, foreign_key: { on_delete: :cascade }
      t.references :company_integration, null: false, foreign_key: { on_delete: :cascade }
      t.string :external_product_id, null: false
      t.decimal :external_price, precision: 10, scale: 2

      t.timestamps
    end

    add_index :product_mappings, %i[company_integration_id external_product_id], unique: true,
              name: 'index_product_mappings_on_integration_and_external_id'
    add_index :product_mappings, %i[product_id company_integration_id], unique: true,
              name: 'index_product_mappings_on_product_and_integration'
  end
end

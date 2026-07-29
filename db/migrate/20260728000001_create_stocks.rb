# frozen_string_literal: true

class CreateStocks < ActiveRecord::Migration[8.1]
  def change
    create_table :stocks do |t|
      t.references :product, null: false, foreign_key: { on_delete: :cascade }
      t.references :warehouse, null: false, foreign_key: { on_delete: :restrict }
      t.integer :quantity, null: false, default: 0

      t.timestamps
    end

    add_index :stocks, %i[product_id warehouse_id], unique: true
  end
end

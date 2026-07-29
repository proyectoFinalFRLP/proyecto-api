# frozen_string_literal: true

class CreateProducts < ActiveRecord::Migration[8.1]
  def change
    create_table :products do |t|
      t.references :company, null: false, foreign_key: { on_delete: :cascade }
      t.string :sku, null: false
      t.string :name, null: false
      t.text :description
      t.decimal :weight, precision: 10, scale: 2, default: 0.0
      t.string :dimensions

      t.timestamps
    end

    add_index :products, %i[company_id sku], unique: true
  end
end

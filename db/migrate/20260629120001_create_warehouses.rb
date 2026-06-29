# frozen_string_literal: true

class CreateWarehouses < ActiveRecord::Migration[8.1]
  def change
    create_table :warehouses do |t|
      t.references :company, null: false, foreign_key: { on_delete: :cascade }
      t.string :name, null: false
      t.string :zip_code, null: false
      t.string :address, null: false

      t.timestamps
    end
  end
end

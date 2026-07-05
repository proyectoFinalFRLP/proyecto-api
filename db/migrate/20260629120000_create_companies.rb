# frozen_string_literal: true

class CreateCompanies < ActiveRecord::Migration[8.1]
  def change
    create_table :companies do |t|
      t.string :name, null: false
      t.string :tax_id, null: false
      t.boolean :is_active, null: false, default: true

      t.timestamps
    end

    add_index :companies, :tax_id, unique: true
  end
end

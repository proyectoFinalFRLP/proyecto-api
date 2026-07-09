# frozen_string_literal: true

class CreateCompanyIntegrations < ActiveRecord::Migration[8.1]
  def change
    create_table :company_integrations do |t|
      t.references :company, null: false, foreign_key: { on_delete: :cascade }
      t.references :service, null: false, foreign_key: { on_delete: :restrict }
      t.jsonb :credentials, null: false, default: {}
      t.boolean :is_active, null: false, default: true

      t.timestamps
    end

    add_index :company_integrations, %i[company_id service_id], unique: true
  end
end

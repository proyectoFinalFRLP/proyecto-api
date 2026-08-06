# frozen_string_literal: true

class CreateOrders < ActiveRecord::Migration[8.1]
  def change
    create_table :orders do |t|
      t.references :company, null: false, foreign_key: { on_delete: :cascade }
      # nullify (no cascade como webhook_logs): las órdenes son historia financiera
      # y no deben borrarse si se elimina la integración que las originó.
      t.references :company_integration, foreign_key: { on_delete: :nullify }
      t.string :external_order_id
      t.string :customer_name, null: false
      t.string :customer_document
      t.string :customer_address
      t.string :customer_zip_code
      t.string :status, null: false, default: 'pending'

      t.timestamps
    end

    add_index :orders, %i[company_id external_order_id], unique: true
    add_check_constraint :orders,
                         "status IN ('pending', 'paid', 'cancelled')",
                         name: 'orders_status_check'
  end
end

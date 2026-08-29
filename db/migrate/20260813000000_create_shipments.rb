# frozen_string_literal: true

class CreateShipments < ActiveRecord::Migration[8.1]
  def change
    create_table :shipments do |t|
      t.references :company, null: false, foreign_key: { on_delete: :cascade }
      # nullify (como orders→company_integration): el envío es historia logística
      # y no debe borrarse si se elimina la integración que originó el despacho.
      t.references :company_integration, foreign_key: { on_delete: :nullify }
      # CASCADE: el envío muere con su orden (1 orden = 1 envío, MVP). El índice
      # UNIQUE sobre order_id garantiza a nivel motor la restricción 1 a 1.
      t.references :order, null: false, foreign_key: { on_delete: :cascade },
                           index: { unique: true }
      t.string :tracking_number
      t.string :shipping_label_url
      t.string :status, null: false, default: 'pending'
      t.decimal :shipping_cost, precision: 10, scale: 2

      t.timestamps
    end

    add_check_constraint :shipments,
                         "status IN ('pending', 'ready_to_ship', 'in_transit', 'delivered')",
                         name: 'shipments_status_check'
  end
end

# frozen_string_literal: true

class CreateShipmentEvents < ActiveRecord::Migration[8.1]
  def change
    create_table :shipment_events do |t|
      t.references :shipment, null: false, foreign_key: { on_delete: :cascade }
      t.string :internal_status, null: false
      t.string :external_status, null: false
      t.text :description
      t.datetime :occurred_at, null: false

      t.timestamps
    end

  end
end

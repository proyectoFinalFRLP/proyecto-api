# frozen_string_literal: true

class CreateServices < ActiveRecord::Migration[8.1]
  def change
    create_table :services do |t|
      t.string :service_name, null: false
      t.string :type, null: false
      t.string :uri, null: false
      t.string :http_method, null: false
      t.jsonb :request_mapper, null: false, default: {}
      t.jsonb :response_mapper, null: false, default: {}
      t.jsonb :request_value_mapper, null: false, default: {}
      t.jsonb :response_value_mapper, null: false, default: {}

      t.timestamps
    end

    add_index :services, :service_name, unique: true
    add_check_constraint :services, "type IN ('ecommerce', 'courier')", name: 'services_type_check'
  end
end

# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_08_24_120000) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "admin_users", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "email", default: "", null: false
    t.string "encrypted_password", default: "", null: false
    t.datetime "remember_created_at"
    t.datetime "updated_at", null: false
    t.index ["email"], name: "index_admin_users_on_email", unique: true
  end

  create_table "companies", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.boolean "is_active", default: true, null: false
    t.string "name", null: false
    t.string "tax_id", null: false
    t.datetime "updated_at", null: false
    t.index ["tax_id"], name: "index_companies_on_tax_id", unique: true
  end

  create_table "company_integrations", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.datetime "created_at", null: false
    t.text "credentials", default: "{}", null: false
    t.boolean "is_active", default: true, null: false
    t.bigint "service_id", null: false
    t.datetime "updated_at", null: false
    t.index ["company_id", "service_id"], name: "index_company_integrations_on_company_id_and_service_id", unique: true
    t.index ["company_id"], name: "index_company_integrations_on_company_id"
    t.index ["service_id"], name: "index_company_integrations_on_service_id"
  end

  create_table "failed_events", force: :cascade do |t|
    t.integer "attempts", default: 0, null: false
    t.datetime "claimed_at"
    t.bigint "company_id", null: false
    t.bigint "company_integration_id"
    t.datetime "created_at", null: false
    t.string "direction", default: "outbound", null: false
    t.string "event_type", null: false
    t.text "last_error"
    t.text "last_response_body"
    t.integer "last_response_status"
    t.integer "max_attempts", default: 5, null: false
    t.datetime "next_retry_at"
    t.jsonb "payload", default: {}, null: false
    t.string "status", default: "pending", null: false
    t.datetime "updated_at", null: false
    t.index ["company_id", "status"], name: "index_failed_events_on_company_id_and_status"
    t.index ["company_id"], name: "index_failed_events_on_company_id"
    t.index ["company_integration_id"], name: "index_failed_events_on_company_integration_id"
    t.index ["status", "claimed_at"], name: "index_failed_events_on_status_and_claimed_at"
    t.index ["status", "next_retry_at"], name: "index_failed_events_on_status_and_next_retry_at"
    t.check_constraint "direction::text = ANY (ARRAY['inbound'::character varying, 'outbound'::character varying]::text[])", name: "failed_events_direction_check"
    t.check_constraint "status::text = ANY (ARRAY['pending'::character varying, 'processing'::character varying, 'succeeded'::character varying, 'dead'::character varying, 'discarded'::character varying]::text[])", name: "failed_events_status_check"
  end

  create_table "order_items", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "order_id", null: false
    t.bigint "product_id", null: false
    t.integer "quantity", default: 1, null: false
    t.decimal "unit_price", precision: 10, scale: 2, null: false
    t.datetime "updated_at", null: false
    t.index ["order_id"], name: "index_order_items_on_order_id"
    t.index ["product_id"], name: "index_order_items_on_product_id"
  end

  create_table "orders", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.bigint "company_integration_id"
    t.datetime "created_at", null: false
    t.string "customer_address"
    t.string "customer_document"
    t.string "customer_name", null: false
    t.string "customer_zip_code"
    t.string "external_order_id"
    t.string "status", default: "pending", null: false
    t.datetime "updated_at", null: false
    t.index ["company_id", "external_order_id"], name: "index_orders_on_company_id_and_external_order_id", unique: true
    t.index ["company_id"], name: "index_orders_on_company_id"
    t.index ["company_integration_id"], name: "index_orders_on_company_integration_id"
    t.check_constraint "status::text = ANY (ARRAY['pending'::character varying, 'paid'::character varying, 'cancelled'::character varying]::text[])", name: "orders_status_check"
  end

  create_table "product_mappings", force: :cascade do |t|
    t.bigint "company_integration_id", null: false
    t.datetime "created_at", null: false
    t.decimal "external_price", precision: 10, scale: 2
    t.string "external_product_id", null: false
    t.bigint "product_id", null: false
    t.datetime "updated_at", null: false
    t.index ["company_integration_id", "external_product_id"], name: "index_product_mappings_on_integration_and_external_id", unique: true
    t.index ["company_integration_id"], name: "index_product_mappings_on_company_integration_id"
    t.index ["product_id", "company_integration_id"], name: "index_product_mappings_on_product_and_integration", unique: true
    t.index ["product_id"], name: "index_product_mappings_on_product_id"
  end

  create_table "products", force: :cascade do |t|
    t.string "category"
    t.bigint "company_id", null: false
    t.datetime "created_at", null: false
    t.text "description"
    t.string "dimensions"
    t.string "name", null: false
    t.string "sku", null: false
    t.datetime "updated_at", null: false
    t.decimal "weight", precision: 10, scale: 2, default: "0.0"
    t.index ["company_id", "category"], name: "index_products_on_company_id_and_category"
    t.index ["company_id", "sku"], name: "index_products_on_company_id_and_sku", unique: true
    t.index ["company_id"], name: "index_products_on_company_id"
  end

  create_table "services", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "http_method", null: false
    t.jsonb "request_mapper", default: {}, null: false
    t.jsonb "request_value_mapper", default: {}, null: false
    t.jsonb "response_mapper", default: {}, null: false
    t.jsonb "response_value_mapper", default: {}, null: false
    t.string "service_name", null: false
    t.string "type", null: false
    t.datetime "updated_at", null: false
    t.string "uri", null: false
    t.index ["service_name"], name: "index_services_on_service_name", unique: true
    t.check_constraint "type::text = ANY (ARRAY['ecommerce'::character varying::text, 'courier'::character varying::text])", name: "services_type_check"
  end

  create_table "shipment_events", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.text "description"
    t.string "external_status", null: false
    t.string "internal_status", null: false
    t.datetime "occurred_at", null: false
    t.bigint "shipment_id", null: false
    t.datetime "updated_at", null: false
    t.index ["shipment_id", "external_status", "occurred_at"], name: "index_shipment_events_on_shipment_and_event", unique: true
    t.index ["shipment_id"], name: "index_shipment_events_on_shipment_id"
    t.check_constraint "internal_status::text = ANY (ARRAY['pending'::character varying, 'ready_to_ship'::character varying, 'in_transit'::character varying, 'delivered'::character varying]::text[])", name: "shipment_events_internal_status_check"
  end

  create_table "shipments", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.bigint "company_integration_id"
    t.datetime "created_at", null: false
    t.bigint "order_id", null: false
    t.decimal "shipping_cost", precision: 10, scale: 2
    t.string "shipping_label_url"
    t.string "status", default: "pending", null: false
    t.string "tracking_number"
    t.datetime "updated_at", null: false
    t.index ["company_id"], name: "index_shipments_on_company_id"
    t.index ["company_integration_id"], name: "index_shipments_on_company_integration_id"
    t.index ["order_id"], name: "index_shipments_on_order_id", unique: true
    t.check_constraint "status::text = ANY (ARRAY['pending'::character varying, 'ready_to_ship'::character varying, 'in_transit'::character varying, 'delivered'::character varying]::text[])", name: "shipments_status_check"
  end

  create_table "stocks", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "product_id", null: false
    t.integer "quantity", default: 0, null: false
    t.datetime "updated_at", null: false
    t.bigint "warehouse_id", null: false
    t.index ["product_id", "warehouse_id"], name: "index_stocks_on_product_id_and_warehouse_id", unique: true
    t.index ["product_id"], name: "index_stocks_on_product_id"
    t.index ["warehouse_id"], name: "index_stocks_on_warehouse_id"
    t.check_constraint "quantity >= 0", name: "stocks_quantity_non_negative"
  end

  create_table "users", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.datetime "created_at", null: false
    t.string "email", default: "", null: false
    t.string "encrypted_password", default: "", null: false
    t.datetime "remember_created_at"
    t.datetime "reset_password_sent_at"
    t.string "reset_password_token"
    t.datetime "updated_at", null: false
    t.index ["company_id"], name: "index_users_on_company_id"
    t.index ["email"], name: "index_users_on_email", unique: true
    t.index ["reset_password_token"], name: "index_users_on_reset_password_token", unique: true
  end

  create_table "warehouses", force: :cascade do |t|
    t.string "address", null: false
    t.bigint "company_id", null: false
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.datetime "updated_at", null: false
    t.string "zip_code", null: false
    t.index ["company_id"], name: "index_warehouses_on_company_id"
  end

  create_table "webhook_logs", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.bigint "company_integration_id", null: false
    t.datetime "created_at", null: false
    t.text "error_message"
    t.jsonb "headers", default: {}, null: false
    t.jsonb "payload", default: {}, null: false
    t.string "status", default: "pending", null: false
    t.datetime "updated_at", null: false
    t.index ["company_id"], name: "index_webhook_logs_on_company_id"
    t.index ["company_integration_id"], name: "index_webhook_logs_on_company_integration_id"
    t.index ["status", "created_at"], name: "index_webhook_logs_on_status_and_created_at"
    t.check_constraint "status::text = ANY (ARRAY['pending'::character varying, 'processed'::character varying, 'failed'::character varying]::text[])", name: "webhook_logs_status_check"
  end

  add_foreign_key "company_integrations", "companies", on_delete: :cascade
  add_foreign_key "company_integrations", "services", on_delete: :restrict
  add_foreign_key "failed_events", "companies", on_delete: :cascade
  add_foreign_key "failed_events", "company_integrations", on_delete: :nullify
  add_foreign_key "order_items", "orders", on_delete: :cascade
  add_foreign_key "order_items", "products", on_delete: :restrict
  add_foreign_key "orders", "companies", on_delete: :cascade
  add_foreign_key "orders", "company_integrations", on_delete: :nullify
  add_foreign_key "product_mappings", "company_integrations", on_delete: :cascade
  add_foreign_key "product_mappings", "products", on_delete: :cascade
  add_foreign_key "products", "companies", on_delete: :cascade
  add_foreign_key "shipment_events", "shipments", on_delete: :cascade
  add_foreign_key "shipments", "companies", on_delete: :cascade
  add_foreign_key "shipments", "company_integrations", on_delete: :nullify
  add_foreign_key "shipments", "orders", on_delete: :cascade
  add_foreign_key "stocks", "products", on_delete: :cascade
  add_foreign_key "stocks", "warehouses", on_delete: :restrict
  add_foreign_key "users", "companies", on_delete: :cascade
  add_foreign_key "warehouses", "companies", on_delete: :cascade
  add_foreign_key "webhook_logs", "companies", on_delete: :cascade
  add_foreign_key "webhook_logs", "company_integrations", on_delete: :cascade
end

# frozen_string_literal: true

class AddConnectionConfigToIntegrations < ActiveRecord::Migration[8.1]
  # Lo que el motor necesita para hablar con un proveedor real, sin código por
  # proveedor (TESIS-138, Shopify end-to-end):
  #
  # - `company_integrations.settings`: la configuración NO secreta de la cuenta
  #   de cada empresa (dominio de la tienda, ubicación de stock, CUIT...). Va
  #   aparte de `credentials` porque no hace falta cifrarla y porque la
  #   plantilla la interpola en la URI (`https://:shop_domain/...`).
  # - `services.auth_strategy` / `auth_config`: cómo se autentica la plantilla.
  #   `bearer` es el comportamiento de siempre; las demás estrategias leen su
  #   configuración de `auth_config`.
  # - `services.credential_fields` / `setting_fields`: qué datos pide la
  #   plantilla a la empresa. Es lo que arma el formulario de conexión.
  # - `services.request_format` / `body_template` / `error_path`: el transporte.
  #   GraphQL manda `{ query: body_template, variables }` y puede contestar un
  #   error con HTTP 200, en la ruta que declara `error_path`.
  # - `services.parent_service_id` / `operation`: plantillas de operación. Una
  #   hija (probar conexión, buscar variante...) no es conectable: se ejecuta
  #   con la integración de su madre.
  def change
    add_column :company_integrations, :settings, :jsonb, default: {}, null: false

    change_table :services, bulk: true do |t|
      t.string :auth_strategy, default: 'bearer', null: false
      t.jsonb :auth_config, default: {}, null: false
      t.jsonb :credential_fields, default: [], null: false
      t.jsonb :setting_fields, default: [], null: false
      t.string :request_format, default: 'json', null: false
      t.text :body_template
      t.string :error_path
      t.string :operation
    end

    add_reference :services, :parent_service,
                  foreign_key: { to_table: :services, on_delete: :cascade }
    add_index :services, %i[parent_service_id operation], unique: true,
                                                          where: 'parent_service_id IS NOT NULL'

    add_check_constraint :services, "auth_strategy IN ('bearer', 'oauth_client_credentials')",
                         name: 'services_auth_strategy_check'
    add_check_constraint :services, "request_format IN ('json', 'graphql')",
                         name: 'services_request_format_check'
  end
end

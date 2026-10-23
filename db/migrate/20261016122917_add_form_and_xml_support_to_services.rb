# frozen_string_literal: true

class AddFormAndXmlSupportToServices < ActiveRecord::Migration[8.1]
  # Lo que el motor necesita para hablar con un proveedor SOAP/ASMX como OCA
  # e-Pak sin código por proveedor (TESIS-186, ADR-022):
  #
  # - `request_format: form`: los parámetros del request_mapper viajan como
  #   `application/x-www-form-urlencoded` (body en POST, query string en GET).
  # - `response_format`: cómo se lee la respuesta. `json` es lo de siempre;
  #   `xml` la convierte a un Hash antes de pasarla por los mappers.
  # - `auth_strategy: none`: la plantilla no manda headers de autenticación
  #   (las credenciales viajan como parámetros, `credentials.<clave>`).
  def up
    add_column :services, :response_format, :string, default: 'json', null: false

    replace_check :services_request_format_check, "request_format IN ('json', 'graphql', 'form')"
    replace_check :services_auth_strategy_check,
                  "auth_strategy IN ('bearer', 'oauth_client_credentials', 'none')"
    add_check_constraint :services, "response_format IN ('json', 'xml')",
                         name: 'services_response_format_check'
  end

  # Las CHECK viejas vuelven como NOT VALID: una base sembrada tiene las
  # plantillas de OCA (`form`, `none`), que no las cumplen, y validarlas hacía
  # fallar el rollback (TESIS-188). Así rigen para lo que se escriba después y
  # no tocan lo que ya está; borrar plantillas de un proveedor no es algo que
  # un rollback de esquema deba decidir solo.
  def down
    remove_check_constraint :services, name: 'services_response_format_check'
    replace_check :services_auth_strategy_check,
                  "auth_strategy IN ('bearer', 'oauth_client_credentials')", validate: false
    replace_check :services_request_format_check, "request_format IN ('json', 'graphql')",
                  validate: false
    remove_column :services, :response_format
  end

  private

  def replace_check(name, expression, validate: true)
    remove_check_constraint :services, name: name.to_s
    add_check_constraint :services, expression, name: name.to_s, validate: validate
  end
end

# frozen_string_literal: true

class UserSerializer < ApplicationSerializer
  identifier :id
  fields :email, :company_id, :created_at, :updated_at

  # Vista de /me. El JWT lleva el company_id pero no el nombre, y una app
  # multi-tenant necesita poder decir en pantalla de qué empresa es la sesión.
  # El registro sigue usando la vista por defecto, que no consulta companies.
  view :with_company do
    association :company, blueprint: CompanySerializer
  end
end

# frozen_string_literal: true

class UserSerializer < ApplicationSerializer
  identifier :id
  # Nunca exponer password ni encrypted_password.
  fields :email, :company_id, :created_at, :updated_at
end

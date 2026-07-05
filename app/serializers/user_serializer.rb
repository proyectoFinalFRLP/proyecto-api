# frozen_string_literal: true

class UserSerializer < ApplicationSerializer
  identifier :id
  fields :email, :company_id, :created_at, :updated_at
end

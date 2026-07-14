# frozen_string_literal: true

class CompanyIntegrationSerializer < ApplicationSerializer
  identifier :id

  fields :service_id, :company_id, :is_active, :created_at, :updated_at
end

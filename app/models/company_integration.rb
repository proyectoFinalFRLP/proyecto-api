# frozen_string_literal: true

class CompanyIntegration < ApplicationRecord
  include CompanyScoped

  belongs_to :company
  belongs_to :service

  validates :service_id, uniqueness: { scope: :company_id }
end

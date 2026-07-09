# frozen_string_literal: true

class CompanyIntegration < ApplicationRecord
  belongs_to :company
  belongs_to :service

  serialize :credentials, coder: JSON
  encrypts :credentials

  validates :service_id, uniqueness: { scope: :company_id }
end

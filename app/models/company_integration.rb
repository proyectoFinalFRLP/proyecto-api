# frozen_string_literal: true

class CompanyIntegration < ApplicationRecord
  include CompanyScoped

  belongs_to :company
  belongs_to :service
  has_many :product_mappings, dependent: :destroy

  serialize :credentials, coder: JSON
  encrypts :credentials

  validates :service_id, uniqueness: { scope: :company_id }
end

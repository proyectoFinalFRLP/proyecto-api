# frozen_string_literal: true

class CompanyIntegration < ApplicationRecord
  belongs_to :company
  belongs_to :service

  # Una PyME no puede configurar dos veces el mismo servicio.
  validates :service_id, uniqueness: { scope: :company_id }
end

# frozen_string_literal: true

module CompanyScoped
  extend ActiveSupport::Concern

  included do
    default_scope { where(company_id: Current.company_id) if Current.company_id }

    before_validation :assign_current_company, on: :create
  end

  private

  def assign_current_company
    self.company_id = Current.company_id if Current.company_id
  end
end

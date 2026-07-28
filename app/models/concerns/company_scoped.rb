# frozen_string_literal: true

module CompanyScoped
  extend ActiveSupport::Concern

  included do
    default_scope { where(company_id: Current.company_id) if Current.company_id }

    before_validation :assign_current_company, on: :create
    validate :company_id_is_immutable, on: :update
  end

  private

  def assign_current_company
    self.company_id = Current.company_id if Current.company_id
  end

  def company_id_is_immutable
    errors.add(:company_id, 'cannot be changed') if company_id_changed?
  end
end

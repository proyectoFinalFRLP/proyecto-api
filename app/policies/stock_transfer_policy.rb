# frozen_string_literal: true

class StockTransferPolicy < ApplicationPolicy
  def index?
    user.present?
  end

  def create?
    user.present?
  end

  def receive?
    record.company_id == user.company_id
  end

  def cancel?
    record.company_id == user.company_id
  end

  class Scope < ApplicationPolicy::Scope
    def resolve
      scope.where(company_id: user.company_id)
    end
  end
end

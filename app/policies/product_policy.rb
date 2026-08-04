# frozen_string_literal: true

class ProductPolicy < ApplicationPolicy
  def index?
    user.present?
  end

  def show?
    record.company_id == user.company_id
  end

  def create?
    user.present?
  end

  def update?
    record.company_id == user.company_id
  end

  def destroy?
    record.company_id == user.company_id
  end

  class Scope < ApplicationPolicy::Scope
    def resolve
      scope.where(company_id: user.company_id)
    end
  end
end

# frozen_string_literal: true

# El aislamiento entre tenants ya lo garantiza `CompanyScoped` (un evento de otra
# empresa ni siquiera se encuentra: 404). La policy es la segunda barrera, por si
# un recurso llega al controller por fuera del scope.
class FailedEventPolicy < ApplicationPolicy
  def index?   = user.present?
  def requeue? = same_company?
  def discard? = same_company?

  class Scope < ApplicationPolicy::Scope
    def resolve
      scope.where(company_id: user.company_id)
    end
  end

  private

  def same_company? = user.present? && record.company_id == user.company_id
end

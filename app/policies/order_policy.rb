# frozen_string_literal: true

class OrderPolicy < ApplicationPolicy
  def index?
    user.present?
  end

  def show?
    record.company_id == user.company_id
  end

  # Cotizar no modifica la orden, pero dispara llamadas salientes con las
  # credenciales de la empresa: se autoriza como una lectura de la orden.
  def quote?
    show?
  end

  def create?
    user.present?
  end

  # El aislamiento real ya lo garantiza el default_scope de CompanyScoped (una
  # orden de otra empresa ni siquiera se encuentra: 404). Este Scope es la
  # segunda barrera, y existe para que `policy_scope` del listado no dependa de
  # que ese default_scope siga estando.
  class Scope < ApplicationPolicy::Scope
    def resolve
      scope.where(company_id: user.company_id)
    end
  end
end

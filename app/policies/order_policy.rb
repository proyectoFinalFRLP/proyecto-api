# frozen_string_literal: true

class OrderPolicy < ApplicationPolicy
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

  # Sin `Scope`: ninguna accion lista ordenes todavia. El listado tendra su
  # propia card (ver TESIS-45).
end

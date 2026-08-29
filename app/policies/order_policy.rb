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

  # Sin `Scope`: ninguna accion lista ordenes todavia. El listado llega con
  # TESIS-42 y define ahi el suyo, en vez de dejar codigo anticipado.
end

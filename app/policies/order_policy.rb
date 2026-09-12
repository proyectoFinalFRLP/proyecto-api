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

  # Dar de alta el envío de la orden (TESIS-105). Mismo criterio que cotizar: el
  # permiso es sobre la orden —que sea del tenant del usuario—, y qué estados
  # admiten despacho es una regla de negocio que vive en Shipments::CreateShipment,
  # no acá.
  def ship?
    show?
  end

  def create?
    user.present?
  end

  # Sin `Scope`: ninguna accion lista ordenes todavia. El listado tendra su
  # propia card (ver TESIS-112).
end

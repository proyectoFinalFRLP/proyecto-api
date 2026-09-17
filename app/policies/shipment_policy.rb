# frozen_string_literal: true

# El aislamiento entre tenants ya lo garantiza `CompanyScoped` (un envío de otra
# empresa ni siquiera se encuentra: 404). La policy es la segunda barrera, por si
# un recurso llega al controller por fuera del scope.
#
# Sólo lectura: un envío no se edita ni se borra por esta API — avanza por el
# tracking del courier (TESIS-48) y por la confirmación del despacho (TESIS-47).
#
# El alta (TESIS-105) tampoco pasa por acá: cuelga de la orden
# (POST /orders/:order_id/shipment) y se autoriza con `OrderPolicy#ship?`, porque
# cuando corre el chequeo el envío todavía no existe y el permiso es sobre la
# orden. Las acciones de escritura quedan en el `false` de ApplicationPolicy.
class ShipmentPolicy < ApplicationPolicy
  def index? = user.present?
  def show?  = user.present? && record.company_id == user.company_id

  class Scope < ApplicationPolicy::Scope
    def resolve
      scope.where(company_id: user.company_id)
    end
  end
end

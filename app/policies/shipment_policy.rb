# frozen_string_literal: true

# El aislamiento entre tenants ya lo garantiza `CompanyScoped` (un envío de otra
# empresa ni siquiera se encuentra: 404). La policy es la segunda barrera, por si
# un recurso llega al controller por fuera del scope.
#
# Un envío no se edita ni se borra por esta API. La única escritura es confirmar
# su despacho (TESIS-47), que no toma campos del cliente: los escribe el courier.
# El resto del avance lo escribe el push de tracking (TESIS-48).
#
# El alta (TESIS-105) tampoco pasa por acá: cuelga de la orden
# (POST /orders/:order_id/shipment) y se autoriza con `OrderPolicy#ship?`, porque
# cuando corre el chequeo el envío todavía no existe y el permiso es sobre la
# orden. Las acciones de escritura quedan en el `false` de ApplicationPolicy.
class ShipmentPolicy < ApplicationPolicy
  def index? = user.present?
  def show?  = user.present? && record.company_id == user.company_id

  # Confirmar el despacho (TESIS-47) es la única escritura que el usuario hace
  # sobre un envío. El permiso es el mismo que para verlo —que sea de su
  # empresa—; qué estados admiten despacho es una regla de negocio y vive en
  # Shipments::ConfirmDispatch, no acá.
  def dispatch? = show?

  class Scope < ApplicationPolicy::Scope
    def resolve
      scope.where(company_id: user.company_id)
    end
  end
end

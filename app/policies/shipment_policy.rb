# frozen_string_literal: true

# El aislamiento entre tenants ya lo garantiza `CompanyScoped` (un envío de otra
# empresa ni siquiera se encuentra: 404). La policy es la segunda barrera, por si
# un recurso llega al controller por fuera del scope.
#
# Sólo lectura: los envíos no se crean ni se editan por esta API — nacen al
# confirmar el despacho (TESIS-105) y avanzan por el tracking del courier
# (TESIS-48). Las acciones de escritura quedan en el `false` de ApplicationPolicy.
class ShipmentPolicy < ApplicationPolicy
  def index? = user.present?
  def show?  = user.present? && record.company_id == user.company_id

  class Scope < ApplicationPolicy::Scope
    def resolve
      scope.where(company_id: user.company_id)
    end
  end
end

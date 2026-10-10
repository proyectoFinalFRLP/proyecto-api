# frozen_string_literal: true

# El feed no tiene modelo propio: se arma con órdenes, eventos de envío y
# eventos fallidos, y los tres ya están scopeados por tenant. La policy existe
# igual para que el controller no tenga que saltear la verificación de Pundit
# —`verify_authorized` está activo en toda la API— y para que quede un lugar
# donde apretar el permiso si algún día el feed deja de ser para cualquiera.
class ActivityPolicy < ApplicationPolicy
  def index? = user.present?
end

# frozen_string_literal: true

# Política sin registro (headless): un reporte no es un recurso con dueño, es una
# vista sobre los datos del tenant. El aislamiento lo da `CompanyScoped` en cada
# modelo que el PORO consulta; acá sólo se exige una sesión.
class ReportPolicy < ApplicationPolicy
  def overview? = user.present?
end

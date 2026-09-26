# frozen_string_literal: true

module Admin
  # Las páginas del backoffice muestran datos de todas las empresas. Con el
  # Cache-Control por default de Rails (private, must-revalidate) el navegador
  # puede guardarlas y, después del logout, el botón «atrás» las vuelve a
  # mostrar desde su cache sin pedirlas de nuevo. no-store le pide que no guarde
  # ninguna (TESIS-129).
  #
  # Se incluye en Avo::ApplicationController desde config/initializers/avo.rb,
  # que es la forma que documenta Avo para sumar comportamiento a todos sus
  # controllers sin copiar el suyo.
  module UncacheablePages
    extend ActiveSupport::Concern

    included do
      before_action :no_store
    end
  end
end

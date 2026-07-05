# frozen_string_literal: true

# Clase base para los POROs (casos de uso de negocio).
# Un PORO = un caso de uso. Convención: instanciar y llamar #call.
class ApplicationPoro
  def self.call(...)
    new(...).call
  end
end

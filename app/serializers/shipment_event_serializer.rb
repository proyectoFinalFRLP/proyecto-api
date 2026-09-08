# frozen_string_literal: true

# Una entrada de la bitácora del envío. `internal_status` es el vocabulario
# normalizado del sistema y `external_status` el texto crudo que mandó el
# courier: los dos viajan porque el front muestra el segundo y colorea por el
# primero.
class ShipmentEventSerializer < ApplicationSerializer
  identifier :id

  fields :internal_status, :external_status, :description, :occurred_at, :created_at
end

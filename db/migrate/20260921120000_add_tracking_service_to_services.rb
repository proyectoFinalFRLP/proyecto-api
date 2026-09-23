# frozen_string_literal: true

class AddTrackingServiceToServices < ActiveRecord::Migration[8.1]
  # Plantilla con la que se consulta periódicamente el estado de los envíos de
  # un courier que no empuja webhooks (TESIS-49). Es una relación entre
  # plantillas, no entre integraciones: "cómo se pregunta por un envío de este
  # proveedor" es igual para todas las empresas que lo usen.
  #
  # nullable: la mayoría de los couriers no la necesita (empujan el tracking,
  # ADR-011), y su ausencia es justamente lo que dice "a éste no se le pregunta".
  def change
    add_reference :services, :tracking_service,
                  foreign_key: { to_table: :services, on_delete: :nullify }
  end
end

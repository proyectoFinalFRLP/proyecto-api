# frozen_string_literal: true

class AddQuoteServiceToServices < ActiveRecord::Migration[8.1]
  # Plantilla con la que se le piden tarifas al courier que despacha con esta
  # plantilla (TESIS-131). Cotizar y despachar son dos endpoints del proveedor y,
  # por convención, dos `Service`; esto es lo que dice que son del mismo
  # proveedor, para que una opción cotizada se pueda despachar.
  #
  # Mismo criterio que `tracking_service_id` (TESIS-49): es una relación entre
  # plantillas, no entre integraciones, y cuelga de la plantilla que despacha.
  # nullable: un courier sin plantilla de cotización simplemente no se ofrece.
  #
  # Único: una plantilla de cotización es de un solo despachador. La cotización
  # devuelve una opción por cotizador y la despacha con UNA integración; si dos
  # plantillas de despacho compartieran la de cotización, una se perdería.
  def change
    add_reference :services, :quote_service,
                  index: { unique: true },
                  foreign_key: { to_table: :services, on_delete: :nullify }
  end
end

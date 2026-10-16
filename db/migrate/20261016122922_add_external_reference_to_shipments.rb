# frozen_string_literal: true

class AddExternalReferenceToShipments < ActiveRecord::Migration[8.1]
  # El identificador con el que el courier nombra el despacho, además del número
  # de seguimiento (TESIS-186). En OCA e-Pak es la orden de retiro: la etiqueta
  # y el seguimiento se piden con los dos.
  def change
    add_column :shipments, :external_reference, :string
  end
end

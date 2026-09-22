# frozen_string_literal: true

class WarehouseSerializer < ApplicationSerializer
  identifier :id
  fields :name, :zip_code, :address

  # Unidades guardadas en el deposito. Alimenta el widget de capacidad del panel
  # (TESIS-55): la barra compara depositos entre si, no contra una capacidad
  # maxima, porque el modelo no tiene ninguna.
  #
  # Se expone como entero y nunca null: un deposito vacio guarda cero unidades,
  # que es un dato, no un dato faltante.
  field :stored_units
end

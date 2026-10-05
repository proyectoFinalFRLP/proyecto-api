# frozen_string_literal: true

class WarehouseSerializer < ApplicationSerializer
  identifier :id
  # `capacity` puede ser null y eso significa algo: nadie declaró el techo de
  # este depósito todavía. No es cero, que diría que no entra nada.
  fields :name, :zip_code, :address, :capacity

  # Unidades guardadas en el deposito. Alimenta el widget de capacidad del panel
  # (TESIS-55): la barra compara depositos entre si, no contra una capacidad
  # maxima, porque el modelo no tiene ninguna.
  #
  # Se expone como entero y nunca null: un deposito vacio guarda cero unidades,
  # que es un dato, no un dato faltante.
  field :stored_units

  # El deposito como referencia dentro de otro recurso (el stock de un
  # producto). Sin `stored_units`: fuera del listado de depositos no viene del
  # scope `with_stored_units` y costaria una query por deposito.
  view :reference do
    excludes :stored_units
  end
end

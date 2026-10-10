# frozen_string_literal: true

# Capacidad del depósito, en unidades. La barra de ocupación del detalle de
# producto compara lo guardado contra un techo, y ese techo no se puede derivar
# de ningún dato: lo sabe quien conoce el depósito.
#
# Nullable a propósito: los depósitos que ya existen no tienen una capacidad que
# alguien haya declarado, y poner un número por defecto sería inventarlo. Sin
# capacidad cargada, la pantalla no dibuja la barra (TESIS-163).
class AddCapacityToWarehouses < ActiveRecord::Migration[8.1]
  def change
    add_column :warehouses, :capacity, :integer
  end
end

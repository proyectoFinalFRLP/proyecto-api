# frozen_string_literal: true

class AddApprovedToUsers < ActiveRecord::Migration[8.1]
  # Registrarse pasa a ser pedir acceso (S02: «Solicitá acceso al espacio de
  # operación de tu organización»). La cuenta que crea el registro público nace
  # sin aprobar y no puede loguearse hasta que la aprueben.
  #
  # Default true a propósito: las cuentas que ya existen, y las que crean el
  # backoffice, los seeds o la consola, quedan habilitadas como hasta ahora.
  # Sólo Auth::RegisterUser crea cuentas con false.
  def change
    add_column :users, :approved, :boolean, default: true, null: false
  end
end

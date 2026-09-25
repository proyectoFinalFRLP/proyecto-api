# frozen_string_literal: true

class AddSessionTokenToAdminUsers < ActiveRecord::Migration[8.1]
  # Parte del salt con el que Devise valida la cookie de sesión del backoffice
  # (AdminUser#authenticatable_salt). El logout lo rota y así invalida las
  # cookies emitidas antes (TESIS-129). Nullable: las cuentas existentes
  # arrancan sin token y siguen con su sesión hasta el primer logout.
  def change
    add_column :admin_users, :session_token, :string
  end
end

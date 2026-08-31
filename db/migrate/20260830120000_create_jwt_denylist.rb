# frozen_string_literal: true

# Lista de revocación de tokens JWT. Sin ella el logout sólo borra la sesión del
# navegador y el token sigue siendo válido contra la API hasta que expira: ver
# ADR-002.
#
# El índice sobre jti es único porque un jti repetido significaría dos tokens con
# la misma identidad, y `exp` se indexa para que la limpieza periódica no barra
# la tabla entera.
class CreateJwtDenylist < ActiveRecord::Migration[8.1]
  def change
    create_table :jwt_denylist do |t|
      t.string :jti, null: false
      t.datetime :exp, null: false

      t.timestamps
    end

    add_index :jwt_denylist, :jti, unique: true
    add_index :jwt_denylist, :exp
  end
end

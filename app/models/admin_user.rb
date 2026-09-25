# frozen_string_literal: true

class AdminUser < ApplicationRecord
  devise :database_authenticatable, :rememberable, :validatable

  # Devise guarda en la cookie de sesión [id, authenticatable_salt] y la da por
  # buena mientras el salt coincida. El salt sale del hash de la password, y el
  # cookie store no guarda nada del lado del servidor que el logout pueda
  # borrar: una cookie copiada antes de salir seguía abriendo el panel después.
  # Sumarle session_token al salt permite invalidarla rotándolo. Las cookies de
  # «Recordarme» caen también, porque :rememberable usa el mismo salt.
  def authenticatable_salt
    "#{super}#{session_token}"
  end

  # Cierra todas las sesiones de la cuenta, no sólo la del navegador que pidió
  # salir: la cookie no dice de qué navegador viene.
  def expire_sessions!
    update!(session_token: SecureRandom.base58(24))
  end
end

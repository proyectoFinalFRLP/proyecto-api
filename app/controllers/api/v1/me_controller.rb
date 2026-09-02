# frozen_string_literal: true

module Api
  module V1
    class MeController < ApplicationController
      # La identidad de la sesión: siempre el usuario del token.
      #
      # No recibe id por parámetro a propósito. Leer un usuario ajeno es otra
      # decisión y otro endpoint; aceptar un id acá abriría esa puerta sin que
      # nadie la haya discutido.
      #
      # Se renderiza el registro que devuelve `authorize`, no `current_user` de
      # nuevo. Hoy son el mismo objeto, pero escribirlo así ata "a quién
      # autorizo" con "qué devuelvo": si mañana el endpoint aceptara un id, hay
      # un solo lugar que tocar. `verify_authorized` sólo comprueba que se haya
      # llamado a `authorize`, no con qué registro, así que sin esta atadura ese
      # desacople pasaría en verde devolviendo un usuario ajeno.
      def show
        user = authorize current_user, :show?

        render json: UserSerializer.render(user, view: :with_company)
      end
    end
  end
end

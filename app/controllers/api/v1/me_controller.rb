# frozen_string_literal: true

module Api
  module V1
    class MeController < ApplicationController
      # La identidad de la sesión: siempre el usuario del token.
      #
      # No recibe id por parámetro a propósito. Leer un usuario ajeno es otra
      # decisión y otro endpoint; aceptar un id acá abriría esa puerta sin que
      # nadie la haya discutido.
      def show
        authorize current_user, :show?

        render json: UserSerializer.render(current_user, view: :with_company)
      end
    end
  end
end

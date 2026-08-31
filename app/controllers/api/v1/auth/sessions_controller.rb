# frozen_string_literal: true

module Api
  module V1
    module Auth
      class SessionsController < ApplicationController
        skip_before_action :authenticate_user!, only: :create
        skip_after_action :verify_authorized, :verify_policy_scoped

        def create
          token = ::Auth::AuthenticateUser.new(
            email: params[:email],
            password: params[:password]
          ).call

          if token
            render json: { token: token }, status: :ok
          else
            render json: { error: 'Invalid email or password' }, status: :unauthorized
          end
        end

        # 204 siempre que la petición venga autenticada, revoque o no: el cliente
        # pidió salir y sale. Devolver un error por un token ilegible lo dejaría
        # con la sesión abierta en pantalla por un problema que ya no importa.
        def destroy
          ::Auth::RevokeToken.new(
            user: current_user,
            authorization_header: request.headers['Authorization']
          ).call

          head :no_content
        end
      end
    end
  end
end

# frozen_string_literal: true

module Api
  module V1
    module Auth
      class SessionsController < ApplicationController
        include TenantFromSlug

        skip_before_action :authenticate_user!, only: :create
        skip_after_action :verify_authorized, :verify_policy_scoped

        # El login está scoped al tenant del slug: un usuario de Norte no obtiene
        # token en el portal de Sur. Los cinco casos de fallo (tenant no
        # resuelto, email desconocido, usuario de otro tenant, password
        # incorrecta) comparten esta única rama y responden idéntico, así que la
        # respuesta no permite enumerar usuarios ni tenants.
        def create
          token = ::Auth::AuthenticateUser.new(
            email: params[:email],
            password: params[:password],
            company: tenant_company
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

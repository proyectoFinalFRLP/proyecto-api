# frozen_string_literal: true

module Api
  module V1
    module Auth
      class RegistrationsController < ApplicationController
        include TenantFromSlug

        skip_before_action :authenticate_user!
        skip_after_action :verify_authorized, :verify_policy_scoped

        def create
          company = tenant_company
          return render_unknown_tenant if company.nil?

          user = ::Auth::RegisterUser.new(params: user_params, company: company).call
          render json: UserSerializer.render(user), status: :created
        rescue ActiveRecord::RecordInvalid => e
          render json: { errors: e.record.errors.full_messages }, status: :unprocessable_content
        end

        private

        # `company_id` ya no se permitea: el tenant sale del slug del request.
        # Mandarlo en el body no hace nada — no es un error, simplemente se
        # ignora, como cualquier atributo desconocido.
        def user_params
          params.permit(:email, :password)
        end

        # Mismo cuerpo para slug ausente, inexistente e inactivo: la respuesta no
        # dice si el tenant existe. Se usa el shape `errors` que ya devuelve el
        # 422 de validación, para que el frontend no distinga dos formatos.
        def render_unknown_tenant
          render json: { errors: ['Unable to complete registration'] },
                 status: :unprocessable_content
        end
      end
    end
  end
end

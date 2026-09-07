# frozen_string_literal: true

module Api
  module V1
    # Config pública del tenant. La pide el frontend antes del login para pintar
    # el branding, así que no exige JWT — pero si el request trae uno válido, ese
    # tenant manda y el slug del header se ignora.
    class TenantConfigController < ApplicationController
      skip_before_action :authenticate_user!
      skip_after_action :verify_authorized, :verify_policy_scoped

      def show
        # `current_user` acá no autentica de forma obligatoria: devuelve el
        # usuario si el token es válido y nil si no hay token, está vencido o
        # fue revocado. Es exactamente la semántica de "si hay JWT, gana el JWT".
        company = ::Auth::ResolveTenant.new(slug: tenant_slug, user: current_user).call

        # Slug inexistente, empresa inactiva o request sin slug ni sesión: 404.
        # No es enumeración — el slug es el subdominio, ya es público.
        return render_not_found if company.nil?

        render json: TenantConfigSerializer.render(company)
      end

      private

      # El query param es una comodidad de debug/curl y sólo se acepta acá; en
      # los endpoints de auth el slug viaja únicamente por header.
      def tenant_slug
        request.headers['X-Tenant-Slug'].presence || params[:slug]
      end
    end
  end
end

# frozen_string_literal: true

module Api
  module V1
    class IntegrationsController < ApplicationController
      skip_after_action :verify_authorized, :verify_policy_scoped

      # Envuelto en `data` como el resto de las colecciones (ADR-015). Era el
      # único listado que devolvía un array pelado, y un array en la raíz no
      # deja lugar para agregarle `meta` el día que pagine sin romper a quien
      # lo consume.
      def index
        integrations = current_company.company_integrations.index_by(&:service_id)
        render json: {
          data: IntegrationStatusSerializer.render_as_hash(
            Service.order(:id), integrations_by_service_id: integrations
          )
        }
      end

      def update
        integration = Integrations::UpsertIntegration.new(
          company: current_company,
          service_id: params[:service_id],
          credentials: credentials_params,
          is_active: params.fetch(:is_active, true)
        ).call
        render json: CompanyIntegrationSerializer.render(integration), status: :ok
      end

      private

      def credentials_params
        raw = params.require(:credentials)
        unless raw.is_a?(ActionController::Parameters)
          raise ActionController::ParameterMissing, :credentials
        end

        raw.to_unsafe_h
      end
    end
  end
end

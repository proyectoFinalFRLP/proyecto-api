# frozen_string_literal: true

module Api
  module V1
    class IntegrationsController < ApplicationController
      # El listado no pasa por Pundit: lo usa el widget de nodos del panel
      # aunque la empresa no tenga la feature `integrations`, y sólo muestra las
      # plantillas globales con el estado de la propia empresa. El alta y la
      # modificación sí: ver CompanyIntegrationPolicy.
      skip_after_action :verify_policy_scoped

      def index
        integrations = current_company.company_integrations.index_by(&:service_id)
        render json: IntegrationStatusSerializer.render(
          Service.order(:id), integrations_by_service_id: integrations
        )
      end

      def update
        authorize CompanyIntegration
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

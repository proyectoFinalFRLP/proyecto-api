# frozen_string_literal: true

module Api
  module V1
    class IntegrationsController < ApplicationController
      skip_after_action :verify_authorized, :verify_policy_scoped

      # El flag `integrations` de la empresa no se miraba acá: el front oculta la
      # sección, pero una empresa sin la feature la configuraba igual llamando al
      # endpoint directo. Se corta el alta y la modificación. El listado queda
      # abierto porque lo usa el widget de nodos del panel, y sólo muestra las
      # plantillas globales con el estado de la propia empresa.
      before_action :require_integrations_feature, only: :update

      def index
        integrations = current_company.company_integrations.index_by(&:service_id)
        render json: IntegrationStatusSerializer.render(
          Service.order(:id), integrations_by_service_id: integrations
        )
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

      def require_integrations_feature
        return if current_company.feature_enabled?(:integrations)

        render json: { error: 'The integrations feature is not enabled for this company' },
               status: :forbidden
      end

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

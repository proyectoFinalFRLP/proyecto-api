# frozen_string_literal: true

module Api
  module V1
    class IntegrationsController < ApplicationController
      include Paginatable

      # El listado no pasa por Pundit: lo usa el widget de nodos del panel
      # aunque la empresa no tenga la feature `integrations`, y sólo muestra las
      # plantillas globales con el estado de la propia empresa. El alta y la
      # modificación sí: ver CompanyIntegrationPolicy.
      skip_after_action :verify_policy_scoped

      # Envuelto en `data` como el resto de las colecciones (ADR-015): era el
      # único listado que devolvía un array pelado, y un array en la raíz no
      # deja lugar para agregarle `meta`.
      #
      # Y pagina como todo listado (TESIS-108), aunque hoy `services` tenga pocas
      # filas: es una tabla global que sólo crece cuando el administrador carga
      # una plantilla nueva. Dejarla afuera sería una excepción que habría que
      # justificar, y la regla vale más que el ahorro.
      #
      # `WHOLE_LIST_PER_PAGE` porque el panel la lee entera para dibujar sus
      # nodos, no de a páginas.
      def index
        integrations = current_company.company_integrations.index_by(&:service_id)
        services, meta = paginate(Service.order(:id), per_page: WHOLE_LIST_PER_PAGE)

        render json: {
          data: IntegrationStatusSerializer.render_as_hash(
            services, integrations_by_service_id: integrations
          ),
          meta: meta
        }
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

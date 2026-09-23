# frozen_string_literal: true

module Api
  module V1
    class IntegrationsController < ApplicationController
      include Paginatable

      skip_after_action :verify_authorized, :verify_policy_scoped

      # Envuelto en `data` como el resto de las colecciones (ADR-015). Era el
      # único listado que devolvía un array pelado, y un array en la raíz no
      # deja lugar para agregarle `meta` el día que pagine sin romper a quien
      # lo consume.
      # Pagina como todo listado (TESIS-108), aunque hoy `services` tenga pocas
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

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

      rescue_from Integrations::InvalidIntegrationError, with: :render_invalid_fields

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
        services, meta = paginate(Service.connectable.includes(:operation_services).order(:id),
                                  per_page: WHOLE_LIST_PER_PAGE)

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
          settings: settings_params,
          is_active: params[:is_active]
        ).call
        render json: CompanyIntegrationSerializer.render(integration), status: :ok
      end

      # Desconectar: deja de operar y borra los secretos, conservando la
      # configuración y los productos vinculados (Integrations::DisconnectIntegration).
      def destroy
        authorize CompanyIntegration
        Integrations::DisconnectIntegration.new(company_integration: current_integration).call
        head :no_content
      end

      # «Probar conexión». Siempre 200: que el proveedor rechace la cuenta es el
      # resultado de la prueba, no un error del request (`ok: false`).
      def test
        authorize CompanyIntegration
        result = Integrations::TestConnection.new(company_integration: current_integration).call
        render json: result, status: :ok
      end

      private

      def current_integration
        current_company.company_integrations.find_by!(service_id: params.expect(:service_id))
      end

      # Opcional: sin credenciales se conservan las que había. Si vienen, tienen
      # que ser un objeto (un string o un array reventarían dentro del cifrado).
      def credentials_params
        return nil unless params.key?(:credentials)

        raw = params[:credentials]
        unless raw.is_a?(ActionController::Parameters)
          raise ActionController::ParameterMissing, :credentials
        end

        raw.to_unsafe_h
      end

      def settings_params
        raw = params[:settings]
        raw.is_a?(ActionController::Parameters) ? raw.to_unsafe_h : nil
      end

      # `error` siempre está (ADR-015); `fields` dice qué campo falló y por qué.
      def render_invalid_fields(exception)
        render json: { error: exception.message, fields: exception.fields },
               status: :unprocessable_content
      end
    end
  end
end

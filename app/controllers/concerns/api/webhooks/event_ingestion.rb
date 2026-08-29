# frozen_string_literal: true

module Api
  module Webhooks
    # Mecánica común a los endpoints públicos de ingesta de webhooks: persistir
    # el evento crudo en un WebhookLog y liberar la conexión. Dos endpoints
    # (integrations y couriers) comparten exactamente esta receta pero difieren
    # en qué worker dispara cada uno después de persistir, así que ese único
    # paso queda como hook para que cada controller lo resuelva.
    module EventIngestion
      extend ActiveSupport::Concern

      # Constante del módulo, no del `included do`: los métodos privados de más
      # abajo (request_headers) están definidos léxicamente dentro de este
      # módulo, así que la resuelven por scoping léxico. Si viviera dentro de
      # `included do` quedaría como constante de la clase que incluye el
      # concern, invisible para esos métodos.
      SENSITIVE_HEADERS = %w[HTTP_COOKIE HTTP_AUTHORIZATION].freeze

      included do
        skip_before_action :authenticate_user!
        skip_before_action :set_current_tenant

        # Endpoint público sin Pundit: no hay usuario que autorizar, el tenant sale
        # de la integración. TESIS-33 agrega los verify_* de Pundit en
        # ApplicationController; `raise: false` deja este skip válido tanto antes
        # como después de ese merge, sin depender del orden en que entren.
        skip_after_action :verify_authorized, :verify_policy_scoped, raise: false

        # Si la integración se borra entre el find y el insert, el FK falla. Vale
        # el mismo 404 que si no existiera: no se persistió nada y el proveedor
        # tiene que dejar de mandar eventos a esa integración.
        rescue_from ActiveRecord::InvalidForeignKey, with: :render_not_found

        # El payload se lee del body crudo por dos razones: ParamsWrapper envolvería
        # el JSON bajo la clave del controller, y tocar `params` dispararía el parseo
        # del body en el middleware, que responde 400 ante un JSON malformado antes
        # de llegar acá. Leyendo path_parameters y raw_post el evento siempre se
        # persiste, incluso si viene roto.
        wrap_parameters false
      end

      def create
        # El tenant sale de la integración, nunca de Current (que acá no se
        # setea). `unscoped` deja explícita la búsqueda cross-tenant y la blinda
        # si más adelante alguien setea Current antes de esta acción.
        integration = CompanyIntegration.unscoped
                                        .find(request.path_parameters[:company_integration_id])

        # Current queda explícitamente en nil durante el insert: si algún día
        # llegara con valor, el assign_current_company de CompanyScoped pisaría
        # el company_id derivado de la integración y el log terminaría en el
        # tenant equivocado. Acá el tenant lo manda la integración, punto.
        log = Current.set(company_id: nil) do
          WebhookLog.create!(
            company_id: integration.company_id,
            company_integration: integration,
            headers: request_headers,
            payload: request_payload
          )
        end

        enqueue_processing(log, integration)

        head :accepted
      end

      private

      # Hook de la clase que incluye el concern: el gateway sólo persiste y suelta
      # la conexión; qué worker procesa el evento lo decide cada endpoint.
      def enqueue_processing(_log, _integration) = nil

      # Un body ilegible no se rechaza: se guarda tal cual para no perder el
      # evento (el reproceso es responsabilidad de la épica de resiliencia).
      def request_payload
        body = request.raw_post
        return {} if body.blank?

        parsed = JSON.parse(body)
        parsed.is_a?(Hash) || parsed.is_a?(Array) ? parsed : { 'raw' => body }
      rescue JSON::ParserError
        { 'raw' => body }
      end

      def request_headers
        request.headers.env.select do |key, value|
          key.start_with?('HTTP_') && SENSITIVE_HEADERS.exclude?(key) && value.is_a?(String)
        end
      end
    end
  end
end

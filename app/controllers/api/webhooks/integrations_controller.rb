# frozen_string_literal: true

module Api
  module Webhooks
    # Punto de entrada público para las plataformas externas: persiste el evento
    # crudo y libera la conexión. Sin autenticación JWT (los proveedores no
    # tienen sesión en el OMS) y sin lógica de negocio: el procesamiento real
    # queda a cargo de los workers asíncronos.
    class IntegrationsController < ApplicationController
      SENSITIVE_HEADERS = %w[HTTP_COOKIE HTTP_AUTHORIZATION].freeze

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
        Current.set(company_id: nil) do
          WebhookLog.create!(
            company_id: integration.company_id,
            company_integration: integration,
            headers: request_headers,
            payload: request_payload
          )
        end

        head :accepted
      end

      private

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

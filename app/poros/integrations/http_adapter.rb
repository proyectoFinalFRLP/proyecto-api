# frozen_string_literal: true

require 'net/http'

module Integrations
  # Adaptador HTTP genérico (Data-Driven): se comunica con cualquier API externa
  # usando la plantilla del Service (uri, http_method y mappers) y las
  # credenciales cifradas de la CompanyIntegration, sin lógica por proveedor.
  class HttpAdapter < ApplicationPoro
    # Segundos para abrir la conexión y para esperar la respuesta.
    TIMEOUTS = { open: 10, read: 10 }.freeze

    HTTP_METHODS = {
      'GET' => Net::HTTP::Get,
      'POST' => Net::HTTP::Post,
      'PUT' => Net::HTTP::Put,
      'PATCH' => Net::HTTP::Patch,
      'DELETE' => Net::HTTP::Delete
    }.freeze

    BODYLESS_METHODS = %w[GET DELETE].freeze

    NETWORK_ERRORS = [
      Net::OpenTimeout, Net::ReadTimeout, Errno::ECONNREFUSED, Errno::ECONNRESET,
      SocketError, OpenSSL::SSL::SSLError, EOFError
    ].freeze

    # Los timeouts son parámetro y no constante fija porque no todos los usos
    # toleran lo mismo: un sync saliente en background puede esperar 10s, pero
    # una cotización que corre dentro de un request HTTP no — ahí el usuario está
    # esperando y el motor prefiere perder un operador antes que la respuesta
    # entera (TESIS-46).
    #
    # `service` permite hablarle al mismo proveedor con otra de sus plantillas y
    # las credenciales de esta integración: la consulta de tracking (TESIS-49)
    # usa la plantilla de seguimiento del courier con la cuenta que despachó.
    def initialize(company_integration:, service: company_integration.service, payload: {},
                   uri_params: {}, timeouts: TIMEOUTS)
      super()
      @integration = company_integration
      @service = service
      @payload = payload
      @uri_params = uri_params
      @timeouts = TIMEOUTS.merge(timeouts)
    end

    def call
      ParseExternalResponse.new(service: @service, response_body: fetch).call
    end

    # La respuesta JSON tal cual la mandó el proveedor, sin pasar por los
    # mappers. `call` aplica el response_value_mapper a todo lo que extrae, y hay
    # quien necesita el dato crudo: el seguimiento conserva el estado externo
    # textual además del traducido (ver Shipments::TranslateTrackingPayload).
    #
    # También es donde se detectan los errores que llegan con HTTP 200
    # (Integrations::DetectResponseErrors): así los ven los dos caminos.
    def fetch
      response = execute_with_token_renewal
      raise_http_error(response) unless response.is_a?(Net::HTTPSuccess)

      parse_json(response.body).tap do |body|
        DetectResponseErrors.new(service: @service, body: body, payload: @payload).call
      end
    rescue *NETWORK_ERRORS => e
      raise AdapterExecutionError.new(
        "#{@service.service_name} request failed: #{e.class}: #{e.message}", payload: @payload
      )
    end

    private

    # Un 401 con un token que el sistema creía vigente (lo revocaron, o el
    # proveedor lo invalidó antes de tiempo) se reintenta una sola vez con un
    # token nuevo. Sólo tiene sentido con las estrategias que obtienen el token
    # solas: con `bearer` el token es el que cargó la empresa.
    def execute_with_token_renewal
      response = execute(build_request)
      return response unless response.is_a?(Net::HTTPUnauthorized) && renewable_token?

      execute(build_request(force_refresh: true))
    end

    def renewable_token? = @integration.service.oauth_client_credentials?

    def build_request(force_refresh: false)
      uri = URI(interpolated_uri)
      request = request_class.new(uri)
      headers(force_refresh).each { |key, value| request[key] = value }
      request.body = request_body unless BODYLESS_METHODS.include?(@service.http_method)
      [uri, request]
    end

    # GraphQL manda el documento tal cual y los valores dinámicos siempre como
    # variables, nunca interpolados en el documento.
    def request_body
      mapped = BuildExternalPayload.new(service: @service, payload: @payload,
                                        settings: @integration.settings).call
      return mapped.to_json unless @service.graphql?

      { query: @service.body_template, variables: mapped }.to_json
    end

    def request_class
      HTTP_METHODS.fetch(@service.http_method) do
        raise AdapterExecutionError.new(
          "#{@service.service_name} has an unsupported http_method: #{@service.http_method}",
          payload: @payload
        )
      end
    end

    def execute((uri, request))
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == 'https'
      http.open_timeout = @timeouts[:open]
      http.read_timeout = @timeouts[:read]
      http.request(request)
    end

    def raise_http_error(response)
      raise AdapterExecutionError.new(
        "#{@service.service_name} responded with HTTP #{response.code}",
        payload: @payload, response_status: response.code.to_i, response_body: response.body
      )
    end

    def parse_json(body)
      JSON.parse(body.to_s)
    rescue JSON::ParserError
      raise AdapterExecutionError.new(
        "#{@service.service_name} returned a non-JSON response",
        payload: @payload, response_body: body
      )
    end

    def headers(force_refresh)
      { 'Content-Type' => 'application/json', 'Accept' => 'application/json' }.merge(
        AuthHeaders.new(company_integration: @integration, force_refresh: force_refresh).call
      )
    end

    # Los settings de la cuenta completan la URI (`https://:shop_domain/...`);
    # los uri_params del caso de uso tienen prioridad sobre ellos.
    def interpolated_uri
      values = (@integration.settings || {}).merge(@uri_params.transform_keys(&:to_s))
      InterpolateUri.new(template: @service.uri, values: values).call
    end
  end
end

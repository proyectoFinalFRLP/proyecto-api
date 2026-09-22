# frozen_string_literal: true

require 'net/http'

module Integrations
  # Adaptador HTTP genérico (Data-Driven): se comunica con cualquier API externa
  # usando la plantilla del Service (uri, http_method y mappers) y las
  # credenciales cifradas de la CompanyIntegration, sin lógica por proveedor.
  class HttpAdapter < ApplicationPoro
    # Segundos para abrir la conexión y para esperar la respuesta.
    TIMEOUTS = { open: 10, read: 10 }.freeze

    # Charset de nombre de header válido (RFC 9110 token). Net::HTTPHeader no
    # valida la clave: un \r\n en el nombre parte la línea e inyecta headers.
    HEADER_NAME = /\A[A-Za-z0-9!#$%&'*+\-.^_`|~]+\z/

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
    def fetch
      response = execute(build_request)
      raise_http_error(response) unless response.is_a?(Net::HTTPSuccess)

      parse_json(response.body)
    rescue *NETWORK_ERRORS => e
      raise AdapterExecutionError.new(
        "#{@service.service_name} request failed: #{e.class}: #{e.message}", payload: @payload
      )
    end

    private

    def build_request
      uri = URI(interpolated_uri)
      request = request_class.new(uri)
      headers.each { |key, value| request[key] = value }
      unless BODYLESS_METHODS.include?(@service.http_method)
        request.body = BuildExternalPayload.new(service: @service, payload: @payload).call.to_json
      end
      [uri, request]
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

    # Convención de credenciales: access_token viaja como Bearer; cualquier otra
    # clave del hash se envía como header literal (ej. X-Api-Key).
    def headers
      base = { 'Content-Type' => 'application/json', 'Accept' => 'application/json' }
      (@integration.credentials || {}).each_with_object(base) do |(key, value), result|
        validate_header_name!(key)

        if key == 'access_token'
          result['Authorization'] = "Bearer #{value}"
        else
          result[key] = value.to_s
        end
      end
    end

    def validate_header_name!(key)
      return if key.to_s.match?(HEADER_NAME)

      raise AdapterExecutionError.new(
        "#{@service.service_name} has an invalid credential key", payload: @payload
      )
    end

    def interpolated_uri
      @uri_params.reduce(@service.uri) do |uri, (key, value)|
        uri.gsub(":#{key}", value.to_s)
      end
    end
  end
end

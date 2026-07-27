# frozen_string_literal: true

require 'net/http'

module Integrations
  # Adaptador HTTP genérico (Data-Driven): se comunica con cualquier API externa
  # usando la plantilla del Service (uri, http_method y mappers) y las
  # credenciales cifradas de la CompanyIntegration, sin lógica por proveedor.
  class HttpAdapter < ApplicationPoro
    OPEN_TIMEOUT = 10
    READ_TIMEOUT = 10

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

    def initialize(company_integration:, payload: {}, uri_params: {})
      super()
      @integration = company_integration
      @service = company_integration.service
      @payload = payload
      @uri_params = uri_params
    end

    def call
      response = execute(build_request)
      handle(response)
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
      http.open_timeout = OPEN_TIMEOUT
      http.read_timeout = READ_TIMEOUT
      http.request(request)
    end

    def handle(response)
      raise_http_error(response) unless response.is_a?(Net::HTTPSuccess)

      ParseExternalResponse.new(service: @service, response_body: parse_json(response.body)).call
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
        if key == 'access_token'
          result['Authorization'] = "Bearer #{value}"
        else
          result[key] = value.to_s
        end
      end
    end

    def interpolated_uri
      @uri_params.reduce(@service.uri) do |uri, (key, value)|
        uri.gsub(":#{key}", value.to_s)
      end
    end
  end
end

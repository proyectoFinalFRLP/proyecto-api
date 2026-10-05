# frozen_string_literal: true

require 'net/http'

module Integrations
  # Pide un token al proveedor con el grant `client_credentials` (RFC 6749
  # §4.4): el body viaja form-urlencoded y la respuesta es un JSON con
  # `access_token` y `expires_in`. Sólo pide: guardarlo y decidir cuándo
  # renovarlo es de Integrations::EnsureAccessToken.
  #
  # Ningún mensaje de error incluye el body de la respuesta ni los datos del
  # pedido: el pedido lleva el client_secret.
  class RequestClientCredentialsToken < ApplicationPoro
    def initialize(token_url:, client:, service_name:, timeouts: HttpAdapter::TIMEOUTS)
      super()
      @uri = URI(token_url)
      @client = client
      @service_name = service_name
      @timeouts = timeouts
    end

    def call
      response = execute
      raise_http_error(response) unless response.is_a?(Net::HTTPSuccess)

      parse(response.body)
    rescue *HttpAdapter::NETWORK_ERRORS => e
      raise AdapterExecutionError, "#{@service_name} token request failed: #{e.class}"
    end

    private

    def execute
      request = Net::HTTP::Post.new(@uri)
      request['Accept'] = 'application/json'
      request.set_form_data(@client.merge('grant_type' => 'client_credentials'))

      http = Net::HTTP.new(@uri.host, @uri.port)
      http.use_ssl = @uri.scheme == 'https'
      http.open_timeout = @timeouts[:open]
      http.read_timeout = @timeouts[:read]
      http.request(request)
    end

    # El proveedor explica el rechazo en el body (Shopify, en el <title> de una
    # página HTML: `Oauth error app_not_installed`). Se conserva sólo ese código,
    # que es lo que permite saber qué falta sin exponer nada más.
    def raise_http_error(response)
      reason = response.body.to_s[/Oauth error ([a-z_]+)/i, 1]
      detail = reason ? " (#{reason})" : ''
      raise AdapterExecutionError.new(
        "#{@service_name} token request responded with HTTP #{response.code}#{detail}",
        response_status: response.code.to_i
      )
    end

    def parse(body)
      data = JSON.parse(body.to_s)
      token = data['access_token']
      if token.blank?
        raise AdapterExecutionError, "#{@service_name} token response has no access_token"
      end

      { access_token: token, expires_at: Integer(data.fetch('expires_in', 0)).seconds.from_now }
    rescue JSON::ParserError, ArgumentError, TypeError
      raise AdapterExecutionError, "#{@service_name} returned an unreadable token response"
    end
  end
end

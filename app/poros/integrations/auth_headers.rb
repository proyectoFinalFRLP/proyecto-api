# frozen_string_literal: true

module Integrations
  # Los headers de autenticación de un request, según cómo declara autenticarse
  # la plantilla de la integración (`Service#auth_strategy`).
  #
  # Sale siempre de la plantilla conectada, no de la que se ejecuta: una
  # plantilla hija (probar la conexión, buscar una variante) usa la cuenta y el
  # token de su madre.
  class AuthHeaders < ApplicationPoro
    # Charset de nombre de header válido (RFC 9110 token). Net::HTTPHeader no
    # valida la clave: un \r\n en el nombre parte la línea e inyecta headers.
    HEADER_NAME = /\A[A-Za-z0-9!#$%&'*+\-.^_`|~]+\z/

    DEFAULT_TOKEN_HEADER = 'Authorization'
    DEFAULT_TOKEN_PREFIX = 'Bearer '

    def initialize(company_integration:, force_refresh: false)
      super()
      @integration = company_integration
      @force_refresh = force_refresh
    end

    def call
      service.oauth_client_credentials? ? oauth_headers : bearer_headers
    end

    private

    def service = @integration.service

    def oauth_headers
      config = service.auth_config
      header = config.fetch('token_header', DEFAULT_TOKEN_HEADER)
      prefix = config.fetch('token_prefix', DEFAULT_TOKEN_PREFIX)
      token = EnsureAccessToken.new(company_integration: @integration, force: @force_refresh).call

      { header => "#{prefix}#{token}" }
    end

    # Convención de siempre: access_token viaja como Bearer; cualquier otra
    # clave del hash se envía como header literal (ej. X-Api-Key).
    def bearer_headers
      (@integration.credentials || {}).each_with_object({}) do |(key, value), result|
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

      raise AdapterExecutionError, "#{service.service_name} has an invalid credential key"
    end
  end
end

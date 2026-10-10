# frozen_string_literal: true

module Integrations
  # Devuelve un token de acceso vigente para una integración cuya plantilla se
  # autentica con OAuth client credentials, y lo pide de nuevo cuando vence.
  #
  # El client_id y el client_secret son de la empresa (cada una conecta su
  # propia app del proveedor), así que viven cifrados en `credentials`, igual
  # que el token que se obtiene con ellos y su vencimiento.
  #
  # La renovación corre con la fila de la integración bloqueada: dos workers que
  # vean el token vencido a la vez harían dos pedidos, y el segundo pisaría al
  # primero. Adentro del lock se vuelve a mirar, porque el que esperó puede
  # encontrarse con que el otro ya lo renovó.
  class EnsureAccessToken < ApplicationPoro
    # Se renueva un poco antes del vencimiento para que un request no salga con
    # un token que expira en el camino.
    RENEWAL_MARGIN = 5.minutes
    CLIENT_KEYS = %w[client_id client_secret].freeze

    # `force` descarta el token cacheado: lo usa el adaptador cuando el
    # proveedor contesta 401 con un token que parecía vigente.
    def initialize(company_integration:, force: false)
      super()
      @integration = company_integration
      @force = force
    end

    def call
      used_token = @integration.credentials&.dig('access_token')
      return used_token if !@force && fresh?

      @integration.with_lock do
        # Otro worker lo renovó mientras éste esperaba el lock.
        next current_token if fresh? && (!@force || current_token != used_token)

        renew
      end
    end

    private

    def service = @integration.service

    def credentials = @integration.credentials || {}

    def current_token = credentials['access_token']

    def fresh?
      expires_at = credentials['token_expires_at']
      current_token.present? && expires_at.present? &&
        Time.zone.parse(expires_at) > RENEWAL_MARGIN.from_now
    end

    def renew
      token = RequestClientCredentialsToken.new(
        token_url: token_url, client: client_credentials, service_name: service.service_name
      ).call
      @integration.update!(credentials: credentials.merge(
        'access_token' => token[:access_token],
        'token_expires_at' => token[:expires_at].iso8601
      ))
      token[:access_token]
    end

    def token_url
      InterpolateUri.new(template: service.auth_config.fetch('token_url'),
                         values: @integration.settings).call
    end

    def client_credentials
      CLIENT_KEYS.to_h do |key|
        value = credentials[key]
        if value.blank?
          raise AdapterExecutionError, "#{service.service_name} is missing the credential #{key}"
        end

        [key, value]
      end
    end
  end
end

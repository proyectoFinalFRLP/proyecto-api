# frozen_string_literal: true

module Webhooks
  # Comprueba que un webhook entrante lo mandó el proveedor y no cualquiera que
  # conozca la URL. La plantilla declara cómo firma su proveedor
  # (`services.webhook_config`):
  #
  #   { "signature": "hmac_sha256_base64",
  #     "signature_header": "X-Shopify-Hmac-SHA256",
  #     "secret_key": "client_secret" }
  #
  # se lee como «el header trae el HMAC-SHA256 del body, en base64, calculado
  # con la credencial `client_secret` de la integración». El secreto es de la
  # integración y no de la plantilla porque cada empresa conecta su propia app
  # (ADR-018): una venta firmada con la app de otra empresa no pasa.
  #
  # Se calcula sobre el body crudo, nunca sobre el JSON re-serializado: un
  # espacio o una tilde escapada de otra forma cambian el HMAC.
  #
  # Una plantilla que no declara firma no se verifica (Mercado Libre no firma,
  # los couriers de los seeds tampoco). Una que la declara y no tiene con qué
  # verificarla rechaza el evento: nunca se saltea la verificación.
  class VerifySignature < ApplicationPoro
    ENCODINGS = {
      'hmac_sha256_base64' => ->(digest) { Base64.strict_encode64(digest) },
      'hmac_sha256_hex' => ->(digest) { digest.unpack1('H*') }
    }.freeze

    REQUIRED_KEYS = %w[signature_header secret_key].freeze

    # Lo que le falta a un `webhook_config` para poder verificarse. Vive acá y
    # no en Service porque es este PORO el que sabe qué algoritmos verifica.
    def self.config_problems(config)
      return ['debe ser un objeto'] unless config.is_a?(Hash)
      return [] if config['signature'].blank?

      problems = REQUIRED_KEYS.select { |key| config[key].blank? }.map { |key| "falta #{key}" }
      return problems if ENCODINGS.key?(config['signature'])

      problems << "signature debe ser una de: #{ENCODINGS.keys.join(', ')}"
    end

    def initialize(company_integration:, raw_body:, headers:)
      super()
      @integration = company_integration
      @raw_body = raw_body.to_s
      @headers = headers
    end

    def call
      return unless service.signs_webhooks?

      reject("#{config['signature_header']} header is missing") if received.blank?
      reject("#{config['secret_key']} is not configured") if secret.blank?
      return if ActiveSupport::SecurityUtils.secure_compare(expected, received)

      reject('signature does not match')
    end

    private

    def reject(reason) = raise(InvalidSignatureError, reason)

    def service = @integration.service

    def config = service.webhook_config

    def received = @headers[config['signature_header']].to_s.strip

    def secret
      credentials = @integration.credentials
      credentials.is_a?(Hash) ? credentials[config['secret_key']] : nil
    end

    def expected
      digest = OpenSSL::HMAC.digest('SHA256', secret, @raw_body)
      ENCODINGS.fetch(config['signature']).call(digest)
    end
  end
end

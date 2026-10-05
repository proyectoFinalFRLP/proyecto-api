# frozen_string_literal: true

module Integrations
  # Valida y combina los datos de la cuenta de una empresa contra lo que
  # declara la plantilla (`credential_fields`, `setting_fields`). Es la única
  # fuente de verdad del formulario: agregar un campo a la plantilla lo hace
  # aparecer en el backoffice (Avo::Actions::ConfigureConnection) y validarse
  # acá, sin tocar código.
  #
  # - Un secreto que llega vacío no se cambia: el formulario nunca los precarga
  #   (nadie los devuelve), así que «vacío» quiere decir «dejalo como está».
  # - Un setting que llega vacío se borra: ése sí se precarga y vaciarlo es
  #   deliberado.
  # - Si cambia una credencial, el token cacheado se descarta: se obtuvo con la
  #   anterior.
  class ApplyDeclaredFields < ApplicationPoro
    TOKEN_KEYS = %w[access_token token_expires_at].freeze

    def initialize(service:, integration:, credentials:, settings:)
      super()
      @service = service
      @integration = integration
      @credentials_in = normalize(credentials)
      @settings_in = normalize(settings)
    end

    # [credenciales, settings] combinados con lo que ya tenía la integración.
    def call
      errors = unknown_errors
      credentials = merged_credentials
      settings = merged_settings
      errors.merge!(declared_errors('credentials', @service.credential_fields, credentials))
      errors.merge!(declared_errors('settings', @service.setting_fields, settings))
      raise InvalidIntegrationError, errors if errors.any?

      [credentials, settings]
    end

    private

    def normalize(values) = (values || {}).to_h.transform_keys(&:to_s)

    def unknown_errors
      unknown = unknown_keys('credentials', @credentials_in, @service.credential_fields) +
                unknown_keys('settings', @settings_in, @service.setting_fields)
      unknown.index_with { ['unknown'] }
    end

    def unknown_keys(scope, values, specs)
      declared = specs.pluck('key')
      (values.keys - declared).map { |key| "#{scope}.#{key}" }
    end

    def merged_credentials
      stored = @integration.credentials || {}
      provided = @credentials_in.select { |_key, value| value.to_s.strip.present? }
      merged = stored.merge(provided)
      changed = provided.any? { |key, value| stored[key] != value }
      changed ? merged.except(*TOKEN_KEYS) : merged
    end

    def merged_settings
      merged = (@integration.settings || {}).merge(@settings_in)
      merged.reject { |_key, value| value.to_s.strip.empty? }
    end

    def declared_errors(scope, specs, values)
      specs.each_with_object({}) do |spec, errors|
        code = field_error(spec, values[spec['key']])
        errors["#{scope}.#{spec['key']}"] = [code] if code
      end
    end

    def field_error(spec, value)
      return (spec['required'] ? 'required' : nil) if value.to_s.strip.empty?
      return if spec['format'].blank?

      'invalid_format' unless Regexp.new(spec['format']).match?(value.to_s)
    end
  end
end

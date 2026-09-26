# frozen_string_literal: true

module Integrations
  # «Probar conexión»: comprueba que la empresa puede hablar con el proveedor
  # usando su cuenta, sin tocar datos de negocio.
  #
  # Si la plantilla declara una hija `connection_test`, la ejecuta. Lo que
  # contesta sirve además para completar la configuración que la empresa no
  # tiene por qué conocer: los settings declarados por la plantilla que siguen
  # vacíos y vienen en la respuesta (en Shopify, `location_id`, la ubicación
  # donde se publica el stock).
  #
  # Nunca propaga el error del proveedor: lo devuelve como mensaje, que es lo
  # que la pantalla le muestra al usuario.
  class TestConnection < ApplicationPoro
    OPERATION = :connection_test
    ACCOUNT_NAME_KEY = 'account_name'

    def initialize(company_integration:)
      super()
      @integration = company_integration
    end

    def call
      template = service.template_for(OPERATION)
      return without_test_template if template.nil?

      response = HttpAdapter.new(company_integration: @integration, service: template).call
      complete_settings(response)
      { ok: true, message: success_message(response) }
    rescue AdapterExecutionError => e
      { ok: false, message: e.message }
    end

    private

    def service = @integration.service

    # Sin hija de prueba, lo único verificable es obtener el token.
    def without_test_template
      unless service.oauth_client_credentials?
        return { ok: false, message: "#{service.service_name} does not declare a connection test" }
      end

      EnsureAccessToken.new(company_integration: @integration).call
      { ok: true, message: "#{service.service_name}: access token obtained" }
    end

    def complete_settings(response)
      settings = @integration.settings || {}
      missing = service.setting_keys.select { |key| settings[key].blank? && response[key].present? }
      return if missing.empty?

      @integration.update!(settings: settings.merge(response.slice(*missing)))
    end

    def success_message(response)
      name = response[ACCOUNT_NAME_KEY]
      name.present? ? "Connected to #{name}" : "#{service.service_name}: connection verified"
    end
  end
end

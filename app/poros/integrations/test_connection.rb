# frozen_string_literal: true

module Integrations
  # «Probar conexión»: comprueba que la empresa puede hablar con el proveedor
  # usando su cuenta, sin tocar datos de negocio.
  #
  # Si la plantilla declara una hija `connection_test`, la ejecuta. Lo que
  # contesta sirve además para completar la configuración que la empresa no
  # tiene por qué conocer: los settings declarados por la plantilla que siguen
  # vacíos y vienen en la respuesta (en Shopify, `location_id`, la ubicación
  # donde se publica el stock). Y guarda el nombre de la cuenta
  # (`account_name`), que es lo que la empresa ve para saber a qué cuenta está
  # conectada: ése se pisa siempre, porque la cuenta se puede renombrar.
  #
  # Nunca propaga el error del proveedor: lo devuelve como mensaje, que es lo
  # que la pantalla le muestra al usuario.
  #
  # Una respuesta en la que no se encuentra nada de lo que la plantilla mapea
  # también es un fallo: hay proveedores que contestan una cuenta inexistente
  # con un 200 vacío (OCA devuelve un DataSet sin filas, TESIS-186).
  #
  # Opciones (TESIS-177): si la respuesta trae una lista de valores posibles
  # para un setting —una entrada de colección del response_mapper que mapea la
  # clave del setting, más `option_label` para nombrarla—, se guardan en
  # `settings['setting_options']` y el formulario de «Configure connection»
  # ofrece ese setting como una lista para elegir. Con más de una opción, el
  # setting ya no se completa solo con la primera: elegir la ubicación de stock
  # equivocada publica el stock donde nadie lo mira.
  class TestConnection < ApplicationPoro
    OPERATION = :connection_test
    ACCOUNT_NAME_KEY = 'account_name'
    OPTIONS_KEY = 'setting_options'
    OPTION_LABEL_KEY = 'option_label'

    def initialize(company_integration:)
      super()
      @integration = company_integration
    end

    def call
      template = service.template_for(OPERATION)
      return without_test_template if template.nil?

      body = HttpAdapter.new(company_integration: @integration, service: template).fetch
      response = ParseExternalResponse.new(service: template, response_body: body).call
      return empty_answer(template) if response.empty? && template.response_mapper.any?

      options = setting_options(template, body)
      complete_settings(response, options)
      { ok: true, message: success_message(response, options) }
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

    def empty_answer(template)
      { ok: false,
        message: "#{template.service_name} answered without account data: check the credentials" }
    end

    # { clave del setting => { etiqueta => valor } } de los settings declarados
    # para los que el proveedor contestó una lista.
    def setting_options(template, body)
      rows = ParseExternalCollection.new(service: template, payload: body).call
      service.setting_keys.each_with_object({}) do |key, options|
        choices = rows.select { |row| row[key].present? }
                      .to_h { |row| [option_label(row, key), row[key].to_s] }
        options[key] = choices if choices.any?
      end
    end

    def option_label(row, key)
      label = row[OPTION_LABEL_KEY]
      label.present? ? "#{label} (#{row[key]})" : row[key].to_s
    end

    # Un setting con más de una opción no se completa solo: lo elige el
    # administrador.
    def complete_settings(response, options)
      settings = @integration.settings || {}
      missing = service.setting_keys.select do |key|
        settings[key].blank? && response[key].present? && options.fetch(key, {}).size <= 1
      end
      learned = response.slice(*missing, ACCOUNT_NAME_KEY).compact_blank
      updated = settings.merge(learned).merge(OPTIONS_KEY => options.presence).compact
      return if updated == settings

      @integration.update!(settings: updated)
    end

    def success_message(response, options)
      name = response[ACCOUNT_NAME_KEY]
      verified = "#{service.service_name}: connection verified"
      verified = "Connected to #{name}" if name.present?
      [verified, *pending_choices(options)].join('. ')
    end

    # Los settings que siguen vacíos porque hay que elegir entre varias opciones.
    def pending_choices(options)
      settings = @integration.settings || {}
      options.filter_map do |key, choices|
        next if settings[key].present? || choices.size <= 1

        "Choose the #{label_for(key)} in «Configure connection»: there are #{choices.size} options"
      end
    end

    def label_for(key)
      service.setting_fields.find { |spec| spec['key'] == key }&.dig('label').presence || key
    end
  end
end

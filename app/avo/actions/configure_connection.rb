# frozen_string_literal: true

module Avo
  module Actions
    # Carga la cuenta de una empresa en un proveedor: un campo por cada dato que
    # declara la plantilla (`credential_fields`, `setting_fields`).
    #
    # Las credenciales las carga el equipo de OneStock, no la empresa (ADR-018):
    # la empresa se las pasa al administrador y él las carga acá. La API de la
    # empresa sólo lee el estado de sus integraciones.
    #
    # - Los secretos nunca se muestran ni se precargan: vacío quiere decir «dejá
    #   el que está» (Integrations::ApplyDeclaredFields, que también valida).
    # - La configuración sí se precarga, y vaciarla la borra.
    # - Después de guardar prueba la conexión si la plantilla sabe hacerlo: en
    #   Shopify eso completa la ubicación donde se publica el stock.
    class ConfigureConnection < Avo::BaseAction
      CREDENTIAL_PREFIX = 'credentials__'
      SETTING_PREFIX = 'settings__'
      STORED_HELP = 'Already set: leave blank to keep it.'

      self.name = 'Configure connection'
      self.message = 'Secrets are never shown. Leave a secret blank to keep the one already stored.'
      self.confirm_button_label = 'Save'
      self.visible = -> { view.show? && resource.record&.service&.declares_fields? }

      def fields
        service = record&.service
        return if service.nil?

        service.credential_fields.each { |spec| credential_field(spec) }
        service.setting_fields.each { |spec| setting_field(spec) }
      end

      def handle(query:, fields:, **)
        integration = query.first
        save(integration, fields)
        report_test(integration)
        reload
      rescue ::Integrations::InvalidIntegrationError => e
        error(invalid_fields_message(integration.service, e.fields))
        keep_modal_open
      end

      private

      def credential_field(spec)
        stored = record.credentials.is_a?(Hash) && record.credentials[spec['key']].present?
        field :"#{CREDENTIAL_PREFIX}#{spec['key']}", as: :password, name: spec['label'],
                                                     help: (STORED_HELP if stored)
      end

      def setting_field(spec)
        field :"#{SETTING_PREFIX}#{spec['key']}", as: :text, name: spec['label'],
                                                  default: record.settings[spec['key']]
      end

      def save(integration, fields)
        credentials, settings = ::Integrations::ApplyDeclaredFields.new(
          service: integration.service, integration: integration,
          credentials: values_with_prefix(fields, CREDENTIAL_PREFIX),
          settings: values_with_prefix(fields, SETTING_PREFIX)
        ).call
        integration.update!(credentials:, settings:)
      end

      def values_with_prefix(fields, prefix)
        fields.to_h
              .select { |key, _value| key.start_with?(prefix) }
              .transform_keys { |key| key.delete_prefix(prefix) }
      end

      def report_test(integration)
        return succeed('Connection saved.') unless integration.service.connection_testable?

        result = ::Integrations::TestConnection.new(company_integration: integration).call
        if result[:ok]
          succeed("Connection saved. #{result[:message]}.")
        else
          warn("Connection saved, but the test failed: #{result[:message]}")
        end
      end

      # «Client ID: required; Shop domain: invalid_format», con el nombre que ve
      # el administrador en el formulario.
      def invalid_fields_message(service, fields)
        labels = (service.credential_fields.map { |spec| ['credentials', spec] } +
                  service.setting_fields.map { |spec| ['settings', spec] })
                 .to_h { |scope, spec| ["#{scope}.#{spec['key']}", spec['label']] }
        fields.map { |key, codes| "#{labels.fetch(key, key)}: #{codes.join(', ')}" }.join('; ')
      end
    end
  end
end

# frozen_string_literal: true

module Avo
  module Actions
    # «Probar conexión» desde el backoffice: llama al proveedor con la cuenta de
    # la empresa sin tocar datos de negocio (Integrations::TestConnection). Si el
    # proveedor devuelve configuración que faltaba, la completa.
    class TestConnection < Avo::BaseAction
      self.name = 'Test connection'
      self.message = 'Calls the provider with this account. No business data is changed.'
      self.confirm_button_label = 'Test'
      self.visible = -> { view.show? && resource.record&.service&.connection_testable? }

      def handle(query:, **)
        result = ::Integrations::TestConnection.new(company_integration: query.first).call
        result[:ok] ? succeed(result[:message]) : error(result[:message])
        reload
      end
    end
  end
end

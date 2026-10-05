# frozen_string_literal: true

module Avo
  module Actions
    # «Registrar webhook» desde el backoffice: le pide al proveedor que avise a
    # OneStock de los eventos de esta cuenta (Integrations::RegisterWebhook).
    # «Configure connection» ya lo hace al guardar; esta acción es para cuando
    # cambió la URL pública de la API o el registro falló.
    class RegisterWebhook < Avo::BaseAction
      self.name = 'Register webhook'
      self.message = 'Asks the provider to notify OneStock of this account events.'
      self.confirm_button_label = 'Register'
      self.visible = lambda {
        view.show? && ::Integrations::RegisterWebhook.declared_by?(resource.record&.service)
      }

      def handle(query:, **)
        result = ::Integrations::RegisterWebhook.new(company_integration: query.first).call
        result[:ok] ? succeed(result[:message]) : error(result[:message])
        reload
      end
    end
  end
end

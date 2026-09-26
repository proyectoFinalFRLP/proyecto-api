# frozen_string_literal: true

module Avo
  module Resources
    class CompanyIntegration < Avo::BaseResource
      CREDENTIAL_MASK = '••••••'

      self.title = :display_name
      self.includes = %i[company service]

      # Las credenciales las carga el equipo de OneStock desde acá (ADR-018): se
      # crea la integración (empresa y plantilla) y los datos de la cuenta se
      # cargan con la acción «Configure connection», que valida contra lo que
      # declara la plantilla.
      def fields
        field :id, as: :id
        field :company, as: :belongs_to
        # Una plantilla hija no se conecta sola (CompanyIntegration valida lo mismo).
        field :service, as: :belongs_to, attach_scope: -> { query.connectable }
        # Nace inactiva: la empresa la vería como conectada antes de tener cuenta.
        field :is_active, as: :boolean, default: false,
                          help: 'Activate it once the connection is configured and tested.'
        credentials_field
        field :settings, as: :code, language: 'json', only_on: :show, disabled: true,
                         format_using: -> { JSON.pretty_generate(value || {}) }
        field :product_mappings, as: :has_many, name: 'Product Mappings'
      end

      def actions
        action Avo::Actions::ConfigureConnection
        action Avo::Actions::TestConnection
      end

      def filters
        filter Avo::Filters::CompanyFilter
      end

      private

      # Las credenciales son API keys y tokens de las cuentas de cada empresa, y
      # el backoffice las mostraba descifradas en el detalle y en el formulario
      # (TESIS-129). Ahora dice qué claves hay configuradas, nunca sus valores.
      # El formulario del recurso no las edita: se cargan con «Configure
      # connection», un campo por clave. Editarlas como JSON acá las rompía: el
      # campo de código manda un String y `serialize :credentials` lo guardaba
      # como String, no como Hash.
      #
      # Un valor que no es Hash (una fila que quedó guardada como String) se
      # enmascara entero en vez de romper la página.
      #
      # `disabled` no es redundante con `only_on: :show`: only_on saca el campo
      # del formulario, pero Avo lo sigue aceptando en un PATCH armado a mano.
      def credentials_field
        field :credentials, as: :code, language: 'json', only_on: :show, disabled: true,
                            name: 'Credentials (masked)',
                            format_using: lambda {
                              next CREDENTIAL_MASK unless value.nil? || value.is_a?(Hash)

                              JSON.pretty_generate(value.to_h.transform_values { CREDENTIAL_MASK })
                            }
      end
    end
  end
end

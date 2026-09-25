# frozen_string_literal: true

module Avo
  module Resources
    class CompanyIntegration < Avo::BaseResource
      CREDENTIAL_MASK = '••••••'

      self.title = :display_name
      self.includes = %i[company service]

      def fields
        field :id, as: :id
        field :company, as: :belongs_to
        field :service, as: :belongs_to
        field :is_active, as: :boolean
        credentials_field
        field :product_mappings, as: :has_many, name: 'Product Mappings'
      end

      def filters
        filter Avo::Filters::CompanyFilter
      end

      private

      # Las credenciales son API keys y tokens de las cuentas de cada empresa, y
      # el backoffice las mostraba descifradas en el detalle y en el formulario
      # (TESIS-129). Ahora dice qué claves hay configuradas, nunca sus valores, y
      # no las edita: las carga cada empresa por la API
      # (PUT /api/v1/integrations/:service_id). Editarlas acá además las rompía:
      # el campo de código manda un String y `serialize :credentials` lo
      # guardaba como String, no como Hash.
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
